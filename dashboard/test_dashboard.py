"""
Smoke test for the Agent Dashboard.
Run: python test_dashboard.py
Tests all API endpoints against real data on disk.
"""

import json
import os
import sys
import tempfile
import shutil
from pathlib import Path

# Point HARNESS_DIR at the real project data
PROJECT_ROOT = Path(__file__).resolve().parent.parent
os.environ["HARNESS_DIR"] = str(PROJECT_ROOT)
# Disable auth for tests
os.environ.pop("DASHBOARD_TOKEN", None)

from app import app  # noqa: E402

client = app.test_client()
PASSED = 0
FAILED = 0


def check(name: str, response, expected_status: int = 200):
    global PASSED, FAILED
    ok = response.status_code == expected_status
    if ok:
        PASSED += 1
        print(f"  PASS  {name} ({response.status_code})")
    else:
        FAILED += 1
        print(f"  FAIL  {name} - expected {expected_status}, got {response.status_code}")
        try:
            print(f"        Body: {response.get_data(as_text=True)[:200]}")
        except Exception:
            pass
    return ok


def main():
    global PASSED, FAILED
    print("=" * 60)
    print("Dashboard Smoke Test")
    print("=" * 60)

    # --- Page routes ---
    print("\n[Pages]")
    check("GET /", client.get("/"))
    check("GET /login (no auth mode, redirects)", client.get("/login"), 302)

    # --- Status API ---
    print("\n[Status API]")
    r = client.get("/api/status")
    check("GET /api/status", r)
    if r.status_code == 200:
        data = r.get_json()
        assert "heartbeat" in data, "Missing heartbeat in status"
        assert "counts" in data, "Missing counts in status"
        print(f"        counts: {data['counts']}")

    # --- Jobs API ---
    print("\n[Jobs API]")
    r = client.get("/api/jobs")
    check("GET /api/jobs", r)
    jobs = r.get_json() if r.status_code == 200 else []
    print(f"        {len(jobs)} jobs found")

    r = client.get("/api/jobs?status=done")
    check("GET /api/jobs?status=done", r)

    r = client.get("/api/jobs?status=running")
    check("GET /api/jobs?status=running", r)

    # Job detail for first job
    if jobs:
        jid = jobs[0]["id"]
        r = client.get(f"/api/jobs/{jid}")
        check(f"GET /api/jobs/{jid}", r)
        if r.status_code == 200:
            detail = r.get_json()
            print(f"        pr_url: {detail.get('pr_url', 'none')}")

    check("GET /api/jobs/nonexistent-id", client.get("/api/jobs/nonexistent-id"), 404)

    # --- Create + Delete Job ---
    print("\n[Job Create/Delete]")
    r = client.post("/api/jobs", json={
        "repo": "https://github.com/test/test-repo.git",
        "task": "Smoke test job - please ignore",
        "time_budget": 300,
    })
    check("POST /api/jobs (create)", r, 201)
    if r.status_code == 201:
        new_job = r.get_json()
        new_id = new_job["id"]
        print(f"        created: {new_id}")

        # Verify it exists
        r2 = client.get(f"/api/jobs/{new_id}")
        check(f"GET /api/jobs/{new_id} (verify)", r2)

        # Delete it
        r3 = client.delete(f"/api/jobs/{new_id}")
        check(f"DELETE /api/jobs/{new_id}", r3)

        # Verify deletion
        r4 = client.get(f"/api/jobs/{new_id}")
        check(f"GET /api/jobs/{new_id} (after delete)", r4, 404)

    # Validation
    r = client.post("/api/jobs", json={"repo": "", "task": ""})
    check("POST /api/jobs (missing fields)", r, 400)

    # --- Logs API ---
    print("\n[Logs API]")
    if jobs:
        jid = jobs[0]["id"]
        r = client.get(f"/api/logs/{jid}")
        if r.status_code == 200:
            check(f"GET /api/logs/{jid}", r)
            text = r.get_data(as_text=True)
            print(f"        log size: {len(text)} chars")
        else:
            check(f"GET /api/logs/{jid}", r, 404)

        r = client.get(f"/api/logs/{jid}?tail=5")
        if r.status_code == 200:
            check(f"GET /api/logs/{jid}?tail=5", r)
            lines = r.get_data(as_text=True).strip().split("\n")
            print(f"        tail lines: {len(lines)}")

        r = client.get(f"/api/logs/{jid}/events")
        if r.status_code == 200:
            check(f"GET /api/logs/{jid}/events", r)
            events = r.get_json()
            print(f"        events: {len(events)}")
        else:
            check(f"GET /api/logs/{jid}/events", r, 404)

    check("GET /api/logs/nonexistent", client.get("/api/logs/nonexistent"), 404)

    # --- Notifications API ---
    print("\n[Notifications API]")
    r = client.get("/api/notifications")
    check("GET /api/notifications", r)
    if r.status_code == 200:
        notifs = r.get_json()
        print(f"        {len(notifs)} notifications")

    r = client.get("/api/notifications?tail=5")
    check("GET /api/notifications?tail=5", r)

    # --- Admin API ---
    print("\n[Admin API]")
    r = client.get("/api/admin/log-stats")
    check("GET /api/admin/log-stats", r)
    if r.status_code == 200:
        stats = r.get_json()
        print(f"        {len(stats['files'])} log files, total: {stats['total_bytes']} bytes")

    # --- Auth test ---
    print("\n[Auth]")
    # Set a token and test that routes are protected
    os.environ["DASHBOARD_TOKEN"] = "test-secret-token-12345"
    from importlib import reload
    import app as app_module
    reload(app_module)
    auth_app = app_module.app
    auth_app.config["TESTING"] = True
    auth_client = auth_app.test_client()

    r = auth_client.get("/api/status")
    check("GET /api/status (no auth)", r, 401)

    r = auth_client.get("/api/status", headers={"Authorization": "Bearer test-secret-token-12345"})
    check("GET /api/status (bearer auth)", r, 200)

    r = auth_client.post("/login", data={"token": "wrong-token"})
    check("POST /login (wrong token)", r, 200)  # renders login page with error

    r = auth_client.post("/login", data={"token": "test-secret-token-12345"}, follow_redirects=False)
    check("POST /login (correct token)", r, 302)  # redirect to /

    os.environ.pop("DASHBOARD_TOKEN", None)

    # --- Summary ---
    print("\n" + "=" * 60)
    total = PASSED + FAILED
    print(f"Results: {PASSED}/{total} passed, {FAILED} failed")
    print("=" * 60)
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
