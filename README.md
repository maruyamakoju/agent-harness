# 24/7 Autonomous Coding Agent System

Claude Code (Headless) + Custom Harness + Hooks + Docker Sandboxing

RTX 4090 High-Spec Local Machine Runner

## Quick Start

```bash
# 1. Clone to your Ubuntu 24.04 runner
git clone <this-repo> ~/agent-harness && cd ~/agent-harness

# 2. Configure secrets
cp .env.example .env && nano .env

# 3. Deploy (first time - does everything)
sudo bash scripts/deploy.sh --full

# 4. Submit your first job
bash scripts/create-job.sh \
  --repo git@github.com:your-org/your-repo.git \
  --task "Add user authentication with JWT" \
  --setup "npm ci" \
  --test "npm test"

# 5. Watch it work
bash scripts/monitor.sh watch
```

## Architecture

```
RTX 4090 Machine (Ubuntu 24.04 Headless)
│
├─ Host OS (Layer 0) ─────────────── Hardened, minimal
│   ├─ systemd: agent-harness.service
│   ├─ Docker Engine + NVIDIA Container Toolkit
│   ├─ Tailscale (VPN overlay)
│   ├─ Ollama (GPU → local LLM for cost reduction)
│   └─ UPS monitor (apcupsd)
│
├─ Docker Container (Layer 1) ────── Isolated, egress-restricted
│   ├─ agent user (unprivileged, no sudo)
│   ├─ agent-loop.sh              ← 24/7 polling loop
│   ├─ run-job.sh                 ← per-job state machine
│   ├─ Claude Code CLI (headless)
│   │   ├─ --allowedTools         ← whitelist only
│   │   ├─ /sandbox (bubblewrap)  ← Layer 2 double isolation
│   │   └─ hooks/block-dangerous.sh ← 100+ blocked patterns
│   ├─ jobs/  (pending → running → done/failed)
│   └─ logs/  (JSONL structured events)
│
└─ Output: Git Branch → PR → CI → Human Review → Merge
```

## Security Model (5 Layers)

| Layer | Component | Protection |
|-------|-----------|------------|
| 1 | Docker Container | dropped capabilities, non-root, no-new-privileges |
| 2 | Claude /sandbox | bubblewrap filesystem/network isolation |
| 3 | Hooks | 100+ dangerous command patterns blocked deterministically |
| 4 | Egress Firewall | iptables whitelist: GitHub, npm, PyPI, Anthropic only |
| 5 | Git PR Gate | No direct push to main/master, CI required |

## Job Lifecycle

```
CLONE → SETUP → INIT → CODE ⇄ TEST → PUSH → DONE
                         ↓              ↓
                       FAILED ←───── FAILED
                     (partial push)
```

| State | Action | On Failure |
|-------|--------|------------|
| CLONE | `git clone --depth 50` | FAILED |
| SETUP | Run setup commands (npm ci, etc.) | FAILED |
| INIT | Initializer agent analyzes repo & creates plan | Fallback to direct CODE |
| CODE | Coding agent implements one subtask per iteration | Retry with error context |
| TEST | Run test commands | Fix agent → retest, or back to CODE |
| PUSH | `git push` + `gh pr create` | FAILED |

**Circuit Breakers:** 3 stalls without commit → abort. 5 repeated errors → abort. Time budget exceeded → partial push. 3 consecutive job failures → 10 min pause.

## Commands Reference

### Job Management

```bash
# Create a job
scripts/create-job.sh --repo <git-url> --task "<description>" \
  [--setup "<cmd>"] [--test "<cmd>"] [--time-budget <sec>] [--gpu]

# List jobs
scripts/list-jobs.sh [pending|running|done|failed|all] [--json]

# Cancel a job
scripts/cancel-job.sh <job-id-pattern>

# View job log
scripts/view-job-log.sh <job-id> [--summary|--errors|--states|--follow]
```

### Monitoring

```bash
scripts/monitor.sh           # One-shot dashboard
scripts/monitor.sh watch     # Live auto-refresh (5s)
```

### Deployment

```bash
sudo scripts/deploy.sh --full       # First-time full setup
scripts/deploy.sh --update           # Pull & restart
scripts/deploy.sh --rebuild          # Force rebuild
scripts/deploy.sh --status           # Show status
scripts/deploy.sh --stop             # Stop agent
```

### Validation

```bash
scripts/validate.sh          # Pre-deployment checks
scripts/smoke-test.sh        # End-to-end smoke test
```

### Job Submission Channels

| Channel | Setup |
|---------|-------|
| SSH | `ssh agent@machine 'scripts/create-job.sh --repo ... --task ...'` |
| Telegram | `systemctl start telegram-bot` (see templates/) |
| GitHub Issues | Label issue with `agent` → auto-creates job (via cron) |
| Cron | See `templates/crontab.example` |

## GPU Utilization (RTX 4090)

Claude Code uses cloud API, but the GPU powers:

- **Ollama (local LLM)**: DeepSeek-Coder-V2 for code review, Phi-3.5 for classification. Reduces API cost.
- **GPU-accelerated testing**: Playwright with GPU rendering
- **ML workloads**: Training/inference for ML-focused jobs

```bash
# Setup Ollama
bash scripts/setup-ollama.sh

# MCP integration is preconfigured in .claude/mcp_servers.json
```

## File Manifest

| File | Purpose |
|------|---------|
| **Core** | |
| `Dockerfile` | Container: Ubuntu 24.04, non-root, GPU, no setuid binaries |
| `docker-compose.yml` | Orchestration: GPU reservation, volumes, networking |
| `CLAUDE.md` | Agent behavior rules (injected into workspace) |
| `.claude/settings.json` | Tool permissions whitelist + hook config |
| `.claude/mcp_servers.json` | Ollama MCP integration |
| **Agent Loop** | |
| `scripts/agent-loop.sh` | 24/7 main loop, circuit breaker, heartbeat |
| `scripts/run-job.sh` | State machine, stall detection, conversation resume |
| **Job Management** | |
| `scripts/create-job.sh` | Job JSON generator CLI |
| `scripts/list-jobs.sh` | List/filter jobs |
| `scripts/cancel-job.sh` | Cancel pending/running jobs |
| `scripts/view-job-log.sh` | Log viewer with colorized output |
| **Security** | |
| `hooks/block-dangerous.sh` | PreToolUse hook: 100+ blocked patterns |
| `scripts/setup-egress.sh` | Docker network egress iptables whitelist |
| `scripts/persist-iptables.sh` | Persist egress rules across reboots |
| **Monitoring** | |
| `scripts/monitor.sh` | Dashboard (one-shot / live) |
| `scripts/watchdog.sh` | External heartbeat checker (cron) |
| `scripts/gpu-monitor.sh` | GPU temperature/usage monitoring |
| `scripts/notify.sh` | Telegram/Discord/Slack notifications |
| **Deployment** | |
| `scripts/deploy.sh` | Full deployment automation |
| `scripts/setup-host.sh` | Host provisioning (Ubuntu 24.04) |
| `scripts/setup-ollama.sh` | Ollama + model setup |
| `scripts/validate.sh` | Pre-deployment validation |
| `scripts/smoke-test.sh` | End-to-end smoke test |
| `scripts/cleanup.sh` | Disk space management (cron) |
| **Job Channels** | |
| `scripts/telegram-bot.sh` | Telegram bot for job submission |
| `scripts/github-issue-handler.sh` | GitHub Issues → jobs |
| **Templates** | |
| `templates/agent-harness.service` | systemd unit |
| `templates/telegram-bot.service` | Telegram bot systemd unit |
| `templates/crontab.example` | Cron jobs |
| `templates/apcupsd.conf` | UPS monitoring config |
| `templates/apccontrol-hooks.sh` | UPS event handlers |

## Troubleshooting

### Agent not starting
```bash
docker compose logs --tail 50
scripts/deploy.sh --status
```

### Job stuck in running
```bash
scripts/view-job-log.sh <job-id> --errors
scripts/cancel-job.sh <job-id>
```

### Container unhealthy
```bash
# Check heartbeat
cat logs/heartbeat.json | jq .

# Restart
docker compose restart
```

### GPU not available in container
```bash
# Verify NVIDIA runtime
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

### Egress rules lost after reboot
```bash
sudo scripts/persist-iptables.sh restore
# Or install auto-restore:
sudo scripts/persist-iptables.sh auto
```

## Cost Estimate

| Item | Monthly | Notes |
|------|---------|-------|
| Hardware | $0 | Existing RTX 4090 machine |
| Electricity | ~$30-50 | 24/7, 450W TDP |
| Claude API | $50-300 | Usage-dependent, Sonnet-primary |
| Tailscale | $0 | Personal plan |
| GitHub | $0 | Free tier |
| **Total** | **$80-350** | |

## MCP Server Integration

Two MCP servers are pre-configured for the agent:

### Ollama (Local LLM)

Used for code review and lightweight classification tasks without API cost.

```bash
# Setup Ollama with recommended models
bash scripts/setup-ollama.sh

# Models used: DeepSeek-Coder-V2, Phi-3.5
```

### RevenueCat MCP

Connect the agent directly to RevenueCat's subscription API using the official [RevenueCat MCP server](https://www.revenuecat.com/docs/tools/mcp).

**Setup:**
```bash
# Add to .env
REVENUECAT_API_KEY=rc_sk_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

**The agent can now:**
- Create and manage products, entitlements, and offerings
- Configure paywalls programmatically
- Query subscription analytics and customer data
- Run pricing experiments via the Charts API

**26 tools across 6 categories**: products, entitlements, offerings, paywalls, customer management, analytics

## RevenueCat Integration

Agent-harness is designed as an "agent-first" platform for subscription app development. With RevenueCat MCP:

```bash
# Example: Create a subscription job
scripts/create-job.sh \
  --repo git@github.com:your-org/app.git \
  --task "Integrate RevenueCat SDK, create monthly/annual offerings, and add paywall screen" \
  --setup "npm ci" \
  --test "npm test"
```

The agent will:
1. Integrate the RevenueCat SDK into your app
2. Use RevenueCat MCP tools to create matching products and entitlements
3. Configure offerings with your pricing tiers
4. Implement and test the paywall UI
5. Open a PR with the complete implementation

**Observability:** Monitor costs and job performance at `http://localhost:7860`. The `/metrics` endpoint exports Prometheus-compatible data for Grafana dashboards.

```bash
# Check Prometheus metrics
curl http://localhost:7860/metrics

# Batch-create jobs across multiple repos
curl -X POST http://localhost:7860/api/v1/jobs/batch \
  -H "Authorization: Bearer $DASHBOARD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jobs": [{"repo": "...", "task": "..."}, ...]}'
```

## Security Guide

### Token Rotation

If a GitHub token is compromised:
1. Revoke at [github.com/settings/tokens](https://github.com/settings/tokens)
2. Generate a new token with the same scopes (`repo`, `read:org`, `workflow`)
3. Update `.env`: `GITHUB_TOKEN=ghp_NEW_TOKEN`
4. Restart: `docker compose restart agent`

If REVENUECAT_API_KEY is compromised:
1. Revoke at [app.revenuecat.com/settings/api-keys](https://app.revenuecat.com/settings/api-keys)
2. Generate a new secret key
3. Update `.env` and restart

**Never commit `.env` to git.** It is in `.gitignore` by default.
