# costctl-001 Observation Report
## Experiment: First real product run — API Cost Tracker CLI
## Date: 2026-03-14
## Profile: Production (strict caps: files=3/2, diff=150, discards=3, ledger-read first)
## Duration: 1931s (~32 min)

---

## Results Summary

| Loop | Verdict | files_changed | Score |
|---|---|---|---|
| 1 | keep | 3 files | 0.2500→0.6750 |
| 2 | discard_audit | 9 > max=3 | 0.6750→0.6750 |
| 3 | discard_audit | 8 > max=3 | 0.6750→0.6750 |
| 4 | discard_audit | 8 > max=3 | 0.6750→0.6750 |

Stop: `consecutive_discard_stop (3 >= 3)` at loop 4.
Final score: 0.6750 (F-001 done, F-002..F-008 not-started).

---

## What Worked

### Arena health (3/3 observable criteria)

**1. Loop 1: clean 1-feature-per-loop execution**
- F-001 implemented in 3 files: pyproject.toml (modified), src/costctl/main.py (new), tests/test_init.py (new)
- Within caps (3 modified, 2 created). CODE_AUDIT: all caps OK.
- pytest 2/2, ruff clean, mypy clean. KEEP (0.25→0.675).
- Score jump: +0.425. Tests + typecheck passed (was 0, now 1).

**2. Ledger-reading worked in loops 3-4**
- Loop 3 PLAN (from log): "F-002 complete (reduced scope — 2 files only): 1 changed + 1 created, reduced from loop 2's 3 files"
- Loop 4 PLAN: "Last verdict: discard_audit (loop 3, files_touched: '', 2 consecutive). Consecutive discards = 2; stop at 3. Response: Same 2-file minimum scope (already reduced from loop 2's 3 files). No further reduction possible while still delivering testable value."
- Agent correctly read the ledger, understood the consecutive discard count, and correctly analyzed the stop condition.

**3. FEATURES.md stayed fixed at 8 features**
- Setup pre-created FEATURES.md with F-001..F-008 (8 features).
- Scaffold Claude did NOT expand the list.
- Baseline frozen at 8 features. Score delta per feature = 0.20/8 = 0.025.

---

## What Failed: Root Cause

**All 3 discard_audit loops have the same root cause: missing `*.egg-info` in .gitignore**

When the CODE agent runs `pip install -e .` (editable install), Python creates:
```
src/costctl.egg-info/
  METADATA
  SOURCES.txt
  top_level.txt
  entry_points.txt
```
These 4+ files are NOT in .gitignore (which has `__pycache__/`, `*.pyc`, `.venv/` but NOT `*.egg-info`).

When the agent commits with `git add .`, the egg-info files are included.
Git diff from PRE_CODE_COMMIT shows: 2 intentional files + 4+ egg-info files = 6-9 total.
CODE_AUDIT counts all of them: files_changed=9 > max=3 → discard_audit.

**Evidence:**
- Loop 1 CODE_AUDIT: all caps OK (3 files: pyproject.toml + main.py + test_init.py)
  → Loop 1 didn't trigger pip install -e . (or didn't add egg-info before commit)
- Loops 2-4: files_changed=9, 8, 8 consistently despite agent saying "2 files"
- .gitignore in workspace has no `*.egg-info` entry
- PLAN in loop 4 correctly deduced "2 files" but CODE committed more due to egg-info

**Agent's self-diagnosis was incorrect (but understandable):**
Loop 4 PLAN: "The harness appears to evaluate against the pre-implementation state."
In reality: the harness evaluates correctly, but egg-info artifacts inflated the count.

---

## Human Review

### Is F-001 actually usable?

Yes. costctl init works:
```bash
costctl init          # creates ~/.costctl.db with usage + budgets tables
costctl init          # second call: idempotent (no error)
```

The CLI scaffolds correctly:
- `src/costctl/main.py`: Typer multi-command app, get_db_path (COSTCTL_DB env),
  init_db (CREATE TABLE IF NOT EXISTS usage + budgets), `costctl init` command
- 2 tests passing: init creates DB, second init idempotent

### Hypothesis→mutation→verdict chain legible?

Yes, loop 1 is clean:
- Hypothesis: implement F-001 (scaffold + init)
- Mutation: 3 files, 95 lines, within caps
- Verdict: KEEP (0.25→0.675)
- Ledger reason: fully legible

### What's the next defect to fix?

**Fix .gitignore in setup commands** — this is the only blocker.

---

## Proposed costctl-002 Fix

Add to setup commands (after pyproject.toml creation):
```bash
printf '__pycache__/\n*.pyc\n*.pyo\n*.egg-info/\n.eggs/\n.pytest_cache/\n.mypy_cache/\n.venv/\nenv/\n*.db\n.env\n.DS_Store\ndist/\nbuild/\n.coverage\nhtmlcov/\n' > .gitignore
```

This ensures that:
- `*.egg-info/` directories are ignored (editable installs)
- `.pytest_cache/`, `.mypy_cache/` are ignored (test/type-check caches)
- `*.db` is ignored (SQLite databases generated during tests)
- `.coverage` is ignored (pytest-cov output)

With this fix, each CODE loop should commit only the intentional files:
- F-001: pyproject.toml (modified), src/costctl/main.py (new), tests/test_init.py (new) → 3 files ✓
- F-002: src/costctl/main.py (modified), tests/test_import.py (new) → 2 files ✓

---

## Arena Verdict

| Criterion | Result |
|---|---|
| 5+ loops stable forward progress | ✗ (stopped at 4, only 1 KEEP) |
| Human-legible hypothesis→verdict | ✓ (loop 1 fully legible) |
| Final artifact usable | Partial (F-001 usable, F-002+ blocked) |
| Target score | ✗ (0.6750, not 1.0) |
| Discard recovery | ✓ (ledger-read worked; agent correctly diagnosed problem) |

**Conclusion**: Not a failure of the arena. A setup bug (missing .gitignore entries) caused artificial cap violations. costctl-002 with .gitignore fix should run cleanly to completion.

---

## Artifact

Workspace preserved at: `workspaces/costctl-001/`
F-001 implemented: `src/costctl/main.py`, `tests/test_init.py`
