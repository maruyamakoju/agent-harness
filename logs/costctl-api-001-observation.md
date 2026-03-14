# costctl-api-001 Observation Report
## Experiment: FastAPI HTTP API — same domain, different architecture
## Date: 2026-03-14
## Profile: Production (strict caps: files=3/2, diff=150, discards=3, ledger-read first)
## Duration: 2726s (~45 min)

---

## Results Summary

| Loop | Verdict | Score Before | Score After | Note |
|---|---|---|---|---|
| 1 | keep | 0.2500 | 0.6750 | F-001 scaffold + health |
| 2 | discard_audit | 0.6750 | — | files_changed=4 > max=3 |
| 3 | keep | 0.6750 | 0.8500 | scope reduced; F-002+F-003 |
| 4 | keep | 0.8500 | 0.8750 | F-004 summary |
| 5 | keep | 0.8750 | 0.9000 | F-005 list+filter |
| 6 | keep | 0.9000 | 0.9250 | F-006 budget |
| 7 | keep | 0.9250 | 0.9500 | F-007 forecast |
| 8 | keep | 0.9500 | 0.9750 | F-008 export |
| 9 | keep | 0.9750 | **1.0000** | final coverage push |

Stop: `target_score_reached (1.0000 >= 1.00)` at loop 9.
Final score: **1.0000** (all F-001..F-008 done, 23 tests passing).

---

## Cross-Stack Comparison (same domain, different architecture)

| Metric | costctl-002 (CLI) | costctl-api-001 (FastAPI) |
|---|---|---|
| Total loops | 11 | **9** |
| KEEPs | 8 | **8** |
| KeepRate | 0.7273 | **0.8889** |
| Discards | 3 (2 diff + 1 regression) | **1 (files)** |
| DiscrRecovery | 2/2 = 1.000 | **1/1 = 1.000** |
| Duration | 3359s | **2726s** |
| Final score | 1.0000 | 1.0000 |
| Tests at completion | 16 | **23** |
| File-count violations | 0 | 1 (intentional, not egg-info) |
| Diff-lines violations | 2 | **0** |

FastAPI run was **faster** (−633s), **fewer discards**, and **more tests** written.

---

## Discard Analysis

### Loop 2 — discard_audit (files_changed=4 > max=3)

- Agent attempted to implement F-002 (import) + F-003 (normalization) in a single loop
- Touching 4 files: main.py + db.py + models.py + test_import.py (or similar)
- This is a **genuine scope violation** — not an artifact (no egg-info or build output)
- Ledger-read correctly triggered: loop 3 PLAN reduced scope
- Loop 3 KEEP (0.6750→0.8500) — DiscrRecovery = 1.0000

**Key finding**: The strict cap (files=3/2) correctly detected a real scope issue.
The ledger-reading instruction enabled immediate correction.

---

## Full Validation Summary (all real product runs)

| Product | Architecture | Domain | Loops | KEEPs | Score | Stop |
|---|---|---|---|---|---|---|
| bmark-cli-002 | Python CLI | Bookmark Manager | 10 | 10 | 0.25→1.00 | max_loops |
| costctl-002 | Python CLI | API Cost Tracker | 11 | 8 | 0.25→1.00 | target_score |
| costctl-api-001 | FastAPI HTTP API | API Cost Tracker | 9 | 8 | 0.25→1.00 | target_score |

**3/3 real product runs reached 1.0000.**
**2 architectures (CLI + FastAPI HTTP API) validated.**
**Standard profile (strict caps + ledger-read + baseline-pinned) is confirmed production-ready.**

---

## Test Coverage at Completion (23 tests)

| Test file | Feature | Tests |
|---|---|---|
| test_health.py | F-001 (scaffold, /health, DB init) | 2 |
| test_import.py | F-002 (POST /usage/import) + F-003 (normalization) | 5 |
| test_summary.py | F-004 (GET /summary?day|week|month) | 4 |
| test_usage_list.py | F-005 (GET /usage with filters) | 4 |
| test_budgets.py | F-006 (PUT /budgets + GET /budgets/report) | 3 |
| test_forecast.py | F-007 (GET /forecast) | 2 |
| test_export.py | F-008 (GET /export?format=json|csv) | 3 |

All 8 features have dedicated tests. 23/23 pass. ruff clean. mypy clean.

---

## Arena Verdict

### Standard Profile: CONFIRMED PRODUCTION-READY

| Criterion | Result |
|---|---|
| Cross-stack compatibility (FastAPI) | ✓ |
| Baseline fixed at 8 features | ✓ |
| Ledger-read discard recovery (1/1) | ✓ |
| file-count cap detects genuine scope (not artifacts) | ✓ |
| diff_lines cap: 0 violations this run | ✓ |
| target_score_reached in 9 loops | ✓ |

### Conclusion

With 3 real product runs (2 CLI + 1 FastAPI), the arena's external validity is confirmed:

- **CLI + FastAPI** both converge to 1.0000 under the same strict profile
- **Ledger-read recovery** is consistent across all runs (DiscrRecovery=1.0)
- **Setup defects** (egg-info) are resolved; remaining discards are legitimate arena behavior
- **Duration** is predictable: 2726–3359s for an 8-feature product (~45–56 min)

**Recommendation**: Arena validation is complete. Move to using the arena to build products
rather than validating the arena itself. Next milestone: v0.7 planning.

---

## Artifact

Workspace removed at DONE (local-only repo, no remote).
23 tests: FastAPI TestClient covering all F-001..F-008 endpoints.
