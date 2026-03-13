# PROGRAM.md — Strict Arena (v1)

## Product: {{PRODUCT_NAME}}

## Objective

Maximize composite quality score through hypothesis-driven mutations.
Each loop must produce a small, testable increment — not a large batch.

## Mutation Scope

- Max files changed per loop: 3
- Max files created per loop: 2
- Max diff lines per loop: 150
- Max endpoint/route changes per loop: 1

## Eval Protocol

weights:
  tests: 0.35
  lint: 0.20
  typecheck: 0.15
  coverage: 0.05
  security: 0.05
  feature_coverage: 0.20

## Keep/Discard Policy

- keep_threshold: score_after > score_before
- tie_policy: discard

## Budget

- max_loops: 10
- max_wall_seconds: 14400
- max_discards_in_a_row: 3

## Stop Conditions

- target_score: 1.00
- min_improvement_delta: 0.01
- max_plateau_loops: 2
- consecutive_discards >= max_discards_in_a_row

## Hypothesis Sources

- FEATURES.md, eval failures, coverage gaps

## Arena Contract

- Choose exactly one baseline feature or one blocking defect per loop.
- Before making changes, search the codebase. Do not assume missing implementation.
- Do not create scratch, debug, or temp files.
- Do not edit scoring files, eval scripts, or EVALS/features-baseline.json.
- Run the smallest relevant test first, then full eval.
- Update FEATURES.md status only for baseline feature IDs.
- KEEP only if score improves and audit passes.
- If tests break, fix them in the SAME loop before moving on.
- Prefer depth (thorough tests for one feature) over breadth.
