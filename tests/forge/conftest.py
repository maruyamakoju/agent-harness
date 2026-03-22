"""Shared fixtures for Product Forge test suite."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


@pytest.fixture()
def tmp_workspace(tmp_path: Path) -> Path:
    """Create a temporary workspace directory with EVALS/ and a git repo."""
    evals_dir = tmp_path / "EVALS"
    evals_dir.mkdir()

    # Initialize a bare-minimum git repo
    subprocess.run(
        ["git", "init"],
        cwd=str(tmp_path),
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "test"],
        cwd=str(tmp_path),
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "config", "user.email", "test@test.com"],
        cwd=str(tmp_path),
        check=True,
        capture_output=True,
    )

    # Create an initial commit so HEAD exists
    readme = tmp_path / "README.md"
    readme.write_text("# test\n", encoding="utf-8")
    subprocess.run(
        ["git", "add", "-A"],
        cwd=str(tmp_path),
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "commit", "-m", "initial"],
        cwd=str(tmp_path),
        check=True,
        capture_output=True,
    )

    return tmp_path


@pytest.fixture()
def sample_program_md() -> str:
    """Return a realistic PROGRAM.md string with standard v0.7.1 weights."""
    return """\
# PROGRAM.md - Test Product (test-001)

## Product: Test Product

## Objective

Maximize composite quality score through hypothesis-driven mutations.

## Mutation Scope

- Max files changed per loop: 3
- Max files created per loop: 2
- Max diff lines per loop: 200

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

## Budget

- max_loops: 12
- max_wall_seconds: 14400
- max_discards_in_a_row: 3

## Stop Conditions

- target_score: 1.00
- min_improvement_delta: 0.01
- max_plateau_loops: 3

## Arena Contract

- Read EVALS/ledger.jsonl before choosing your hypothesis.

## Quality Requirements

- Edge-case tests mandatory
- Input validation
- Modular code
"""


@pytest.fixture()
def sample_features_md() -> str:
    """Return FEATURES.md with 8 features: 4 done, 4 not-started."""
    return """\
# Feature Tracker

## Product: Test Product

### Features

| ID | Feature | Status | Priority | Notes |
|----|---------|--------|----------|-------|
| F-001 | Scaffold + init command | done | P0 | Setup |
| F-002 | Add command | done | P0 | CRUD |
| F-003 | List command | done | P0 | Query |
| F-004 | Summary command | done | P0 | Stats |
| F-005 | Budget command | not-started | P1 | Limits |
| F-006 | Search command | not-started | P1 | Search |
| F-007 | Categories command | not-started | P2 | Tags |
| F-008 | Export command | not-started | P2 | Export |

### Backlog
_(none)_
"""
