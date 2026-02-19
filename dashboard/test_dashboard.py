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
import time
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
    (d / "config").mkdir(parents=True)

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

    def test_content_security_policy_present(self, client):
        r = client.get("/api/status")
        csp = r.headers.get("Content-Security-Policy", "")
        assert "default-src" in csp

    def test_csp_restricts_default_src_to_self(self, client):
        r = client.get("/api/status")
        csp = r.headers.get("Content-Security-Policy", "")
        assert "default-src 'self'" in csp

    def test_csp_allows_connect_src_self(self, client):
        # SSE/fetch must work same-origin
        r = client.get("/api/status")
        csp = r.headers.get("Content-Security-Policy", "")
        assert "connect-src 'self'" in csp

    def test_csp_denies_frame_ancestors(self, client):
        r = client.get("/api/status")
        csp = r.headers.get("Content-Security-Policy", "")
        assert "frame-ancestors 'none'" in csp


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
# Auto-queue API
# ---------------------------------------------------------------------------
class TestAutoQueueAPI:
    def test_get_default_when_no_file(self, client, test_data_dir):
        # Ensure config file does not exist
        cfg = test_data_dir / "config" / "auto-queue-config.json"
        cfg.unlink(missing_ok=True)
        r = client.get("/api/autoqueue")
        assert r.status_code == 200
        data = r.get_json()
        assert data["enabled"] is False
        assert data["trigger_threshold"] == 2
        assert data["tasks"] == []

    def test_get_returns_file_content(self, client, test_data_dir):
        config = {"enabled": True, "trigger_threshold": 3, "tasks": []}
        cfg = test_data_dir / "config" / "auto-queue-config.json"
        cfg.write_text(json.dumps(config), encoding="utf-8")
        try:
            r = client.get("/api/autoqueue")
            assert r.status_code == 200
            data = r.get_json()
            assert data["enabled"] is True
            assert data["trigger_threshold"] == 3
        finally:
            cfg.unlink(missing_ok=True)

    def test_put_valid(self, client, test_data_dir):
        payload = {
            "enabled": True,
            "trigger_threshold": 3,
            "tasks": [
                {
                    "id": "task1",
                    "repo": "owner/repo",
                    "task": "do something",
                    "enabled": True,
                    "queued": False,
                    "time_budget_sec": 3600,
                }
            ],
        }
        r = client.put("/api/autoqueue", json=payload)
        assert r.status_code == 200
        data = r.get_json()
        assert data["enabled"] is True
        assert data["trigger_threshold"] == 3
        assert len(data["tasks"]) == 1
        # Cleanup
        (test_data_dir / "config" / "auto-queue-config.json").unlink(missing_ok=True)

    def test_put_enabled_not_bool_returns_400(self, client):
        r = client.put("/api/autoqueue", json={
            "enabled": "yes", "trigger_threshold": 2, "tasks": []
        })
        assert r.status_code == 400

    def test_put_threshold_not_int_returns_400(self, client):
        r = client.put("/api/autoqueue", json={
            "enabled": True, "trigger_threshold": "3", "tasks": []
        })
        assert r.status_code == 400

    def test_put_task_missing_task_field_returns_400(self, client):
        payload = {
            "enabled": False,
            "trigger_threshold": 2,
            "tasks": [{"id": "t1", "repo": "owner/repo"}],  # missing task, enabled, queued
        }
        r = client.put("/api/autoqueue", json=payload)
        assert r.status_code == 400

    def test_put_task_enabled_not_bool_returns_400(self, client):
        payload = {
            "enabled": False,
            "trigger_threshold": 2,
            "tasks": [{"id": "t1", "repo": "owner/repo", "task": "do it", "enabled": "yes", "queued": False}],
        }
        r = client.put("/api/autoqueue", json=payload)
        assert r.status_code == 400

    def test_put_roundtrip(self, client, test_data_dir):
        payload = {"enabled": False, "trigger_threshold": 5, "tasks": []}
        client.put("/api/autoqueue", json=payload)
        r = client.get("/api/autoqueue")
        assert r.get_json()["trigger_threshold"] == 5
        # Cleanup
        (test_data_dir / "config" / "auto-queue-config.json").unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Job State API
# ---------------------------------------------------------------------------
class TestJobStateAPI:
    def test_state_with_events(self, client):
        r = client.get("/api/jobs/2026-01-01T120000Z-test-done/state")
        assert r.status_code == 200
        data = r.get_json()
        assert data["state"] == "DONE"
        assert data["iteration"] == 1
        assert data["elapsed_sec"] == 1200
        assert data["last_event"] == "job_done"

    def test_state_nonexistent_returns_null(self, client):
        r = client.get("/api/jobs/nonexistent-job/state")
        assert r.status_code == 200
        data = r.get_json()
        assert data["state"] is None
        assert data["iteration"] == 0
        assert data["elapsed_sec"] is None

    def test_state_sanitizes_job_id(self, client):
        # Path traversal is handled safely - Flask routing or sanitization prevents access
        # Flask normalizes the URL so it may return 404 before reaching the handler
        r = client.get("/api/jobs/../../etc/passwd/state")
        assert r.status_code in (200, 404)
        assert r.status_code != 500


# ---------------------------------------------------------------------------
# PRs API
# ---------------------------------------------------------------------------
class TestPRsAPI:
    def test_no_repos_returns_empty_list(self, client):
        # No repos param → empty list without needing a GitHub token
        r = client.get("/api/prs")
        assert r.status_code == 200
        assert r.get_json() == []

    def test_no_token_returns_503(self, client):
        # GITHUB_TOKEN not set in test environment → 503 when repos requested
        r = client.get("/api/prs?repos=owner/repo")
        assert r.status_code == 503

    def test_no_token_empty_repos_returns_empty(self, client):
        # Even without token, empty repos param → 200 []
        r = client.get("/api/prs?repos=")
        assert r.status_code == 200
        assert r.get_json() == []


# ---------------------------------------------------------------------------
# Costs API
# ---------------------------------------------------------------------------
class TestCostsAPI:
    def test_costs_no_events(self, client):
        r = client.get("/api/costs")
        assert r.status_code == 200
        data = r.get_json()
        assert data["total_usd"] == 0.0
        assert data["jobs"] == []

    def test_costs_with_cleanup_event(self, client, test_data_dir):
        jp = test_data_dir / "logs" / "2026-01-01T120000Z-test-done.jsonl"
        original = jp.read_text(encoding="utf-8")
        jp.write_text(original + '\n' + json.dumps({
            "timestamp": "2026-01-01T12:20:02Z",
            "job_id": "2026-01-01T120000Z-test-done",
            "event": "cleanup",
            "state": "DONE",
            "iteration": 1,
            "elapsed_sec": 1201,
            "detail": "duration=1201s iterations=1 cost=0.0512",
        }), encoding="utf-8")
        try:
            r = client.get("/api/costs")
            assert r.status_code == 200
            data = r.get_json()
            assert data["total_usd"] == pytest.approx(0.0512)
            assert len(data["jobs"]) == 1
            assert data["jobs"][0]["job_id"] == "2026-01-01T120000Z-test-done"
            assert data["jobs"][0]["cost_usd"] == pytest.approx(0.0512)
        finally:
            jp.write_text(original, encoding="utf-8")


# ---------------------------------------------------------------------------
# Kanban SSE Stream API
# ---------------------------------------------------------------------------
class TestKanbanStreamAPI:
    def test_kanban_stream_content_type(self, client):
        # Verify SSE endpoint returns correct Content-Type
        # Use buffered=False and read only headers to avoid hanging on stream
        with client.get("/api/events/kanban-stream", buffered=False) as r:
            assert r.content_type.startswith("text/event-stream")


# ---------------------------------------------------------------------------
# Priority
# ---------------------------------------------------------------------------
class TestPriority:
    def test_create_job_default_priority(self, client):
        r = client.post("/api/jobs", json={
            "repo": "https://github.com/test/repo.git",
            "task": "Test default priority",
        })
        assert r.status_code == 201
        job = r.get_json()
        assert job["priority"] == 3
        client.delete(f"/api/jobs/{job['id']}")

    def test_create_job_with_priority_1(self, client):
        r = client.post("/api/jobs", json={
            "repo": "https://github.com/test/repo.git",
            "task": "Urgent fix",
            "priority": 1,
        })
        assert r.status_code == 201
        job = r.get_json()
        assert job["priority"] == 1
        client.delete(f"/api/jobs/{job['id']}")

    def test_create_job_priority_clamped(self, client):
        # Priority must be between 1 and 5
        r = client.post("/api/jobs", json={
            "repo": "https://github.com/test/repo.git",
            "task": "Priority clamping test",
            "priority": 99,
        })
        assert r.status_code == 201
        job = r.get_json()
        assert job["priority"] == 5  # clamped to max 5
        client.delete(f"/api/jobs/{job['id']}")

    def test_rerun_preserves_priority(self, client):
        # The done job in fixtures has no priority → should default to 3 on rerun
        r = client.post("/api/jobs/2026-01-01T120000Z-test-done/rerun")
        assert r.status_code == 201
        job = r.get_json()
        assert "priority" in job
        assert 1 <= job["priority"] <= 5
        client.delete(f"/api/jobs/{job['id']}")

    def test_create_job_with_issue_number(self, client):
        r = client.post("/api/jobs", json={
            "repo": "https://github.com/test/repo.git",
            "task": "Close issue 42",
            "issue_number": 42,
            "issue_repo": "org/myrepo",
        })
        assert r.status_code == 201
        job = r.get_json()
        assert job["issue_number"] == 42
        assert job["issue_repo"] == "org/myrepo"
        client.delete(f"/api/jobs/{job['id']}")


# ---------------------------------------------------------------------------
# Pagination
# ---------------------------------------------------------------------------
class TestPagination:
    def test_default_returns_all_when_under_limit(self, client):
        r = client.get("/api/jobs")
        assert r.status_code == 200
        jobs = r.get_json()
        assert len(jobs) == 3
        assert r.headers.get("X-Total-Count") == "3"

    def test_page1_per_page2(self, client):
        r = client.get("/api/jobs?page=1&per_page=2")
        assert r.status_code == 200
        jobs = r.get_json()
        assert len(jobs) == 2
        assert r.headers.get("X-Total-Count") == "3"
        assert r.headers.get("X-Page") == "1"
        assert r.headers.get("X-Per-Page") == "2"

    def test_page2_per_page2(self, client):
        r = client.get("/api/jobs?page=2&per_page=2")
        assert r.status_code == 200
        jobs = r.get_json()
        assert len(jobs) == 1  # 3 total: page 2 has 1 remaining
        assert r.headers.get("X-Total-Count") == "3"

    def test_page_beyond_range_returns_empty(self, client):
        r = client.get("/api/jobs?page=99&per_page=50")
        assert r.status_code == 200
        jobs = r.get_json()
        assert len(jobs) == 0
        assert r.headers.get("X-Total-Count") == "3"

    def test_per_page_capped_at_200(self, client):
        r = client.get("/api/jobs?per_page=9999")
        assert r.status_code == 200
        assert r.headers.get("X-Per-Page") == "200"

    def test_x_total_count_header_present(self, client):
        r = client.get("/api/jobs?status=done")
        assert r.status_code == 200
        assert r.headers.get("X-Total-Count") == "1"


# ---------------------------------------------------------------------------
# Log Truncation
# ---------------------------------------------------------------------------
class TestLogTruncation:
    def test_tail_uses_deque_based_read(self, client):
        r = client.get("/api/logs/2026-01-01T120000Z-test-done?tail=2")
        assert r.status_code == 200
        lines = r.get_data(as_text=True).strip().split("\n")
        assert len(lines) == 2

    def test_tail_1_returns_last_line(self, client):
        r = client.get("/api/logs/2026-01-01T120000Z-test-done?tail=1")
        assert r.status_code == 200
        text = r.get_data(as_text=True).strip()
        assert "\n" not in text  # only 1 line

    def test_large_file_truncation(self, client, test_data_dir):
        import app as app_module
        log_path = test_data_dir / "logs" / "2026-01-01T120000Z-test-done.log"
        original = log_path.read_text(encoding="utf-8")
        original_limit = app_module.MAX_LOG_BYTES
        try:
            # Set a very small limit so any file triggers truncation
            app_module.MAX_LOG_BYTES = 10
            r = client.get("/api/logs/2026-01-01T120000Z-test-done")
            assert r.status_code == 200
            text = r.get_data(as_text=True)
            assert "先頭部分省略" in text
        finally:
            app_module.MAX_LOG_BYTES = original_limit

    def test_small_file_not_truncated(self, client):
        # Default limit is 5MB; our test log is tiny
        r = client.get("/api/logs/2026-01-01T120000Z-test-done")
        assert r.status_code == 200
        text = r.get_data(as_text=True)
        assert "先頭部分省略" not in text
        assert "Starting job" in text


# ---------------------------------------------------------------------------
# Costs Cache
# ---------------------------------------------------------------------------
class TestCostCache:
    def test_cache_populated_after_request(self, client):
        import app as app_module
        app_module._costs_cache["data"] = None
        app_module._costs_cache["ts"] = 0.0

        r = client.get("/api/costs")
        assert r.status_code == 200
        assert app_module._costs_cache["data"] is not None
        assert app_module._costs_cache["ts"] > 0

    def test_cache_served_within_ttl(self, client):
        import app as app_module
        # Pre-populate cache with a sentinel value
        sentinel = {"total_usd": 9999.0, "jobs": [], "_sentinel": True}
        app_module._costs_cache["data"] = sentinel
        app_module._costs_cache["ts"] = time.time()  # fresh timestamp

        r = client.get("/api/costs")
        assert r.status_code == 200
        data = r.get_json()
        assert data["total_usd"] == 9999.0  # served from cache

    def test_cache_expires_after_ttl(self, client):
        import app as app_module
        sentinel = {"total_usd": 9999.0, "jobs": []}
        app_module._costs_cache["data"] = sentinel
        app_module._costs_cache["ts"] = time.time() - (app_module._COSTS_TTL + 1)

        r = client.get("/api/costs")
        assert r.status_code == 200
        data = r.get_json()
        assert data["total_usd"] != 9999.0  # cache expired, recalculated


# ---------------------------------------------------------------------------
# Duration Cache
# ---------------------------------------------------------------------------
class TestDurationCache:
    def test_done_job_duration_cached(self, client):
        import app as app_module
        app_module._duration_cache.clear()

        # api_jobs enriches done jobs and should populate the cache
        r = client.get("/api/jobs?status=done")
        assert r.status_code == 200
        jobs = r.get_json()
        assert len(jobs) == 1
        assert jobs[0]["duration_sec"] == 1200

        # Cache should now contain the done job's duration
        assert "2026-01-01T120000Z-test-done" in app_module._duration_cache
        assert app_module._duration_cache["2026-01-01T120000Z-test-done"] == 1200

    def test_pending_job_not_cached(self, client, test_data_dir):
        import app as app_module
        pending = {
            "id": "2026-01-04T000000Z-pending-cache-test",
            "repo": "https://github.com/test/x.git",
            "task": "cache test",
            "commands": {"setup": [], "test": []},
            "time_budget_sec": 3600,
            "max_retries": 2,
            "gpu_required": False,
            "created_at": "2026-01-04T00:00:00Z",
        }
        p = test_data_dir / "jobs" / "pending" / "2026-01-04T000000Z-pending-cache-test.json"
        p.write_text(json.dumps(pending), encoding="utf-8")
        app_module._duration_cache.clear()
        try:
            r = client.get("/api/jobs?status=pending")
            assert r.status_code == 200
            jobs = r.get_json()
            pending_job = next((j for j in jobs if j["id"] == pending["id"]), None)
            assert pending_job is not None
            assert pending_job["duration_sec"] is None
            # Pending job must NOT be in cache
            assert pending["id"] not in app_module._duration_cache
        finally:
            p.unlink(missing_ok=True)

    def test_cached_value_returned_on_second_call(self, client):
        import app as app_module
        app_module._duration_cache.clear()

        # First call
        client.get("/api/jobs?status=done")
        assert "2026-01-01T120000Z-test-done" in app_module._duration_cache

        # Overwrite cache with sentinel to verify second call uses cache
        app_module._duration_cache["2026-01-01T120000Z-test-done"] = 42

        r = client.get("/api/jobs?status=done")
        jobs = r.get_json()
        assert jobs[0]["duration_sec"] == 42  # returned from cache, not re-read


# ---------------------------------------------------------------------------
# Login Rate Limiting
# ---------------------------------------------------------------------------
class TestRateLimit:
    def test_repeated_failures_return_429(self, auth_client):
        import app as app_module
        app_module._login_attempts.clear()
        for _ in range(app_module._RATE_LIMIT_MAX):
            auth_client.post("/login", data={"token": "wrong"})
        # The next attempt should be rate-limited
        r = auth_client.post("/login", data={"token": "wrong"})
        assert r.status_code == 429

    def test_success_clears_attempts(self, auth_client):
        import app as app_module
        app_module._login_attempts.clear()
        # A couple of failures first
        for _ in range(2):
            auth_client.post("/login", data={"token": "wrong"})
        # Correct token: should succeed and clear the counter
        r = auth_client.post("/login", data={"token": "test-secret-123"})
        assert r.status_code == 302
        ip = "127.0.0.1"
        assert len(app_module._login_attempts.get(ip, [])) == 0

    def test_rate_limit_window_expires(self, auth_client):
        import app as app_module
        app_module._login_attempts.clear()
        ip = "127.0.0.1"
        # Inject attempts that are older than the window
        old_ts = time.time() - (app_module._RATE_LIMIT_WINDOW + 10)
        app_module._login_attempts[ip] = [old_ts] * app_module._RATE_LIMIT_MAX
        # Should NOT be rate-limited because all attempts are expired
        r = auth_client.post("/login", data={"token": "wrong"})
        assert r.status_code != 429

    def test_no_rate_limit_without_auth_enabled(self, client):
        """When DASHBOARD_TOKEN is not set, login redirects immediately (no POST check)."""
        for _ in range(10):
            r = client.post("/login", data={"token": "anything"})
            # Without auth, /login always redirects
            assert r.status_code == 302


# ---------------------------------------------------------------------------
# Cancel API
# ---------------------------------------------------------------------------
class TestCancel:
    def test_cancel_pending_job(self, client):
        r = client.post("/api/jobs", json={"repo": "https://github.com/test/cancel.git", "task": "Cancel me"})
        assert r.status_code == 201
        job_id = r.get_json()["id"]

        r2 = client.post(f"/api/jobs/{job_id}/cancel")
        assert r2.status_code == 200
        j = r2.get_json()
        assert j["cancelled"] == job_id
        assert j["was"] == "pending"

        # Verify it's gone
        r3 = client.get(f"/api/jobs/{job_id}")
        assert r3.status_code == 404

    def test_cancel_running_job(self, client, test_data_dir):
        job_id = "2026-01-10T000000Z-test-cancel-running"
        job = {
            "id": job_id,
            "repo": "https://github.com/test/r.git",
            "base_ref": "main",
            "work_branch": "agent/" + job_id,
            "task": "cancel running test",
            "commands": {},
            "time_budget_sec": 3600,
            "gpu_required": False,
            "created_at": "2026-01-10T00:00:00Z",
        }
        p = test_data_dir / "jobs" / "running" / f"{job_id}.json"
        p.write_text(json.dumps(job), encoding="utf-8")
        try:
            r = client.post(f"/api/jobs/{job_id}/cancel")
            assert r.status_code == 200
            j = r.get_json()
            assert j["cancelled"] == job_id
            assert j["was"] == "running"
            # Verify cancelled flag written to file
            updated = json.loads(p.read_text(encoding="utf-8"))
            assert updated.get("cancelled") is True
        finally:
            p.unlink(missing_ok=True)

    def test_cancel_nonexistent_returns_404(self, client):
        r = client.post("/api/jobs/nonexistent-job-id/cancel")
        assert r.status_code == 404

    def test_cancel_done_job_returns_404(self, client):
        r = client.post("/api/jobs/2026-01-01T120000Z-test-done/cancel")
        assert r.status_code == 404

    def test_cancel_path_traversal_blocked(self, client):
        r = client.post("/api/jobs/../../../etc/passwd/cancel")
        assert r.status_code in (400, 404)


# ---------------------------------------------------------------------------
# Legacy compatibility - keep the original runner for backward compat
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
