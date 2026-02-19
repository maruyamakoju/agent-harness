"""
Agent Dashboard - Flask web UI for monitoring the autonomous coding agent.
Serves at http://localhost:7860
"""

import hmac
import json
import os
import re
import time
import uuid
import hashlib
import secrets
import urllib.request
import urllib.error
from datetime import datetime, timezone
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
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "") or os.environ.get("GH_TOKEN", "")

# Auth token from env; if not set, auth is disabled (dev mode)
DASHBOARD_TOKEN = os.environ.get("DASHBOARD_TOKEN", "")
TOKEN_COOKIE = "dash_token"

# PR URL pattern compiled once
_PR_URL_RE = re.compile(r'https://github\.com/[^\s"\']+/pull/\d+')

# Notification line pattern compiled once
_NOTIF_RE = re.compile(r'\[(.+?)\]\s+\[NOTIFY\]\s+(\S+)\s+(\S+)\s*(.*)')

# Cost extraction pattern (matches "cost=1.2345" in cleanup event detail)
_COST_RE = re.compile(r'cost=([0-9.]+)')

# ---------------------------------------------------------------------------
# Performance caches
# ---------------------------------------------------------------------------
# Duration cache: keyed by job_id; persists forever for done/failed jobs
_duration_cache: dict[str, int | None] = {}

# Costs cache: TTL-based to avoid full-scan on every request
_costs_cache: dict = {"data": None, "ts": 0.0}
_COSTS_TTL = 60.0  # seconds

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
    """Return job duration, using an in-memory cache for completed jobs."""
    if status == "pending":
        return None
    if status in ("done", "failed") and job_id in _duration_cache:
        return _duration_cache[job_id]
    dur = _get_job_duration(job_id)["duration_sec"]
    if status in ("done", "failed"):
        _duration_cache[job_id] = dur  # cache permanently for finished jobs
    return dur


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

    # Enrich with duration data to avoid N+1 frontend calls
    if request.args.get("enrich") != "false":
        for job in jobs_page:
            if job.get("status") != "pending":
                job["duration_sec"] = _get_cached_duration(job["id"], job.get("status", ""))
            else:
                job["duration_sec"] = None

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
    return jsonify(data)


@app.route("/api/jobs", methods=["POST"])
@require_auth
def api_create_job():
    body = request.get_json(force=True)
    repo = body.get("repo", "").strip()
    task = body.get("task", "").strip()
    if not repo or not task:
        abort(400, description="'repo' and 'task' are required")

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


@app.route("/api/jobs/<job_id>", methods=["DELETE"])
@require_auth
def api_delete_job(job_id: str):
    job_id = _sanitize_job_id(job_id)
    p = PENDING / f"{job_id}.json"
    if not p.exists():
        abort(404, description="Pending job not found (can only cancel pending jobs)")
    p.unlink()
    return jsonify({"deleted": job_id})


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
    """Return recent activity events across all jobs (server-side aggregation)."""
    limit = request.args.get("limit", 15, type=int)
    limit = min(limit, 100)

    jobs = _list_jobs()
    items = []
    for j in jobs[:10]:
        events = _read_jsonl(_jsonl_path(j["id"]))
        for ev in events[-3:]:
            items.append(ev)

    items.sort(key=lambda e: e.get("timestamp", ""), reverse=True)
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
            text = f"[... 先頭部分省略（{size // 1024}KB中最後の5MBを表示）...]\n" + text
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


# ===== Error handlers =======================================================

@app.errorhandler(400)
@app.errorhandler(401)
@app.errorhandler(404)
def handle_error(e):
    return jsonify({"error": str(e)}), e.code


# ===== Main =================================================================

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=7860, debug=False)
