# PROGRAM.md — Autoresearch Program Definition

## Product: {{PRODUCT_NAME}}

## Objective

Maximize composite quality score through hypothesis-driven mutations.
Each loop must produce a small, testable increment — not a large batch.

## Mutation Scope

- Max files changed per loop: 5
- Max files created per loop: 4
- Max diff lines per loop: 300
- Max endpoint/route changes per loop: 1

## Eval Protocol

weights:
  tests: 0.30
  lint: 0.15
  typecheck: 0.10
  coverage: 0.15
  security: 0.05
  feature_coverage: 0.25

## Keep/Discard Policy

- keep_threshold: score_after > score_before
- tie_policy: discard

## Budget

- max_loops: {{MAX_LOOPS}}
- max_wall_seconds: {{TIME_BUDGET}}
- max_discards_in_a_row: 3

## Stop Conditions

- target_score: 1.00
- min_improvement_delta: 0.01
- max_plateau_loops: 2
- consecutive_discards >= max_discards_in_a_row

## Hypothesis Sources

- FEATURES.md, eval failures, coverage gaps, EVALS/ledger.jsonl

## Arena Contract

- **FIRST: Read EVALS/ledger.jsonl before choosing your hypothesis.**
  Find the most recent entry. Check the "verdict" field.
  If verdict was "discard_audit", your next hypothesis MUST reduce scope (fewer files).
  Write your hypothesis as: "Last verdict: <verdict> | Response: <your adaptation>"
- Choose exactly one baseline feature or one blocking defect per loop.
- Before making changes, search the codebase. Do not assume missing implementation.
- Do not create scratch, debug, or temp files.
- Do not edit scoring files, eval scripts, or EVALS/features-baseline.json.
- Run the smallest relevant test first, then full eval.
- Update FEATURES.md status only for baseline feature IDs.
- KEEP only if score improves and audit passes.
- If tests break, fix them in the SAME loop before moving on.
- Prefer depth (thorough tests for one feature) over breadth (many features with no tests).

## Quality Requirements

- **Edge-case tests mandatory**: Every feature MUST include at least one test for invalid input,
  empty results, or boundary conditions (e.g., bad date format, missing required arg, zero items).
- **Input validation**: All user-facing commands must validate arguments and print a clear,
  actionable error message for bad input. Never let exceptions propagate as raw tracebacks.
- **Modular code**: When source exceeds 150 lines, split into separate modules
  (e.g., db.py for database, cli.py for commands, models.py for data types).
  One monolithic file is not acceptable.
- **pytest-cov required**: Include `pytest-cov` in dev dependencies. Coverage is measured
  automatically — aim for ≥80% line coverage.
- **Database indexes**: Add indexes on columns used in WHERE/ORDER BY clauses
  (e.g., project, date, status). Full table scans are not acceptable for query features.
