"""Workspace and git operations for Product Forge."""

from __future__ import annotations

import logging
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from forge.models import JobConfig

logger = logging.getLogger(__name__)

# Files that are harness state, not product code — excluded from audit counting.
STATE_FILES = frozenset({
    "PROGRESS.md",
    "FEATURES.md",
    "DECISIONS.md",
    "AGENT.md",
    "PROGRAM.md",
    "RUNBOOK.md",
})

_SUBPROCESS_TIMEOUT = 120  # seconds


@dataclass
class DiffStat:
    """Summary statistics from a git diff."""

    files_changed: int = 0
    files_created: int = 0
    diff_lines: int = 0
    changed_file_list: list[str] = field(default_factory=list)
    created_file_list: list[str] = field(default_factory=list)


def _is_state_file(path: str) -> bool:
    """Return True if *path* is a harness state file or under EVALS/."""
    name = path.replace("\\", "/").split("/")[-1] if "/" in path or "\\" in path else path
    if name in STATE_FILES:
        return True
    normalised = path.replace("\\", "/")
    return normalised.startswith("EVALS/") or "/EVALS/" in normalised


class Workspace:
    """Manages a product workspace directory and its git repository."""

    def __init__(self, path: Path, job: JobConfig) -> None:
        self.path = path.resolve()
        self.job = job

    # ------------------------------------------------------------------
    # Creation helpers
    # ------------------------------------------------------------------

    @classmethod
    def create(cls, base_dir: Path, job: JobConfig) -> Workspace:
        """Create a brand-new local repository for a product run."""
        ws_path = (base_dir / job.id).resolve()
        ws_path.mkdir(parents=True, exist_ok=True)

        ws = cls(ws_path, job)

        # Initialise git
        ws.git("init")
        ws._configure_git()

        # Seed files
        readme = (
            f"# {job.product_name or job.id}\n\n"
            "> Built by Product Forge - Autonomous Coding Agent\n\n"
            f"## Description\n{job.task}\n\n"
            "## Getting Started\nSee RUNBOOK.md for setup and deployment instructions.\n"
        )
        ws.write_file("README.md", readme)

        gitignore = (
            "node_modules/\n__pycache__/\n.venv/\n*.pyc\n"
            ".env\n.env.local\ndist/\nbuild/\ncoverage/\n"
            ".DS_Store\n*.log\n"
        )
        ws.write_file(".gitignore", gitignore)

        ws.git("add", "-A")
        ws.git("commit", "-m", f"chore: initial repository setup for {job.product_name or job.id}")

        # Create work branch
        if job.work_branch:
            ws.git("checkout", "-b", job.work_branch)

        logger.info("Created workspace %s", ws_path)
        return ws

    @classmethod
    def clone(cls, repo_url: str, base_dir: Path, job: JobConfig) -> Workspace:
        """Clone a remote repository into *base_dir*/*job.id*."""
        ws_path = (base_dir / job.id).resolve()

        subprocess.run(
            ["git", "clone", "--depth", "50", repo_url, str(ws_path)],
            check=True,
            timeout=_SUBPROCESS_TIMEOUT,
            capture_output=True,
            text=True,
        )

        ws = cls(ws_path, job)
        ws._configure_git()

        if job.work_branch:
            ws.git("checkout", "-b", job.work_branch)

        logger.info("Cloned %s into %s", repo_url, ws_path)
        return ws

    @classmethod
    def continue_from(cls, source_id: str, base_dir: Path, job: JobConfig) -> Workspace:
        """Clone an existing workspace for a continuation run.

        1. Clone source workspace (full history)
        2. Remove origin remote
        3. Create work branch
        4. Delete EVALS/*.json (keep features-baseline.json and ledger.jsonl)
        """
        source_path = (base_dir / source_id).resolve()
        if not (source_path / ".git").is_dir():
            raise FileNotFoundError(
                f"Source workspace not found or not a git repo: {source_path}"
            )

        ws_path = (base_dir / job.id).resolve()

        subprocess.run(
            ["git", "clone", str(source_path), str(ws_path)],
            check=True,
            timeout=_SUBPROCESS_TIMEOUT,
            capture_output=True,
            text=True,
        )

        ws = cls(ws_path, job)
        ws._configure_git()

        # Remove origin to prevent accidental writes back to source
        ws.git("remote", "remove", "origin", check=False)

        # Create new work branch
        if job.work_branch:
            ws.git("checkout", "-b", job.work_branch)

        # Delete stale eval result files (keep ledger.jsonl and features-baseline.json)
        evals_dir = ws_path / "EVALS"
        if evals_dir.is_dir():
            for json_file in evals_dir.glob("*.json"):
                if json_file.name != "features-baseline.json":
                    json_file.unlink(missing_ok=True)
            logger.info("Cleaned stale eval results (kept ledger.jsonl, features-baseline.json)")

        logger.info(
            "Continued from %s into %s (branch=%s)",
            source_id,
            ws_path,
            job.work_branch,
        )
        return ws

    # ------------------------------------------------------------------
    # Git operations
    # ------------------------------------------------------------------

    def git(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        """Run a git command inside the workspace."""
        cmd = ["git", "-C", str(self.path), *args]
        logger.debug("git %s", " ".join(args))
        return subprocess.run(
            cmd,
            check=check,
            timeout=_SUBPROCESS_TIMEOUT,
            capture_output=True,
            text=True,
        )

    def current_commit(self) -> str:
        """Return the current HEAD SHA."""
        result = self.git("rev-parse", "HEAD")
        return result.stdout.strip()

    def diff_stat(self, from_commit: str) -> DiffStat:
        """Compute diff statistics between *from_commit* and HEAD."""
        changed = self.changed_files(from_commit, exclude_state_files=True)
        created = self.created_files(from_commit, exclude_state_files=True)

        # Diff lines: total insertions + deletions across ALL files
        diff_lines = self._count_diff_lines(from_commit)

        return DiffStat(
            files_changed=len(changed),
            files_created=len(created),
            diff_lines=diff_lines,
            changed_file_list=changed,
            created_file_list=created,
        )

    def changed_files(
        self, from_commit: str, exclude_state_files: bool = True
    ) -> list[str]:
        """Return list of files changed between *from_commit* and HEAD."""
        result = self.git("diff", "--name-only", f"{from_commit}..HEAD", check=False)
        files = [
            f.strip().replace("\\", "/")
            for f in result.stdout.splitlines()
            if f.strip()
        ]
        if exclude_state_files:
            files = [f for f in files if not _is_state_file(f)]
        return files

    def created_files(
        self, from_commit: str, exclude_state_files: bool = True
    ) -> list[str]:
        """Return list of newly created files between *from_commit* and HEAD."""
        result = self.git(
            "diff", "--diff-filter=A", "--name-only", f"{from_commit}..HEAD",
            check=False,
        )
        files = [
            f.strip().replace("\\", "/")
            for f in result.stdout.splitlines()
            if f.strip()
        ]
        if exclude_state_files:
            files = [f for f in files if not _is_state_file(f)]
        return files

    def rollback(self, to_commit: str) -> None:
        """Hard-reset to *to_commit*."""
        self.git("reset", "--hard", to_commit)
        logger.info("Rolled back to %s", to_commit)

    def commit_all(self, message: str) -> str:
        """Stage all changes and commit.  Returns the new commit SHA."""
        self.git("add", "-A")
        self.git("commit", "-m", message)
        return self.current_commit()

    # ------------------------------------------------------------------
    # File operations
    # ------------------------------------------------------------------

    def read_file(self, relative_path: str) -> str:
        """Read a file from the workspace (UTF-8)."""
        target = self.path / relative_path
        return target.read_text(encoding="utf-8")

    def write_file(self, relative_path: str, content: str) -> None:
        """Write *content* to a file inside the workspace, creating dirs as needed."""
        target = self.path / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def file_exists(self, relative_path: str) -> bool:
        """Return True if the file exists in the workspace."""
        return (self.path / relative_path).exists()

    # ------------------------------------------------------------------
    # Eval helpers
    # ------------------------------------------------------------------

    @property
    def evals_dir(self) -> Path:
        """Path to the EVALS/ directory inside the workspace."""
        return self.path / "EVALS"

    def ensure_evals_dir(self) -> Path:
        """Create EVALS/ if it doesn't exist and return the path."""
        self.evals_dir.mkdir(parents=True, exist_ok=True)
        return self.evals_dir

    # ------------------------------------------------------------------
    # Setup & testing
    # ------------------------------------------------------------------

    def run_setup_commands(self, commands: list[str]) -> None:
        """Run a list of shell commands sequentially inside the workspace.

        Each command is run via ``bash -c`` with cwd set to the workspace path.
        A failing command raises ``subprocess.CalledProcessError``.
        """
        for cmd in commands:
            logger.info("Setup: %s", cmd)
            subprocess.run(
                ["bash", "-c", cmd],
                cwd=str(self.path),
                check=True,
                timeout=_SUBPROCESS_TIMEOUT,
                capture_output=True,
                text=True,
            )

    def run_test_commands(self, commands: list[str]) -> tuple[bool, str]:
        """Run test commands and return ``(passed, combined_output)``.

        All commands are executed; the suite passes only if every command
        returns exit-code 0.
        """
        outputs: list[str] = []
        all_passed = True
        for cmd in commands:
            logger.info("Test: %s", cmd)
            result = subprocess.run(
                ["bash", "-c", cmd],
                cwd=str(self.path),
                check=False,
                timeout=_SUBPROCESS_TIMEOUT,
                capture_output=True,
                text=True,
            )
            combined = result.stdout + result.stderr
            outputs.append(combined)
            if result.returncode != 0:
                all_passed = False
                logger.warning("Test command failed (rc=%d): %s", result.returncode, cmd)
        return all_passed, "\n".join(outputs)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _configure_git(self) -> None:
        """Set user.name and user.email for commits."""
        self.git("config", "user.name", "forge-agent", check=False)
        self.git("config", "user.email", "forge@local", check=False)

    def _count_diff_lines(self, from_commit: str) -> int:
        """Count total insertions + deletions between *from_commit* and HEAD."""
        result = self.git("diff", "--stat", f"{from_commit}..HEAD", check=False)
        # The last line of --stat looks like:
        #  3 files changed, 45 insertions(+), 12 deletions(-)
        lines = result.stdout.strip().splitlines()
        if not lines:
            return 0
        summary = lines[-1]
        total = 0
        import re
        for m in re.finditer(r"(\d+)\s+(?:insertion|deletion)", summary):
            total += int(m.group(1))
        return total
