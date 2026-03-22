"""Natural language to job JSON generation for Product Forge."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Any

from forge.models import Commands, JobConfig

# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------

PYTHON_CLI_TEMPLATE: dict[str, Any] = {
    "setup": [
        'python -m pip install typer rich pytest pytest-cov ruff mypy pip-audit',
        (
            "printf '__pycache__/\\n*.pyc\\n*.pyo\\n*.egg-info/\\n.eggs/\\n"
            ".pytest_cache/\\n.mypy_cache/\\n.venv/\\nenv/\\n*.db\\n.env\\n"
            ".DS_Store\\ndist/\\nbuild/\\n.coverage\\nhtmlcov/\\n' > .gitignore"
        ),
    ],
    "test": [
        'python -m pytest tests/ -v --tb=short',
        'python -m ruff check .',
        'python -m mypy src/ --ignore-missing-imports',
    ],
}

PYTHON_API_TEMPLATE: dict[str, Any] = {
    "setup": [
        'python -m pip install fastapi uvicorn pydantic pytest pytest-cov ruff mypy pip-audit httpx',
        (
            "printf '__pycache__/\\n*.pyc\\n*.pyo\\n*.egg-info/\\n.eggs/\\n"
            ".pytest_cache/\\n.mypy_cache/\\n.venv/\\nenv/\\n*.db\\n.env\\n"
            ".DS_Store\\ndist/\\nbuild/\\n.coverage\\nhtmlcov/\\n' > .gitignore"
        ),
    ],
    "test": [
        'python -m pytest tests/ -v --tb=short',
        'python -m ruff check .',
        'python -m mypy src/ --ignore-missing-imports',
    ],
}

# Standard feature patterns for common product types
_CLI_FEATURE_PATTERNS: list[tuple[str, str]] = [
    ("Scaffold + init command", "Create package structure, database, init command with idempotent setup"),
    ("Add/create command", "Add new records with validation (positive amounts, valid dates, non-empty fields)"),
    ("List command with filters", "List records with optional filters (category, date range, limit), rich table output"),
    ("Summary/stats command", "Aggregate statistics: totals, counts, averages, top categories with percentages"),
    ("Budget/limits command", "Set and track limits per category with over-limit detection, colored output"),
    ("Search command", "Case-insensitive substring search across text fields with optional date filter"),
    ("Categories/tags command", "List categories with totals, counts, averages, percentages, sorted by total"),
    ("Export command (JSON/CSV)", "Export filtered data as JSON array or CSV with header, to stdout or file"),
]

_API_FEATURE_PATTERNS: list[tuple[str, str]] = [
    ("Scaffold + health endpoint", "Create package structure, database, GET /health endpoint"),
    ("Create resource endpoint", "POST endpoint with Pydantic validation, returns created resource"),
    ("List resources with filters", "GET endpoint with query params for filtering, pagination"),
    ("Get single resource", "GET /{id} with 404 handling"),
    ("Update resource", "PUT/PATCH /{id} with validation and 404 handling"),
    ("Delete resource", "DELETE /{id} with 404 handling"),
    ("Summary/aggregation endpoint", "GET /summary with aggregate stats"),
    ("Export endpoint", "GET /export with format query param (json/csv)"),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _slugify(name: str) -> str:
    """Convert a product name to a slug: 'Expense Tracker CLI' -> 'expense-tracker'."""
    # Remove common suffixes
    name = re.sub(r'\s+(CLI|API|App|Tool|Service|Server|Library)\s*$', '', name, flags=re.IGNORECASE)
    # Lowercase, replace non-alphanum with hyphens, collapse
    slug = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')
    return slug or "product"


def _next_job_id(slug: str, examples_dir: Path) -> str:
    """Find the next available job ID: expense-001, expense-002, etc."""
    counter = 1
    while True:
        candidate = f"{slug}-{counter:03d}"
        if not (examples_dir / f"{candidate}.json").exists():
            return candidate
        counter += 1


def _detect_product_type(description: str) -> str:
    """Detect product type from description: 'cli', 'api', or 'library'."""
    desc_lower = description.lower()
    api_keywords = ["api", "fastapi", "http", "rest", "endpoint", "server", "web service"]
    if any(kw in desc_lower for kw in api_keywords):
        return "api"
    # Default to CLI
    return "cli"


def _extract_product_name(description: str) -> str:
    """Extract a product name from a natural language description."""
    # Common patterns: "Build a/an X", "Create a/an X", "X tool/app/cli"
    patterns = [
        r'(?:build|create|make|develop|implement)\s+(?:a|an)\s+(.+?)(?:\s+(?:in|using|with)\s)',
        r'(?:build|create|make|develop|implement)\s+(?:a|an)\s+(.+?)(?:\.|$)',
        r'^(.+?)\s+(?:in|using|with)\s',
    ]
    for pat in patterns:
        m = re.search(pat, description, re.IGNORECASE)
        if m:
            name = m.group(1).strip().rstrip('.')
            # Capitalize words
            return ' '.join(w.capitalize() for w in name.split())
    # Fallback: use first few words
    words = description.split()[:4]
    return ' '.join(w.capitalize() for w in words)


def _generate_features_md(
    product_name: str,
    features: list[tuple[str, str, str]],
) -> str:
    """Generate FEATURES.md content.

    features: list of (id, name, notes) tuples.
    """
    lines = [
        "# Feature Tracker",
        "",
        f"## Product: {product_name}",
        "",
        "### Status Legend",
        "- `not-started` - Not yet begun",
        "- `in-progress` - Currently being implemented",
        "- `done` - Implemented and tested",
        "- `blocked` - Blocked by external dependency",
        "",
        "### Features",
        "",
        "| ID | Feature | Status | Priority | Notes |",
        "|----|---------|--------|----------|-------|",
    ]

    for i, (fid, name, notes) in enumerate(features):
        priority = "P0" if i < len(features) // 2 else "P1" if i < len(features) * 3 // 4 else "P2"
        lines.append(f"| {fid} | {name} | not-started | {priority} | {notes} |")

    lines.extend([
        "",
        "### Backlog",
        f"_(none - feature set is fixed at {len(features)})_",
        "",
    ])
    return "\n".join(lines)


def _generate_program_md(
    product_name: str,
    job_id: str,
    max_loops: int = 12,
    time_budget: int = 14400,
) -> str:
    """Generate PROGRAM.md with standard v0.7.1 operational profile."""
    return f"""# PROGRAM.md - {product_name} ({job_id})

## Product: {product_name}

## Objective

Maximize composite quality score through hypothesis-driven mutations.
Each loop must produce a small, testable increment - not a large batch.

## Mutation Scope

- Max files changed per loop: 3
- Max files created per loop: 2
- Max diff lines per loop: 200
- Max endpoint/route changes per loop: 1

## Eval Protocol

weights:
  tests: 0.30
  lint: 0.15
  typecheck: 0.10
  coverage: 0.15
  security: 0.05
  feature_coverage: 0.25

## Keep/Discard Policy

- keep_threshold: score_after > score_before
- tie_policy: discard

## Budget

- max_loops: {max_loops}
- max_wall_seconds: {time_budget}
- max_discards_in_a_row: 3

## Stop Conditions

- target_score: 1.00
- min_improvement_delta: 0.01
- max_plateau_loops: 3
- consecutive_discards >= max_discards_in_a_row

## Hypothesis Sources

- FEATURES.md, eval failures, coverage gaps, EVALS/ledger.jsonl

## Arena Contract

- **FIRST: Read EVALS/ledger.jsonl before choosing your hypothesis.**
  Find the most recent entry. Check the "verdict" field.
  If verdict was "discard_audit", your next hypothesis MUST reduce scope (fewer files).
  Write your hypothesis as: "Last verdict: <verdict> | Response: <your adaptation>"
- Choose exactly one baseline feature (F-001..F-{len(_CLI_FEATURE_PATTERNS):03d}) or one blocking defect per loop.
- Before making changes, search the codebase. Do not assume missing implementation.
- Do not create scratch, debug, or temp files.
- Do not edit scoring files, eval scripts, or EVALS/features-baseline.json.
- Do not add, remove, reorder, or split features in FEATURES.md.
- Run the smallest relevant test first, then full eval.
- Update FEATURES.md status only for baseline features.
- KEEP only if score improves and audit passes.
- If tests break, fix them in the SAME loop before moving on.
- Prefer depth (thorough tests for one feature) over breadth.

## Quality Requirements

- **Edge-case tests mandatory**: Every feature MUST include at least one test for invalid input,
  empty results, or boundary conditions.
- **Input validation**: All user-facing commands must validate arguments and print a clear,
  actionable error message for bad input. Never let exceptions propagate as raw tracebacks.
- **Modular code**: Source MUST be split into separate modules:
  db.py (database layer), main.py (CLI/API commands), and helpers as needed.
  One monolithic file is not acceptable. Split at ~150 lines.
- **pytest-cov required**: pytest-cov is installed. Coverage is measured automatically.
  Aim for >=80% line coverage. Low coverage will lower your score.
- **Database indexes**: Indexes on columns used in WHERE/ORDER BY are required.
  Full table scans are not acceptable for query features.
"""


def _generate_pyproject_toml(slug: str) -> str:
    """Generate printf command for pyproject.toml."""
    # Escape for printf inside shell
    content = (
        f"[project]\\nname = \\\"{slug}\\\"\\nversion = \\\"0.1.0\\\"\\n"
        f"requires-python = \\\">=3.11\\\"\\n\\n"
        f"[project.optional-dependencies]\\ndev = [\\\"pytest\\\", \\\"pytest-cov\\\", "
        f"\\\"ruff\\\", \\\"mypy\\\", \\\"pip-audit\\\"]\\n\\n"
        f"[project.scripts]\\n{slug} = \\\"{slug}.main:app\\\"\\n\\n"
        f"[tool.ruff]\\nline-length = 88\\n\\n"
        f"[tool.ruff.lint]\\nselect = [\\\"E\\\", \\\"F\\\", \\\"W\\\", \\\"I\\\"]\\n\\n"
        f"[tool.mypy]\\nstrict = true\\nwarn_return_any = true\\nwarn_unused_configs = true\\n\\n"
        f"[tool.pytest.ini_options]\\ntestpaths = [\\\"tests\\\"]\\npythonpath = [\\\"src\\\"]\\n\\n"
        f"[tool.coverage.run]\\nsource = [\\\"src\\\"]\\n\\n"
        f"[tool.coverage.report]\\nfail_under = 60\\nshow_missing = true\\n"
    )
    return f"printf '{content}' > pyproject.toml"


def _generate_features_setup_cmd(product_name: str, slug: str, features: list[tuple[str, str, str]]) -> str:
    """Generate the setup command that creates FEATURES.md."""
    features_content = _generate_features_md(product_name, features)
    # Escape for printf
    escaped = features_content.replace("'", "'\\''").replace("\n", "\\n")
    return f"mkdir -p tests && printf '{escaped}' > FEATURES.md"


def _build_task_description(
    product_name: str,
    slug: str,
    product_type: str,
    features: list[tuple[str, str, str]],
    description: str,
) -> str:
    """Build the detailed task field for the job config."""
    if product_type == "api":
        stack = "Python 3.11+, FastAPI, SQLite3 (stdlib), Pydantic, pytest, pytest-cov, ruff, mypy"
        framework = "fastapi for API, pydantic for validation"
    else:
        stack = "Python 3.11+, Typer, SQLite3 (stdlib), Rich, pytest, pytest-cov, ruff, mypy"
        framework = "typer for CLI, sqlite3 (stdlib) for storage, rich for output"

    lines = [
        f"Build a {product_type.upper()} tool called {slug} for {description.lower().rstrip('.')}.",
        f"Use {framework}, pytest + pytest-cov + ruff + mypy for quality.",
        "Use pyproject.toml with all tool configs.",
        "",
        f"Stack: {stack}.",
        "",
        "IMPORTANT: FEATURES.md is already created in the workspace by the setup script.",
        "Do NOT recreate, overwrite, reorder, modify, or expand it.",
        f"Do NOT add features beyond F-001..F-{len(features):03d}. Do NOT split features into sub-features.",
        "Do NOT add separate 'test coverage' or 'tooling' features.",
        f"The {len(features)} features are fixed. Implement them as described, no more.",
        "",
        "QUALITY REQUIREMENTS (non-negotiable):",
        "- Modular code: separate files for database (db.py), CLI commands (main.py), and models/helpers.",
        "  Do NOT put everything in one giant file. Split at ~150 lines per file.",
        "- Input validation: every command must validate its arguments. Print clear error messages, never raw tracebacks.",
        "- Edge-case tests: each feature must include at least 1 test for invalid input or boundary condition.",
        "- Database indexes: add CREATE INDEX on columns used in WHERE/ORDER BY.",
        "- pytest-cov is included in dev deps. Aim for >=80% line coverage.",
        "",
        "Feature overview (read FEATURES.md for authoritative spec):",
        "",
    ]

    for fid, name, notes in features:
        lines.append(f"{fid}: {name}")
        if notes:
            lines.append(f"  {notes}")
        lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def generate_job(
    description: str,
    product_name: str = "",
    num_features: int = 8,
    stack: str = "",
) -> JobConfig:
    """Generate a complete JobConfig from a natural language description.

    Uses template mode (no external API needed). For Claude-assisted mode,
    call _generate_with_claude() directly.
    """
    # Try Claude-assisted first if available, fall back to templates
    if _claude_available():
        try:
            return _generate_with_claude(description, product_name, num_features, stack)
        except Exception:
            pass  # Fall through to template mode

    return _generate_with_templates(description, product_name, num_features, stack)


def _claude_available() -> bool:
    """Check if Claude CLI is available for assisted generation."""
    try:
        result = subprocess.run(
            ["claude", "--version"],
            capture_output=True,
            timeout=5,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return False


def _generate_with_templates(
    description: str,
    product_name: str = "",
    num_features: int = 8,
    stack: str = "",
) -> JobConfig:
    """Generate using built-in templates (no API needed)."""
    # Detect product type
    product_type = _detect_product_type(description) if not stack else (
        "api" if "api" in stack.lower() or "fastapi" in stack.lower() else "cli"
    )

    # Generate or use provided product name
    if not product_name:
        product_name = _extract_product_name(description)

    slug = _slugify(product_name)
    examples_dir = Path("examples")
    examples_dir.mkdir(exist_ok=True)
    job_id = _next_job_id(slug, examples_dir)

    # Select template
    template = PYTHON_API_TEMPLATE if product_type == "api" else PYTHON_CLI_TEMPLATE
    feature_patterns = _API_FEATURE_PATTERNS if product_type == "api" else _CLI_FEATURE_PATTERNS

    # Generate features
    features: list[tuple[str, str, str]] = []
    for i in range(min(num_features, len(feature_patterns))):
        fid = f"F-{i + 1:03d}"
        name, notes = feature_patterns[i]
        features.append((fid, name, notes))

    # If more features requested than patterns, generate generic ones
    for i in range(len(feature_patterns), num_features):
        fid = f"F-{i + 1:03d}"
        features.append((fid, f"Feature {i + 1}", ""))

    # Build setup commands
    setup_cmds = list(template["setup"])
    setup_cmds.append(_generate_pyproject_toml(slug))
    setup_cmds.append(_generate_features_setup_cmd(product_name, slug, features))

    # Build task description
    task = _build_task_description(product_name, slug, product_type, features, description)

    # Build PROGRAM.md
    program_md = _generate_program_md(product_name, job_id)

    return JobConfig(
        id=job_id,
        repo="local://create",
        base_ref="main",
        work_branch=f"forge/{job_id}",
        task=task,
        time_budget_sec=14400,
        mode="product",
        product_name=product_name,
        max_loops=12,
        create_repo=True,
        commands=Commands(
            setup=setup_cmds,
            test=list(template["test"]),
        ),
        program_md=program_md,
    )


def _generate_with_claude(
    description: str,
    product_name: str = "",
    num_features: int = 8,
    stack: str = "",
) -> JobConfig:
    """Generate using Claude for full spec generation.

    Calls Claude CLI in print mode to generate a detailed feature spec,
    then wraps it in a JobConfig.
    """
    import json

    prompt = f"""Generate a product specification as JSON for:

Description: {description}
Product name: {product_name or '(auto-detect from description)'}
Number of features: {num_features}
Stack preference: {stack or 'Python CLI with Typer + SQLite + Rich'}

Output ONLY valid JSON with this structure:
{{
  "product_name": "Name of the Product",
  "product_type": "cli" or "api",
  "features": [
    {{"id": "F-001", "name": "Feature name", "notes": "Implementation details"}},
    ...
  ]
}}

Rules:
- First feature should always be scaffold/init
- Last feature should be export
- Features should build on each other progressively
- Include specific implementation details in notes
- Use standard Python tooling (pytest, ruff, mypy)
"""

    result = subprocess.run(
        ["claude", "--print", prompt],
        capture_output=True,
        text=True,
        timeout=60,
    )

    if result.returncode != 0:
        raise RuntimeError(f"Claude CLI failed: {result.stderr}")

    # Extract JSON from output
    output = result.stdout.strip()
    # Try to find JSON block
    json_match = re.search(r'\{[\s\S]*\}', output)
    if not json_match:
        raise ValueError("No JSON found in Claude output")

    spec = json.loads(json_match.group())

    detected_name = spec.get("product_name", product_name or _extract_product_name(description))
    product_type = spec.get("product_type", "cli")
    raw_features = spec.get("features", [])

    slug = _slugify(detected_name)
    examples_dir = Path("examples")
    examples_dir.mkdir(exist_ok=True)
    job_id = _next_job_id(slug, examples_dir)

    features = [
        (f.get("id", f"F-{i+1:03d}"), f.get("name", ""), f.get("notes", ""))
        for i, f in enumerate(raw_features[:num_features])
    ]

    template = PYTHON_API_TEMPLATE if product_type == "api" else PYTHON_CLI_TEMPLATE

    setup_cmds = list(template["setup"])
    setup_cmds.append(_generate_pyproject_toml(slug))
    setup_cmds.append(_generate_features_setup_cmd(detected_name, slug, features))

    task = _build_task_description(detected_name, slug, product_type, features, description)
    program_md = _generate_program_md(detected_name, job_id)

    return JobConfig(
        id=job_id,
        repo="local://create",
        base_ref="main",
        work_branch=f"forge/{job_id}",
        task=task,
        time_budget_sec=14400,
        mode="product",
        product_name=detected_name,
        max_loops=12,
        create_repo=True,
        commands=Commands(
            setup=setup_cmds,
            test=list(template["test"]),
        ),
        program_md=program_md,
    )
