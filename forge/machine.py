"""State machine for Product Forge — drives the SCAFFOLD -> PLAN -> CODE -> AUDIT -> JUDGE -> LEDGER -> LOOP cycle."""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from forge.models import (
    AuditResult,
    FeatureBaseline,
    JobConfig,
    LedgerEntry,
    LoopState,
    MutationCaps,
    ProgramSpec,
    State,
    StopReason,
    Verdict,
)

log = logging.getLogger("forge.machine")

TEMPLATE_DIR = Path("templates/product-state")


def _append_ledger_entry(ledger_path: Path, entry: LedgerEntry) -> None:
    """Append a single entry to EVALS/ledger.jsonl."""
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    with open(ledger_path, "a", encoding="utf-8") as f:
        f.write(entry.model_dump_json() + "\n")


def _read_ledger_entries(ledger_path: Path, tail: int = 5) -> list[LedgerEntry]:
    """Read the last N ledger entries."""
    if not ledger_path.exists():
        return []
    lines = ledger_path.read_text(encoding="utf-8").strip().splitlines()
    entries: list[LedgerEntry] = []
    for line in lines[-tail:]:
        try:
            entries.append(LedgerEntry(**json.loads(line)))
        except Exception:
            continue
    return entries


class Workspace:
    """Minimal workspace adapter wrapping a product repo directory."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def exists(self) -> bool:
        return self.path.exists()

    def mkdir(self) -> None:
        self.path.mkdir(parents=True, exist_ok=True)

    def current_commit(self) -> str:
        """Return HEAD commit SHA."""
        try:
            result = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                capture_output=True, text=True, cwd=self.path,
            )
            return result.stdout.strip()
        except Exception:
            return ""

    def rollback_to(self, commit: str) -> bool:
        """Hard-reset to a given commit."""
        if not commit:
            log.warning("rollback_to called with empty commit")
            return False
        result = subprocess.run(
            ["git", "reset", "--hard", commit],
            capture_output=True, text=True, cwd=self.path,
        )
        ok = result.returncode == 0
        if ok:
            log.info("rolled back to %s", commit[:8])
        else:
            log.error("rollback failed: %s", result.stderr.strip())
        return ok

    def read_file(self, relpath: str) -> str:
        """Read a file relative to the workspace root."""
        fp = self.path / relpath
        if fp.exists():
            return fp.read_text(encoding="utf-8")
        return ""

    def write_file(self, relpath: str, content: str) -> None:
        """Write a file relative to the workspace root."""
        fp = self.path / relpath
        fp.parent.mkdir(parents=True, exist_ok=True)
        fp.write_text(content, encoding="utf-8")

    def git_log(self, n: int = 10) -> str:
        """Return last N commits in oneline format."""
        result = subprocess.run(
            ["git", "log", f"--oneline", f"-{n}"],
            capture_output=True, text=True, cwd=self.path,
        )
        return result.stdout.strip()


def _compute_composite_score(workspace: Workspace, spec: ProgramSpec) -> float:
    """Compute composite score. Delegates to forge.scorer if available."""
    try:
        from forge.scorer import compute_composite_score
        return compute_composite_score(workspace.path, spec.weights)
    except ImportError:
        log.warning("forge.scorer not available, returning 0.0")
        return 0.0


def _audit_code_changes(
    workspace: Workspace, caps: MutationCaps, pre_commit: str,
) -> AuditResult:
    """Audit code changes against mutation caps."""
    try:
        from forge.auditor import audit_code_changes as _audit
        from forge.workspace import Workspace as RealWorkspace
        rw = RealWorkspace(workspace.path, JobConfig(id="audit"))
        return _audit(rw, caps, pre_commit)
    except ImportError:
        log.warning("forge.auditor not available, auto-passing audit")
        return AuditResult(passed=True)


def _run_product_tests(workspace: Workspace, test_commands: list[str]) -> bool:
    """Run the product test suite. Returns True if all pass."""
    if not test_commands:
        log.info("no test commands configured, skipping")
        return True
    for cmd in test_commands:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, cwd=workspace.path,
        )
        if result.returncode != 0:
            log.warning("test command failed: %s\n%s", cmd, result.stderr[:500])
            return False
    return True


class ProductForge:
    """Drives the SCAFFOLD -> PLAN -> CODE -> AUDIT -> JUDGE -> LEDGER -> LOOP cycle."""

    def __init__(
        self,
        job: JobConfig,
        workspaces_dir: Path,
        harness_dir: Path,
        *,
        job_file: Path | None = None,
        model: str = "opus",
    ) -> None:
        self.job = job
        self.workspaces_dir = workspaces_dir
        self.harness_dir = harness_dir
        self.job_file = job_file
        self.model = model

        self.workspace = Workspace(workspaces_dir / job.id)
        self.spec = ProgramSpec()  # populated after SCAFFOLD
        self.loop_state = LoopState(
            loop_count=job.loop_count,
            consecutive_discards=job.consecutive_discards,
        )
        self.start_time = time.time()

        self._handlers: dict[State, Callable[[], State]] = {
            State.CREATE_REPO: self._state_create_repo,
            State.CONTINUE_REPO: self._state_continue_repo,
            State.SETUP: self._state_setup,
            State.SCAFFOLD: self._state_scaffold,
            State.SYNC: self._state_sync,
            State.EVAL_BASELINE: self._state_eval_baseline,
            State.PLAN: self._state_plan,
            State.CODE: self._state_code,
            State.CODE_AUDIT: self._state_code_audit,
            State.PRODUCT_TEST: self._state_product_test,
            State.JUDGE: self._state_judge,
            State.LEDGER: self._state_ledger,
            State.LOOP_CHECK: self._state_loop_check,
            State.PUSH: self._state_push,
        }

    def run(self) -> StopReason:
        """Execute the full state machine. Returns the reason for stopping."""
        state = self._determine_initial_state()
        log.info("starting forge run id=%s initial_state=%s", self.job.id, state.value)

        while state not in (State.DONE, State.FAILED):
            handler = self._handlers.get(state)
            if handler is None:
                log.error("no handler for state %s", state.value)
                self.loop_state.stop_reason = StopReason.STALL_DETECTED
                break
            log.info("[%s] entering", state.value)
            try:
                state = handler()
            except Exception:
                log.exception("unhandled error in state %s", state.value)
                state = State.FAILED
                self.loop_state.stop_reason = StopReason.STALL_DETECTED
            self._persist_state(state)

        reason = self.loop_state.stop_reason or StopReason.TARGET_SCORE_REACHED
        log.info("forge run complete: %s (loops=%d)", reason.value, self.loop_state.loop_count)
        return reason

    def _determine_initial_state(self) -> State:
        if self.job.is_continuation:
            return State.CONTINUE_REPO
        if self.job.create_repo:
            return State.CREATE_REPO
        raise NotImplementedError("CLONE mode is not yet implemented")

    # -- Setup states --

    def _state_create_repo(self) -> State:
        """Create a fresh git repo in the workspaces directory."""
        ws = self.workspace
        ws.mkdir()
        subprocess.run(
            ["git", "init", "-b", "main"],
            capture_output=True, text=True, cwd=ws.path,
        )
        subprocess.run(
            ["git", "commit", "--allow-empty", "-m", "Initial commit"],
            capture_output=True, text=True, cwd=ws.path,
        )
        branch = self.job.work_branch or f"feat/{self.job.id}"
        subprocess.run(
            ["git", "checkout", "-b", branch],
            capture_output=True, text=True, cwd=ws.path,
        )
        log.info("created repo at %s on branch %s", ws.path, branch)
        return State.SETUP

    def _state_continue_repo(self) -> State:
        """Clone an existing workspace for a continuation run."""
        source = self.workspaces_dir / self.job.continue_from
        if not source.exists():
            log.error("continuation source not found: %s", source)
            self.loop_state.stop_reason = StopReason.STALL_DETECTED
            return State.FAILED

        ws = self.workspace
        if ws.exists():
            log.warning("workspace already exists, removing: %s", ws.path)
            shutil.rmtree(ws.path)

        shutil.copytree(source, ws.path)
        # Remove origin (this is a local copy, not a clone)
        subprocess.run(
            ["git", "remote", "remove", "origin"],
            capture_output=True, text=True, cwd=ws.path,
        )
        branch = self.job.work_branch or f"feat/{self.job.id}"
        subprocess.run(
            ["git", "checkout", "-b", branch],
            capture_output=True, text=True, cwd=ws.path,
        )
        # Delete stale eval files but keep ledger
        evals_dir = ws.path / "EVALS"
        if evals_dir.exists():
            for f in evals_dir.iterdir():
                if f.name != "ledger.jsonl" and f.is_file():
                    f.unlink()
        log.info("continued from %s into %s", source, ws.path)
        return State.SETUP

    def _state_setup(self) -> State:
        """Run setup commands from job config."""
        commands = (
            self.job.commands.continue_setup
            if self.job.is_continuation and self.job.commands.continue_setup
            else self.job.commands.setup
        )
        for cmd in commands:
            log.info("setup: %s", cmd)
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True, cwd=self.workspace.path,
            )
            if result.returncode != 0:
                log.warning("setup command exited %d: %s", result.returncode, result.stderr[:300])
        return State.SCAFFOLD

    def _state_scaffold(self) -> State:
        """Copy template files and create baseline feature list."""
        ws = self.workspace
        template_dir = self.harness_dir / TEMPLATE_DIR

        if self.job.is_continuation:
            # Continuation: append new features, regenerate baseline
            self._scaffold_continuation()
        else:
            # Fresh scaffold: copy templates
            self._scaffold_fresh(template_dir)

        # Parse PROGRAM.md into structured spec
        program_text = ws.read_file("PROGRAM.md")
        if program_text:
            self.spec = ProgramSpec.from_program_md(program_text)

        # Create features baseline
        self._create_features_baseline()

        # Git commit the scaffold
        subprocess.run(
            ["git", "add", "-A"], capture_output=True, text=True, cwd=ws.path,
        )
        subprocess.run(
            ["git", "commit", "-m", "chore(scaffold): initial product scaffold"],
            capture_output=True, text=True, cwd=ws.path,
        )
        log.info("scaffold complete")
        return State.SYNC

    def _scaffold_fresh(self, template_dir: Path) -> None:
        """Copy template files into a fresh workspace."""
        ws = self.workspace
        if not template_dir.exists():
            log.warning("template dir not found: %s", template_dir)
            return
        for item in template_dir.iterdir():
            dest = ws.path / item.name
            if item.is_dir():
                if not dest.exists():
                    shutil.copytree(item, dest)
            else:
                shutil.copy2(item, dest)

    def _scaffold_continuation(self) -> None:
        """Append new features to FEATURES.md for continuation runs."""
        ws = self.workspace
        if not self.job.new_features:
            return
        features_text = ws.read_file("FEATURES.md")
        # Insert new features before ### Backlog if present
        marker = "### Backlog"
        if marker in features_text:
            features_text = features_text.replace(
                marker, f"{self.job.new_features}\n\n{marker}",
            )
        else:
            features_text += f"\n{self.job.new_features}\n"
        ws.write_file("FEATURES.md", features_text)

    def _create_features_baseline(self) -> None:
        """Parse FEATURES.md and write EVALS/features-baseline.json."""
        ws = self.workspace
        features_text = ws.read_file("FEATURES.md")
        if not features_text:
            log.warning("no FEATURES.md found, skipping baseline")
            return

        import re
        feature_ids: list[str] = re.findall(
            r"^[-*]\s+\*\*(F-\d+)\*\*", features_text, re.MULTILINE,
        )
        if not feature_ids:
            # Try alternate format: - F-001: ...
            feature_ids = re.findall(r"^[-*]\s+(F-\d+)", features_text, re.MULTILINE)

        baseline = FeatureBaseline(
            feature_ids=feature_ids,
            frozen_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            source="SCAFFOLD_CONTINUE" if self.job.is_continuation else "SCAFFOLD",
        )
        evals_dir = ws.path / "EVALS"
        evals_dir.mkdir(parents=True, exist_ok=True)
        (evals_dir / "features-baseline.json").write_text(
            baseline.model_dump_json(indent=2) + "\n", encoding="utf-8",
        )
        log.info("baseline created with %d features: %s", len(feature_ids), feature_ids)

    def _state_sync(self) -> State:
        """Sync with remote. No-op for local://create repos."""
        log.info("sync: no-op for local repo")
        return State.EVAL_BASELINE

    # -- Loop states --

    def _state_eval_baseline(self) -> State:
        """Run evaluator and record score_before for this loop."""
        self.loop_state.loop_start_time = time.time()
        self.loop_state.score_before = _compute_composite_score(self.workspace, self.spec)
        self.loop_state.pre_code_commit = self.workspace.current_commit()
        log.info(
            "loop %d baseline: score=%.4f commit=%s",
            self.loop_state.loop_count,
            self.loop_state.score_before,
            self.loop_state.pre_code_commit[:8],
        )
        return State.PLAN

    def _state_plan(self) -> State:
        """Invoke Claude to plan the next feature."""
        prompt = self._build_plan_prompt()
        rc = self._invoke_claude(prompt)
        if rc != 0:
            log.warning("plan exited with code %d", rc)
        return State.CODE

    def _state_code(self) -> State:
        """Invoke Claude to implement the planned feature."""
        self.loop_state.pre_code_commit = self.workspace.current_commit()
        prompt = self._build_code_prompt()
        rc = self._invoke_claude(prompt)
        if rc != 0:
            log.warning("code exited with code %d", rc)
        return State.CODE_AUDIT

    def _state_code_audit(self) -> State:
        """Audit code changes against mutation caps."""
        audit = _audit_code_changes(
            self.workspace, self.spec.caps, self.loop_state.pre_code_commit,
        )
        log.info("audit: %s", audit.summary())
        if not audit.passed:
            self.loop_state.verdict = Verdict.DISCARD_AUDIT
            self.loop_state.consecutive_discards += 1
            self.workspace.rollback_to(self.loop_state.pre_code_commit)
            return State.LEDGER
        return State.PRODUCT_TEST

    def _state_product_test(self) -> State:
        """Run product test suite."""
        passed = _run_product_tests(self.workspace, self.job.commands.test)
        if not passed:
            self.loop_state.verdict = Verdict.DISCARD_TEST_FAIL
            self.loop_state.consecutive_discards += 1
            self.workspace.rollback_to(self.loop_state.pre_code_commit)
            return State.LEDGER
        return State.JUDGE

    def _state_judge(self) -> State:
        """Compare score_after vs score_before to decide keep/discard."""
        score_after = _compute_composite_score(self.workspace, self.spec)
        self.loop_state.score_after = score_after
        delta = score_after - self.loop_state.score_before

        log.info(
            "judge: before=%.4f after=%.4f delta=%+.4f",
            self.loop_state.score_before, score_after, delta,
        )

        if score_after > self.loop_state.score_before:
            self.loop_state.verdict = Verdict.KEEP
            self.loop_state.consecutive_discards = 0
        else:
            self.loop_state.verdict = Verdict.DISCARD_REGRESSION
            self.loop_state.consecutive_discards += 1
            self.workspace.rollback_to(self.loop_state.pre_code_commit)

        # Plateau detection
        if abs(delta) < self.spec.stops.min_improvement_delta:
            self.loop_state.plateau_count += 1
            log.info("plateau count: %d", self.loop_state.plateau_count)

        return State.LEDGER

    def _state_ledger(self) -> State:
        """Record loop outcome in EVALS/ledger.jsonl."""
        ls = self.loop_state
        wall_seconds = int(time.time() - ls.loop_start_time) if ls.loop_start_time else 0

        entry = LedgerEntry.now(
            loop=ls.loop_count,
            hypothesis="",  # TODO: extract from PROGRESS.md
            files_touched="",  # TODO: extract from git diff
            wall_seconds=wall_seconds,
            score_before=f"{ls.score_before:.4f}",
            score_after=f"{ls.score_after:.4f}",
            kept=ls.verdict == Verdict.KEEP,
            commit_sha=self.workspace.current_commit()[:8],
            verdict=ls.verdict.value,
        )

        ledger_path = self.workspace.path / "EVALS" / "ledger.jsonl"
        _append_ledger_entry(ledger_path, entry)
        log.info(
            "ledger: loop=%d verdict=%s score=%.4f->%.4f",
            ls.loop_count, ls.verdict.value, ls.score_before, ls.score_after,
        )
        return State.LOOP_CHECK

    def _state_loop_check(self) -> State:
        """Check stop conditions and decide whether to continue."""
        ls = self.loop_state
        elapsed = time.time() - self.start_time
        time_budget = self.job.time_budget_sec or self.spec.time_budget_sec
        max_loops = self.job.max_loops or self.spec.max_loops
        stops = self.spec.stops

        # 1. Job cancelled externally
        if self.job.cancelled:
            ls.stop_reason = StopReason.CANCELLED
            return State.FAILED

        # 2. Time budget exceeded
        if time_budget and elapsed >= time_budget:
            ls.stop_reason = StopReason.TIME_BUDGET_EXCEEDED
            log.info("time budget exceeded: %.0fs >= %ds", elapsed, time_budget)
            return State.DONE

        # 3. Max loops reached
        if max_loops and ls.loop_count >= max_loops:
            ls.stop_reason = StopReason.MAX_LOOPS_REACHED
            log.info("max loops reached: %d", ls.loop_count)
            return State.DONE

        # 4. Target score reached
        if ls.score_after >= stops.target_score:
            ls.stop_reason = StopReason.TARGET_SCORE_REACHED
            log.info("target score reached: %.4f >= %.4f", ls.score_after, stops.target_score)
            return State.DONE

        # 5. Plateau
        if ls.plateau_count >= stops.max_plateau_loops:
            ls.stop_reason = StopReason.PLATEAU_STOP
            log.info("plateau stop: %d consecutive", ls.plateau_count)
            return State.DONE

        # 6. Consecutive discards
        if ls.consecutive_discards >= stops.max_discards_in_a_row:
            ls.stop_reason = StopReason.CONSECUTIVE_DISCARD_STOP
            log.info("consecutive discard stop: %d", ls.consecutive_discards)
            return State.DONE

        # 7. Continue — next loop
        ls.loop_count += 1
        log.info("continuing to loop %d", ls.loop_count)
        return State.EVAL_BASELINE

    def _state_push(self) -> State:
        """Push to remote. Currently a no-op for local repos."""
        # TODO: implement for remote repos
        log.info("push: no-op for local repo")
        return State.DONE

    # -- Claude invocation --

    def _invoke_claude(self, prompt: str) -> int:
        """Invoke Claude CLI. Returns exit code."""
        if os.environ.get("CLAUDE_MOCK"):
            return self._mock_response(prompt)

        cmd = ["claude", "-p", "--output-format", "json", "--model", self.model]
        try:
            result = subprocess.run(
                cmd, input=prompt, capture_output=True, text=True,
                cwd=self.workspace.path, timeout=1800,
            )
            return result.returncode
        except FileNotFoundError:
            log.error("claude CLI not found in PATH")
            return 1
        except subprocess.TimeoutExpired:
            log.error("claude CLI timed out after 1800s")
            return 1

    def _mock_response(self, prompt: str) -> int:
        """Mock Claude response for testing. Mimics bash CLAUDE_MOCK behavior."""
        ws = self.workspace

        if "scaffold" in prompt.lower() or "features" in prompt.lower():
            # SCAFFOLD mock: create minimal files
            ws.write_file("src/__init__.py", "")
            ws.write_file("src/main.py", '"""Main module."""\n')
            subprocess.run(
                ["git", "add", "-A"], capture_output=True, cwd=ws.path,
            )
            subprocess.run(
                ["git", "commit", "-m", "feat(scaffold): mock scaffold"],
                capture_output=True, cwd=ws.path,
            )
        elif "plan" in prompt.lower():
            # PLAN mock: write hypothesis to PROGRESS.md
            progress = ws.read_file("PROGRESS.md")
            progress += "\n### Hypothesis\nImplement next feature from backlog.\n"
            ws.write_file("PROGRESS.md", progress)
            subprocess.run(
                ["git", "add", "PROGRESS.md"], capture_output=True, cwd=ws.path,
            )
            subprocess.run(
                ["git", "commit", "-m", "plan: mock hypothesis"],
                capture_output=True, cwd=ws.path,
            )
        elif "code" in prompt.lower() or "implement" in prompt.lower():
            # CODE mock: create a dummy source file
            ws.write_file("src/feature.py", '"""Mock feature."""\n\ndef run():\n    return True\n')
            subprocess.run(
                ["git", "add", "-A"], capture_output=True, cwd=ws.path,
            )
            subprocess.run(
                ["git", "commit", "-m", "feat: mock implementation"],
                capture_output=True, cwd=ws.path,
            )

        return 0

    # -- Prompt builders --

    def _build_context(self) -> str:
        """Shared context included in all prompts."""
        ws = self.workspace
        parts: list[str] = []

        features = ws.read_file("FEATURES.md")
        if features:
            parts.append(f"## FEATURES.md\n{features}")

        # Recent ledger entries
        ledger_path = ws.path / "EVALS" / "ledger.jsonl"
        entries = _read_ledger_entries(ledger_path, tail=5)
        if entries:
            ledger_text = "\n".join(e.model_dump_json() for e in entries)
            parts.append(f"## Recent ledger entries\n{ledger_text}")

        # Time remaining
        elapsed = time.time() - self.start_time
        budget = self.job.time_budget_sec or self.spec.time_budget_sec
        remaining = max(0, budget - elapsed)
        parts.append(f"## Time remaining: {int(remaining)}s of {budget}s")
        parts.append(f"## Loop: {self.loop_state.loop_count}")

        return "\n\n".join(parts)

    def _build_plan_prompt(self) -> str:
        """Build the PLAN prompt for Claude."""
        ws = self.workspace
        parts = [
            "You are a product engineer planning the next feature to implement.",
            "",
            self._build_context(),
            "",
        ]
        progress = ws.read_file("PROGRESS.md")
        if progress:
            parts.append(f"## PROGRESS.md\n{progress}")

        program = ws.read_file("PROGRAM.md")
        if program:
            parts.append(f"## PROGRAM.md\n{program}")

        git_log = ws.git_log(10)
        if git_log:
            parts.append(f"## Recent commits\n{git_log}")

        parts.append(
            "\nPick the next not-started feature. Write your hypothesis and plan "
            "to PROGRESS.md. Do NOT write any code yet."
        )
        return "\n\n".join(parts)

    def _build_code_prompt(self) -> str:
        """Build the CODE prompt for Claude."""
        ws = self.workspace
        caps = self.spec.caps
        parts = [
            "You are a product engineer implementing a feature.",
            "",
            self._build_context(),
            "",
            f"## Mutation caps\n"
            f"- Max files changed: {caps.max_files_changed}\n"
            f"- Max files created: {caps.max_files_created}\n"
            f"- Max diff lines: {caps.max_diff_lines}",
        ]

        progress = ws.read_file("PROGRESS.md")
        if progress:
            parts.append(f"## PROGRESS.md (contains your plan/hypothesis)\n{progress}")

        program = ws.read_file("PROGRAM.md")
        if program:
            quality = self.spec.quality_requirements
            if quality:
                parts.append(f"## Quality Requirements\n{quality}")

        parts.append(
            "\nImplement the planned feature. Stay within mutation caps. "
            "Write tests. Commit your changes with a descriptive message."
        )
        return "\n\n".join(parts)

    # -- State persistence --

    def _persist_state(self, state: State) -> None:
        """Write runtime state back to job JSON."""
        self.job.loop_count = self.loop_state.loop_count
        self.job.consecutive_discards = self.loop_state.consecutive_discards
        self.job.last_state = state.value
        self.job.last_state_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        if self.job_file:
            try:
                self.job.to_json_file(self.job_file)
            except Exception:
                log.exception("failed to persist state to %s", self.job_file)

    @property
    def elapsed(self) -> float:
        return time.time() - self.start_time
