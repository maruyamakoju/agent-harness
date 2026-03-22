"""Tests for forge.ledger — ledger I/O and metrics."""

from __future__ import annotations

from pathlib import Path

import pytest

from forge.ledger import (
    append_entry,
    compute_metrics,
    read_baseline,
    read_entries,
    write_baseline,
)
from forge.models import FeatureBaseline, LedgerEntry


# ---------------------------------------------------------------------------
# read_entries / append_entry
# ---------------------------------------------------------------------------


class TestLedgerIO:
    def test_roundtrip_single_entry(self, tmp_workspace: Path) -> None:
        entry = LedgerEntry(
            loop=1,
            hypothesis="Add scaffold",
            score_before="0.0000",
            score_after="0.2500",
            kept=True,
            wall_seconds=300,
        )
        append_entry(tmp_workspace, entry)
        entries = read_entries(tmp_workspace)

        assert len(entries) == 1
        assert entries[0].loop == 1
        assert entries[0].hypothesis == "Add scaffold"
        assert entries[0].score_after == "0.2500"

    def test_roundtrip_multiple_entries(self, tmp_workspace: Path) -> None:
        for i in range(3):
            entry = LedgerEntry(
                loop=i + 1,
                hypothesis=f"Feature {i + 1}",
                kept=True,
                wall_seconds=100,
            )
            append_entry(tmp_workspace, entry)

        entries = read_entries(tmp_workspace)
        assert len(entries) == 3
        assert [e.loop for e in entries] == [1, 2, 3]

    def test_read_entries_nonexistent_file(self, tmp_workspace: Path) -> None:
        # Remove the EVALS dir to ensure no ledger exists
        entries = read_entries(tmp_workspace)
        assert entries == []

    def test_read_entries_empty_file(self, tmp_workspace: Path) -> None:
        ledger_path = tmp_workspace / "EVALS" / "ledger.jsonl"
        ledger_path.write_text("", encoding="utf-8")
        entries = read_entries(tmp_workspace)
        assert entries == []

    def test_read_entries_skips_malformed_lines(self, tmp_workspace: Path) -> None:
        ledger_path = tmp_workspace / "EVALS" / "ledger.jsonl"
        lines = [
            '{"loop": 1, "kept": true}',
            'not json at all',
            '{"loop": 2, "kept": false}',
        ]
        ledger_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        entries = read_entries(tmp_workspace)
        assert len(entries) == 2
        assert entries[0].loop == 1
        assert entries[1].loop == 2


# ---------------------------------------------------------------------------
# read_baseline / write_baseline
# ---------------------------------------------------------------------------


class TestBaselineIO:
    def test_roundtrip(self, tmp_workspace: Path) -> None:
        baseline = FeatureBaseline(
            feature_ids=["F-001", "F-002", "F-003"],
            frozen_at="2026-03-20T00:00:00Z",
            source="SCAFFOLD",
        )
        write_baseline(tmp_workspace, baseline)
        loaded = read_baseline(tmp_workspace)

        assert loaded is not None
        assert loaded.feature_ids == ["F-001", "F-002", "F-003"]
        assert loaded.frozen_at == "2026-03-20T00:00:00Z"
        assert loaded.source == "SCAFFOLD"
        assert loaded.total == 3

    def test_read_baseline_nonexistent(self, tmp_workspace: Path) -> None:
        result = read_baseline(tmp_workspace)
        assert result is None

    def test_read_baseline_malformed_json(self, tmp_workspace: Path) -> None:
        path = tmp_workspace / "EVALS" / "features-baseline.json"
        path.write_text("not json", encoding="utf-8")
        result = read_baseline(tmp_workspace)
        assert result is None


# ---------------------------------------------------------------------------
# compute_metrics
# ---------------------------------------------------------------------------


class TestComputeMetrics:
    def test_empty_entries(self) -> None:
        m = compute_metrics([])
        assert m["total_loops"] == 0
        assert m["keeps"] == 0
        assert m["keep_rate"] == 0.0
        assert m["loops_to_target"] is None

    def test_all_kept(self) -> None:
        entries = [
            LedgerEntry(loop=1, kept=True, score_before="0.00", score_after="0.25", wall_seconds=300),
            LedgerEntry(loop=2, kept=True, score_before="0.25", score_after="0.50", wall_seconds=300),
            LedgerEntry(loop=3, kept=True, score_before="0.50", score_after="0.75", wall_seconds=300),
            LedgerEntry(loop=4, kept=True, score_before="0.75", score_after="1.00", wall_seconds=300),
        ]
        m = compute_metrics(entries)
        assert m["total_loops"] == 4
        assert m["keeps"] == 4
        assert m["discards"] == 0
        assert m["keep_rate"] == pytest.approx(1.0)
        assert m["loops_to_target"] == 4
        assert m["time_to_target"] == 1200

    def test_mixed_keep_discard(self) -> None:
        entries = [
            LedgerEntry(loop=1, kept=True, score_before="0.00", score_after="0.25", wall_seconds=300),
            LedgerEntry(loop=2, kept=False, score_before="0.25", score_after="0.20", wall_seconds=200),
            LedgerEntry(loop=3, kept=True, score_before="0.25", score_after="0.50", wall_seconds=300),
        ]
        m = compute_metrics(entries)
        assert m["total_loops"] == 3
        assert m["keeps"] == 2
        assert m["discards"] == 1
        assert m["keep_rate"] == pytest.approx(2 / 3)

    def test_discard_recovery_rate(self) -> None:
        entries = [
            LedgerEntry(loop=1, kept=True, wall_seconds=100),
            LedgerEntry(loop=2, kept=False, wall_seconds=100),  # discard
            LedgerEntry(loop=3, kept=True, wall_seconds=100),   # recovered
            LedgerEntry(loop=4, kept=False, wall_seconds=100),  # discard
            LedgerEntry(loop=5, kept=False, wall_seconds=100),  # not recovered
        ]
        m = compute_metrics(entries)
        # 2 discards followed by another entry: loop2→loop3 (recovery), loop4→loop5 (not)
        assert m["discard_recovery_rate"] == pytest.approx(0.5)

    def test_score_range(self) -> None:
        entries = [
            LedgerEntry(loop=1, kept=True, score_after="0.25", wall_seconds=100),
            LedgerEntry(loop=2, kept=True, score_after="0.75", wall_seconds=100),
            LedgerEntry(loop=3, kept=True, score_after="0.50", wall_seconds=100),
        ]
        m = compute_metrics(entries)
        assert m["score_range"] == (0.25, 0.75)

    def test_mean_score_delta(self) -> None:
        entries = [
            LedgerEntry(loop=1, kept=True, score_before="0.00", score_after="0.25", wall_seconds=100),
            LedgerEntry(loop=2, kept=True, score_before="0.25", score_after="0.50", wall_seconds=100),
        ]
        m = compute_metrics(entries)
        assert m["mean_score_delta"] == pytest.approx(0.25)

    def test_total_wall_seconds(self) -> None:
        entries = [
            LedgerEntry(loop=1, kept=True, wall_seconds=300),
            LedgerEntry(loop=2, kept=True, wall_seconds=200),
        ]
        m = compute_metrics(entries)
        assert m["total_wall_seconds"] == 500

    def test_no_target_reached(self) -> None:
        entries = [
            LedgerEntry(loop=1, kept=True, score_after="0.50", wall_seconds=300),
        ]
        m = compute_metrics(entries)
        assert m["loops_to_target"] is None
        assert m["time_to_target"] is None
