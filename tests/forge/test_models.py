"""Tests for forge.models — Pydantic data models."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from forge.models import (
    AuditResult,
    EvalWeights,
    Feature,
    JobConfig,
    LedgerEntry,
    MutationCaps,
    ProgramSpec,
    Verdict,
)


# ---------------------------------------------------------------------------
# JobConfig
# ---------------------------------------------------------------------------


class TestJobConfig:
    def test_from_json_file(self, tmp_path: Path) -> None:
        data = {
            "id": "test-001",
            "repo": "local://create",
            "task": "Build a CLI tool",
            "product_name": "Test CLI",
        }
        path = tmp_path / "job.json"
        path.write_text(json.dumps(data), encoding="utf-8")

        config = JobConfig.from_json_file(path)
        assert config.id == "test-001"
        assert config.product_name == "Test CLI"
        assert config.task == "Build a CLI tool"

    def test_to_json_file(self, tmp_path: Path) -> None:
        config = JobConfig(id="out-001", product_name="Output Test")
        path = tmp_path / "output.json"
        config.to_json_file(path)

        data = json.loads(path.read_text(encoding="utf-8"))
        assert data["id"] == "out-001"
        assert data["product_name"] == "Output Test"

    def test_roundtrip(self, tmp_path: Path) -> None:
        original = JobConfig(
            id="rt-001",
            repo="local://create",
            task="roundtrip test",
            product_name="Roundtrip",
            max_loops=8,
            time_budget_sec=7200,
        )
        path = tmp_path / "roundtrip.json"
        original.to_json_file(path)
        loaded = JobConfig.from_json_file(path)

        assert loaded.id == original.id
        assert loaded.max_loops == original.max_loops
        assert loaded.time_budget_sec == original.time_budget_sec

    def test_clean_example_excludes_runtime_fields(self) -> None:
        config = JobConfig(
            id="clean-001",
            agent_pid=12345,
            loop_count=5,
            last_state="CODE",
            consecutive_discards=2,
        )
        clean = config.clean_example()
        assert "agent_pid" not in clean
        assert "loop_count" not in clean
        assert "last_state" not in clean
        assert "consecutive_discards" not in clean
        assert clean["id"] == "clean-001"

    def test_is_continuation_true(self) -> None:
        config = JobConfig(id="cont-001", continue_from="base-001")
        assert config.is_continuation is True

    def test_is_continuation_false(self) -> None:
        config = JobConfig(id="new-001")
        assert config.is_continuation is False


# ---------------------------------------------------------------------------
# ProgramSpec
# ---------------------------------------------------------------------------


class TestProgramSpec:
    def test_from_program_md_parses_weights(self, sample_program_md: str) -> None:
        spec = ProgramSpec.from_program_md(sample_program_md)
        assert spec.weights.tests == pytest.approx(0.30)
        assert spec.weights.lint == pytest.approx(0.15)
        assert spec.weights.typecheck == pytest.approx(0.10)
        assert spec.weights.coverage == pytest.approx(0.15)
        assert spec.weights.security == pytest.approx(0.05)
        assert spec.weights.feature_coverage == pytest.approx(0.25)

    def test_from_program_md_parses_caps(self, sample_program_md: str) -> None:
        spec = ProgramSpec.from_program_md(sample_program_md)
        assert spec.caps.max_files_changed == 3
        assert spec.caps.max_files_created == 2
        assert spec.caps.max_diff_lines == 200

    def test_from_program_md_parses_stop_conditions(self, sample_program_md: str) -> None:
        spec = ProgramSpec.from_program_md(sample_program_md)
        assert spec.stops.target_score == pytest.approx(1.00)
        assert spec.stops.min_improvement_delta == pytest.approx(0.01)
        assert spec.stops.max_plateau_loops == 3
        assert spec.stops.max_discards_in_a_row == 3

    def test_from_program_md_parses_product_name(self, sample_program_md: str) -> None:
        spec = ProgramSpec.from_program_md(sample_program_md)
        assert spec.product_name == "Test Product"

    def test_from_program_md_parses_budget_fields(self, sample_program_md: str) -> None:
        spec = ProgramSpec.from_program_md(sample_program_md)
        assert spec.max_loops == 12
        assert spec.time_budget_sec == 14400

    def test_from_program_md_empty_string(self) -> None:
        spec = ProgramSpec.from_program_md("")
        assert spec.product_name == ""
        # Should use defaults
        assert spec.weights.tests == pytest.approx(0.30)

    def test_from_program_md_arena_contract(self, sample_program_md: str) -> None:
        spec = ProgramSpec.from_program_md(sample_program_md)
        assert "ledger.jsonl" in spec.arena_contract

    def test_from_program_md_quality_requirements(self, sample_program_md: str) -> None:
        spec = ProgramSpec.from_program_md(sample_program_md)
        assert "Edge-case" in spec.quality_requirements


# ---------------------------------------------------------------------------
# EvalWeights
# ---------------------------------------------------------------------------


class TestEvalWeights:
    def test_default_values_sum_to_one(self) -> None:
        w = EvalWeights()
        total = w.tests + w.lint + w.typecheck + w.coverage + w.security + w.feature_coverage
        assert total == pytest.approx(1.0, abs=0.01)

    def test_default_individual_values(self) -> None:
        w = EvalWeights()
        assert w.tests == pytest.approx(0.30)
        assert w.lint == pytest.approx(0.15)
        assert w.typecheck == pytest.approx(0.10)
        assert w.coverage == pytest.approx(0.15)
        assert w.security == pytest.approx(0.05)
        assert w.feature_coverage == pytest.approx(0.25)


# ---------------------------------------------------------------------------
# MutationCaps
# ---------------------------------------------------------------------------


class TestMutationCaps:
    def test_default_values(self) -> None:
        caps = MutationCaps()
        assert caps.max_files_changed == 3
        assert caps.max_files_created == 2
        assert caps.max_diff_lines == 200
        assert caps.max_endpoint_changes == 1


# ---------------------------------------------------------------------------
# LedgerEntry
# ---------------------------------------------------------------------------


class TestLedgerEntry:
    def test_now_sets_timestamp(self) -> None:
        entry = LedgerEntry.now(loop=1, hypothesis="test")
        assert entry.timestamp != ""
        assert "T" in entry.timestamp
        assert entry.timestamp.endswith("Z")

    def test_now_timestamp_format(self) -> None:
        entry = LedgerEntry.now(loop=1)
        # Format: YYYY-MM-DDTHH:MM:SSZ
        import re
        assert re.match(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", entry.timestamp)

    def test_default_verdict(self) -> None:
        entry = LedgerEntry(loop=1)
        assert entry.verdict == "keep"


# ---------------------------------------------------------------------------
# Feature
# ---------------------------------------------------------------------------


class TestFeature:
    def test_is_done_true(self) -> None:
        f = Feature(id="F-001", name="Scaffold", status="done")
        assert f.is_done is True

    def test_is_done_false_not_started(self) -> None:
        f = Feature(id="F-002", name="Add", status="not-started")
        assert f.is_done is False

    def test_is_done_false_in_progress(self) -> None:
        f = Feature(id="F-003", name="List", status="in-progress")
        assert f.is_done is False


# ---------------------------------------------------------------------------
# AuditResult
# ---------------------------------------------------------------------------


class TestAuditResult:
    def test_verdict_keep_when_passed(self) -> None:
        result = AuditResult(passed=True)
        assert result.verdict == Verdict.KEEP

    def test_verdict_discard_when_failed(self) -> None:
        result = AuditResult(passed=False, violations=["too many files"])
        assert result.verdict == Verdict.DISCARD_AUDIT

    def test_summary_passed(self) -> None:
        result = AuditResult(
            passed=True,
            files_changed=2,
            files_created=1,
            diff_lines=50,
        )
        s = result.summary()
        assert "audit OK" in s
        assert "2 files changed" in s

    def test_summary_failed(self) -> None:
        result = AuditResult(
            passed=False,
            violations=["files_changed=5 > max=3", "diff_lines=300 > max=200"],
        )
        s = result.summary()
        assert "audit FAIL" in s
        assert "files_changed=5" in s
        assert "diff_lines=300" in s
