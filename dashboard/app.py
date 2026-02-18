"""
Agent Dashboard - Flask web UI for monitoring the autonomous coding agent.
Serves at http://localhost:7860
"""

import json
import os
import time
import re
import uuid
import hashlib
import secrets
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

# Auth token from env; if not set, auth is disabled (dev mode)
DASHBOARD_TOKEN = os.environ.get("DASHBOARD_TOKEN", "")
TOKEN_COOKIE = "dash_token"


# ===== Auth =================================================================

def _check_auth() -> bool:
    """Return True if the request is authenticated (or auth is disabled)."""
    if not DASHBOARD_TOKEN:
        return True
    # Check cookie
    cookie = request.cookies.get(TOKEN_COOKIE, "")
    if cookie and _hash_token(cookie) == _hash_token(DASHBOARD_TOKEN):
        return True
    # Check Authorization header (for API clients)
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        tok = auth[7:]
        if _hash_token(tok) == _hash_token(DASHBOARD_TOKEN):
            return True
    return False


def _hash_token(tok: str) -> str:
    return hashlib.sha256(tok.encode()).hexdigest()


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
        token = request.form.get("token", "").strip()
        if _hash_token(token) == _hash_token(DASHBOARD_TOKEN):
            resp = make_response(redirect("/"))
            resp.set_cookie(TOKEN_COOKIE, token, httponly=True, samesite="Lax",
                            max_age=60 * 60 * 24 * 30)
            return resp
        return render_template("login.html", error="Invalid token")
    return render_template("login.html", error=None)


@app.route("/logout")
def logout():
    resp = make_response(redirect("/login"))
    resp.delete_cookie(TOKEN_COOKIE)
    return resp


# ===== Helpers ==============================================================

def _read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


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


def _log_path(job_id: str) -> Path:
    return LOGS_DIR / f"{job_id}.log"


def _jsonl_path(job_id: str) -> Path:
    return LOGS_DIR / f"{job_id}.jsonl"


def _extract_pr_url(log_path: Path) -> str | None:
    if not log_path.exists():
        return None
    try:
        text = log_path.read_text(encoding="utf-8", errors="replace")
        m = re.search(r'https://github\.com/[^\s"\']+/pull/\d+', text)
        return m.group(0) if m else None
    except Exception:
        return None


def _sanitize_job_id(job_id: str) -> str:
    """Remove path traversal chars from job id."""
    return re.sub(r'[^a-zA-Z0-9._\-]', '', job_id)


# ===== Page routes ==========================================================

@app.route("/")
@require_auth
def index():
    return render_template("index.html")


# ===== API: Status ==========================================================

@app.route("/api/status")
@require_auth
def api_status():
    heartbeat = _read_json(HEARTBEAT_FILE) or {}
    quota = _read_json(QUOTA_FILE) or {}
    counts = {}
    for s, d in STATUS_DIRS.items():
        counts[s] = len(list(d.glob("*.json"))) if d.is_dir() else 0
    return jsonify({
        "heartbeat": heartbeat,
        "quota": quota,
        "counts": counts,
        "server_time": datetime.now(timezone.utc).isoformat(),
    })


# ===== API: Jobs ============================================================

@app.route("/api/jobs")
@require_auth
def api_jobs():
    status_filter = request.args.get("status", "all")
    if status_filter == "all":
        jobs = _list_jobs()
    else:
        jobs = _list_jobs(status_filter)
    return jsonify(jobs)


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

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    slug = re.sub(r'[^a-z0-9-]', '', task.lower().replace(' ', '-'))[:40]
    if not slug:
        slug = uuid.uuid4().hex[:8]
    job_id = f"{ts}-{slug}"

    setup_cmds = body.get("setup", [])
    test_cmds = body.get("test", [])
    if isinstance(setup_cmds, str):
        setup_cmds = [c.strip() for c in setup_cmds.split("\n") if c.strip()]
    if isinstance(test_cmds, str):
        test_cmds = [c.strip() for c in test_cmds.split("\n") if c.strip()]

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
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }

    PENDING.mkdir(parents=True, exist_ok=True)
    out = PENDING / f"{job_id}.json"
    out.write_text(json.dumps(job, indent=2, ensure_ascii=False), encoding="utf-8")
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


# ===== API: Logs ============================================================

@app.route("/api/logs/<job_id>")
@require_auth
def api_log(job_id: str):
    job_id = _sanitize_job_id(job_id)
    lp = _log_path(job_id)
    if not lp.exists():
        abort(404, description="Log not found")
    tail = request.args.get("tail", type=int)
    text = lp.read_text(encoding="utf-8", errors="replace")
    if tail:
        lines = text.splitlines()
        text = "\n".join(lines[-tail:])
    return Response(text, mimetype="text/plain")


@app.route("/api/logs/<job_id>/events")
@require_auth
def api_log_events(job_id: str):
    job_id = _sanitize_job_id(job_id)
    jp = _jsonl_path(job_id)
    if not jp.exists():
        abort(404, description="Events file not found")
    events = []
    for line in jp.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line:
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return jsonify(events)


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
        m = re.match(r'\[(.+?)\]\s+\[NOTIFY\]\s+(\S+)\s+(\S+)\s*(.*)', line)
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
                stats.append({
                    "name": f.name,
                    "size": f.stat().st_size,
                    "modified": datetime.fromtimestamp(
                        f.stat().st_mtime, tz=timezone.utc
                    ).isoformat(),
                })
    total = sum(s["size"] for s in stats)
    return jsonify({"files": stats, "total_bytes": total})


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
            for line in f:
                yield f"data: {json.dumps(line.rstrip())}\n\n"
            while True:
                line = f.readline()
                if line:
                    yield f"data: {json.dumps(line.rstrip())}\n\n"
                else:
                    _, status = _find_job(job_id)
                    if status != "running":
                        yield "event: done\ndata: {}\n\n"
                        break
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
            heartbeat = _read_json(HEARTBEAT_FILE) or {}
            quota = _read_json(QUOTA_FILE) or {}
            counts = {}
            for s, d in STATUS_DIRS.items():
                counts[s] = len(list(d.glob("*.json"))) if d.is_dir() else 0
            payload = json.dumps({
                "heartbeat": heartbeat,
                "quota": quota,
                "counts": counts,
                "server_time": datetime.now(timezone.utc).isoformat(),
            })
            yield f"data: {payload}\n\n"
            time.sleep(5)

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
