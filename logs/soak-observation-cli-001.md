# Soak Test Observation

## Experiment

| Field | Value |
|-------|-------|
| Job ID | soak-cli-001 |
| Product | TaskForge CLI (typer+rich+SQLite) |
| Date | 2026-03-11 |
| max_loops | 10 |
| time_budget_sec | 32400 (9h) |

---

## Stop Condition

| Field | Value |
|-------|-------|
| **stop_reason** | `target_score_reached` |
| **final_loop** | 1 / 10 |
| **final_score** | 1.0000 |
| **duration_sec** | 615 |

---

## Score Progression

| Loop | SCORE_BEFORE | SCORE_AFTER | Verdict |
|------|-------------|-------------|---------|
| 1 | 0.3000 | 1.0000 | keep |

---

## Eval Breakdown (final loop)

| Eval | pass |
|------|------|
| unit (tests) | true |
| lint | true |
| typecheck | true |
| security-scan | true (soft-pass, unauditable packages only) |

---

## Keep / Discard Counts

| | Count |
|---|---|
| keep | 1 |
| discard_regression | 0 |
| discard_audit | 0 |
| **CONSECUTIVE_DISCARDS max** | 0 |
| **PLATEAU_COUNT max** | 0 |

---

## Ledger Integrity

| Check | Result |
|-------|--------|
| ledger.jsonl line count | 1 line |
| All lines valid JSON | yes (workspace cleaned, verified via log output) |
| No missing loops | yes (loop 1 only) |

---

## CODE_AUDIT Results

| Check | Result |
|-------|--------|
| Mutation cap check | all caps OK |
| Files changed | within limit |
| Files created | within limit |

---

## Time-Dependent Issues Observed

- [ ] ledger corruption mid-run
- [ ] eval JSON parse error (jq fails)
- [ ] init.sh failure worsens over loops
- [ ] rollback leaves stale state
- [ ] plateau/discard priority out of order
- [ ] workspace cleanup missed files

**Notes:**
- init.sh failed (non-fatal, continued correctly) — Claude tried to pip install which triggered a permission error on Windows Store Python. This is pre-existing and harmless.
- CRLF warnings on .gitignore and README.md — Windows line ending normalization, not a bug.
- Permission denial on `git commit` (agent tried to commit directly) — harness-level commit handled it correctly.
- Security soft-pass triggered correctly: "no CVEs found (unauditable packages only)"

---

## Verdict

| | |
|---|---|
| **Result** | PASS |
| **Next action** | No issues found. Agent solves TaskForge CLI in 1 loop consistently. |

---

## Observation

The soak was designed for 10 loops to stress multi-loop behavior, but the agent achieves target_score (1.0000) in a single loop. This matches Exp#8 behavior. The 10-loop soak did not reveal new failure modes because the agent never enters discard/rollback paths.

To stress multi-loop behavior in future soaks, consider:
- Lowering mutation caps (max_files_changed=2, max_files_created=1)
- Adding stricter eval requirements (coverage threshold)
- Using a more complex product specification
