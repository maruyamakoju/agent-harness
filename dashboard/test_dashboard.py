"""
Test suite for the Agent Dashboard.
Run: pytest test_dashboard.py -v
Uses isolated temp directory for test data - does not depend on real project files.
"""

import json
import os
import sys
import tempfile
import shutil
from pathlib import Path
from datetime import datetime, timezone

import pytest

# ---------------------------------------------------------------------------
# Fixtures - isolated test environment
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def test_data_dir():
    """Create isolated test data directory with realistic sample data."""
    d = Path(tempfile.mkdtemp(prefix="dash_test_"))
    jobs = d / "jobs"
    logs = d / "logs"

    for sub in ("pending", "running", "done", "failed"):
        (jobs / sub).mkdir(parents=True)
    logs.mkdir(parents=True)

    # Done job
    done_job = {
        "id": "2026-01-01T120000Z-test-done",
        "repo": "https://github.com/test/repo.git",
        "base_ref": "main",
        "work_branch": "agent/2026-01-01T120000Z-test-done",
        "task": "Add unit tests for auth module",
        "commands": {"setup": ["npm ci"], "test": ["npm test"]},
        "time_budget_sec": 3600,
        "max_retries": 2,
        "gpu_required": False,
        "created_at": "2026-01-01T12:00:00Z",
    }
    (jobs / "done" / "2026-01-01T120000Z-test-done.json").write_text(
        json.dumps(done_job, indent=2), encoding="utf-8"
    )

    # Failed job
    failed_job = {
        "id": "2026-01-02T080000Z-test-failed",
        "repo": "https://github.com/test/other.git",
        "base_ref": "develop",
        "work_branch": "agent/2026-01-02T080000Z-test-failed",
        "task": "Fix login bug",
        "commands": {"setup": [], "test": ["pytest"]},
        "time_budget_sec": 1800,
        "max_retries": 1,
        "gpu_required": False,
        "created_at": "2026-01-02T08:00:00Z",
    }
    (jobs / "failed" / "2026-01-02T080000Z-test-failed.json").write_text(
        json.dumps(failed_job, indent=2), encoding="utf-8"
    )

    # Running job
    running_job = {
        "id": "2026-01-03T100000Z-test-running",
        "repo": "https://github.com/test/repo.git",
        "base_ref": "main",
        "work_branch": "agent/2026-01-03T100000Z-test-running",
        "task": "Refactor database layer",
        "commands": {"setup": ["pip install -r requirements.txt"], "test": ["pytest"]},
        "time_budget_sec": 7200,
        "max_retries": 2,
        "gpu_required": True,
        "created_at": "2026-01-03T10:00:00Z",
    }
    (jobs / "running" / "2026-01-03T100000Z-test-running.json").write_text(
        json.dumps(running_job, indent=2), encoding="utf-8"
    )

    # Log file with PR URL
    log_content = """[2026-01-01T12:00:01Z] Starting job 2026-01-01T120000Z-test-done
[2026-01-01T12:05:00Z] [INFO] Cloning repository
[2026-01-01T12:10:00Z] [WARN] Slow network detected
[2026-01-01T12:15:00Z] Tests passed
[2026-01-01T12:20:00Z] PR created: https://github.com/test/repo/pull/42
[2026-01-01T12:20:01Z] [ERROR] Minor cleanup issue
"""
    (logs / "2026-01-01T120000Z-test-done.log").write_text(log_content, encoding="utf-8")

    # JSONL events file
    events = [
        {"timestamp": "2026-01-01T12:00:01Z", "job_id": "2026-01-01T120000Z-test-done",
         "event": "job_start", "state": "CLONE", "iteration": 0, "elapsed_sec": 0,
         "detail": "repo=test task=test"},
        {"timestamp": "2026-01-01T12:05:00Z", "job_id": "2026-01-01T120000Z-test-done",
         "event": "clone_success", "state": "CLONE", "iteration": 0, "elapsed_sec": 299,
         "detail": "branch=agent/test"},
        {"timestamp": "2026-01-01T12:20:01Z", "job_id": "2026-01-01T120000Z-test-done",
         "event": "job_done", "state": "DONE", "iteration": 1, "elapsed_sec": 1200,
         "detail": "success=true"},
    ]
    jsonl_lines = "\n".join(json.dumps(e) for e in events)
    (logs / "2026-01-01T120000Z-test-done.jsonl").write_text(jsonl_lines, encoding="utf-8")

    # Heartbeat
    heartbeat = {
        "timestamp": "2026-01-03T10:00:00Z",
        "status": "alive",
        "auth": "max-plan",
        "queue": {"pending": 0, "running": 1, "done": 1, "failed": 1},
        "consecutive_failures": 0,
        "quota": {"jobs_today": 3, "max_per_day": 20},
    }
    (logs / "heartbeat.json").write_text(json.dumps(heartbeat), encoding="utf-8")

    # Quota counter
    (logs / "quota-counter.json").write_text(
        json.dumps({"date": "2026-01-03", "count": 3}), encoding="utf-8"
    )

    # Notifications log
    notif_content = """[2026-01-01T12:00:00Z] [NOTIFY] job_start 2026-01-01T120000Z-test-done Starting job
[2026-01-01T12:20:01Z] [NOTIFY] job_done 2026-01-01T120000Z-test-done Job completed
[2026-01-02T08:00:00Z] [NOTIFY] job_start 2026-01-02T080000Z-test-failed Starting job
[2026-01-02T08:30:00Z] [NOTIFY] job_failed 2026-01-02T080000Z-test-failed Job failed
"""
    (logs / "notifications.log").write_text(notif_content, encoding="utf-8")

    yield d

    shutil.rmtree(d, ignore_errors=True)


@pytest.fixture
def app(test_data_dir):
    """Create Flask test app with isolated data."""
    os.environ["HARNESS_DIR"] = str(test_data_dir)
    os.environ.pop("DASHBOARD_TOKEN", None)

    # Force reimport to pick up new env
    if "app" in sys.modules:
        del sys.modules["app"]
    import app as app_module
    from importlib import reload
    reload(app_module)

    app_module.app.config["TESTING"] = True
    return app_module.app


@pytest.fixture
def client(app):
    """Flask test client."""
    return app.test_client()


@pytest.fixture
def auth_app(test_data_dir):
    """Create Flask test app with auth enabled."""
    os.environ["HARNESS_DIR"] = str(test_data_dir)
    os.environ["DASHBOARD_TOKEN"] = "test-secret-123"

    if "app" in sys.modules:
        del sys.modules["app"]
    import app as app_module
    from importlib import reload
    reload(app_module)

    app_module.app.config["TESTING"] = True
    return app_module.app


@pytest.fixture
def auth_client(auth_app):
    """Flask test client with auth enabled."""
    return auth_app.test_client()


# ---------------------------------------------------------------------------
# Page Routes
# ---------------------------------------------------------------------------
class TestPages:
    def test_index_returns_200(self, client):
        r = client.get("/")
        assert r.status_code == 200
        assert b"Agent Dashboard" in r.data

    def test_login_redirects_when_no_auth(self, client):
        r = client.get("/login")
        assert r.status_code == 302

    def test_logout_redirects(self, client):
        r = client.get("/logout")
        assert r.status_code == 302


# ---------------------------------------------------------------------------
# Status API
# ---------------------------------------------------------------------------
class TestStatusAPI:
    def test_status_returns_required_fields(self, client):
        r = client.get("/api/status")
        assert r.status_code == 200
        data = r.get_json()
        assert "heartbeat" in data
        assert "counts" in data
        assert "quota" in data
        assert "server_time" in data

    def test_status_counts_correct(self, client):
        data = client.get("/api/status").get_json()
        c = data["counts"]
        assert c["done"] == 1
        assert c["failed"] == 1
        assert c["running"] == 1
        assert c["pending"] == 0

    def test_status_heartbeat_alive(self, client):
        data = client.get("/api/status").get_json()
        assert data["heartbeat"]["status"] == "alive"


# ---------------------------------------------------------------------------
# Jobs API
# ---------------------------------------------------------------------------
class TestJobsAPI:
    def test_list_all_jobs(self, client):
        r = client.get("/api/jobs")
        assert r.status_code == 200
        jobs = r.get_json()
        assert len(jobs) == 3

    def test_filter_by_status(self, client):
        r = client.get("/api/jobs?status=done")
        jobs = r.get_json()
        assert len(jobs) == 1
        assert jobs[0]["status"] == "done"

    def test_filter_running(self, client):
        r = client.get("/api/jobs?status=running")
        jobs = r.get_json()
        assert len(jobs) == 1
        assert jobs[0]["task"] == "Refactor database layer"

    def test_filter_empty_status(self, client):
        r = client.get("/api/jobs?status=pending")
        assert r.status_code == 200
        assert r.get_json() == []

    def test_jobs_enriched_with_duration(self, client):
        jobs = client.get("/api/jobs").get_json()
        done_job = next(j for j in jobs if j["status"] == "done")
        assert "duration_sec" in done_job
        assert done_job["duration_sec"] == 1200

    def test_jobs_pending_duration_null(self, client, test_data_dir):
        # Create a pending job
        pending = {
            "id": "2026-01-04T000000Z-pending-test",
            "repo": "https://github.com/test/x.git",
            "task": "test",
            "commands": {"setup": [], "test": []},
            "time_budget_sec": 3600,
            "max_retries": 2,
            "gpu_required": False,
            "created_at": "2026-01-04T00:00:00Z",
        }
        p = test_data_dir / "jobs" / "pending" / "2026-01-04T000000Z-pending-test.json"
        p.write_text(json.dumps(pending), encoding="utf-8")
        try:
            jobs = client.get("/api/jobs?status=pending").get_json()
            assert len(jobs) == 1
            assert jobs[0]["duration_sec"] is None
        finally:
            p.unlink(missing_ok=True)

    def test_jobs_no_enrich(self, client):
        jobs = client.get("/api/jobs?enrich=false").get_json()
        assert len(jobs) == 3
        # duration_sec should not be present when enrich=false
        for j in jobs:
            assert "duration_sec" not in j

    def test_job_detail(self, client):
        r = client.get("/api/jobs/2026-01-01T120000Z-test-done")
        assert r.status_code == 200
        data = r.get_json()
        assert data["repo"] == "https://github.com/test/repo.git"
        assert data["pr_url"] == "https://github.com/test/repo/pull/42"

    def test_job_detail_404(self, client):
        r = client.get("/api/jobs/nonexistent-id")
        assert r.status_code == 404


# ---------------------------------------------------------------------------
# Job Create/Delete
# ---------------------------------------------------------------------------
class TestJobCRUD:
    def test_create_job(self, client):
        r = client.post("/api/jobs", json={
            "repo": "https://github.com/test/new-repo.git",
            "task": "Test task for creation",
            "time_budget": 600,
        })
        assert r.status_code == 201
        job = r.get_json()
        assert "id" in job
        assert job["repo"] == "https://github.com/test/new-repo.git"
        assert job["task"] == "Test task for creation"
        assert job["time_budget_sec"] == 600

        # Cleanup
        client.delete(f"/api/jobs/{job['id']}")

    def test_create_job_with_string_commands(self, client):
        r = client.post("/api/jobs", json={
            "repo": "https://github.com/test/repo.git",
            "task": "Test with string commands",
            "setup": "npm ci\nnpm build",
            "test": "npm test",
        })
        assert r.status_code == 201
        job = r.get_json()
        assert job["commands"]["setup"] == ["npm ci", "npm build"]
        assert job["commands"]["test"] == ["npm test"]
        client.delete(f"/api/jobs/{job['id']}")

    def test_create_job_validation(self, client):
        r = client.post("/api/jobs", json={"repo": "", "task": ""})
        assert r.status_code == 400

    def test_create_job_missing_fields(self, client):
        r = client.post("/api/jobs", json={"repo": "x"})
        assert r.status_code == 400

    def test_delete_pending_job(self, client):
        r = client.post("/api/jobs", json={
            "repo": "https://github.com/test/del.git",
            "task": "Delete me",
        })
        job_id = r.get_json()["id"]

        r2 = client.delete(f"/api/jobs/{job_id}")
        assert r2.status_code == 200
        assert r2.get_json()["deleted"] == job_id

        # Verify gone
        r3 = client.get(f"/api/jobs/{job_id}")
        assert r3.status_code == 404

    def test_delete_nonpending_fails(self, client):
        r = client.delete("/api/jobs/2026-01-01T120000Z-test-done")
        assert r.status_code == 404


# ---------------------------------------------------------------------------
# Re-run API
# ---------------------------------------------------------------------------
class TestRerun:
    def test_rerun_done_job(self, client):
        r = client.post("/api/jobs/2026-01-01T120000Z-test-done/rerun")
        assert r.status_code == 201
        job = r.get_json()
        assert job["repo"] == "https://github.com/test/repo.git"
        assert job["task"] == "Add unit tests for auth module"
        client.delete(f"/api/jobs/{job['id']}")

    def test_rerun_failed_job(self, client):
        r = client.post("/api/jobs/2026-01-02T080000Z-test-failed/rerun")
        assert r.status_code == 201
        job = r.get_json()
        assert job["repo"] == "https://github.com/test/other.git"
        client.delete(f"/api/jobs/{job['id']}")

    def test_rerun_running_job_rejected(self, client):
        r = client.post("/api/jobs/2026-01-03T100000Z-test-running/rerun")
        assert r.status_code == 400

    def test_rerun_nonexistent(self, client):
        r = client.post("/api/jobs/nonexistent/rerun")
        assert r.status_code == 404


# ---------------------------------------------------------------------------
# Activity API
# ---------------------------------------------------------------------------
class TestActivityAPI:
    def test_activity_returns_events(self, client):
        r = client.get("/api/activity")
        assert r.status_code == 200
        items = r.get_json()
        assert isinstance(items, list)
        assert len(items) > 0
        assert "timestamp" in items[0]
        assert "event" in items[0]

    def test_activity_sorted_by_time(self, client):
        items = client.get("/api/activity").get_json()
        timestamps = [e.get("timestamp", "") for e in items]
        assert timestamps == sorted(timestamps, reverse=True)

    def test_activity_limit(self, client):
        items = client.get("/api/activity?limit=1").get_json()
        assert len(items) <= 1


# ---------------------------------------------------------------------------
# Logs API
# ---------------------------------------------------------------------------
class TestLogsAPI:
    def test_get_log(self, client):
        r = client.get("/api/logs/2026-01-01T120000Z-test-done")
        assert r.status_code == 200
        assert r.content_type == "text/plain; charset=utf-8"
        assert b"Starting job" in r.data

    def test_get_log_tail(self, client):
        r = client.get("/api/logs/2026-01-01T120000Z-test-done?tail=2")
        assert r.status_code == 200
        lines = r.get_data(as_text=True).strip().split("\n")
        assert len(lines) == 2

    def test_log_not_found(self, client):
        r = client.get("/api/logs/nonexistent")
        assert r.status_code == 404

    def test_events(self, client):
        r = client.get("/api/logs/2026-01-01T120000Z-test-done/events")
        assert r.status_code == 200
        events = r.get_json()
        assert len(events) == 3
        assert events[0]["event"] == "job_start"
        assert events[-1]["event"] == "job_done"

    def test_events_not_found(self, client):
        r = client.get("/api/logs/nonexistent/events")
        assert r.status_code == 404


# ---------------------------------------------------------------------------
# Duration API
# ---------------------------------------------------------------------------
class TestDurationAPI:
    def test_duration_with_events(self, client):
        r = client.get("/api/jobs/2026-01-01T120000Z-test-done/duration")
        assert r.status_code == 200
        data = r.get_json()
        assert data["duration_sec"] == 1200
        assert data["start"] == "2026-01-01T12:00:01Z"
        assert data["end"] == "2026-01-01T12:20:01Z"

    def test_duration_no_events(self, client):
        r = client.get("/api/jobs/nonexistent/duration")
        assert r.status_code == 200
        data = r.get_json()
        assert data["duration_sec"] is None


# ---------------------------------------------------------------------------
# GPU API
# ---------------------------------------------------------------------------
class TestGPU:
    def test_gpu_info(self, client):
        r = client.get("/api/gpu")
        assert r.status_code == 200
        data = r.get_json()
        assert "available" in data
        assert "gpu" in data


# ---------------------------------------------------------------------------
# Notifications API
# ---------------------------------------------------------------------------
class TestNotifications:
    def test_notifications(self, client):
        r = client.get("/api/notifications")
        assert r.status_code == 200
        items = r.get_json()
        assert len(items) == 4
        assert items[0]["event"] == "job_start"

    def test_notifications_tail(self, client):
        items = client.get("/api/notifications?tail=2").get_json()
        assert len(items) == 2

    def test_notifications_missing_file(self, client, test_data_dir):
        notif = test_data_dir / "logs" / "notifications.log"
        backup = notif.read_text(encoding="utf-8")
        notif.unlink()
        try:
            r = client.get("/api/notifications")
            assert r.status_code == 200
            assert r.get_json() == []
        finally:
            notif.write_text(backup, encoding="utf-8")


# ---------------------------------------------------------------------------
# Admin API
# ---------------------------------------------------------------------------
class TestAdmin:
    def test_log_stats(self, client):
        r = client.get("/api/admin/log-stats")
        assert r.status_code == 200
        data = r.get_json()
        assert "files" in data
        assert "total_bytes" in data
        assert len(data["files"]) > 0
        # Check file entry has required fields
        f = data["files"][0]
        assert "name" in f
        assert "size" in f
        assert "modified" in f


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------
class TestAuth:
    def test_api_requires_auth(self, auth_client):
        r = auth_client.get("/api/status")
        assert r.status_code == 401

    def test_bearer_auth(self, auth_client):
        r = auth_client.get("/api/status", headers={
            "Authorization": "Bearer test-secret-123"
        })
        assert r.status_code == 200

    def test_wrong_bearer_rejected(self, auth_client):
        r = auth_client.get("/api/status", headers={
            "Authorization": "Bearer wrong-token"
        })
        assert r.status_code == 401

    def test_page_redirects_to_login(self, auth_client):
        r = auth_client.get("/")
        assert r.status_code == 302
        assert "/login" in r.headers["Location"]

    def test_login_page_renders(self, auth_client):
        r = auth_client.get("/login")
        assert r.status_code == 200
        assert b"Agent Dashboard" in r.data

    def test_login_wrong_token(self, auth_client):
        r = auth_client.post("/login", data={"token": "wrong"})
        assert r.status_code == 200  # renders error page

    def test_login_correct_token(self, auth_client):
        r = auth_client.post("/login", data={"token": "test-secret-123"},
                             follow_redirects=False)
        assert r.status_code == 302

    def test_login_sets_cookie(self, auth_client):
        r = auth_client.post("/login", data={"token": "test-secret-123"},
                             follow_redirects=False)
        assert "dash_token" in r.headers.get("Set-Cookie", "")


# ---------------------------------------------------------------------------
# Security Headers
# ---------------------------------------------------------------------------
class TestSecurityHeaders:
    def test_x_content_type_options(self, client):
        r = client.get("/api/status")
        assert r.headers.get("X-Content-Type-Options") == "nosniff"

    def test_x_frame_options(self, client):
        r = client.get("/api/status")
        assert r.headers.get("X-Frame-Options") == "DENY"

    def test_referrer_policy(self, client):
        r = client.get("/api/status")
        assert r.headers.get("Referrer-Policy") == "strict-origin-when-cross-origin"


# ---------------------------------------------------------------------------
# Edge Cases & Security
# ---------------------------------------------------------------------------
class TestEdgeCases:
    def test_path_traversal_in_job_id(self, client):
        r = client.get("/api/jobs/../../../etc/passwd")
        assert r.status_code == 404

    def test_path_traversal_in_logs(self, client):
        r = client.get("/api/logs/../../etc/passwd")
        assert r.status_code == 404

    def test_special_chars_in_job_id(self, client):
        r = client.get("/api/jobs/test%00null")
        assert r.status_code == 404

    def test_empty_json_body_create(self, client):
        r = client.post("/api/jobs", data=b"{}", content_type="application/json")
        assert r.status_code == 400

    def test_malformed_jsonl(self, client, test_data_dir):
        """JSONL with corrupt lines should still parse valid lines."""
        jp = test_data_dir / "logs" / "2026-01-01T120000Z-test-done.jsonl"
        original = jp.read_text(encoding="utf-8")
        jp.write_text(original + "\n{invalid json\n" + '{"event":"extra"}\n', encoding="utf-8")
        try:
            r = client.get("/api/logs/2026-01-01T120000Z-test-done/events")
            assert r.status_code == 200
            events = r.get_json()
            assert len(events) >= 3  # Original events still parsed
        finally:
            jp.write_text(original, encoding="utf-8")

    def test_error_handler_json_format(self, client):
        r = client.get("/api/jobs/nonexistent")
        assert r.status_code == 404
        data = r.get_json()
        assert "error" in data


# ---------------------------------------------------------------------------
# Legacy compatibility - keep the original runner for backward compat
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
