# PROGRAM.md — Relaxed Arena (v2)

## Product: {{PRODUCT_NAME}}

## Objective

Maximize composite quality score through hypothesis-driven mutations.
Each loop must produce a small, testable increment — not a large batch.

## Mutation Scope

- Max files changed per loop: 5
- Max files created per loop: 4
- Max diff lines per loop: 300
- Max endpoint/route changes per loop: 2

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
- max_discards_in_a_row: 5

## Stop Conditions

- target_score: 1.00
- min_improvement_delta: 0.005
- max_plateau_loops: 3
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
