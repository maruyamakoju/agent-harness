# Soak Test Observation

## Experiment

| Field | Value |
|-------|-------|
| Job ID | soak-fastapi-001 |
| Product | FastAPI Notes API (FastAPI+Pydantic v2+SQLite) |
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
| **duration_sec** | 578 |

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
- init.sh failed (non-fatal, continued correctly) — same pip permission issue as CLI soak.
- pytest-asyncio deprecation warning about `asyncio_default_fixture_loop_scope` — cosmetic, does not affect test results.
- Permission denial on `git commit` — harness-level commit handled correctly.
- Security soft-pass triggered correctly for unauditable packages.
- Cross-product validation: FastAPI (async, httpx, Pydantic v2) uses the same arena pipeline as CLI (typer, rich) without modification.

---

## Verdict

| | |
|---|---|
| **Result** | PASS |
| **Next action** | No issues found. Arena works cross-product. Same 1-loop behavior as CLI. |

---

## Observation

Both soak experiments (CLI + FastAPI) reached target_score in a single loop, confirming:
1. The arena pipeline (EVAL_BASELINE → PLAN → CODE → CODE_AUDIT → TEST → JUDGE → LEDGER → LOOP_CHECK) is stable.
2. Security soft-pass (PR#6) and control char stripping (PR#8) work correctly in real runs.
3. Cross-product behavior is identical — no product-specific bugs.
4. No time-dependent issues observed.

**Limitation**: Both products are solved in 1 loop (0.30 → 1.00), so multi-loop stress paths (discard, rollback, consecutive_discard_stop, plateau_stop) were NOT exercised in this soak. Those paths were validated in Experiments #3, #6, #7 with MOCK and real runs.
