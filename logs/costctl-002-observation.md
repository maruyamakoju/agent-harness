# costctl-002 Observation Report
## Experiment: Real product run — API Cost Tracker CLI (.gitignore fix)
## Date: 2026-03-14
## Profile: Production (strict caps: files=3/2, diff=150, discards=3, ledger-read first)
## Duration: 3359s (~56 min)

---

## Results Summary

| Loop | Verdict | Score Before | Score After | Note |
|---|---|---|---|---|
| 1 | keep | 0.2500 | 0.6750 | F-001 scaffold |
| 2 | keep | 0.6750 | 0.8250 | F-002/F-003 import+normalization |
| 3 | discard_audit | 0.8250 | — | diff_lines=165 > max=150 |
| 4 | keep | 0.8250 | 0.8750 | F-004 summary |
| 5 | discard_regression | 0.8750 | — | CODE_AUDIT OK; score fell |
| 6 | keep | 0.8750 | 0.9000 | F-005 list+filter |
| 7 | keep | 0.9000 | 0.9250 | F-006 budget |
| 8 | keep | 0.9250 | 0.9500 | F-007 forecast |
| 9 | keep | 0.9500 | 0.9750 | F-008 export |
| 10 | discard_audit | 0.9750 | — | diff_lines=153 > max=150 |
| 11 | keep | 0.9750 | 1.0000 | final coverage push |

Stop: `target_score_reached (1.0000 >= 1.00)` at loop 11.
Final score: **1.0000** (all F-001..F-008 done).

---

## Primary Finding: .gitignore Fix Confirmed

### costctl-001 vs costctl-002 comparison

| Metric | costctl-001 | costctl-002 |
|---|---|---|
| File-count violations | 3 (loops 2,3,4: files=9,8,8) | **0** |
| Diff-lines violations | 0 | 2 (loops 3,10: 165,153) |
| Regression discards | 0 | 1 (loop 5) |
| Total discards | 3 | 3 |
| KEEPs | 1 | **8** |
| Final score | 0.6750 (stuck) | **1.0000** |
| Stop reason | consecutive_discard_stop | target_score_reached |

The `*.egg-info/` .gitignore fix completely eliminated file-count violations.
All 3 discards in costctl-002 were unrelated to the original bug.

---

## Discard Analysis

### Loop 3 — discard_audit (diff_lines=165 > 150)
- CODE_AUDIT correctly detected the violation
- Ledger-read worked: loop 4 reduced scope and KEEP'd (0.8250→0.8750)
- DiscrRecovery: ✓

### Loop 5 — discard_regression
- CODE_AUDIT: all caps OK (files and diff within limits)
- JUDGE discarded because score_after < score_before
- No consecutive count accumulated (different verdict type from discard_audit)
- Loop 6 KEEP'd (0.8750→0.9000) immediately after

### Loop 10 — discard_audit (diff_lines=153 > 150)
- Very close to cap (only 3 lines over)
- Loop 11 reduced scope, KEEP'd (0.9750→1.0000) → target_score_reached

---

## Arena Health

| Criterion | Result |
|---|---|
| .gitignore fix eliminates file-count violations | ✓ (0/11 loops violated file caps) |
| Baseline fixed at 8 features (no scaffold expansion) | ✓ (baseline frozen at 8) |
| Ledger-read discard recovery | ✓ (loops 4, 11 both recovered) |
| Forward progress every 2 loops | ✓ (no plateau) |
| Human-legible hypothesis→verdict | ✓ |
| Target score reached | ✓ (1.0000) |
| Final artifact usable (16 tests, ruff, mypy clean) | ✓ |

---

## Residual Issues

### diff_lines=150 cap is tight for some features

Loop 3 hit 165, loop 10 hit 153 — both within ~10% over cap.
These were legitimate implementations (not padding), reduced by the agent in the next loop.

**Options:**
1. Keep cap=150 — agent recovers cleanly via ledger-read (demonstrated here)
2. Raise to cap=160 — would have prevented both discard_audits (saving ~2 loops)
3. No change needed — 2 discard_audits out of 11 is acceptable for strict mode

**Recommendation:** Keep cap=150 for now. The recovery mechanism works. Loosening caps
should be reserved for A/B experiments, not default profile changes.

### discard_regression (loop 5)

Score regression after CODE_AUDIT pass is normal arena behavior.
The agent introduced a change that broke some score component (likely coverage or typecheck).
Immediate recovery in loop 6 — no systemic issue.

---

## Score Trajectory

```
0.25 → 0.675 → 0.825 → DISC → 0.875 → DISC → 0.90 → 0.925 → 0.95 → 0.975 → DISC → 1.00
 L1     L2      L3             L4       L5     L6     L7      L8     L9      L10     L11
```

---

## Arena Verdict

**Conclusion**: costctl-002 validates the arena end-to-end with a real Python product.

- `.gitignore` fix (egg-info): root cause resolved ✓
- FEATURES.md baseline-pinned at 8: no scaffold expansion ✓
- Ledger-read: discard recovery functional (2/2 discard_audits recovered) ✓
- Production profile (strict caps): sufficient for real products ✓
- Duration: 3359s, comparable to bmark-cli-002 (3269s) ✓

**costctl is the second validated real product in the arena** (after bmark-cli-002).
Arena setup defects are now fully resolved. The standard profile is production-ready.

---

## Artifact

Workspace preserved at: `workspaces/costctl-002/` (removed at DONE)
All 8 features implemented, 16 tests passing, ruff + mypy clean.
