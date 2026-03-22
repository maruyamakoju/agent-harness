"""CODE_AUDIT implementation — checks mutation caps and code structure."""

from __future__ import annotations

import logging
from pathlib import Path

from forge.models import AuditResult, MutationCaps
from forge.workspace import Workspace

logger = logging.getLogger(__name__)


def audit_code_changes(
    workspace: Workspace,
    caps: MutationCaps,
    pre_code_commit: str,
) -> AuditResult:
    """Audit code changes between *pre_code_commit* and HEAD.

    Checks (in order):
    1. Files changed  — code files modified (state files excluded)
    2. Files created  — new code files (state files excluded)
    3. Diff lines     — total insertions + deletions (all files)
    4. Structure gate — monolith detection in src/{pkg}/

    Returns an :class:`AuditResult` with pass/fail and violation details.
    """
    violations: list[str] = []
    structure_violation = False

    # Gather diff statistics
    stat = workspace.diff_stat(pre_code_commit)

    # --- 1. Files changed ---
    if stat.files_changed > caps.max_files_changed:
        violations.append(
            f"files_changed={stat.files_changed} > max={caps.max_files_changed}"
        )

    # --- 2. Files created ---
    if stat.files_created > caps.max_files_created:
        violations.append(
            f"files_created={stat.files_created} > max={caps.max_files_created}"
        )

    # --- 3. Diff lines ---
    if stat.diff_lines > caps.max_diff_lines:
        violations.append(
            f"diff_lines={stat.diff_lines} > max={caps.max_diff_lines}"
        )

    # --- 4. Structure gate: monolith detection ---
    structure_violation = _check_structure_monolith(workspace)
    if structure_violation:
        violations.append(structure_violation)

    passed = len(violations) == 0

    result = AuditResult(
        passed=passed,
        violations=violations,
        files_changed=stat.files_changed,
        files_created=stat.files_created,
        diff_lines=stat.diff_lines,
        structure_violation=bool(structure_violation),
    )

    if passed:
        logger.info("CODE_AUDIT passed: %s", result.summary())
    else:
        logger.warning("CODE_AUDIT failed: %s", result.summary())

    return result


def _check_structure_monolith(workspace: Workspace) -> str:
    """Detect monolithic Python modules under ``src/{pkg}/``.

    Returns a violation description string, or empty string if OK.

    Rule: if total LOC across implementation files (excluding ``__init__.py``)
    exceeds 150 AND fewer than 2 implementation files exist, it's a monolith.
    """
    src_dir = workspace.path / "src"
    if not src_dir.is_dir():
        return ""

    # Find the first package directory under src/
    pkg_dir: Path | None = None
    try:
        for child in sorted(src_dir.iterdir()):
            if child.is_dir() and not child.name.startswith("."):
                pkg_dir = child
                break
    except OSError:
        logger.debug("Could not iterate src/ directory")
        return ""

    if pkg_dir is None:
        return ""

    # Collect implementation .py files (exclude __init__.py), top-level only
    impl_files: list[Path] = []
    try:
        for py_file in pkg_dir.iterdir():
            if (
                py_file.is_file()
                and py_file.suffix == ".py"
                and py_file.name != "__init__.py"
            ):
                impl_files.append(py_file)
    except OSError:
        logger.debug("Could not iterate package directory %s", pkg_dir)
        return ""

    impl_count = len(impl_files)
    if impl_count == 0:
        return ""

    total_loc = 0
    for f in impl_files:
        try:
            total_loc += sum(1 for _ in f.open(encoding="utf-8", errors="replace"))
        except OSError:
            logger.debug("Could not read %s for LOC count", f)

    if total_loc > 150 and impl_count < 2:
        msg = (
            f"structure_monolith: {total_loc} LOC in {impl_count} file(s) "
            f"(split required >150 LOC)"
        )
        logger.warning(msg)
        return msg

    return ""
