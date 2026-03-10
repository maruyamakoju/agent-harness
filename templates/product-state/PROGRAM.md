# PROGRAM.md — Autoresearch Program Definition

## Product: {{PRODUCT_NAME}}

## Objective

Maximize composite quality score through hypothesis-driven mutations.

## Mutation Scope

- Max files changed per loop: 3
- Max files created per loop: 2
- Max diff lines per loop: 250
- Max endpoint/route changes per loop: 1

## Eval Protocol

weights:
  tests: 0.40
  lint: 0.20
  typecheck: 0.15
  coverage: 0.15
  security: 0.10

## Keep/Discard Policy

- keep_threshold: score_after > score_before
- tie_policy: discard

## Budget

- max_loops: {{MAX_LOOPS}}
- max_wall_seconds: {{TIME_BUDGET}}
- max_discards_in_a_row: 5

## Stop Conditions

- score >= 0.95
- consecutive_discards >= max_discards_in_a_row

## Hypothesis Sources

- FEATURES.md, eval failures, coverage gaps, agent observations
