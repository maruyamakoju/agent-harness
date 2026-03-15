# costctl-003 Observation Report
## Experiment: API Cost Tracker CLI
## Date: 2026-03-15
## Profile: Production (files=3/2, diff=200, discards=3, ledger-read first)
## Duration: 2669s (~44 min)

---

## Results Summary

| Loop | Verdict | Score | Hypothesis (truncated) |
|------|---------|-------|------------------------|
| 1 | ✓ keep | 0.2500→0.8250 | Begin with P0 foundation feature.  - Feature: F-001 (Scaffold + SQLite... |
| 2 | ✓ keep | 0.8250→0.8500 | Continue with next P0 feature.  - Feature: F-002 (Import usage data: `... |
| 3 | ✓ keep | 0.8500→0.8750 | Continue with next P0 feature.  - Feature: F-003 (Provider/model/proje... |
| 4 | ✓ keep | 0.8750→0.9000 | Continue with next P0 feature.  - Feature: F-004 (Summary: `costctl su... |
| 5 | ✓ keep | 0.9000→0.9250 | Continue with next P1 feature.  - Feature: F-005 (List + filter: `cost... |
| 6 | ✗ discard_regression | 0.9250→0.8250 | Continue with next P1 feature.  - Feature: F-006 (Budget: `costctl bud... |
| 7 | ✗ discard_regression | 0.9500→0.8250 | Continue with next P1 feature.  - Feature: F-006 (Budget: `costctl bud... |
| 8 | ✗ discard_regression | 0.9500→0.8000 | Continue with next P1 feature.  - Feature: F-006 (Budget: `costctl bud... |

Stop: `consecutive_discard_stop (3/3) at loop 8`.
Final score: 0.9500

---

## Metrics

| Metric | Value |
|--------|-------|
| Loops | 8 |
| KEEPs | 5 (0.6250) |
| Discards | 3 (0 audit, 3 regression) |
| DiscrRecovery | 0.0000 |
| Duration | 2669s |
| Score range | 0.2500→0.9500 |

---

## Feature Status

| ID | Feature | Status |
|----|---------|--------|
| F-001 | Scaffold + SQLite init + `costctl init` | done |
| F-002 | Import usage data: `costctl import <file>` | done |
| F-003 | Provider/model/project normalization | done |
| F-004 | Summary: `costctl summary [--day\ | --week\ |
| F-005 | List + filter: `costctl list [filters]` | done |
| F-006 | Budget: `costctl budget set` + `costctl budget report` | done |
| F-007 | Forecast: `costctl forecast [--days N]` | not-started |
| F-008 | Export: `costctl export [--format json\ | csv]` |

**5/8 features done.**

---

## Loop Detail

### Loop 1 — KEEP (keep)
- Score: 0.2500 → 0.8250 (+0.5750)
- Files: `FEATURES.md,PROGRESS.md,pyproject.toml,src/costctl/__init__.py,tests/test_init.py`
- Wall: 491s
- Hypothesis: Last verdict: (none — loop 0 baseline) | Response: Begin with P0 foundation feature.  - Feature: F-001 (Scaffold + SQLite init + `costctl init`) - Hypothesis: If we create src/costctl/ package (__

### Loop 2 — KEEP (keep)
- Score: 0.8250 → 0.8500 (+0.0250)
- Files: `FEATURES.md,PROGRESS.md,src/costctl/__init__.py,tests/test_import.py`
- Wall: 440s
- Hypothesis: Last verdict: keep (+0.575, 0.25→0.825) | Response: Continue with next P0 feature.  - Feature: F-002 (Import usage data: `costctl import <file>`) - Hypothesis: If we add the `import` command (CSV + 

### Loop 3 — KEEP (keep)
- Score: 0.8500 → 0.8750 (+0.0250)
- Files: `FEATURES.md,PROGRESS.md,src/costctl/__init__.py,tests/test_normalize.py`
- Wall: 221s
- Hypothesis: Last verdict: keep (0.825→0.850) | Response: Continue with next P0 feature.  - Feature: F-003 (Provider/model/project normalization) - Hypothesis: If we add a `_normalize_row()` helper that lowercas

### Loop 4 — KEEP (keep)
- Score: 0.8750 → 0.9000 (+0.0250)
- Files: `FEATURES.md,PROGRESS.md,src/costctl/__init__.py,tests/test_summary.py`
- Wall: 281s
- Hypothesis: Last verdict: keep (0.850→0.875) | Response: Continue with next P0 feature.  - Feature: F-004 (Summary: `costctl summary [--day|--week|--month]`) - Hypothesis: If we add the `summary` command with -

### Loop 5 — KEEP (keep)
- Score: 0.9000 → 0.9250 (+0.0250)
- Files: `FEATURES.md,PROGRESS.md,src/costctl/__init__.py,tests/test_list.py`
- Wall: 307s
- Hypothesis: Last verdict: keep (0.875→0.900) | Response: Continue with next P1 feature.  - Feature: F-005 (List + filter: `costctl list [filters]`) - Hypothesis: If we add a `_query_list()` helper that builds a

### Loop 6 — DISCARD (discard_regression)
- Score: 0.9250 → 0.8250 (-0.1000)
- Files: (rolled back / none)
- Wall: 443s
- Hypothesis: Last verdict: keep (0.900→0.925) | Response: Continue with next P1 feature.  - Feature: F-006 (Budget: `costctl budget set` + `costctl budget report`) - Hypothesis: If we add a `budget` sub-app with

### Loop 7 — DISCARD (discard_regression)
- Score: 0.9500 → 0.8250 (-0.1250)
- Files: (rolled back / none)
- Wall: 286s
- Hypothesis: Last verdict: keep (0.900→0.925) | Response: Continue with next P1 feature.  - Feature: F-006 (Budget: `costctl budget set` + `costctl budget report`) - Hypothesis: If we add a `budget` sub-app with

### Loop 8 — DISCARD (discard_regression)
- Score: 0.9500 → 0.8000 (-0.1500)
- Files: (rolled back / none)
- Wall: 200s
- Hypothesis: Last verdict: keep (0.900→0.925) | Response: Continue with next P1 feature.  - Feature: F-006 (Budget: `costctl budget set` + `costctl budget report`) - Hypothesis: If we add a `budget` sub-app with

---

## Arena Verdict

| Criterion | Result |
|-----------|--------|
| 5+ loops stable forward progress | ✓ |
| All discards recovered | ✗ |
| Target score reached | ✗ |
| Human-legible hypothesis→verdict chain | ✓ |

**Workspace**: `workspaces/costctl-003/`

*Auto-generated by scripts/generate-observation.py*