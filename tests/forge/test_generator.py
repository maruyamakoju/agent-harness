"""Tests for forge.generator — job generation from descriptions."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from forge.generator import (
    _detect_product_type,
    _extract_product_name,
    _slugify,
    generate_job,
)


# ---------------------------------------------------------------------------
# _slugify
# ---------------------------------------------------------------------------


class TestSlugify:
    def test_expense_tracker_cli(self) -> None:
        assert _slugify("Expense Tracker CLI") == "expense-tracker"

    def test_api_suffix_removed(self) -> None:
        assert _slugify("Cost Controller API") == "cost-controller"

    def test_tool_suffix_removed(self) -> None:
        assert _slugify("Budget Tool") == "budget"

    def test_already_lowercase(self) -> None:
        assert _slugify("myapp") == "myapp"

    def test_special_characters(self) -> None:
        result = _slugify("My App! (v2)")
        assert result == "my-app-v2"

    def test_only_suffix_returns_slug(self) -> None:
        # "CLI" alone is not matched by the suffix regex (requires leading space)
        # so it becomes "cli"
        assert _slugify("CLI") == "cli"

    def test_empty_after_stripping_returns_product(self) -> None:
        assert _slugify("") == "product"

    def test_app_suffix_removed(self) -> None:
        assert _slugify("Todo App") == "todo"

    def test_multiple_spaces(self) -> None:
        result = _slugify("  Multi   Space  CLI  ")
        assert "--" not in result  # No double hyphens
        assert result == "multi-space"


# ---------------------------------------------------------------------------
# _detect_product_type
# ---------------------------------------------------------------------------


class TestDetectProductType:
    def test_cli_keyword(self) -> None:
        # No explicit CLI keyword match → defaults to cli
        assert _detect_product_type("Build a CLI expense tracker") == "cli"

    def test_api_keyword(self) -> None:
        assert _detect_product_type("Build a REST API for costs") == "api"

    def test_fastapi_keyword(self) -> None:
        assert _detect_product_type("Build a FastAPI service") == "api"

    def test_http_keyword(self) -> None:
        assert _detect_product_type("Build an HTTP server") == "api"

    def test_endpoint_keyword(self) -> None:
        assert _detect_product_type("Create CRUD endpoints") == "api"

    def test_default_is_cli(self) -> None:
        assert _detect_product_type("Build a budget tracker") == "cli"

    def test_case_insensitive(self) -> None:
        assert _detect_product_type("Build a REST Api for tracking") == "api"


# ---------------------------------------------------------------------------
# _extract_product_name
# ---------------------------------------------------------------------------


class TestExtractProductName:
    def test_build_a_pattern(self) -> None:
        name = _extract_product_name("Build a daily habit tracker in Python")
        assert "Habit" in name or "Daily" in name

    def test_create_an_pattern(self) -> None:
        name = _extract_product_name("Create an expense tracker CLI")
        assert name  # Should extract something non-empty

    def test_fallback_first_words(self) -> None:
        name = _extract_product_name("something without a verb pattern here")
        assert name  # Should return something


# ---------------------------------------------------------------------------
# generate_job
# ---------------------------------------------------------------------------


class TestGenerateJob:
    @patch("forge.generator._claude_available", return_value=False)
    def test_generates_valid_job(self, mock_claude: object, tmp_path: Path) -> None:
        """generate_job produces a JobConfig with required fields."""
        # Temporarily change examples dir context
        with patch("forge.generator.Path", return_value=tmp_path):
            job = generate_job(
                description="Build an expense tracker CLI",
                product_name="Expense Tracker",
                num_features=4,
            )

        assert job.id  # Non-empty
        assert job.repo == "local://create"
        assert job.product_name == "Expense Tracker"
        assert job.task  # Non-empty task description
        assert job.commands.setup  # Has setup commands
        assert job.commands.test  # Has test commands
        assert job.program_md  # Has PROGRAM.md content
        assert job.mode == "product"

    @patch("forge.generator._claude_available", return_value=False)
    def test_cli_type_uses_cli_template(self, mock_claude: object) -> None:
        job = generate_job(
            description="Build a bookmark manager CLI",
            product_name="Bookmark Manager",
            num_features=4,
        )
        assert "pytest" in " ".join(job.commands.setup)
        assert "typer" in " ".join(job.commands.setup).lower() or "pip" in " ".join(job.commands.setup).lower()

    @patch("forge.generator._claude_available", return_value=False)
    def test_api_type_uses_api_template(self, mock_claude: object) -> None:
        job = generate_job(
            description="Build a REST API for cost tracking",
            product_name="Cost API",
            num_features=4,
        )
        # API template includes fastapi
        assert "fastapi" in " ".join(job.commands.setup).lower()

    @patch("forge.generator._claude_available", return_value=False)
    def test_num_features_respected(self, mock_claude: object) -> None:
        job = generate_job(
            description="Build a task manager CLI",
            product_name="Task Manager",
            num_features=3,
        )
        # The FEATURES.md in setup should have exactly 3 features
        assert "F-003" in job.task
        assert "F-004" not in job.task

    @patch("forge.generator._claude_available", return_value=False)
    def test_work_branch_set(self, mock_claude: object) -> None:
        job = generate_job(
            description="Build a notes CLI",
            product_name="Notes CLI",
        )
        assert job.work_branch.startswith("forge/")

    @patch("forge.generator._claude_available", return_value=False)
    def test_program_md_contains_weights(self, mock_claude: object) -> None:
        job = generate_job(
            description="Build a timer CLI",
            product_name="Timer",
        )
        assert "tests: 0.30" in job.program_md
        assert "lint: 0.15" in job.program_md
        assert "feature_coverage: 0.25" in job.program_md
