# OpenClaw Control Plane — STATUS: SCAFFOLDED

This module is **scaffolded only** — the YAML definitions describe the intended
architecture but the backing infrastructure is not yet implemented.

## What exists (working)

| Tool | Backed by |
|------|-----------|
| `submit-job` | `POST /api/jobs` |
| `list-jobs` | `GET /api/jobs` |
| `cancel-job` | `POST /api/jobs/{id}/cancel` |
| `get-progress` | `GET /api/jobs/{id}/state-files` |
| `get-features` | `GET /api/jobs/{id}/state-files` |

## What does NOT exist yet

| Tool | Missing |
|------|---------|
| `set-priority` | No `POST /api/jobs/{id}/priority` endpoint |
| `pause-resume` | Cancel works; resume (re-queue) not implemented |
| `daily-summary` | Requires gateway orchestration layer |

## What is needed before this module is "real"

1. Implement missing API endpoints in `dashboard/app.py`
2. Build or adopt an actual gateway process (the `docker-compose.openclaw.yml` is config-only)
3. Integrate chat adapters (Telegram/Discord bots)
4. Test E2E: chat command → gateway → harness API → response
