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
  tests: 0.45
  lint: 0.25
  typecheck: 0.20
  coverage: 0.05
  security: 0.05

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

- FEATURES.md, eval failures, coverage gaps, agent observations

## Arena Rules

- Each hypothesis must target exactly ONE feature or ONE eval improvement
- Do NOT implement multiple features in a single loop
- If tests break, fix them in the SAME loop before moving on
- Prefer depth (thorough tests for one feature) over breadth (many features with no tests)
