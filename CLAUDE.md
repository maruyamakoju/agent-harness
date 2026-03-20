# CLAUDE.md - Autonomous Coding Agent Behavior Rules

You are an autonomous coding agent running in a 24/7 headless loop.
There is NO human in the loop during your execution. Follow these rules strictly.

## Core Principles

1. **One task per iteration.** Focus on a single feature, fix, or subtask. Do not try to do everything at once.
2. **Tests are mandatory.** Never commit code that doesn't pass the project's test suite. If no tests exist, write them first.
3. **Progress logging is mandatory.** Update `claude-progress.txt` after every successful commit.
4. **Small, atomic commits.** Each commit should represent one logical change with a descriptive message.
5. **Never push directly to main/master.** Work only on the assigned feature branch.

## Workflow Per Iteration

1. Read `claude-progress.txt` and `requirements.json` to understand current state
2. Pick the next incomplete subtask
3. Implement the subtask (write code, modify files)
4. Run tests to verify
5. If tests pass → commit with descriptive message → update `claude-progress.txt`
6. If tests fail → fix the issue → re-run tests → repeat (max 3 fix attempts per subtask)

## File Rules

- **DO** read and modify files within the project workspace
- **DO** create new files when needed for the implementation
- **DO NOT** access files outside `/workspaces/` directory
- **DO NOT** modify `.git/config` or any git configuration
- **DO NOT** access `/etc/`, `/home/agent/.ssh/`, or any system files

## Git Rules

- Commit message format: `<type>(<scope>): <description>`
  - Types: `feat`, `fix`, `test`, `refactor`, `docs`, `chore`
- Never amend commits
- Never force push
- Never rebase onto main
- Never delete branches

## Testing Rules

- Always run the project's test suite before committing
- If you add a new feature, add corresponding tests
- If you fix a bug, add a regression test
- If tests fail after 3 fix attempts, log the failure in `claude-progress.txt` and move to the next subtask

## Safety Rules

- Do not install new system packages (apt, yum, etc.)
- Do not modify system configuration
- Do not access network resources other than the project's defined dependencies
- Do not use `sudo` or escalate privileges
- Do not execute arbitrary scripts from the internet
- Do not access environment variables containing secrets

## Progress File Format

```markdown
# Progress Log
## Task: <original task description>
## Status: IN_PROGRESS | COMPLETED | BLOCKED

### Completed
- [x] Subtask 1: <description> (commit: <hash>)
- [x] Subtask 2: <description> (commit: <hash>)

### In Progress
- [ ] Subtask 3: <description>

### Blocked
- [ ] Subtask 4: <description> - Reason: <why blocked>

### Notes
- <any important observations or decisions>
```

## Core Freeze Policy (v0.6.0, 2026-03-13)

The harness core is **frozen**. This means:

### Permitted harness changes
1. **Evaluator integrity** — scoring accuracy bugs, baseline file format corrections
2. **Rollback / concurrency / data-loss** — preventing workspace corruption or lost commits
3. **Ledger schema stabilization** — additive schema changes that preserve backward compat

### Not permitted without explicit unfreeze
- Dashboard features or UI changes
- OpenClaw / chat integration
- New stop policies or loop variants
- Subagent role complexity additions
- New language/framework support
- Any run-job.sh state machine changes outside the permitted list

### What to work on instead
The human-editable research surface is **PROGRAM.md**. Change arena rules there.
Compare results using `scripts/compare-programs.sh` after running A/B experiments with
`scripts/create-variant-jobs.sh`.

---

## Standard Operational Profile (v0.7.1, 2026-03-20)

Validated across 8+ experiments. Use these settings for new product runs.

### Default (production)
```
max_files_changed: 3
max_files_created: 2
max_diff_lines:    150
max_discards_in_a_row: 3
min_improvement_delta: 0.01
max_plateau_loops: 2
```

### Eval Weights (v0.7.1 — quality focus)
```
tests: 0.30
lint: 0.15
typecheck: 0.10
coverage: 0.15    # ↑ from 0.05 — now measured via pytest --cov
security: 0.05
feature_coverage: 0.25  # ↑ from 0.20
```

Arena Contract **must** include:
- Ledger-reading as first rule (read EVALS/ledger.jsonl before planning)
- baseline-pinned feature_coverage (SCAFFOLD generates EVALS/features-baseline.json)
- Quality Requirements: edge-case tests, input validation, modular code, pytest-cov, DB indexes

### Experimental (A/B comparison only)
```
max_files_changed: 5
max_files_created: 4
max_diff_lines:    300
max_discards_in_a_row: 5
```
Same ledger-read requirement. Use `scripts/create-variant-jobs.sh` to generate pairs.

### Rationale
- **Tight caps (3/2)**: enforce 1-feature-per-loop; agent never exceeded cap in v1 (9/9 KEEP)
- **Ledger-read**: fixes PROGRESS.md rollback memory loss; DiscrRecovery 0→1 in v2.1
- **Baseline-pinned**: prevents early stop via extra features; confirmed in bmark-cli-002 (13-feature baseline)

---

## MCP Server Integration

Two MCP servers are configured in `.claude/mcp_servers.json`:

### Ollama (local LLM)
- **Usage**: Call for lightweight tasks, code review, or when minimising API cost is important
- Tool prefix: `ollama-review__*`

### RevenueCat MCP (`revenuecat`)
- **URL**: `https://mcp.revenuecat.ai/mcp`
- **Auth**: `REVENUECAT_API_KEY` environment variable (set in `.env`)
- **26 tools across 6 categories**: products, entitlements, offerings, paywalls, customer management, subscription analytics
- **Usage examples**:
  - List products: use `revenuecat__list_products`
  - Get subscription metrics: use `revenuecat__get_charts`
  - Create entitlement: use `revenuecat__create_entitlement`
  - Manage offerings: use `revenuecat__list_offerings`, `revenuecat__create_offering`
- **When to use**: Any task involving subscription monetization, pricing experiments, or RevenueCat API integration
- **Authentication note**: Requires `REVENUECAT_API_KEY` in environment. If not set, RevenueCat tools will fail with auth error — log this and continue with other tasks.
