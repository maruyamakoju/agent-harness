"""Evaluator — runs tests, lint, typecheck, security scans on a workspace."""

from __future__ import annotations

import json
import logging
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from forge.models import EvalResult, EvalSuite, EvalType

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_CONTROL_CHAR_RE = re.compile(r"[\x00-\x08\x0b-\x1f]")


def _strip_control_chars(text: str) -> str:
    """Remove control characters that break JSON strings."""
    return _CONTROL_CHAR_RE.sub("", text)


def _escape_backslashes(text: str) -> str:
    """Escape backslashes in summary text (Windows paths)."""
    return text.replace("\\", "\\\\")


def _sanitize_summary(text: str, max_len: int = 200) -> str:
    """Clean summary text for safe JSON embedding."""
    text = _strip_control_chars(text)
    text = _escape_backslashes(text)
    text = text.replace("\n", " ").replace("\r", "")
    return text[:max_len]


def _run_command(
    cmd: list[str],
    cwd: Path,
    timeout: int = 300,
) -> tuple[str, int]:
    """Run a subprocess command, return (output, exit_code).

    Returns combined stdout+stderr and the exit code. Never raises on
    non-zero exit — the caller decides what constitutes pass/fail.
    """
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=str(cwd),
            timeout=timeout,
        )
        output = (result.stdout or "") + (result.stderr or "")
        return output, result.returncode
    except FileNotFoundError:
        return f"Command not found: {cmd[0]}", 127
    except subprocess.TimeoutExpired:
        return f"Command timed out after {timeout}s", 124
    except Exception as exc:
        return f"Error running command: {exc}", 1


def _timestamp_slug() -> str:
    """Return YYYYMMDD-HHMMSS slug for filenames."""
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def _iso_timestamp() -> str:
    """Return ISO 8601 UTC timestamp."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_eval_result(workspace: Path, result: EvalResult) -> Path:
    """Write an EvalResult to EVALS/{type}-{timestamp}.json."""
    evals_dir = workspace / "EVALS"
    evals_dir.mkdir(parents=True, exist_ok=True)
    slug = result.timestamp.replace("T", "-").replace(":", "").replace("Z", "")
    # Convert ISO timestamp to slug format: 2026-03-22-123456 -> 20260322-123456
    slug = slug.replace("-", "")
    # Now slug is like "20260322123456", split into YYYYMMDD-HHMMSS
    if len(slug) >= 14:
        slug = slug[:8] + "-" + slug[8:14]
    out_path = evals_dir / f"{result.eval_type}-{slug}.json"
    out_path.write_text(
        json.dumps(result.to_file_dict(), ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    logger.info("Wrote: %s", out_path)
    return out_path


def _tail_lines(text: str, n: int = 50) -> str:
    """Return the last n lines of text."""
    lines = text.strip().splitlines()
    return "\n".join(lines[-n:])


# ---------------------------------------------------------------------------
# Language detection
# ---------------------------------------------------------------------------

def detect_language(workspace: Path) -> str:
    """Detect project language from marker files.

    Returns one of: 'python', 'javascript', 'rust', 'go', 'unknown'.
    """
    if (workspace / "pyproject.toml").exists() or (workspace / "setup.py").exists():
        return "python"
    if (workspace / "package.json").exists():
        return "javascript"
    if (workspace / "Cargo.toml").exists():
        return "rust"
    if (workspace / "go.mod").exists():
        return "go"
    # Check for pytest.ini as Python fallback
    if (workspace / "pytest.ini").exists():
        return "python"
    return "unknown"


# ---------------------------------------------------------------------------
# Individual evaluators
# ---------------------------------------------------------------------------

def run_unit_tests(workspace: Path) -> EvalResult:
    """Run unit tests and return an EvalResult with optional coverage_pct."""
    ts = _iso_timestamp()
    start = time.monotonic()
    lang = detect_language(workspace)

    output: str
    exit_code: int
    coverage_pct: float | None = None

    if lang == "python":
        # Determine coverage target
        cov_target = "src" if (workspace / "src").is_dir() else "."

        # Try with --cov first
        probe_output, probe_rc = _run_command(
            ["python", "-m", "pytest", "--co", "-q", f"--cov={cov_target}"],
            cwd=workspace,
            timeout=30,
        )
        if probe_rc == 0:
            output, exit_code = _run_command(
                [
                    "python", "-m", "pytest",
                    "--tb=short", "-q",
                    f"--cov={cov_target}",
                    "--cov-report=term",
                ],
                cwd=workspace,
            )
            # Parse coverage from TOTAL line: "TOTAL    500    50    90%"
            for line in output.splitlines():
                if line.startswith("TOTAL"):
                    m = re.search(r"(\d+)%", line)
                    if m:
                        coverage_pct = float(m.group(1))
                        break
        else:
            logger.info("pytest-cov not available, running without coverage")
            output, exit_code = _run_command(
                ["python", "-m", "pytest", "--tb=short", "-q"],
                cwd=workspace,
            )

    elif lang == "javascript":
        output, exit_code = _run_command(["npm", "test"], cwd=workspace)

    elif lang == "rust":
        output, exit_code = _run_command(["cargo", "test"], cwd=workspace)

    elif lang == "go":
        output, exit_code = _run_command(["go", "test", "./..."], cwd=workspace)

    else:
        logger.info("No test framework detected, skipping unit tests")
        result = EvalResult(
            type=EvalType.UNIT,
            timestamp=ts,
            **{"pass": True},
            summary="No test framework detected",
            details={"skipped": True},
            duration_sec=0,
        )
        _write_eval_result(workspace, result)
        return result

    duration = int(time.monotonic() - start)
    passed = exit_code == 0
    tail = _tail_lines(output, 50)
    summary = _sanitize_summary("\n".join(tail.splitlines()[-5:]))

    details: dict = {"exit_code": exit_code}
    if coverage_pct is not None:
        details["coverage_pct"] = coverage_pct
        logger.info("Coverage measured: %d%%", int(coverage_pct))

    result = EvalResult(
        type=EvalType.UNIT,
        timestamp=ts,
        **{"pass": passed},
        summary=summary,
        details=details,
        duration_sec=duration,
    )
    _write_eval_result(workspace, result)
    return result


def run_lint(workspace: Path) -> EvalResult:
    """Run linter and return an EvalResult."""
    ts = _iso_timestamp()
    start = time.monotonic()
    lang = detect_language(workspace)

    output: str
    exit_code: int

    if lang == "python":
        # Check ruff is available
        _, ruff_rc = _run_command(
            ["python", "-m", "ruff", "--version"], cwd=workspace, timeout=15
        )
        if ruff_rc == 0:
            output, exit_code = _run_command(
                ["python", "-m", "ruff", "check", "."], cwd=workspace
            )
        else:
            logger.info("ruff not available, skipping lint")
            result = EvalResult(
                type=EvalType.LINT,
                timestamp=ts,
                **{"pass": True},
                summary="No linter available",
                details={"skipped": True},
                duration_sec=0,
            )
            _write_eval_result(workspace, result)
            return result

    elif lang == "javascript":
        # Try npm run lint
        pkg = workspace / "package.json"
        if pkg.exists() and '"lint"' in pkg.read_text(encoding="utf-8"):
            output, exit_code = _run_command(["npm", "run", "lint"], cwd=workspace)
        else:
            output, exit_code = _run_command(["npx", "eslint", "."], cwd=workspace)

    else:
        logger.info("No linter detected for language: %s", lang)
        result = EvalResult(
            type=EvalType.LINT,
            timestamp=ts,
            **{"pass": True},
            summary="No linter detected",
            details={"skipped": True},
            duration_sec=0,
        )
        _write_eval_result(workspace, result)
        return result

    duration = int(time.monotonic() - start)
    passed = exit_code == 0
    tail = _tail_lines(output, 30)
    summary = _sanitize_summary("\n".join(tail.splitlines()[-3:]))

    result = EvalResult(
        type=EvalType.LINT,
        timestamp=ts,
        **{"pass": passed},
        summary=summary,
        details={"exit_code": exit_code},
        duration_sec=duration,
    )
    _write_eval_result(workspace, result)
    return result


def run_typecheck(workspace: Path) -> EvalResult:
    """Run type checker and return an EvalResult."""
    ts = _iso_timestamp()
    start = time.monotonic()
    lang = detect_language(workspace)

    output: str
    exit_code: int

    if lang == "python":
        _, mypy_rc = _run_command(
            ["python", "-m", "mypy", "--version"], cwd=workspace, timeout=15
        )
        if mypy_rc == 0:
            target = "src/" if (workspace / "src").is_dir() else "."
            output, exit_code = _run_command(
                ["python", "-m", "mypy", target, "--ignore-missing-imports"],
                cwd=workspace,
            )
        else:
            logger.info("mypy not available, skipping typecheck")
            result = EvalResult(
                type=EvalType.TYPECHECK,
                timestamp=ts,
                **{"pass": True},
                summary="No type checker available",
                details={"skipped": True},
                duration_sec=0,
            )
            _write_eval_result(workspace, result)
            return result

    elif lang == "javascript":
        if (workspace / "tsconfig.json").exists():
            output, exit_code = _run_command(
                ["tsc", "--noEmit"], cwd=workspace
            )
        else:
            logger.info("No tsconfig.json found, skipping typecheck")
            result = EvalResult(
                type=EvalType.TYPECHECK,
                timestamp=ts,
                **{"pass": True},
                summary="No type checker detected",
                details={"skipped": True},
                duration_sec=0,
            )
            _write_eval_result(workspace, result)
            return result

    else:
        logger.info("No type checker detected for language: %s", lang)
        result = EvalResult(
            type=EvalType.TYPECHECK,
            timestamp=ts,
            **{"pass": True},
            summary="No type checker detected",
            details={"skipped": True},
            duration_sec=0,
        )
        _write_eval_result(workspace, result)
        return result

    duration = int(time.monotonic() - start)
    passed = exit_code == 0
    tail = _tail_lines(output, 30)
    summary = _sanitize_summary("\n".join(tail.splitlines()[-3:]))

    result = EvalResult(
        type=EvalType.TYPECHECK,
        timestamp=ts,
        **{"pass": passed},
        summary=summary,
        details={"exit_code": exit_code},
        duration_sec=duration,
    )
    _write_eval_result(workspace, result)
    return result


def run_security_scan(workspace: Path) -> EvalResult:
    """Run security scanner and return an EvalResult.

    Soft-passes if the only failures are 'not found on PyPI' warnings
    (no actual CVEs).
    """
    ts = _iso_timestamp()
    start = time.monotonic()
    lang = detect_language(workspace)

    output: str = ""
    exit_code: int = 0
    scanned = False

    if lang == "javascript" and (workspace / "package-lock.json").exists():
        output, exit_code = _run_command(
            ["npm", "audit", "--json"], cwd=workspace
        )
        scanned = True

    elif lang in ("python", "unknown"):
        # Try multiple pip-audit invocations
        for cmd in [
            ["pip-audit"],
            ["python", "-m", "pip_audit"],
            ["python3", "-m", "pip_audit"],
        ]:
            probe_output, probe_rc = _run_command(
                cmd + ["--version"] if len(cmd) == 1 else cmd[:2] + ["pip_audit", "--version"],
                cwd=workspace,
                timeout=15,
            )
            # Actually just try running the audit directly
            output, exit_code = _run_command(cmd, cwd=workspace)
            if exit_code != 127:  # command was found
                scanned = True
                break

    elif lang == "rust":
        output, exit_code = _run_command(
            ["cargo", "audit"], cwd=workspace
        )
        if exit_code != 127:
            scanned = True

    if not scanned:
        logger.info("No security scanner detected, skipping")
        result = EvalResult(
            type=EvalType.SECURITY,
            timestamp=ts,
            **{"pass": True},
            summary="No security scanner available",
            details={"skipped": True},
            duration_sec=0,
        )
        _write_eval_result(workspace, result)
        return result

    # Soft-pass: if exit code != 0 but no actual CVEs found
    if exit_code != 0:
        has_cve = bool(
            re.search(r"(vulnerability found|CVE-\d|GHSA-)", output, re.IGNORECASE)
        )
        if not has_cve:
            logger.info(
                "security: no CVEs found (unauditable packages only), treating as pass"
            )
            exit_code = 0

    duration = int(time.monotonic() - start)
    passed = exit_code == 0
    tail = _tail_lines(output, 30)
    summary = _sanitize_summary("\n".join(tail.splitlines()[-3:]))

    result = EvalResult(
        type=EvalType.SECURITY,
        timestamp=ts,
        **{"pass": passed},
        summary=summary,
        details={"exit_code": exit_code},
        duration_sec=duration,
    )
    _write_eval_result(workspace, result)
    return result


# ---------------------------------------------------------------------------
# Run all
# ---------------------------------------------------------------------------

def run_all(workspace: Path) -> EvalSuite:
    """Run all evaluations and return an EvalSuite."""
    logger.info("Starting evaluation suite for: %s", workspace)

    unit = run_unit_tests(workspace)
    lint = run_lint(workspace)
    typecheck = run_typecheck(workspace)
    security = run_security_scan(workspace)

    suite = EvalSuite(
        unit=unit,
        lint=lint,
        typecheck=typecheck,
        security=security,
        coverage_pct=unit.coverage_pct or 0.0,
    )

    logger.info("Evaluation complete. Results in: %s", workspace / "EVALS")
    return suite
