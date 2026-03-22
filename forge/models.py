"""Data models for Product Forge — typed, validated, serializable."""

from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Optional

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class Verdict(str, Enum):
    KEEP = "keep"
    DISCARD_REGRESSION = "discard_regression"
    DISCARD_AUDIT = "discard_audit"
    DISCARD_TEST_FAIL = "discard_test_fail"


class State(str, Enum):
    # Setup states
    CREATE_REPO = "CREATE_REPO"
    CONTINUE_REPO = "CONTINUE_REPO"
    CLONE = "CLONE"
    SETUP = "SETUP"
    SCAFFOLD = "SCAFFOLD"
    SYNC = "SYNC"
    INIT_SH = "INIT_SH"

    # Loop states
    EVAL_BASELINE = "EVAL_BASELINE"
    PLAN = "PLAN"
    CODE = "CODE"
    CODE_AUDIT = "CODE_AUDIT"
    PRODUCT_TEST = "PRODUCT_TEST"
    JUDGE = "JUDGE"
    LEDGER = "LEDGER"
    LOOP_CHECK = "LOOP_CHECK"

    # Terminal states
    PUSH = "PUSH"
    DONE = "DONE"
    FAILED = "FAILED"


class StopReason(str, Enum):
    TARGET_SCORE_REACHED = "target_score_reached"
    MAX_LOOPS_REACHED = "max_loops_reached"
    PLATEAU_STOP = "plateau_stop"
    CONSECUTIVE_DISCARD_STOP = "consecutive_discard_stop"
    TIME_BUDGET_EXCEEDED = "time_budget_exceeded"
    CANCELLED = "cancelled"
    ALL_FEATURES_DONE = "all_features_done"
    STALL_DETECTED = "stall_detected"


class EvalType(str, Enum):
    UNIT = "unit"
    LINT = "lint"
    TYPECHECK = "typecheck"
    SECURITY = "security-scan"


# ---------------------------------------------------------------------------
# Eval & Scoring
# ---------------------------------------------------------------------------

class EvalWeights(BaseModel):
    """Weights for composite score calculation (must sum to 1.0)."""
    tests: float = 0.30
    lint: float = 0.15
    typecheck: float = 0.10
    coverage: float = 0.15
    security: float = 0.05
    feature_coverage: float = 0.25


class MutationCaps(BaseModel):
    """CODE_AUDIT thresholds — code changes exceeding these are discarded."""
    max_files_changed: int = 3
    max_files_created: int = 2
    max_diff_lines: int = 200
    max_endpoint_changes: int = 1


class StopConditions(BaseModel):
    """When to stop the product loop."""
    target_score: float = 1.00
    min_improvement_delta: float = 0.01
    max_plateau_loops: int = 3
    max_discards_in_a_row: int = 3


class ProgramSpec(BaseModel):
    """Parsed representation of PROGRAM.md — the arena contract."""
    product_name: str = ""
    weights: EvalWeights = Field(default_factory=EvalWeights)
    caps: MutationCaps = Field(default_factory=MutationCaps)
    stops: StopConditions = Field(default_factory=StopConditions)
    max_loops: int = 12
    time_budget_sec: int = 14400
    arena_contract: str = ""
    quality_requirements: str = ""

    @classmethod
    def from_program_md(cls, text: str) -> ProgramSpec:
        """Parse PROGRAM.md text into a structured ProgramSpec."""
        import re

        spec = cls()

        # Product name
        m = re.search(r"^## Product:\s*(.+)$", text, re.MULTILINE)
        if m:
            spec.product_name = m.group(1).strip()

        # Weights from ## Eval Protocol section
        weight_section = _extract_section(text, "Eval Protocol")
        if weight_section:
            for field in ["tests", "lint", "typecheck", "coverage", "security", "feature_coverage"]:
                m = re.search(rf"{field}:\s*([\d.]+)", weight_section)
                if m:
                    setattr(spec.weights, field, float(m.group(1)))

        # Mutation caps from ## Mutation Scope
        scope_section = _extract_section(text, "Mutation Scope")
        if scope_section:
            cap_map = {
                r"Max files changed.*?:\s*(\d+)": "max_files_changed",
                r"Max files created.*?:\s*(\d+)": "max_files_created",
                r"Max diff lines.*?:\s*(\d+)": "max_diff_lines",
            }
            for pattern, attr in cap_map.items():
                m = re.search(pattern, scope_section, re.IGNORECASE)
                if m:
                    setattr(spec.caps, attr, int(m.group(1)))

        # Stop conditions
        stop_section = _extract_section(text, "Stop Conditions")
        budget_section = _extract_section(text, "Budget")
        for section in [stop_section, budget_section]:
            if not section:
                continue
            stop_map = {
                r"target_score:\s*([\d.]+)": ("stops", "target_score", float),
                r"min_improvement_delta:\s*([\d.]+)": ("stops", "min_improvement_delta", float),
                r"max_plateau_loops:\s*(\d+)": ("stops", "max_plateau_loops", int),
                r"max_discards_in_a_row:\s*(\d+)": ("stops", "max_discards_in_a_row", int),
                r"max_loops:\s*(\d+)": (None, "max_loops", int),
                r"max_wall_seconds:\s*(\d+)": (None, "time_budget_sec", int),
            }
            for pattern, (sub, attr, typ) in stop_map.items():
                m = re.search(pattern, section)
                if m:
                    obj = getattr(spec, sub) if sub else spec
                    setattr(obj, attr, typ(m.group(1)))

        # Arena contract (raw text)
        spec.arena_contract = _extract_section(text, "Arena Contract") or ""
        spec.quality_requirements = _extract_section(text, "Quality Requirements") or ""

        return spec


def _extract_section(text: str, heading: str) -> str | None:
    """Extract content between ## heading and next ## heading."""
    import re
    pattern = rf"^## {re.escape(heading)}\s*\n(.*?)(?=^## |\Z)"
    m = re.search(pattern, text, re.MULTILINE | re.DOTALL)
    return m.group(1).strip() if m else None


# ---------------------------------------------------------------------------
# Eval Results
# ---------------------------------------------------------------------------

class EvalResult(BaseModel):
    """Single evaluation result (unit test, lint, typecheck, or security scan)."""
    eval_type: str = Field(alias="type", default="unit")
    timestamp: str = ""
    passed: bool = Field(alias="pass", default=False)
    summary: str = ""
    details: dict[str, Any] = Field(default_factory=dict)
    duration_sec: int = 0

    model_config = {"populate_by_name": True}

    @property
    def coverage_pct(self) -> float | None:
        """Extract coverage percentage from unit test details."""
        return self.details.get("coverage_pct")

    def to_file_dict(self) -> dict[str, Any]:
        """Serialize for writing to EVALS/{type}-{timestamp}.json."""
        return {
            "type": self.eval_type,
            "timestamp": self.timestamp,
            "pass": self.passed,
            "summary": self.summary[:200],
            "details": self.details,
            "duration_sec": self.duration_sec,
        }


class EvalSuite(BaseModel):
    """All evaluation results for one scoring pass."""
    unit: EvalResult | None = None
    lint: EvalResult | None = None
    typecheck: EvalResult | None = None
    security: EvalResult | None = None
    coverage_pct: float = 0.0
    feature_coverage: float = 0.0


# ---------------------------------------------------------------------------
# Ledger
# ---------------------------------------------------------------------------

class LedgerEntry(BaseModel):
    """One row in EVALS/ledger.jsonl — records a single loop's outcome."""
    loop: int
    hypothesis: str = ""
    files_touched: str = ""
    wall_seconds: int = 0
    score_before: str = "0.0000"
    score_after: str = "0.0000"
    kept: bool = False
    commit_sha: str = ""
    timestamp: str = ""
    verdict: str = Verdict.KEEP.value

    @classmethod
    def now(cls, **kwargs: Any) -> LedgerEntry:
        """Create entry with current timestamp."""
        return cls(
            timestamp=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            **kwargs,
        )


# ---------------------------------------------------------------------------
# Features
# ---------------------------------------------------------------------------

class Feature(BaseModel):
    """A single feature from FEATURES.md."""
    id: str
    name: str
    status: str = "not-started"
    priority: str = "P0"
    notes: str = ""

    @property
    def is_done(self) -> bool:
        return self.status == "done"


class FeatureBaseline(BaseModel):
    """Immutable feature list for scoring denominator."""
    feature_ids: list[str] = Field(default_factory=list)
    frozen_at: str = ""
    source: str = "SCAFFOLD"

    @property
    def total(self) -> int:
        return len(self.feature_ids)


# ---------------------------------------------------------------------------
# Job Config
# ---------------------------------------------------------------------------

class Commands(BaseModel):
    """Shell commands for setup and testing."""
    setup: list[str] = Field(default_factory=list)
    continue_setup: list[str] = Field(default_factory=list)
    test: list[str] = Field(default_factory=list)


class DayPlan(BaseModel):
    """Optional daily planning structure."""
    name: str = ""
    max_loops: int = 4
    goals: list[str] = Field(default_factory=list)
    quality_gates: list[str] = Field(default_factory=list)


class JobConfig(BaseModel):
    """Complete job definition — maps to examples/*.json."""
    id: str
    repo: str = "local://create"
    base_ref: str = "main"
    work_branch: str = ""
    task: str = ""
    time_budget_sec: int = 14400
    mode: str = "product"
    product_name: str = ""
    max_loops: int = 12
    create_repo: bool = True
    continue_from: str = ""
    new_features: str = ""
    commands: Commands = Field(default_factory=Commands)
    program_md: str = ""
    day_plan: Optional[dict[str, Any]] = None

    # Runtime state (written during execution)
    agent_pid: Optional[int] = None
    current_day: int = 0
    loop_count: int = 0
    last_state: str = ""
    last_state_ts: str = ""
    consecutive_discards: int = 0
    cancelled: bool = False

    @classmethod
    def from_json_file(cls, path: str | Path) -> JobConfig:
        """Load job config from a JSON file."""
        import json
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return cls(**data)

    def to_json_file(self, path: str | Path) -> None:
        """Save job config to a JSON file (including runtime state)."""
        import json
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.model_dump(exclude_none=True), f, indent=2, ensure_ascii=False)
            f.write("\n")

    def clean_example(self) -> dict[str, Any]:
        """Return dict without runtime fields — for clean example JSON."""
        runtime_fields = {
            "agent_pid", "current_day", "loop_count",
            "last_state", "last_state_ts", "consecutive_discards", "cancelled",
        }
        return {k: v for k, v in self.model_dump(exclude_none=True).items()
                if k not in runtime_fields}

    @property
    def is_continuation(self) -> bool:
        return bool(self.continue_from)


# ---------------------------------------------------------------------------
# Loop Runtime
# ---------------------------------------------------------------------------

class LoopState(BaseModel):
    """Mutable state tracked during the product loop."""
    loop_count: int = 0
    current_day: int = 0
    score_before: float = 0.0
    score_after: float = 0.0
    pre_code_commit: str = ""
    consecutive_discards: int = 0
    plateau_count: int = 0
    verdict: Verdict = Verdict.KEEP
    conversation_id: str = ""
    total_cost_usd: float = 0.0
    loop_start_time: float = 0.0
    stop_reason: StopReason | None = None


# ---------------------------------------------------------------------------
# Audit Result
# ---------------------------------------------------------------------------

class AuditResult(BaseModel):
    """Result of CODE_AUDIT — pass or fail with details."""
    passed: bool = True
    violations: list[str] = Field(default_factory=list)
    files_changed: int = 0
    files_created: int = 0
    diff_lines: int = 0
    structure_violation: bool = False

    @property
    def verdict(self) -> Verdict:
        return Verdict.KEEP if self.passed else Verdict.DISCARD_AUDIT

    def summary(self) -> str:
        if self.passed:
            return (
                f"audit OK: {self.files_changed} files changed, "
                f"{self.files_created} created, {self.diff_lines} diff lines"
            )
        return "audit FAIL: " + "; ".join(self.violations)
