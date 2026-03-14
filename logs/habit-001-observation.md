# habit-001 Observation Report
## Experiment: Daily Habit Tracker CLI — different domain (consumer app)
## Date: 2026-03-14
## Profile: Production (strict caps: files=3/2, diff=150, discards=3, ledger-read first)
## Duration: 3176s (~53 min)

---

## Results Summary

| Loop | Verdict | Score Before | Score After | Note |
|---|---|---|---|---|
| 1 | keep | 0.2500 | 0.6750 | F-001 scaffold + init |
| 2 | keep | 0.6750 | 0.8250 | F-002 + F-003 add/done |
| 3 | keep | 0.8250 | 0.8500 | F-004 today view |
| 4 | keep | 0.8500 | 0.8750 | F-005 streak |
| 5 | keep | 0.8750 | 0.9000 | F-006 summary |
| 6 | discard_audit | 0.9000 | — | diff_lines=249 > max=150 |
| 7 | keep | 0.9000 | 0.9250 | scope reduced; F-007 list |
| 8 | keep | 0.9250 | 0.9500 | F-008 export |
| 9 | keep | 0.9500 | 0.9750 | coverage push |
| 10 | keep | 0.9750 | **1.0000** | final push |

Stop: `target_score_reached (1.0000 >= 1.00)` at loop 10.

---

## Full Validation Summary (all real product runs to date)

| Product | Architecture | Domain | Loops | KEEPs | KeepRate | Discards | Duration | Score |
|---|---|---|---|---|---|---|---|---|
| bmark-cli-002 | Python CLI | Bookmark Mgr | 10 | 10 | 1.0000 | 0 | 3269s | 1.0000 |
| costctl-002 | Python CLI | API Cost Tracker | 11 | 8 | 0.7273 | 3 | 3359s | 1.0000 |
| costctl-api-001 | FastAPI HTTP API | API Cost Tracker | 9 | 8 | 0.8889 | 1 | 2726s | 1.0000 |
| habit-001 | Python CLI | Habit Tracker | 10 | 9 | 0.9000 | 1 | 3176s | 1.0000 |

**4/4 real product runs → target_score_reached. 3 domains. 2 architectures.**

---

## Discard Analysis

### Loop 6 — discard_audit (diff_lines=249 > 150)

- Largest diff_lines violation observed across all runs (249 vs cap=150)
- Most likely cause: streak calculation (F-005 or F-006) requires complex date logic
  spanning multiple functions — inherently more verbose than simple CRUD features
- Ledger-read worked correctly: loop 7 reduced scope → KEEP (0.9000→0.9250)
- DiscrRecovery = 1.0000

**Note on diff_lines=249**: This is substantially above the cap (1.66×), unlike the
previous borderline cases (153, 165). Streak/summary date logic may genuinely require
more than 150 lines for a clean, tested implementation. Worth monitoring across future runs
to determine if cap should be raised for date-heavy features.

---

## Arena Health: Consumer App Domain

| Criterion | Result |
|---|---|
| Different domain (not developer tool) | ✓ (habit tracker) |
| Baseline fixed at 8 features | ✓ |
| No file-count violations | ✓ (0/10 loops) |
| Ledger-read discard recovery | ✓ (1/1) |
| target_score_reached | ✓ (1.0000) |
| Duration comparable to other runs | ✓ (3176s vs avg 3132s) |

---

## Cross-Run Metrics (4 runs)

| Metric | Min | Max | Avg |
|---|---|---|---|
| Loops to target | 9 | 11 | 10.0 |
| Duration (s) | 2726 | 3359 | 3130 |
| KeepRate | 0.7273 | 1.0000 | 0.8790 |
| DiscrRecovery | 1.0000 | 1.0000 | 1.0000 |
| File-count violations | 0 | 0 | 0 |

**DiscrRecovery = 1.0000 across all 4 runs** — ledger-read mechanism is fully reliable.
**File-count violations = 0 across all 4 runs** — .gitignore fix held in all cases.

---

## Conclusion

habit-001 confirms that the standard profile generalizes to consumer-domain apps,
not just developer tools. The arena is domain-agnostic within the Python + SQLite stack.

The diff_lines=249 violation in loop 6 is the first time we've seen a violation
substantially above the cap (not just borderline). This is a signal to watch —
if future date-logic-heavy features consistently hit 200+ lines, cap=160 may not be
sufficient and a different strategy (split the feature further) may be needed.

For now: the arena works. 4/4 runs → 1.0000.
