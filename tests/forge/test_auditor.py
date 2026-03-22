"""Tests for forge.auditor — CODE_AUDIT mutation cap checks."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from forge.auditor import _check_structure_monolith, audit_code_changes
from forge.models import AuditResult, JobConfig, MutationCaps, Verdict
from forge.workspace import Workspace


def _git(cwd: Path, *args: str) -> None:
    """Run a git command in a directory."""
    subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        check=True,
        capture_output=True,
    )


def _make_workspace(tmp_path: Path) -> Workspace:
    """Create a minimal Workspace with git repo and initial commit."""
    _git(tmp_path, "init")
    _git(tmp_path, "config", "user.name", "test")
    _git(tmp_path, "config", "user.email", "test@test.com")

    readme = tmp_path / "README.md"
    readme.write_text("# test\n", encoding="utf-8")
    _git(tmp_path, "add", "-A")
    _git(tmp_path, "commit", "-m", "initial")

    job = JobConfig(id="test-audit")
    return Workspace(tmp_path, job)


# ---------------------------------------------------------------------------
# audit_code_changes
# ---------------------------------------------------------------------------


class TestAuditCodeChanges:
    def test_within_caps_passes(self, tmp_path: Path) -> None:
        ws = _make_workspace(tmp_path)
        pre_commit = ws.current_commit()

        # Add one file, small change
        (tmp_path / "src").mkdir(parents=True)
        (tmp_path / "src" / "pkg").mkdir()
        (tmp_path / "src" / "pkg" / "__init__.py").write_text("", encoding="utf-8")
        (tmp_path / "src" / "pkg" / "main.py").write_text("def main():\n    pass\n", encoding="utf-8")
        (tmp_path / "src" / "pkg" / "db.py").write_text("def init():\n    pass\n", encoding="utf-8")
        _git(tmp_path, "add", "-A")
        _git(tmp_path, "commit", "-m", "add code")

        caps = MutationCaps(max_files_changed=5, max_files_created=5, max_diff_lines=500)
        result = audit_code_changes(ws, caps, pre_commit)

        assert result.passed is True
        assert result.verdict == Verdict.KEEP
        assert len(result.violations) == 0

    def test_files_changed_exceeds_cap(self, tmp_path: Path) -> None:
        ws = _make_workspace(tmp_path)
        pre_commit = ws.current_commit()

        # Create many files to exceed cap
        for i in range(5):
            (tmp_path / f"file{i}.py").write_text(f"# file {i}\n", encoding="utf-8")
        _git(tmp_path, "add", "-A")
        _git(tmp_path, "commit", "-m", "add many files")

        caps = MutationCaps(max_files_changed=2, max_files_created=2, max_diff_lines=500)
        result = audit_code_changes(ws, caps, pre_commit)

        assert result.passed is False
        assert result.verdict == Verdict.DISCARD_AUDIT
        assert any("files_changed" in v or "files_created" in v for v in result.violations)

    def test_diff_lines_exceeds_cap(self, tmp_path: Path) -> None:
        ws = _make_workspace(tmp_path)
        pre_commit = ws.current_commit()

        # Write a large file
        big_content = "\n".join(f"line_{i} = {i}" for i in range(300))
        (tmp_path / "big.py").write_text(big_content, encoding="utf-8")
        _git(tmp_path, "add", "-A")
        _git(tmp_path, "commit", "-m", "add large file")

        caps = MutationCaps(max_files_changed=10, max_files_created=10, max_diff_lines=50)
        result = audit_code_changes(ws, caps, pre_commit)

        assert result.passed is False
        assert any("diff_lines" in v for v in result.violations)


# ---------------------------------------------------------------------------
# Structure gate (_check_structure_monolith)
# ---------------------------------------------------------------------------


class TestStructureGate:
    def test_single_large_file_fails(self, tmp_path: Path) -> None:
        """A single .py file > 150 LOC under src/pkg/ should trigger monolith."""
        ws = _make_workspace(tmp_path)
        pkg_dir = tmp_path / "src" / "mypkg"
        pkg_dir.mkdir(parents=True)
        (pkg_dir / "__init__.py").write_text("", encoding="utf-8")

        # Write a single large implementation file
        lines = [f"line_{i} = {i}" for i in range(200)]
        (pkg_dir / "main.py").write_text("\n".join(lines), encoding="utf-8")

        violation = _check_structure_monolith(ws)
        assert violation != ""
        assert "structure_monolith" in violation

    def test_two_files_passes(self, tmp_path: Path) -> None:
        """Two implementation files should pass even if total LOC > 150."""
        ws = _make_workspace(tmp_path)
        pkg_dir = tmp_path / "src" / "mypkg"
        pkg_dir.mkdir(parents=True)
        (pkg_dir / "__init__.py").write_text("", encoding="utf-8")

        lines_a = [f"a_{i} = {i}" for i in range(100)]
        lines_b = [f"b_{i} = {i}" for i in range(100)]
        (pkg_dir / "main.py").write_text("\n".join(lines_a), encoding="utf-8")
        (pkg_dir / "db.py").write_text("\n".join(lines_b), encoding="utf-8")

        violation = _check_structure_monolith(ws)
        assert violation == ""

    def test_no_src_dir_passes(self, tmp_path: Path) -> None:
        """No src/ directory should pass (no monolith possible)."""
        ws = _make_workspace(tmp_path)
        violation = _check_structure_monolith(ws)
        assert violation == ""

    def test_small_single_file_passes(self, tmp_path: Path) -> None:
        """A single small file (< 150 LOC) should pass."""
        ws = _make_workspace(tmp_path)
        pkg_dir = tmp_path / "src" / "mypkg"
        pkg_dir.mkdir(parents=True)
        (pkg_dir / "__init__.py").write_text("", encoding="utf-8")

        lines = [f"line_{i} = {i}" for i in range(50)]
        (pkg_dir / "main.py").write_text("\n".join(lines), encoding="utf-8")

        violation = _check_structure_monolith(ws)
        assert violation == ""
