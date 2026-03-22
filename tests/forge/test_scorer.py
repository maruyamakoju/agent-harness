"""Tests for forge.scorer — composite scoring logic."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from forge.models import EvalWeights
from forge.scorer import (
    compute_composite_score,
    compute_feature_coverage,
    compute_score_breakdown,
    parse_weights_from_program_md,
    score_coverage,
)


# ---------------------------------------------------------------------------
# score_coverage
# ---------------------------------------------------------------------------


class TestScoreCoverage:
    def test_zero_percent(self) -> None:
        assert score_coverage(0.0) == 0.0

    def test_forty_percent(self) -> None:
        assert score_coverage(40.0) == pytest.approx(0.5)

    def test_eighty_percent(self) -> None:
        assert score_coverage(80.0) == 1.0

    def test_ninety_percent(self) -> None:
        assert score_coverage(90.0) == 1.0

    def test_hundred_percent(self) -> None:
        assert score_coverage(100.0) == 1.0

    def test_twenty_percent(self) -> None:
        assert score_coverage(20.0) == pytest.approx(0.25)

    def test_sixty_percent(self) -> None:
        assert score_coverage(60.0) == pytest.approx(0.75)


# ---------------------------------------------------------------------------
# compute_feature_coverage
# ---------------------------------------------------------------------------


class TestComputeFeatureCoverage:
    def test_no_features_md_returns_one(self, tmp_workspace: Path) -> None:
        """When FEATURES.md does not exist, return 1.0 (backward compat)."""
        assert compute_feature_coverage(tmp_workspace) == 1.0

    def test_legacy_mode_half_done(self, tmp_workspace: Path) -> None:
        """Without baseline, use FEATURES.md rows as denominator."""
        features_md = """\
| F-001 | Scaffold | done | P0 | |
| F-002 | Add | done | P0 | |
| F-003 | List | not-started | P1 | |
| F-004 | Summary | not-started | P1 | |
"""
        (tmp_workspace / "FEATURES.md").write_text(features_md, encoding="utf-8")
        assert compute_feature_coverage(tmp_workspace) == pytest.approx(0.5)

    def test_baseline_mode_three_of_four(self, tmp_workspace: Path) -> None:
        """With features-baseline.json, use baseline IDs as denominator."""
        features_md = """\
| F-001 | Scaffold | done | P0 | |
| F-002 | Add | done | P0 | |
| F-003 | List | done | P1 | |
| F-004 | Summary | not-started | P1 | |
"""
        (tmp_workspace / "FEATURES.md").write_text(features_md, encoding="utf-8")

        baseline = {
            "feature_ids": ["F-001", "F-002", "F-003", "F-004"],
            "frozen_at": "2026-03-20T00:00:00Z",
            "source": "SCAFFOLD",
        }
        (tmp_workspace / "EVALS" / "features-baseline.json").write_text(
            json.dumps(baseline), encoding="utf-8"
        )
        assert compute_feature_coverage(tmp_workspace) == pytest.approx(0.75)

    def test_baseline_empty_ids(self, tmp_workspace: Path) -> None:
        """Empty baseline feature_ids list should return 0.0."""
        (tmp_workspace / "FEATURES.md").write_text(
            "| F-001 | Test | done | P0 | |", encoding="utf-8"
        )
        baseline = {"feature_ids": [], "frozen_at": "", "source": "SCAFFOLD"}
        (tmp_workspace / "EVALS" / "features-baseline.json").write_text(
            json.dumps(baseline), encoding="utf-8"
        )
        assert compute_feature_coverage(tmp_workspace) == 0.0

    def test_all_done(self, tmp_workspace: Path) -> None:
        features_md = """\
| F-001 | A | done | P0 | |
| F-002 | B | done | P0 | |
"""
        (tmp_workspace / "FEATURES.md").write_text(features_md, encoding="utf-8")
        assert compute_feature_coverage(tmp_workspace) == pytest.approx(1.0)


# ---------------------------------------------------------------------------
# compute_composite_score
# ---------------------------------------------------------------------------


class TestComputeCompositeScore:
    def _write_eval(self, workspace: Path, eval_type: str, passed: bool, details: dict | None = None) -> None:
        evals_dir = workspace / "EVALS"
        evals_dir.mkdir(exist_ok=True)
        data = {
            "type": eval_type,
            "timestamp": "2026-03-22T12:00:00Z",
            "pass": passed,
            "summary": "test",
            "details": details or {},
            "duration_sec": 1,
        }
        (evals_dir / f"{eval_type}-20260322-120000.json").write_text(
            json.dumps(data), encoding="utf-8"
        )

    def test_all_passing(self, tmp_workspace: Path) -> None:
        """All evals pass, no FEATURES.md → fc defaults to 1.0."""
        self._write_eval(tmp_workspace, "unit", True, {"coverage_pct": 90})
        self._write_eval(tmp_workspace, "lint", True)
        self._write_eval(tmp_workspace, "typecheck", True)
        self._write_eval(tmp_workspace, "security-scan", True)

        weights = EvalWeights()
        score = compute_composite_score(tmp_workspace, weights)
        # All raw = 1.0, all weights sum to 1.0 → composite = 1.0
        assert score == pytest.approx(1.0)

    def test_no_evals_returns_zero(self, tmp_workspace: Path) -> None:
        score = compute_composite_score(tmp_workspace, EvalWeights())
        assert score == 0.0

    def test_partial_passing(self, tmp_workspace: Path) -> None:
        """Only unit tests pass, others missing."""
        self._write_eval(tmp_workspace, "unit", True, {"coverage_pct": 80})
        weights = EvalWeights()
        score = compute_composite_score(tmp_workspace, weights)
        # tests=0.30*1.0 + coverage=0.15*1.0 + fc=0.25*1.0 = 0.70
        assert score == pytest.approx(0.70)

    def test_weighted_sum_correctness(self, tmp_workspace: Path) -> None:
        """Verify exact weighted sum with specific weights."""
        self._write_eval(tmp_workspace, "unit", True, {"coverage_pct": 40})
        self._write_eval(tmp_workspace, "lint", True)
        self._write_eval(tmp_workspace, "typecheck", False)
        self._write_eval(tmp_workspace, "security-scan", True)

        weights = EvalWeights()
        score = compute_composite_score(tmp_workspace, weights)
        # tests=0.30*1.0 + lint=0.15*1.0 + tc=0.10*0.0 + cov=0.15*0.5 + sec=0.05*1.0 + fc=0.25*1.0
        # = 0.30 + 0.15 + 0.0 + 0.075 + 0.05 + 0.25 = 0.825
        assert score == pytest.approx(0.825)


# ---------------------------------------------------------------------------
# parse_weights_from_program_md
# ---------------------------------------------------------------------------


class TestParseWeightsFromProgramMd:
    def test_standard_weights(self, sample_program_md: str) -> None:
        w = parse_weights_from_program_md(sample_program_md)
        assert w.tests == pytest.approx(0.30)
        assert w.lint == pytest.approx(0.15)
        assert w.coverage == pytest.approx(0.15)
        assert w.feature_coverage == pytest.approx(0.25)

    def test_no_eval_section_returns_defaults(self) -> None:
        w = parse_weights_from_program_md("# Nothing here\n\n## Other Section\nstuff\n")
        # Should get default values
        assert w.tests == pytest.approx(0.30)

    def test_partial_weights(self) -> None:
        text = """\
## Eval Protocol

weights:
  tests: 0.40
  lint: 0.10
"""
        w = parse_weights_from_program_md(text)
        assert w.tests == pytest.approx(0.40)
        assert w.lint == pytest.approx(0.10)
        # Remaining should be defaults
        assert w.typecheck == pytest.approx(0.10)


# ---------------------------------------------------------------------------
# compute_score_breakdown
# ---------------------------------------------------------------------------


class TestComputeScoreBreakdown:
    def _write_eval(self, workspace: Path, eval_type: str, passed: bool, details: dict | None = None) -> None:
        evals_dir = workspace / "EVALS"
        evals_dir.mkdir(exist_ok=True)
        data = {
            "type": eval_type,
            "timestamp": "2026-03-22T12:00:00Z",
            "pass": passed,
            "summary": "test",
            "details": details or {},
            "duration_sec": 1,
        }
        (evals_dir / f"{eval_type}-20260322-120000.json").write_text(
            json.dumps(data), encoding="utf-8"
        )

    def test_breakdown_structure(self, tmp_workspace: Path) -> None:
        self._write_eval(tmp_workspace, "unit", True, {"coverage_pct": 80})
        self._write_eval(tmp_workspace, "lint", True)

        breakdown = compute_score_breakdown(tmp_workspace, EvalWeights())
        assert "composite" in breakdown
        assert "components" in breakdown
        components = breakdown["components"]
        assert "tests" in components
        assert "lint" in components
        assert "typecheck" in components
        assert "coverage" in components
        assert "security" in components
        assert "feature_coverage" in components

    def test_breakdown_component_structure(self, tmp_workspace: Path) -> None:
        self._write_eval(tmp_workspace, "unit", True)

        breakdown = compute_score_breakdown(tmp_workspace, EvalWeights())
        for name, comp in breakdown["components"].items():
            assert "weight" in comp, f"Missing 'weight' in component {name}"
            assert "raw" in comp, f"Missing 'raw' in component {name}"
            assert "weighted" in comp, f"Missing 'weighted' in component {name}"

    def test_breakdown_composite_matches_sum(self, tmp_workspace: Path) -> None:
        self._write_eval(tmp_workspace, "unit", True, {"coverage_pct": 60})
        self._write_eval(tmp_workspace, "lint", True)
        self._write_eval(tmp_workspace, "typecheck", False)
        self._write_eval(tmp_workspace, "security-scan", True)

        breakdown = compute_score_breakdown(tmp_workspace, EvalWeights())
        weighted_sum = sum(c["weighted"] for c in breakdown["components"].values())
        assert breakdown["composite"] == pytest.approx(weighted_sum, abs=0.001)
