"""Ledger I/O operations for Product Forge."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from forge.models import FeatureBaseline, LedgerEntry

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_LEDGER_FILENAME = "EVALS/ledger.jsonl"
_BASELINE_FILENAME = "EVALS/features-baseline.json"


# ---------------------------------------------------------------------------
# Read / Write
# ---------------------------------------------------------------------------

def read_entries(workspace_path: Path) -> list[LedgerEntry]:
    """Read all entries from EVALS/ledger.jsonl."""
    ledger_path = workspace_path / _LEDGER_FILENAME
    if not ledger_path.exists():
        return []

    entries: list[LedgerEntry] = []
    text = ledger_path.read_text(encoding="utf-8").strip()
    if not text:
        return []

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
            entries.append(LedgerEntry(**data))
        except (json.JSONDecodeError, ValueError):
            # Skip malformed lines
            continue

    return entries


def append_entry(workspace_path: Path, entry: LedgerEntry) -> None:
    """Append one entry to EVALS/ledger.jsonl."""
    ledger_path = workspace_path / _LEDGER_FILENAME
    ledger_path.parent.mkdir(parents=True, exist_ok=True)

    line = json.dumps(entry.model_dump(), ensure_ascii=False)
    with open(ledger_path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def read_baseline(workspace_path: Path) -> FeatureBaseline | None:
    """Read EVALS/features-baseline.json if it exists."""
    baseline_path = workspace_path / _BASELINE_FILENAME
    if not baseline_path.exists():
        return None

    try:
        text = baseline_path.read_text(encoding="utf-8")
        data = json.loads(text)
        return FeatureBaseline(**data)
    except (json.JSONDecodeError, ValueError):
        return None


def write_baseline(workspace_path: Path, baseline: FeatureBaseline) -> None:
    """Write EVALS/features-baseline.json."""
    baseline_path = workspace_path / _BASELINE_FILENAME
    baseline_path.parent.mkdir(parents=True, exist_ok=True)

    text = json.dumps(baseline.model_dump(), indent=2, ensure_ascii=False)
    baseline_path.write_text(text + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def compute_metrics(entries: list[LedgerEntry]) -> dict[str, Any]:
    """Compute summary metrics from ledger entries.

    Returns:
        dict with keys: total_loops, keeps, discards, keep_rate,
        discard_recovery_rate, score_range, total_wall_seconds,
        mean_score_delta, loops_to_target, time_to_target
    """
    if not entries:
        return {
            "total_loops": 0,
            "keeps": 0,
            "discards": 0,
            "keep_rate": 0.0,
            "discard_recovery_rate": 0.0,
            "score_range": (0.0, 0.0),
            "total_wall_seconds": 0,
            "mean_score_delta": 0.0,
            "loops_to_target": None,
            "time_to_target": None,
        }

    total = len(entries)
    keeps = sum(1 for e in entries if e.kept)
    discards = total - keeps

    # Keep rate
    keep_rate = keeps / total if total > 0 else 0.0

    # Discard recovery rate: after a discard, how often does the next loop keep?
    discard_recoveries = 0
    discard_followed = 0
    for i in range(len(entries) - 1):
        if not entries[i].kept:
            discard_followed += 1
            if entries[i + 1].kept:
                discard_recoveries += 1
    discard_recovery_rate = (
        discard_recoveries / discard_followed if discard_followed > 0 else 0.0
    )

    # Score range
    scores = []
    for e in entries:
        try:
            scores.append(float(e.score_after))
        except (ValueError, TypeError):
            pass
    score_range = (min(scores), max(scores)) if scores else (0.0, 0.0)

    # Total wall seconds
    total_wall_seconds = sum(e.wall_seconds for e in entries)

    # Mean score delta (only for kept entries)
    deltas: list[float] = []
    for e in entries:
        if e.kept:
            try:
                delta = float(e.score_after) - float(e.score_before)
                deltas.append(delta)
            except (ValueError, TypeError):
                pass
    mean_score_delta = sum(deltas) / len(deltas) if deltas else 0.0

    # Loops to target (first loop where score_after >= 1.0)
    loops_to_target: int | None = None
    time_to_target: int | None = None
    cumulative_time = 0
    for e in entries:
        cumulative_time += e.wall_seconds
        try:
            if float(e.score_after) >= 1.0:
                loops_to_target = e.loop
                time_to_target = cumulative_time
                break
        except (ValueError, TypeError):
            pass

    return {
        "total_loops": total,
        "keeps": keeps,
        "discards": discards,
        "keep_rate": keep_rate,
        "discard_recovery_rate": discard_recovery_rate,
        "score_range": score_range,
        "total_wall_seconds": total_wall_seconds,
        "mean_score_delta": mean_score_delta,
        "loops_to_target": loops_to_target,
        "time_to_target": time_to_target,
    }
