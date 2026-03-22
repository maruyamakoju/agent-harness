"""Scorer — computes composite weighted score from evaluation results."""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Any

from forge.models import EvalResult, EvalWeights

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_latest_eval(workspace: Path, eval_type: str) -> EvalResult | None:
    """Find the most recent EVALS/{eval_type}-*.json file and parse it.

    Returns None if no matching file exists or parsing fails.
    """
    evals_dir = workspace / "EVALS"
    if not evals_dir.is_dir():
        return None

    matches = sorted(evals_dir.glob(f"{eval_type}-*.json"), reverse=True)
    if not matches:
        return None

    latest = matches[0]
    try:
        data = json.loads(latest.read_text(encoding="utf-8"))
        return EvalResult(
            type=data.get("type", eval_type),
            timestamp=data.get("timestamp", ""),
            **{"pass": data.get("pass", False)},
            summary=data.get("summary", ""),
            details=data.get("details", {}),
            duration_sec=data.get("duration_sec", 0),
        )
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        logger.warning("Failed to parse %s: %s", latest, exc)
        return None


# ---------------------------------------------------------------------------
# Coverage scoring
# ---------------------------------------------------------------------------

def score_coverage(coverage_pct: float) -> float:
    """Coverage saturation score: linear up to 80%, then 1.0.

    Args:
        coverage_pct: Percentage 0-100.

    Returns:
        Score between 0.0 and 1.0, rounded to 4 decimal places.
    """
    if coverage_pct >= 80.0:
        return 1.0
    return round(min(coverage_pct / 80.0, 1.0), 4)


# ---------------------------------------------------------------------------
# Feature coverage
# ---------------------------------------------------------------------------

def compute_feature_coverage(workspace: Path) -> float:
    """Compute fraction of baseline features marked 'done' in FEATURES.md.

    Scoring rules:
    - If EVALS/features-baseline.json exists, use its feature_ids as the
      denominator (arena mode). Only baseline IDs count.
    - Otherwise, fall back to counting all F-NNN rows in FEATURES.md.
    - If FEATURES.md does not exist, return 1.0 (backward compat).

    Returns:
        Float between 0.0 and 1.0, rounded to 4 decimal places.
    """
    features_file = workspace / "FEATURES.md"
    baseline_file = workspace / "EVALS" / "features-baseline.json"

    if not features_file.exists():
        return 1.0

    try:
        features_text = features_file.read_text(encoding="utf-8")
    except OSError:
        return 1.0

    total: int
    done_count: int

    if baseline_file.exists():
        # Arena mode: denominator is baseline feature count (immutable)
        try:
            baseline_data = json.loads(baseline_file.read_text(encoding="utf-8"))
            feature_ids: list[str] = baseline_data.get("feature_ids", [])
        except (json.JSONDecodeError, OSError):
            feature_ids = []

        total = len(feature_ids)
        if total == 0:
            return 0.0

        done_count = 0
        for fid in feature_ids:
            fid = fid.strip()
            if not fid:
                continue
            # Match: | F-001 ... | done
            pattern = rf"^\| {re.escape(fid)} .*\| done"
            if re.search(pattern, features_text, re.MULTILINE):
                done_count += 1

        # Warn about extra features (informational only)
        current_total = len(re.findall(r"^\| F-\d+", features_text, re.MULTILINE))
        if current_total > total:
            extra = current_total - total
            logger.warning(
                "%d extra feature(s) added beyond baseline (not counted in score)",
                extra,
            )
    else:
        # Legacy mode: use current FEATURES.md as denominator
        all_features = re.findall(r"^\| F-\d+", features_text, re.MULTILINE)
        done_features = re.findall(r"^\| F-\d+.*\| done", features_text, re.MULTILINE)
        total = len(all_features)
        done_count = len(done_features)

    if total == 0:
        return 0.0

    return round(done_count / total, 4)


# ---------------------------------------------------------------------------
# Parse weights from PROGRAM.md
# ---------------------------------------------------------------------------

def parse_weights_from_program_md(text: str) -> EvalWeights:
    """Extract eval weights from the ## Eval Protocol section of PROGRAM.md.

    Looks for lines like:
        tests: 0.30
        lint: 0.15
        coverage: 0.15
        ...

    Falls back to defaults for any field not found.
    """
    weights = EvalWeights()

    # Extract the Eval Protocol section
    section_match = re.search(
        r"^## Eval Protocol\s*\n(.*?)(?=^## |\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not section_match:
        return weights

    section = section_match.group(1)

    for field in ["tests", "lint", "typecheck", "coverage", "security", "feature_coverage"]:
        m = re.search(rf"{field}:\s*([\d.]+)", section)
        if m:
            setattr(weights, field, float(m.group(1)))

    return weights


# ---------------------------------------------------------------------------
# Composite score
# ---------------------------------------------------------------------------

def compute_composite_score(
    workspace: Path,
    weights: EvalWeights | None = None,
) -> float:
    """Compute weighted composite score from latest eval results.

    Reads EVALS/*.json for the latest result of each type, applies weights,
    and returns a score between 0.0000 and 1.0000.

    Args:
        workspace: Path to the product workspace.
        weights: Optional explicit weights. If None, reads from PROGRAM.md
                 or uses defaults.

    Returns:
        Composite score rounded to 4 decimal places.
    """
    # Resolve weights
    if weights is None:
        program_md = workspace / "PROGRAM.md"
        if program_md.exists():
            try:
                text = program_md.read_text(encoding="utf-8")
                weights = parse_weights_from_program_md(text)
            except OSError:
                weights = EvalWeights()
        else:
            weights = EvalWeights()

    # Read latest eval results
    score_tests = 0.0
    score_lint = 0.0
    score_typecheck = 0.0
    score_coverage = 0.0
    score_security = 0.0
    found_any = False

    for eval_type, attr in [
        ("unit", "score_tests"),
        ("lint", "score_lint"),
        ("typecheck", "score_typecheck"),
        ("security-scan", "score_security"),
    ]:
        result = get_latest_eval(workspace, eval_type)
        if result is None:
            continue

        found_any = True
        val = 1.0 if result.passed else 0.0

        if eval_type == "unit":
            score_tests = val
        elif eval_type == "lint":
            score_lint = val
        elif eval_type == "typecheck":
            score_typecheck = val
        elif eval_type == "security-scan":
            score_security = val

    # Coverage: check if unit result has coverage_pct in details
    unit_result = get_latest_eval(workspace, "unit")
    if unit_result is not None:
        cov_pct = unit_result.coverage_pct
        if cov_pct is not None:
            score_coverage = score_coverage_fn(cov_pct)
        elif score_tests == 1.0:
            # Tests pass but no coverage measurement — assume baseline
            score_coverage = 1.0

    if not found_any:
        return 0.0

    # Feature coverage
    fc = compute_feature_coverage(workspace)

    # Weighted composite
    composite = (
        weights.tests * score_tests
        + weights.lint * score_lint
        + weights.typecheck * score_typecheck
        + weights.coverage * score_coverage
        + weights.security * score_security
        + weights.feature_coverage * fc
    )

    return round(composite, 4)


def score_coverage_fn(coverage_pct: float) -> float:
    """Alias used internally — delegates to score_coverage."""
    return score_coverage(coverage_pct)


def compute_score_breakdown(
    workspace: Path,
    weights: EvalWeights | None = None,
) -> dict[str, Any]:
    """Compute composite score with per-component breakdown.

    Returns a dict with 'composite' (float) and 'components' (dict of name -> {weight, raw, weighted}).
    """
    if weights is None:
        program_md = workspace / "PROGRAM.md"
        if program_md.exists():
            try:
                weights = parse_weights_from_program_md(program_md.read_text(encoding="utf-8"))
            except OSError:
                weights = EvalWeights()
        else:
            weights = EvalWeights()

    components: dict[str, dict[str, float]] = {}

    # Eval components
    score_map = {"unit": 0.0, "lint": 0.0, "typecheck": 0.0, "security-scan": 0.0}
    weight_map = {
        "unit": weights.tests, "lint": weights.lint,
        "typecheck": weights.typecheck, "security-scan": weights.security,
    }
    for eval_type in score_map:
        result = get_latest_eval(workspace, eval_type)
        raw = (1.0 if result.passed else 0.0) if result else 0.0
        score_map[eval_type] = raw

    # Coverage
    unit_result = get_latest_eval(workspace, "unit")
    cov_raw = 0.0
    if unit_result:
        cov_pct = unit_result.coverage_pct
        if cov_pct is not None:
            cov_raw = score_coverage(cov_pct)
        elif score_map["unit"] == 1.0:
            cov_raw = 1.0

    # Feature coverage
    fc_raw = compute_feature_coverage(workspace)

    # Build breakdown
    name_map = {
        "tests": ("unit", weights.tests),
        "lint": ("lint", weights.lint),
        "typecheck": ("typecheck", weights.typecheck),
        "coverage": (None, weights.coverage),
        "security": ("security-scan", weights.security),
        "feature_coverage": (None, weights.feature_coverage),
    }
    composite = 0.0
    for name, (eval_key, w) in name_map.items():
        if name == "coverage":
            raw = cov_raw
        elif name == "feature_coverage":
            raw = fc_raw
        else:
            raw = score_map.get(eval_key, 0.0)  # type: ignore[arg-type]
        weighted = round(w * raw, 4)
        composite += weighted
        components[name] = {"weight": w, "raw": round(raw, 4), "weighted": weighted}

    return {"composite": round(composite, 4), "components": components}
