"""
Agent Dashboard - Flask web UI for monitoring the autonomous coding agent.
Serves at http://localhost:7860
"""

import hmac
import json
import logging
import os
import re
import shutil
import time
import uuid
import hashlib
import secrets
import urllib.request
import urllib.error
from datetime import datetime, timedelta, timezone
from functools import wraps
from pathlib import Path

from flask import (
    Flask, Response, jsonify, render_template, request, abort,
    stream_with_context, redirect, make_response,
)

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET", secrets.token_hex(32))

# ---------------------------------------------------------------------------
# Paths - inside the container these are under /harness/
# ---------------------------------------------------------------------------
HARNESS = Path(os.environ.get("HARNESS_DIR", "/harness"))
JOBS_DIR = HARNESS / "jobs"
LOGS_DIR = HARNESS / "logs"

PENDING = JOBS_DIR / "pending"
RUNNING = JOBS_DIR / "running"
DONE = JOBS_DIR / "done"
FAILED = JOBS_DIR / "failed"

STATUS_DIRS = {
    "pending": PENDING,
    "running": RUNNING,
    "done": DONE,
    "failed": FAILED,
}

HEARTBEAT_FILE = LOGS_DIR / "heartbeat.json"
QUOTA_FILE = LOGS_DIR / "quota-counter.json"
NOTIFICATIONS_LOG = LOGS_DIR / "notifications.log"

CONFIG_DIR = HARNESS / "config"
AUTOQUEUE_CONFIG = CONFIG_DIR / "auto-queue-config.json"
WEBHOOKS_CONFIG = CONFIG_DIR / "webhooks.json"
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "") or os.environ.get("GH_TOKEN", "")
DEFAULT_MODEL = os.environ.get("DEFAULT_MODEL", "claude-sonnet-4-6")
MAX_PENDING_JOBS = int(os.environ.get("MAX_PENDING_JOBS", "0"))  # 0 = unlimited

# Notification channel credentials (optional - only used for /api/notify/test)
_TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
_TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
_DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "")
_WEBHOOK_URL = os.environ.get("WEBHOOK_URL", "")

# Auth token from env; if not set, auth is disabled (dev mode)
DASHBOARD_TOKEN = os.environ.get("DASHBOARD_TOKEN", "")
TOKEN_COOKIE = "dash_token"

# PR URL pattern compiled once
_PR_URL_RE = re.compile(r'https://github\.com/[^\s"\']+/pull/\d+')

# Notification line pattern compiled once
_NOTIF_RE = re.compile(r'\[(.+?)\]\s+\[NOTIFY\]\s+(\S+)\s+(\S+)\s*(.*)')

# Cost extraction pattern (matches "cost=1.2345" in cleanup event detail)
_COST_RE = re.compile(r'cost=([0-9.]+)')

# GitHub PR URL parser: https://github.com/{owner}/{repo}/pull/{number}
_PR_GITHUB_RE = re.compile(r'github\.com/([^/]+)/([^/\s"\']+)/pull/(\d+)')

# ---------------------------------------------------------------------------
# Performance caches
# ---------------------------------------------------------------------------
# Maximum number of entries for per-job caches (prevents unbounded growth)
_CACHE_MAX = 1000


def _cache_set(cache: dict, key: str, value) -> None:
    """Insert into cache dict, evicting the oldest entry when at capacity (FIFO-LRU)."""
    if key in cache:
        cache[key] = value
        return
    if len(cache) >= _CACHE_MAX:
        try:
            del cache[next(iter(cache))]
        except StopIteration:
            pass
    cache[key] = value


# Duration cache: keyed by job_id; persists for done/failed jobs (bounded)
_duration_cache: dict[str, int | None] = {}

# Per-job cost cache: keyed by job_id; persists for done/failed jobs (bounded)
_cost_per_job_cache: dict[str, float | None] = {}

# Costs cache: TTL-based to avoid full-scan on every request
_costs_cache: dict = {"data": None, "ts": 0.0}
_COSTS_TTL = 60.0  # seconds

# Metrics cache: aggregated success/cost/duration stats
_metrics_cache: dict = {"data": None, "ts": 0.0}
_METRICS_TTL = 120.0  # seconds

# Activity cache: short-lived to avoid N+1 on fast-polling UIs
_activity_cache: dict = {"data": None, "ts": 0.0}
_ACTIVITY_TTL = 10.0  # seconds

# Prometheus metrics cache (text format)
_prom_cache: dict = {"data": None, "ts": 0.0}
_PROM_TTL = 15.0  # seconds

# Log endpoint: refuse to load more than this many bytes into memory at once
MAX_LOG_BYTES = 5 * 1024 * 1024  # 5 MB

# ---------------------------------------------------------------------------
# Login rate limiting
# ---------------------------------------------------------------------------
_login_attempts: dict[str, list[float]] = {}  # ip → [attempt_timestamps]
_RATE_LIMIT_WINDOW = 60.0   # sliding window in seconds
_RATE_LIMIT_MAX = 5         # max failed attempts within the window
_RATE_LIMIT_LOCKOUT = 30.0  # extra lockout after hitting the limit


def _is_rate_limited(ip: str) -> bool:
    """Return True if the IP has hit the failed-login rate limit."""
    now = time.time()
    attempts = [t for t in _login_attempts.get(ip, []) if now - t < _RATE_LIMIT_WINDOW]
    _login_attempts[ip] = attempts
    return len(attempts) >= _RATE_LIMIT_MAX


def _record_login_attempt(ip: str) -> None:
    """Record a failed login attempt for rate-limiting purposes."""
    now = time.time()
    attempts = [t for t in _login_attempts.get(ip, []) if now - t < _RATE_LIMIT_WINDOW]
    attempts.append(now)
    _login_attempts[ip] = attempts


# ===== Request Logging Middleware ===========================================

_req_logger = logging.getLogger("dashboard.requests")
logging.basicConfig(
    level=logging.INFO,
    format='%(message)s',
)


@app.before_request
def _log_request_start():
    request._start_ts = time.time()  # type: ignore[attr-defined]


@app.after_request
def _log_request_end(response):
    try:
        elapsed = round((time.time() - getattr(request, "_start_ts", time.time())) * 1000, 1)
        _req_logger.info(json.dumps({
            "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "method": request.method,
            "path": request.path,
            "status": response.status_code,
            "elapsed_ms": elapsed,
            "ip": request.remote_addr,
        }))
    except Exception:
        pass
    return response


# ===== Security Middleware ==================================================

@app.after_request
def add_security_headers(response):
    """Add security headers to all responses."""
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "0"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    # CSP: inline scripts/styles are required by the SPA; restrict all other sources to 'self'
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; "
        "script-src 'self' 'unsafe-inline'; "
        "style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data:; "
        "connect-src 'self'; "
        "font-src 'self'; "
        "frame-ancestors 'none';"
    )
    if request.is_secure:
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return response


# ===== Auth =================================================================

def _hash_token(tok: str) -> str:
    return hashlib.sha256(tok.encode()).hexdigest()


def _check_auth() -> bool:
    """Return True if the request is authenticated (or auth is disabled)."""
    if not DASHBOARD_TOKEN:
        return True
    expected = _hash_token(DASHBOARD_TOKEN)
    # Check cookie (timing-safe comparison)
    cookie = request.cookies.get(TOKEN_COOKIE, "")
    if cookie and hmac.compare_digest(_hash_token(cookie), expected):
        return True
    # Check Authorization header (for API clients)
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        if hmac.compare_digest(_hash_token(auth[7:]), expected):
            return True
    return False


def require_auth(f):
    """Decorator to protect routes with token auth."""
    @wraps(f)
    def decorated(*args, **kwargs):
        if not _check_auth():
            if request.path.startswith("/api/"):
                return jsonify({"error": "Unauthorized"}), 401
            return redirect("/login")
        return f(*args, **kwargs)
    return decorated


@app.route("/login", methods=["GET", "POST"])
def login():
    if not DASHBOARD_TOKEN:
        return redirect("/")
    if request.method == "POST":
        ip = request.remote_addr or "unknown"
        if _is_rate_limited(ip):
            return render_template(
                "login.html",
                error="試行回数が多すぎます。しばらく待ってから再試行してください。"
            ), 429
        token = request.form.get("token", "").strip()
        if hmac.compare_digest(_hash_token(token), _hash_token(DASHBOARD_TOKEN)):
            # Clear failed attempts on successful login
            _login_attempts.pop(ip, None)
            resp = make_response(redirect("/"))
            resp.set_cookie(
                TOKEN_COOKIE, token, httponly=True, samesite="Lax",
                secure=request.is_secure, max_age=60 * 60 * 24 * 30,
            )
            return resp
        _record_login_attempt(ip)
        return render_template("login.html", error="Invalid token")
    return render_template("login.html", error=None)


@app.route("/logout")
def logout():
    resp = make_response(redirect("/login"))
    resp.delete_cookie(TOKEN_COOKIE)
    return resp


# ===== Data Access Helpers ==================================================

def _read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _read_jsonl(path: Path) -> list[dict]:
    """Read a JSONL file and return list of parsed events."""
    if not path.exists():
        return []
    events = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line:
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return events


def _log_path(job_id: str) -> Path:
    return LOGS_DIR / f"{job_id}.log"


def _jsonl_path(job_id: str) -> Path:
    return LOGS_DIR / f"{job_id}.jsonl"


def _sanitize_job_id(job_id: str) -> str:
    """Remove path traversal chars from job id."""
    return re.sub(r'[^a-zA-Z0-9_\-]', '', job_id)


def _extract_pr_url(log_path: Path) -> str | None:
    """Extract PR URL from log file, reading only the last 8KB for performance."""
    if not log_path.exists():
        return None
    try:
        size = log_path.stat().st_size
        read_size = min(size, 8192)
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            if size > read_size:
                f.seek(size - read_size)
            text = f.read()
        m = _PR_URL_RE.search(text)
        if m:
            return m.group(0)
        # Fallback: if not found in tail, scan full file only for small files
        if size > read_size and size < 1_000_000:
            text = log_path.read_text(encoding="utf-8", errors="replace")
            m = _PR_URL_RE.search(text)
            return m.group(0) if m else None
        return None
    except Exception:
        return None


def _get_job_duration(job_id: str) -> dict:
    """Calculate job duration from JSONL events."""
    events = _read_jsonl(_jsonl_path(job_id))
    if not events:
        return {"duration_sec": None, "start": None, "end": None}
    return {
        "duration_sec": events[-1].get("elapsed_sec"),
        "start": events[0].get("timestamp"),
        "end": events[-1].get("timestamp"),
    }


def _get_cached_duration(job_id: str, status: str) -> int | None:
    """Return job duration, using a bounded in-memory cache for completed jobs."""
    if status == "pending":
        return None
    if status in ("done", "failed") and job_id in _duration_cache:
        return _duration_cache[job_id]
    dur = _get_job_duration(job_id)["duration_sec"]
    if status in ("done", "failed"):
        _cache_set(_duration_cache, job_id, dur)
    return dur


def _get_job_cost(job_id: str) -> float | None:
    """Extract cost_usd from per-job JSONL events."""
    events = _read_jsonl(_jsonl_path(job_id))
    for ev in reversed(events):
        m = _COST_RE.search(ev.get("detail", ""))
        if m:
            return round(float(m.group(1)), 4)
    return None


def _get_cached_cost(job_id: str, status: str) -> float | None:
    """Return job cost, using a bounded in-memory cache for completed jobs."""
    if status == "pending":
        return None
    if status in ("done", "failed") and job_id in _cost_per_job_cache:
        return _cost_per_job_cache[job_id]
    cost = _get_job_cost(job_id)
    if status in ("done", "failed"):
        _cache_set(_cost_per_job_cache, job_id, cost)
    return cost


# ===== API Response Helpers =================================================

def _api_response(data, status_code: int = 200):
    """Wrap data in a standard envelope: {"success": true, "data": ..., "ts": ...}.

    Callers that need the old flat format can request ?format=legacy on any endpoint
    that explicitly supports it. New endpoints should use this wrapper.
    """
    if request.args.get("format") == "legacy":
        return jsonify(data), status_code
    envelope = {
        "success": status_code < 400,
        "data": data,
        "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    return jsonify(envelope), status_code


# ===== Job Data Access ======================================================

def _list_jobs(status: str | None = None) -> list[dict]:
    jobs = []
    dirs = [status] if status and status in STATUS_DIRS else STATUS_DIRS.keys()
    for s in dirs:
        d = STATUS_DIRS[s]
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.json"), reverse=True):
            data = _read_json(f)
            if data:
                data["status"] = s
                jobs.append(data)
    jobs.sort(key=lambda j: j.get("id", ""), reverse=True)
    return jobs


def _find_job(job_id: str) -> tuple[dict | None, str | None]:
    for s, d in STATUS_DIRS.items():
        p = d / f"{job_id}.json"
        if p.exists():
            data = _read_json(p)
            if data:
                data["status"] = s
                return data, s
    return None, None


def _build_status_payload() -> dict:
    """Build the status payload (shared by REST endpoint and SSE stream)."""
    heartbeat = _read_json(HEARTBEAT_FILE) or {}
    quota = _read_json(QUOTA_FILE) or {}
    counts = {}
    for s, d in STATUS_DIRS.items():
        counts[s] = len(list(d.glob("*.json"))) if d.is_dir() else 0
    return {
        "heartbeat": heartbeat,
        "quota": quota,
        "counts": counts,
        "model": DEFAULT_MODEL,
        "server_time": datetime.now(timezone.utc).isoformat(),
    }


def _generate_job_id(slug_source: str) -> str:
    """Generate a timestamped job ID with a slug derived from the source text."""
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    slug = re.sub(r'[^a-z0-9-]', '', slug_source.lower().replace(' ', '-'))[:40]
    if not slug:
        slug = uuid.uuid4().hex[:8]
    return f"{ts}-{slug}"


def _write_pending_job(job: dict) -> Path:
    """Write a job JSON file to the pending directory."""
    PENDING.mkdir(parents=True, exist_ok=True)
    out = PENDING / f"{job['id']}.json"
    out.write_text(json.dumps(job, indent=2, ensure_ascii=False), encoding="utf-8")
    return out


# ===== Page routes ==========================================================

@app.route("/")
@require_auth
def index():
    return render_template("index.html")


# ===== API: Status ==========================================================

@app.route("/api/status")
@require_auth
def api_status():
    return jsonify(_build_status_payload())


# ===== API: Jobs ============================================================

@app.route("/api/jobs")
@require_auth
def api_jobs():
    status_filter = request.args.get("status", "all")
    if status_filter == "all":
        jobs = _list_jobs()
    else:
        jobs = _list_jobs(status_filter)

    # Pagination
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 50, type=int), 200)
    total = len(jobs)
    start = (page - 1) * per_page
    jobs_page = jobs[start:start + per_page]

    # Enrich with duration and cost data to avoid N+1 frontend calls
    if request.args.get("enrich") != "false":
        for job in jobs_page:
            status = job.get("status", "")
            if status != "pending":
                job["duration_sec"] = _get_cached_duration(job["id"], status)
                job["cost_usd"] = _get_cached_cost(job["id"], status)
            else:
                job["duration_sec"] = None
                job["cost_usd"] = None

    resp = jsonify(jobs_page)
    resp.headers["X-Total-Count"] = total
    resp.headers["X-Page"] = page
    resp.headers["X-Per-Page"] = per_page
    return resp


@app.route("/api/jobs/<job_id>")
@require_auth
def api_job_detail(job_id: str):
    job_id = _sanitize_job_id(job_id)
    data, status = _find_job(job_id)
    if not data:
        abort(404, description="Job not found")
    data["pr_url"] = _extract_pr_url(_log_path(job_id))
    # Retry count: use field from job JSON if already written by run-job.sh,
    # otherwise count job_start events (each retry emits one).
    if "retry_count" not in data:
        evs = _read_jsonl(_jsonl_path(job_id))
        starts = sum(1 for e in evs if e.get("event") == "job_start")
        data["retry_count"] = max(0, starts - 1)
    return jsonify(data)


# ===== API: Search ==========================================================

@app.route("/api/search")
@require_auth
def api_search():
    """Full-text search across all jobs by task description, repo URL, or job ID.

    Query parameter:
        q   - search string (minimum 2 characters)

    Returns up to 50 matches sorted by status priority then id descending.
    """
    q = request.args.get("q", "").strip().lower()
    if len(q) < 2:
        return jsonify([])

    _STATUS_ORDER = {"running": 0, "pending": 1, "done": 2, "failed": 3}
    results: list[dict] = []

    for s in ("running", "pending", "done", "failed"):
        d = STATUS_DIRS[s]
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.json"), reverse=True):
            data = _read_json(f)
            if not data:
                continue
            if (q in data.get("task", "").lower()
                    or q in data.get("repo", "").lower()
                    or q in data.get("id", "").lower()):
                data["status"] = s
                results.append(data)

    results.sort(key=lambda j: (_STATUS_ORDER.get(j.get("status", ""), 4), j.get("id", "")))
    return jsonify(results[:50])


@app.route("/api/jobs", methods=["POST"])
@require_auth
def api_create_job():
    body = request.get_json(force=True)
    repo = body.get("repo", "").strip()
    task = body.get("task", "").strip()
    if not repo or not task:
        abort(400, description="'repo' and 'task' are required")

    # Pending queue depth limit (0 = unlimited)
    if MAX_PENDING_JOBS > 0:
        pending_count = len(list(PENDING.glob("*.json"))) if PENDING.is_dir() else 0
        if pending_count >= MAX_PENDING_JOBS:
            abort(429, description=f"Pending queue is full ({pending_count}/{MAX_PENDING_JOBS}). Wait for jobs to be processed.")

    setup_cmds = body.get("setup", [])
    test_cmds = body.get("test", [])
    if isinstance(setup_cmds, str):
        setup_cmds = [c.strip() for c in setup_cmds.split("\n") if c.strip()]
    if isinstance(test_cmds, str):
        test_cmds = [c.strip() for c in test_cmds.split("\n") if c.strip()]

    job_id = _generate_job_id(task)
    priority = max(1, min(5, int(body.get("priority", 3))))
    job = {
        "id": job_id,
        "repo": repo,
        "base_ref": body.get("base_ref", "main"),
        "work_branch": f"agent/{job_id}",
        "task": task,
        "commands": {"setup": setup_cmds, "test": test_cmds},
        "time_budget_sec": int(body.get("time_budget", 3600)),
        "max_retries": int(body.get("max_retries", 2)),
        "gpu_required": bool(body.get("gpu_required", False)),
        "priority": priority,
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    if body.get("issue_number") and body.get("issue_repo"):
        job["issue_number"] = int(body["issue_number"])
        job["issue_repo"] = str(body["issue_repo"])

    _write_pending_job(job)
    return jsonify(job), 201


@app.route("/api/jobs/batch", methods=["POST"])
@require_auth
def api_create_jobs_batch():
    """Create up to 50 jobs atomically in a single request.

    Request body: {"jobs": [{"repo": "...", "task": "...", ...}, ...]}
    Returns: {"created": [...], "errors": [...]}
    """
    body = request.get_json(force=True) or {}
    job_specs = body.get("jobs", [])
    if not isinstance(job_specs, list) or not job_specs:
        abort(400, description="'jobs' must be a non-empty array")
    if len(job_specs) > 50:
        abort(400, description="Batch size limit is 50 jobs per request")

    # Pending queue depth limit (0 = unlimited)
    if MAX_PENDING_JOBS > 0:
        pending_count = len(list(PENDING.glob("*.json"))) if PENDING.is_dir() else 0
        remaining = MAX_PENDING_JOBS - pending_count
        if remaining <= 0:
            abort(429, description=f"Pending queue is full ({pending_count}/{MAX_PENDING_JOBS})")
        job_specs = job_specs[:remaining]  # trim to available slots

    created = []
    errors = []

    for i, spec in enumerate(job_specs):
        if not isinstance(spec, dict):
            errors.append({"index": i, "error": "job spec must be an object"})
            continue
        repo = spec.get("repo", "").strip()
        task = spec.get("task", "").strip()
        if not repo or not task:
            errors.append({"index": i, "error": "'repo' and 'task' are required", "spec": spec})
            continue

        setup_cmds = spec.get("setup", [])
        test_cmds = spec.get("test", [])
        if isinstance(setup_cmds, str):
            setup_cmds = [c.strip() for c in setup_cmds.split("\n") if c.strip()]
        if isinstance(test_cmds, str):
            test_cmds = [c.strip() for c in test_cmds.split("\n") if c.strip()]

        try:
            job_id = _generate_job_id(task)
            priority = max(1, min(5, int(spec.get("priority", 3))))
            job = {
                "id": job_id,
                "repo": repo,
                "base_ref": spec.get("base_ref", "main"),
                "work_branch": f"agent/{job_id}",
                "task": task,
                "commands": {"setup": setup_cmds, "test": test_cmds},
                "time_budget_sec": int(spec.get("time_budget", 3600)),
                "max_retries": int(spec.get("max_retries", 2)),
                "gpu_required": bool(spec.get("gpu_required", False)),
                "priority": priority,
                "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "batch_index": i,
            }
            _write_pending_job(job)
            created.append(job)
        except Exception as e:
            errors.append({"index": i, "error": str(e)[:200], "spec": spec})

    status_code = 201 if created else 400
    return jsonify({"created": created, "errors": errors, "total_created": len(created)}), status_code


@app.route("/api/jobs/<job_id>", methods=["DELETE"])
@require_auth
def api_delete_job(job_id: str):
    job_id = _sanitize_job_id(job_id)
    p = PENDING / f"{job_id}.json"
    if not p.exists():
        abort(404, description="Pending job not found (can only cancel pending jobs)")
    p.unlink()
    return jsonify({"deleted": job_id})


@app.route("/api/jobs/<job_id>/cancel", methods=["POST"])
@require_auth
def api_cancel_job(job_id: str):
    """Cancel a pending or running job.

    Pending jobs are removed immediately.
    Running jobs are marked cancelled=true so run-job.sh stops on next
    state-transition check; SIGTERM is also sent if agent_pid is recorded.
    """
    job_id = _sanitize_job_id(job_id)

    # Pending → delete immediately
    p = PENDING / f"{job_id}.json"
    if p.exists():
        p.unlink()
        return jsonify({"cancelled": job_id, "was": "pending"})

    # Running → set cancelled flag + signal the process
    r = RUNNING / f"{job_id}.json"
    if r.exists():
        data = _read_json(r)
        if data is None:
            abort(404, description="Could not read running job file")
        data["cancelled"] = True
        r.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")

        # Best-effort SIGTERM (works when dashboard and agent share the same OS)
        agent_pid = data.get("agent_pid")
        if agent_pid:
            import signal as _signal
            try:
                import os as _os
                _os.kill(int(agent_pid), _signal.SIGTERM)
            except (ProcessLookupError, PermissionError, ValueError):
                pass  # process already gone or cross-container

        return jsonify({"cancelled": job_id, "was": "running"})

    abort(404, description="Job not found in pending or running state")


# ===== API: Job Re-run ======================================================

@app.route("/api/jobs/<job_id>/rerun", methods=["POST"])
@require_auth
def api_rerun_job(job_id: str):
    """Re-submit a failed/done job as a new pending job."""
    job_id = _sanitize_job_id(job_id)
    data, status = _find_job(job_id)
    if not data:
        abort(404, description="Job not found")
    if status not in ("done", "failed"):
        abort(400, description="Can only re-run done or failed jobs")

    old_slug = job_id.split("-", 3)[-1] if "-" in job_id else job_id
    new_id = _generate_job_id(old_slug or "rerun")

    new_job = {
        "id": new_id,
        "repo": data.get("repo", ""),
        "base_ref": data.get("base_ref", "main"),
        "work_branch": f"agent/{new_id}",
        "task": data.get("task", ""),
        "commands": data.get("commands", {"setup": [], "test": []}),
        "time_budget_sec": data.get("time_budget_sec", 3600),
        "max_retries": data.get("max_retries", 2),
        "gpu_required": data.get("gpu_required", False),
        "priority": data.get("priority", 3),
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }

    _write_pending_job(new_job)
    return jsonify(new_job), 201


# ===== API: Activity Feed (batch - eliminates N+1) =========================

@app.route("/api/activity")
@require_auth
def api_activity():
    """Return recent activity events across all jobs (server-side aggregation).

    Results are cached for _ACTIVITY_TTL seconds to avoid repeated file I/O
    on fast-polling UIs (e.g., dashboard refreshing every 5 seconds).
    """
    limit = request.args.get("limit", 15, type=int)
    limit = min(limit, 100)

    now = time.time()
    cached = _activity_cache.get("data")
    if cached is not None and (now - _activity_cache.get("ts", 0.0)) < _ACTIVITY_TTL:
        return jsonify(cached[:limit])

    jobs = _list_jobs()
    items = []
    for j in jobs[:10]:
        events = _read_jsonl(_jsonl_path(j["id"]))
        for ev in events[-3:]:
            items.append(ev)

    items.sort(key=lambda e: e.get("timestamp", ""), reverse=True)
    _activity_cache["data"] = items
    _activity_cache["ts"] = now
    return jsonify(items[:limit])


# ===== API: Logs ============================================================

@app.route("/api/logs/<job_id>")
@require_auth
def api_log(job_id: str):
    job_id = _sanitize_job_id(job_id)
    lp = _log_path(job_id)
    if not lp.exists():
        abort(404, description="Log not found")
    tail = request.args.get("tail", type=int)
    if tail:
        from collections import deque
        with open(lp, "r", encoding="utf-8", errors="replace") as f:
            lines = deque(f, maxlen=tail)
        text = "".join(lines)
    else:
        size = lp.stat().st_size
        if size > MAX_LOG_BYTES:
            with open(lp, "r", encoding="utf-8", errors="replace") as f:
                f.seek(size - MAX_LOG_BYTES)
                f.readline()  # skip the partial first line
                text = f.read()
            text = f"[... 先頭部分省略（{size // (1024 * 1024)}MB のログのうち最後の5MBを表示）...]\n" + text
        else:
            text = lp.read_text(encoding="utf-8", errors="replace")
    return Response(text, mimetype="text/plain")


@app.route("/api/logs/<job_id>/events")
@require_auth
def api_log_events(job_id: str):
    job_id = _sanitize_job_id(job_id)
    jp = _jsonl_path(job_id)
    if not jp.exists():
        abort(404, description="Events file not found")
    return jsonify(_read_jsonl(jp))


# ===== API: Notifications ===================================================

@app.route("/api/notifications")
@require_auth
def api_notifications():
    """Return recent notification log entries."""
    if not NOTIFICATIONS_LOG.exists():
        return jsonify([])
    lines = NOTIFICATIONS_LOG.read_text(encoding="utf-8", errors="replace").splitlines()
    tail = request.args.get("tail", 50, type=int)
    entries = []
    for line in lines[-tail:]:
        m = _NOTIF_RE.match(line)
        if m:
            entries.append({
                "timestamp": m.group(1),
                "event": m.group(2),
                "job_id": m.group(3),
                "message": m.group(4),
            })
    return jsonify(entries)


# ===== API: Log Management ==================================================

@app.route("/api/admin/log-stats")
@require_auth
def api_log_stats():
    """Return log file statistics for the management UI."""
    stats = []
    if LOGS_DIR.is_dir():
        for f in sorted(LOGS_DIR.iterdir()):
            if f.suffix in (".log", ".jsonl", ".gz"):
                st = f.stat()
                stats.append({
                    "name": f.name,
                    "size": st.st_size,
                    "modified": datetime.fromtimestamp(
                        st.st_mtime, tz=timezone.utc
                    ).isoformat(),
                })
    total = sum(s["size"] for s in stats)
    return jsonify({"files": stats, "total_bytes": total})


# ===== API: GPU Info ========================================================

@app.route("/api/gpu")
@require_auth
def api_gpu():
    """Return GPU info from heartbeat.json if available."""
    heartbeat = _read_json(HEARTBEAT_FILE) or {}
    return jsonify({
        "gpu": heartbeat.get("gpu", None),
        "available": heartbeat.get("gpu") is not None,
    })


# ===== API: Job Duration ===================================================

@app.route("/api/jobs/<job_id>/duration")
@require_auth
def api_job_duration(job_id: str):
    """Calculate job duration from JSONL events."""
    job_id = _sanitize_job_id(job_id)
    return jsonify(_get_job_duration(job_id))


# ===== SSE Streams ==========================================================

@app.route("/api/events/log-stream/<job_id>")
@require_auth
def sse_log_stream(job_id: str):
    job_id = _sanitize_job_id(job_id)
    lp = _log_path(job_id)
    if not lp.exists():
        abort(404, description="Log not found")

    def generate():
        with open(lp, "r", encoding="utf-8", errors="replace") as f:
            # Send existing content
            for line in f:
                yield f"data: {json.dumps(line.rstrip())}\n\n"
            # Tail for new content
            idle_count = 0
            while True:
                line = f.readline()
                if line:
                    idle_count = 0
                    yield f"data: {json.dumps(line.rstrip())}\n\n"
                else:
                    idle_count += 1
                    # Check job status every 5 idle cycles instead of every cycle
                    if idle_count % 5 == 0:
                        _, status = _find_job(job_id)
                        if status != "running":
                            yield "event: done\ndata: {}\n\n"
                            break
                    # Send keepalive every 30 idle cycles to prevent proxy timeout
                    if idle_count % 30 == 0:
                        yield ": keepalive\n\n"
                    time.sleep(1)

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/api/events/status-stream")
@require_auth
def sse_status_stream():
    def generate():
        while True:
            payload = json.dumps(_build_status_payload())
            yield f"data: {payload}\n\n"
            time.sleep(5)

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# ===== API: Auto-queue Config ===============================================

_AQ_DEFAULT = {"enabled": False, "trigger_threshold": 2, "tasks": []}


@app.route("/api/autoqueue")
@require_auth
def api_autoqueue_get():
    """Return current auto-queue configuration."""
    if not AUTOQUEUE_CONFIG.exists():
        return jsonify(_AQ_DEFAULT)
    data = _read_json(AUTOQUEUE_CONFIG)
    if data is None:
        return jsonify(_AQ_DEFAULT)
    return jsonify(data)


@app.route("/api/autoqueue", methods=["PUT"])
@require_auth
def api_autoqueue_put():
    """Update auto-queue configuration."""
    body = request.get_json(force=True)

    if not isinstance(body.get("enabled"), bool):
        abort(400, description="'enabled' must be a boolean")
    if not isinstance(body.get("trigger_threshold"), int):
        abort(400, description="'trigger_threshold' must be an integer")

    tasks = body.get("tasks", [])
    for t in tasks:
        if not isinstance(t.get("id"), str) or not t["id"]:
            abort(400, description="task 'id' must be a non-empty string")
        if not isinstance(t.get("repo"), str) or not t["repo"]:
            abort(400, description="task 'repo' must be a non-empty string")
        if not isinstance(t.get("task"), str) or not t["task"]:
            abort(400, description="task 'task' must be a non-empty string")
        if not isinstance(t.get("enabled"), bool):
            abort(400, description="task 'enabled' must be a boolean")
        if not isinstance(t.get("queued"), bool):
            abort(400, description="task 'queued' must be a boolean")

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = AUTOQUEUE_CONFIG.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(body, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.rename(AUTOQUEUE_CONFIG)
    return jsonify(body)


# ===== API: GitHub PRs ======================================================

_REPO_RE = re.compile(r'^[a-zA-Z0-9_.\-]+/[a-zA-Z0-9_.\-]+$')


@app.route("/api/prs")
@require_auth
def api_prs():
    """Return open PRs for specified GitHub repositories."""
    repos_param = request.args.get("repos", "").strip()
    if not repos_param:
        return jsonify([])

    if not GITHUB_TOKEN:
        return jsonify({"error": "GITHUB_TOKEN not configured"}), 503

    repos = [r.strip() for r in repos_param.split(",") if r.strip()][:5]
    results = []

    for repo in repos:
        if not _REPO_RE.match(repo):
            continue
        url = f"https://api.github.com/repos/{repo}/pulls?state=open&per_page=20"
        req = urllib.request.Request(url)
        req.add_header("Authorization", f"token {GITHUB_TOKEN}")
        req.add_header("Accept", "application/vnd.github.v3+json")
        req.add_header("User-Agent", "agent-dashboard/1.0")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                prs = json.loads(resp.read().decode())
                for pr in prs:
                    results.append({
                        "repo": repo,
                        "number": pr["number"],
                        "title": pr["title"],
                        "head_ref": pr["head"]["ref"],
                        "html_url": pr["html_url"],
                        "created_at": pr["created_at"],
                        "user": pr["user"]["login"],
                        "draft": pr.get("draft", False),
                    })
        except Exception:
            pass  # Skip repos that fail (rate limit, not found, etc.)

    return jsonify(results)


# ===== API: Job State =======================================================

@app.route("/api/jobs/<job_id>/state")
@require_auth
def api_job_state(job_id: str):
    """Return the latest state from a job's JSONL events file."""
    job_id = _sanitize_job_id(job_id)
    jp = _jsonl_path(job_id)
    if not jp.exists():
        return jsonify({"state": None, "iteration": 0, "elapsed_sec": None})

    events = _read_jsonl(jp)
    if not events:
        return jsonify({"state": None, "iteration": 0, "elapsed_sec": None})

    last = events[-1]
    return jsonify({
        "state": last.get("state"),
        "iteration": last.get("iteration", 0),
        "elapsed_sec": last.get("elapsed_sec"),
        "last_event": last.get("event"),
        "timestamp": last.get("timestamp"),
    })


# ===== API: Costs ===========================================================

@app.route("/api/costs")
@require_auth
def api_costs():
    """Return API cost totals aggregated from cleanup events in job JSONL logs."""
    now = time.time()
    if _costs_cache["data"] is not None and (now - _costs_cache["ts"]) < _COSTS_TTL:
        return jsonify(_costs_cache["data"])

    total = 0.0
    by_job = []
    if LOGS_DIR.is_dir():
        for jp in sorted(LOGS_DIR.glob("*.jsonl"), reverse=True):
            for ev in _read_jsonl(jp):
                if ev.get("event") == "cleanup":
                    m = _COST_RE.search(ev.get("detail", ""))
                    if m:
                        cost = float(m.group(1))
                        total += cost
                        by_job.append({
                            "job_id": ev.get("job_id", jp.stem),
                            "cost_usd": round(cost, 4),
                            "timestamp": ev.get("timestamp"),
                        })
    result = {"total_usd": round(total, 4), "jobs": by_job[:50]}
    _costs_cache["data"] = result
    _costs_cache["ts"] = now
    return jsonify(result)


# ===== API: Metrics =========================================================

@app.route("/api/metrics")
@require_auth
def api_metrics():
    """Aggregate success rates, durations, costs, and top repos.

    Response is cached for _METRICS_TTL seconds to avoid repeated full scans.
    """
    now = time.time()
    if _metrics_cache["data"] is not None and (now - _metrics_cache["ts"]) < _METRICS_TTL:
        return jsonify(_metrics_cache["data"])

    now_dt = datetime.now(timezone.utc)
    cutoffs = {
        "7d":  now_dt - timedelta(days=7),
        "30d": now_dt - timedelta(days=30),
    }

    # Accumulators
    sr: dict[str, dict[str, int]] = {"7d": {}, "30d": {}, "all": {}}
    dur_lists: dict[str, list[int]] = {"7d": [], "30d": [], "all": []}
    cost_by_day: dict[str, float] = {}
    repos: dict[str, dict[str, int]] = {}

    for s in ("done", "failed"):
        d = STATUS_DIRS[s]
        if not d.is_dir():
            continue
        for f in d.glob("*.json"):
            data = _read_json(f)
            if not data:
                continue
            job_id = data.get("id", f.stem)
            repo = data.get("repo", "")
            if repo not in repos:
                repos[repo] = {"done": 0, "failed": 0}
            repos[repo][s] += 1

            # Parse created_at
            created_str = data.get("created_at", "")
            created = None
            try:
                created = datetime.fromisoformat(created_str.replace("Z", "+00:00"))
            except (ValueError, AttributeError):
                pass

            # Accumulate success rate counts
            for window in ("7d", "30d", "all"):
                cutoff = cutoffs.get(window)
                in_window = (cutoff is None) or (created is not None and created >= cutoff)
                if in_window:
                    sr[window][s] = sr[window].get(s, 0) + 1

            # Duration
            dur = _get_cached_duration(job_id, s)
            if dur is not None and created is not None:
                for window in ("7d", "30d", "all"):
                    cutoff = cutoffs.get(window)
                    if cutoff is None or created >= cutoff:
                        dur_lists[window].append(dur)

            # Cost by calendar day
            if created is not None:
                cost = _get_cached_cost(job_id, s)
                if cost is not None:
                    dk = created.strftime("%Y-%m-%d")
                    cost_by_day[dk] = round(cost_by_day.get(dk, 0.0) + cost, 6)

    def _build_rate(w: dict) -> dict:
        done = w.get("done", 0)
        failed = w.get("failed", 0)
        total = done + failed
        return {
            "done": done, "failed": failed, "total": total,
            "rate": round(done / total, 3) if total > 0 else None,
        }

    def _avg(lst: list) -> int | None:
        return round(sum(lst) / len(lst)) if lst else None

    top_repos = sorted(
        [
            {
                "repo": r,
                "done": v["done"],
                "failed": v["failed"],
                "total": v["done"] + v["failed"],
                "failure_rate": (
                    round(v["failed"] / (v["done"] + v["failed"]), 3)
                    if (v["done"] + v["failed"]) > 0 else None
                ),
            }
            for r, v in repos.items()
        ],
        key=lambda x: x["total"],
        reverse=True,
    )[:10]

    # Cost by day — last 30 calendar days, sorted ascending
    cost_by_day_list = sorted(
        [{"date": dk, "cost_usd": round(c, 4)} for dk, c in cost_by_day.items()],
        key=lambda x: x["date"],
    )[-30:]

    result = {
        "success_rate": {
            "7d":  _build_rate(sr["7d"]),
            "30d": _build_rate(sr["30d"]),
            "all": _build_rate(sr["all"]),
        },
        "avg_duration_sec": {
            "7d":  _avg(dur_lists["7d"]),
            "30d": _avg(dur_lists["30d"]),
            "all": _avg(dur_lists["all"]),
        },
        "cost_by_day": cost_by_day_list,
        "top_repos": top_repos,
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    _metrics_cache["data"] = result
    _metrics_cache["ts"] = now
    return jsonify(result)


# ===== Prometheus Metrics (/metrics) ========================================

@app.route("/metrics")
@require_auth
def prometheus_metrics():
    """Expose agent metrics in Prometheus text exposition format (text/plain; version=0.0.4).

    Designed to be scraped by Prometheus or Grafana Agent.
    Results are cached for _PROM_TTL seconds to avoid hammering disk on every scrape.
    """
    now = time.time()
    if _prom_cache["data"] is not None and (now - _prom_cache["ts"]) < _PROM_TTL:
        return Response(_prom_cache["data"], mimetype="text/plain; version=0.0.4")

    # Collect counts
    counts: dict[str, int] = {}
    for s, d in STATUS_DIRS.items():
        counts[s] = len(list(d.glob("*.json"))) if d.is_dir() else 0

    # Collect cost + latency from metrics cache (reuse existing computation)
    metrics_data = _metrics_cache.get("data") or {}
    total_cost = 0.0
    for day_entry in metrics_data.get("cost_by_day", []):
        total_cost += day_entry.get("cost_usd", 0.0)

    avg_dur = (metrics_data.get("avg_duration_sec") or {}).get("all")
    success_rate_all = (metrics_data.get("success_rate") or {}).get("all", {})
    total_jobs = success_rate_all.get("total", 0)
    done_jobs = success_rate_all.get("done", 0)
    failed_jobs = success_rate_all.get("failed", 0)

    # Collect per-endpoint latency from recent request log (approximation)
    # We track just the job counts per status for now; latency would need middleware instrumentation
    lines = [
        "# HELP agent_jobs_total Total number of jobs by status",
        "# TYPE agent_jobs_total gauge",
        f'agent_jobs_total{{status="pending"}} {counts.get("pending", 0)}',
        f'agent_jobs_total{{status="running"}} {counts.get("running", 0)}',
        f'agent_jobs_total{{status="done"}} {counts.get("done", 0)}',
        f'agent_jobs_total{{status="failed"}} {counts.get("failed", 0)}',
        "",
        "# HELP agent_cost_total Total API cost in USD (from job logs)",
        "# TYPE agent_cost_total gauge",
        f"agent_cost_total {round(total_cost, 4)}",
        "",
        "# HELP agent_jobs_success_total Total completed (done) jobs across all time",
        "# TYPE agent_jobs_success_total counter",
        f"agent_jobs_success_total {done_jobs}",
        "",
        "# HELP agent_jobs_failed_total Total failed jobs across all time",
        "# TYPE agent_jobs_failed_total counter",
        f"agent_jobs_failed_total {failed_jobs}",
        "",
    ]

    if avg_dur is not None:
        lines += [
            "# HELP agent_job_duration_avg_seconds Average job duration in seconds (all time)",
            "# TYPE agent_job_duration_avg_seconds gauge",
            f"agent_job_duration_avg_seconds {avg_dur}",
            "",
        ]

    # Agent liveness
    heartbeat = _read_json(HEARTBEAT_FILE) or {}
    hb_ts_str = heartbeat.get("timestamp", "")
    agent_alive = 0
    try:
        hb_ts = datetime.fromisoformat(hb_ts_str.replace("Z", "+00:00"))
        age = (datetime.now(timezone.utc) - hb_ts).total_seconds()
        agent_alive = 1 if age < 120 else 0
    except (ValueError, AttributeError):
        pass

    lines += [
        "# HELP agent_alive Agent heartbeat liveness (1=alive, 0=dead)",
        "# TYPE agent_alive gauge",
        f"agent_alive {agent_alive}",
        "",
    ]

    body = "\n".join(lines) + "\n"
    _prom_cache["data"] = body
    _prom_cache["ts"] = now
    return Response(body, mimetype="text/plain; version=0.0.4")


# ===== API: Detailed Health =================================================

@app.route("/api/health/detailed")
@require_auth
def api_health_detailed():
    """Return a rich health snapshot: agent liveness, queue depths, disk, recent jobs."""
    now_dt = datetime.now(timezone.utc)
    now_ts = time.time()

    # Agent liveness from heartbeat
    heartbeat = _read_json(HEARTBEAT_FILE) or {}
    hb_ts_str = heartbeat.get("timestamp", "")
    hb_age: int | None = None
    agent_alive = False
    try:
        hb_ts = datetime.fromisoformat(hb_ts_str.replace("Z", "+00:00"))
        hb_age = int((now_dt - hb_ts).total_seconds())
        agent_alive = hb_age < 120  # alive if heartbeat < 2 min ago
    except (ValueError, AttributeError):
        pass

    # Queue depths + oldest pending
    counts: dict[str, int] = {}
    oldest_pending_age: int | None = None
    for s, d in STATUS_DIRS.items():
        files = list(d.glob("*.json")) if d.is_dir() else []
        counts[s] = len(files)
        if s == "pending" and files:
            oldest_mtime = min(f.stat().st_mtime for f in files)
            oldest_pending_age = int(now_ts - oldest_mtime)

    # Disk usage (harness partition)
    disk_info: dict | None = None
    try:
        disk = shutil.disk_usage(str(HARNESS))
        disk_info = {
            "total_gb": round(disk.total / 1e9, 2),
            "used_gb":  round(disk.used  / 1e9, 2),
            "free_gb":  round(disk.free  / 1e9, 2),
            "percent_used": round(disk.used / disk.total * 100, 1) if disk.total else 0.0,
        }
    except Exception:
        pass

    # Total size of log directory
    logs_size = 0
    if LOGS_DIR.is_dir():
        logs_size = sum(f.stat().st_size for f in LOGS_DIR.iterdir() if f.is_file())

    # Activity in last 1 hour (by file mtime)
    cutoff_1h = now_ts - 3600
    recent_1h: dict[str, int] = {"done": 0, "failed": 0}
    for s in ("done", "failed"):
        d = STATUS_DIRS[s]
        if d.is_dir():
            recent_1h[s] = sum(1 for f in d.glob("*.json") if f.stat().st_mtime >= cutoff_1h)

    # Determine overall health
    overall: str
    if not agent_alive:
        overall = "critical"
    elif (disk_info and disk_info["percent_used"] > 90) or counts.get("failed", 0) > max(counts.get("done", 0), 1) * 2:
        overall = "degraded"
    else:
        overall = "healthy"

    return jsonify({
        "overall": overall,
        "agent": {
            "alive": agent_alive,
            "last_heartbeat_age_sec": hb_age,
        },
        "queue": {
            "pending": counts.get("pending", 0),
            "running": counts.get("running", 0),
            "done":    counts.get("done", 0),
            "failed":  counts.get("failed", 0),
            "oldest_pending_age_sec": oldest_pending_age,
        },
        "disk": disk_info,
        "logs_size_bytes": logs_size,
        "recent_1h": recent_1h,
        "checked_at": now_dt.isoformat().replace("+00:00", "Z"),
    })


# ===== SSE: Kanban Stream ===================================================

@app.route("/api/events/kanban-stream")
@require_auth
def sse_kanban_stream():
    """SSE stream that pushes Kanban board updates when job states change."""
    def generate():
        prev_hash = None
        while True:
            jobs = _list_jobs()
            curr_hash = hash(str([(j['id'], j['status']) for j in jobs]))
            if curr_hash != prev_hash:
                for j in jobs:
                    j["duration_sec"] = _get_cached_duration(j["id"], j.get("status", ""))
                yield f"data: {json.dumps(jobs)}\n\n"
                prev_hash = curr_hash
            else:
                yield ": keepalive\n\n"
            time.sleep(3)

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# ===== PR Merge =============================================================

@app.route("/api/jobs/<job_id>/merge", methods=["POST"])
@require_auth
def api_merge_pr(job_id: str):
    """Merge the GitHub PR associated with this job via the GitHub API."""
    job_id = _sanitize_job_id(job_id)
    if not GITHUB_TOKEN:
        abort(503, description="GITHUB_TOKEN not configured")

    pr_url = _extract_pr_url(_log_path(job_id))
    if not pr_url:
        abort(404, description="No PR URL found for this job")

    m = _PR_GITHUB_RE.search(pr_url)
    if not m:
        abort(400, description="Cannot parse PR URL")
    owner, repo_name, pr_number = m.group(1), m.group(2), m.group(3)

    body = request.get_json(force=True) or {}
    merge_method = body.get("merge_method", "merge")
    if merge_method not in ("merge", "squash", "rebase"):
        abort(400, description="merge_method must be one of: merge, squash, rebase")

    api_url = f"https://api.github.com/repos/{owner}/{repo_name}/pulls/{pr_number}/merge"
    payload = json.dumps({"merge_method": merge_method}).encode()
    req = urllib.request.Request(
        api_url, data=payload, method="PUT",
        headers={
            "Authorization": f"Bearer {GITHUB_TOKEN}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            result = json.loads(r.read().decode())
        return jsonify({"merged": True, "message": result.get("message", ""), "pr_url": pr_url})
    except urllib.error.HTTPError as e:
        try:
            err_data = json.loads(e.read().decode())
        except Exception:
            err_data = {}
        return jsonify({"merged": False, "message": err_data.get("message", str(e))}), e.code
    except Exception as e:
        abort(502, description=f"GitHub API error: {str(e)[:100]}")


# ===== Notification helpers =================================================

def _send_channel_notification(channel_type: str, url: str, payload: dict, timeout: int = 5) -> str:
    """Send a notification to a single channel. Returns 'ok' or an error string."""
    try:
        data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout):
            return "ok"
    except urllib.error.HTTPError as e:
        return f"http_{e.code}"
    except Exception as e:
        return f"error: {str(e)[:100]}"


# ===== Notification test ====================================================

@app.route("/api/notify/test", methods=["POST"])
@require_auth
def api_notify_test():
    """Send a test notification to all configured channels."""
    msg = "🧪 [Agent Dashboard] 通知テスト - システムは正常です"
    results: dict[str, str] = {}

    if _TELEGRAM_BOT_TOKEN and _TELEGRAM_CHAT_ID:
        url = f"https://api.telegram.org/bot{_TELEGRAM_BOT_TOKEN}/sendMessage"
        results["telegram"] = _send_channel_notification(
            "telegram", url, {"chat_id": _TELEGRAM_CHAT_ID, "text": msg}
        )
    else:
        results["telegram"] = "not_configured"

    if _DISCORD_WEBHOOK_URL:
        results["discord"] = _send_channel_notification(
            "discord", _DISCORD_WEBHOOK_URL, {"content": msg}
        )
    else:
        results["discord"] = "not_configured"

    if _WEBHOOK_URL:
        results["webhook"] = _send_channel_notification(
            "webhook", _WEBHOOK_URL, {"text": msg}
        )
    else:
        results["webhook"] = "not_configured"

    return jsonify(results)


# ===== Job Completion Webhooks ==============================================

def _load_webhooks() -> list[dict]:
    """Load webhook registrations from config/webhooks.json."""
    if not WEBHOOKS_CONFIG.exists():
        return []
    try:
        data = json.loads(WEBHOOKS_CONFIG.read_text(encoding="utf-8"))
        if isinstance(data, list):
            return data
    except Exception:
        pass
    return []


def _save_webhooks(hooks: list[dict]) -> None:
    """Persist webhook registrations atomically (works on Linux and Windows)."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = WEBHOOKS_CONFIG.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(hooks, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(WEBHOOKS_CONFIG)  # atomic on POSIX; replace() works on Windows too


@app.route("/api/webhooks", methods=["GET"])
@require_auth
def api_webhooks_list():
    """List all registered job-completion webhooks."""
    hooks = _load_webhooks()
    # Mask secret if present
    safe = [
        {k: ("***" if k == "secret" and v else v) for k, v in h.items()}
        for h in hooks
    ]
    return jsonify(safe)


@app.route("/api/webhooks", methods=["POST"])
@require_auth
def api_webhooks_register():
    """Register a new job-completion webhook.

    Body: {"url": "https://...", "events": ["job_done", "job_failed"], "secret": "opt"}
    The 'events' field defaults to ["job_done", "job_failed"] if omitted.
    """
    body = request.get_json(force=True) or {}
    url = body.get("url", "").strip()
    if not url or not url.startswith("https://"):
        abort(400, description="'url' is required and must start with https://")
    events = body.get("events", ["job_done", "job_failed"])
    if not isinstance(events, list):
        abort(400, description="'events' must be an array")
    valid_events = {"job_done", "job_failed", "job_start"}
    for ev in events:
        if ev not in valid_events:
            abort(400, description=f"Invalid event '{ev}'. Valid: {sorted(valid_events)}")
    hook = {
        "id": uuid.uuid4().hex[:12],
        "url": url,
        "events": events,
        "secret": body.get("secret", ""),
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    hooks = _load_webhooks()
    if len(hooks) >= 20:
        abort(400, description="Webhook limit is 20 registrations")
    hooks.append(hook)
    _save_webhooks(hooks)
    safe = {k: ("***" if k == "secret" and v else v) for k, v in hook.items()}
    return jsonify(safe), 201


@app.route("/api/webhooks/<hook_id>", methods=["DELETE"])
@require_auth
def api_webhooks_delete(hook_id: str):
    """Remove a registered webhook by ID."""
    hook_id = re.sub(r'[^a-z0-9]', '', hook_id)
    hooks = _load_webhooks()
    new_hooks = [h for h in hooks if h.get("id") != hook_id]
    if len(new_hooks) == len(hooks):
        abort(404, description="Webhook not found")
    _save_webhooks(new_hooks)
    return jsonify({"deleted": hook_id})


# ===== API: v1 Blueprint (aliases to existing routes) =======================

from flask import Blueprint  # noqa: E402 — placed here to avoid circular import concerns

api_v1 = Blueprint("api_v1", __name__, url_prefix="/api/v1")


@api_v1.route("/jobs", methods=["GET"])
@require_auth
def v1_jobs():
    return api_jobs()


@api_v1.route("/jobs", methods=["POST"])
@require_auth
def v1_create_job():
    return api_create_job()


@api_v1.route("/jobs/batch", methods=["POST"])
@require_auth
def v1_batch_jobs():
    return api_create_jobs_batch()


@api_v1.route("/jobs/<job_id>", methods=["GET"])
@require_auth
def v1_job_detail(job_id: str):
    return api_job_detail(job_id)


@api_v1.route("/jobs/<job_id>/cancel", methods=["POST"])
@require_auth
def v1_cancel_job(job_id: str):
    return api_cancel_job(job_id)


@api_v1.route("/status", methods=["GET"])
@require_auth
def v1_status():
    return api_status()


@api_v1.route("/metrics", methods=["GET"])
@require_auth
def v1_metrics():
    return api_metrics()


@api_v1.route("/health", methods=["GET"])
@require_auth
def v1_health():
    return api_health_detailed()


app.register_blueprint(api_v1)


# ===== Error handlers =======================================================

@app.errorhandler(400)
@app.errorhandler(401)
@app.errorhandler(404)
@app.errorhandler(429)
def handle_error(e):
    return jsonify({"error": str(e)}), e.code


# ===== Main =================================================================

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=7860, debug=False)
