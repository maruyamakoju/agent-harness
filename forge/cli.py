"""CLI interface for Product Forge — Typer-based commands."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Annotated, Any

import typer
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

app = typer.Typer(
    name="forge",
    help="Product Forge — autonomous product builder with quality-gated evaluation loops.",
    no_args_is_help=True,
)
console = Console()

# ---------------------------------------------------------------------------
# Lazy imports — some modules may not exist yet
# ---------------------------------------------------------------------------

def _import_models() -> Any:
    from forge.models import JobConfig, LedgerEntry, FeatureBaseline
    return JobConfig, LedgerEntry, FeatureBaseline


def _import_generator() -> Any:
    from forge.generator import generate_job
    return generate_job


def _import_ledger() -> Any:
    from forge.ledger import read_entries, compute_metrics, read_baseline
    return read_entries, compute_metrics, read_baseline


# ---------------------------------------------------------------------------
# forge create
# ---------------------------------------------------------------------------

@app.command()
def create(
    description: Annotated[str, typer.Argument(help="Natural language product description")],
    name: Annotated[str, typer.Option("--name", "-n", help="Product name")] = "",
    features: Annotated[int, typer.Option("--features", "-f", help="Number of features")] = 8,
    output: Annotated[str, typer.Option("--output", "-o", help="Output JSON path")] = "",
) -> None:
    """Generate a job JSON from a natural language description."""
    try:
        generate_job = _import_generator()
    except ImportError as exc:
        console.print(f"[red]Error:[/red] Cannot import generator module: {exc}")
        raise typer.Exit(1) from None

    try:
        JobConfig, _, _ = _import_models()
    except ImportError as exc:
        console.print(f"[red]Error:[/red] Cannot import models module: {exc}")
        raise typer.Exit(1) from None

    job = generate_job(description, product_name=name, num_features=features)

    # Determine output path
    if not output:
        examples_dir = Path("examples")
        examples_dir.mkdir(exist_ok=True)
        output = str(examples_dir / f"{job.id}.json")

    out_path = Path(output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    job.to_json_file(out_path)

    # Print summary
    panel_content = (
        f"[bold]ID:[/bold] {job.id}\n"
        f"[bold]Product:[/bold] {job.product_name}\n"
        f"[bold]Features:[/bold] {features}\n"
        f"[bold]Max loops:[/bold] {job.max_loops}\n"
        f"[bold]Time budget:[/bold] {job.time_budget_sec}s\n"
        f"[bold]Output:[/bold] {out_path}"
    )
    console.print(Panel(panel_content, title="Job Created", border_style="green"))


# ---------------------------------------------------------------------------
# forge run
# ---------------------------------------------------------------------------

@app.command()
def run(
    job_file: Annotated[str, typer.Argument(help="Path to job JSON file")],
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Parse and validate only")] = False,
) -> None:
    """Run a product forge job."""
    try:
        JobConfig, _, _ = _import_models()
    except ImportError as exc:
        console.print(f"[red]Error:[/red] Cannot import models: {exc}")
        raise typer.Exit(1) from None

    job_path = Path(job_file)
    if not job_path.exists():
        console.print(f"[red]Error:[/red] Job file not found: {job_path}")
        raise typer.Exit(1)

    job = JobConfig.from_json_file(job_path)

    # Validate required fields
    errors: list[str] = []
    if not job.id:
        errors.append("Missing 'id'")
    if not job.commands.setup:
        errors.append("Missing 'commands.setup'")
    if not job.commands.test:
        errors.append("Missing 'commands.test'")
    if not job.task:
        errors.append("Missing 'task'")

    if errors:
        console.print("[red]Validation errors:[/red]")
        for err in errors:
            console.print(f"  - {err}")
        raise typer.Exit(1)

    if dry_run:
        console.print(Panel(
            f"[bold]ID:[/bold] {job.id}\n"
            f"[bold]Product:[/bold] {job.product_name}\n"
            f"[bold]Mode:[/bold] {job.mode}\n"
            f"[bold]Max loops:[/bold] {job.max_loops}\n"
            f"[bold]Time budget:[/bold] {job.time_budget_sec}s\n"
            f"[bold]Setup cmds:[/bold] {len(job.commands.setup)}\n"
            f"[bold]Test cmds:[/bold] {len(job.commands.test)}\n"
            f"[bold]Continuation:[/bold] {job.is_continuation}",
            title="Dry Run — Parsed Config",
            border_style="cyan",
        ))
        return

    # Attempt to run
    try:
        from forge.machine import ProductForge
        forge = ProductForge(job)
        forge.run()
    except ImportError:
        console.print(
            "[yellow]Warning:[/yellow] forge.machine module not available. "
            "Falling back to shell runner."
        )
        # Fall back to scripts/run-job.sh
        import subprocess
        harness_dir = Path(__file__).resolve().parent.parent
        cmd = ["bash", str(harness_dir / "scripts" / "run-job.sh"), str(job_path.resolve())]
        console.print(f"[dim]Running: {' '.join(cmd)}[/dim]")
        result = subprocess.run(cmd, cwd=str(harness_dir))
        if result.returncode != 0:
            console.print(f"[red]Job failed with exit code {result.returncode}[/red]")
            raise typer.Exit(result.returncode)


# ---------------------------------------------------------------------------
# forge status
# ---------------------------------------------------------------------------

@app.command()
def status(
    workspace: Annotated[str, typer.Argument(help="Workspace directory")] = "",
) -> None:
    """Show status of a workspace or list all workspaces."""
    workspaces_dir = Path("workspaces")

    if not workspace:
        # List all workspaces
        if not workspaces_dir.exists():
            console.print("[yellow]No workspaces/ directory found.[/yellow]")
            raise typer.Exit(0)

        table = Table(title="Workspaces")
        table.add_column("ID", style="bold")
        table.add_column("Product")
        table.add_column("Last State")
        table.add_column("Score")

        for ws_dir in sorted(workspaces_dir.iterdir()):
            if not ws_dir.is_dir():
                continue
            job_json = ws_dir / "job.json"
            product = ""
            last_state = ""
            score = ""
            if job_json.exists():
                try:
                    with open(job_json, encoding="utf-8") as f:
                        data = json.load(f)
                    product = data.get("product_name", "")
                    last_state = data.get("last_state", "")
                except (json.JSONDecodeError, OSError):
                    pass

            # Try to read latest score from ledger
            ledger_path = ws_dir / "EVALS" / "ledger.jsonl"
            if ledger_path.exists():
                try:
                    lines = ledger_path.read_text(encoding="utf-8").strip().splitlines()
                    if lines:
                        last_entry = json.loads(lines[-1])
                        score = last_entry.get("score_after", "")
                except (json.JSONDecodeError, OSError):
                    pass

            table.add_row(ws_dir.name, product, last_state, str(score))

        console.print(table)
        return

    # Detailed status for a specific workspace
    ws_path = Path(workspace)
    if not ws_path.exists():
        ws_path = workspaces_dir / workspace
    if not ws_path.exists():
        console.print(f"[red]Workspace not found:[/red] {workspace}")
        raise typer.Exit(1)

    # Read job.json
    job_json = ws_path / "job.json"
    job_data: dict[str, Any] = {}
    if job_json.exists():
        try:
            with open(job_json, encoding="utf-8") as f:
                job_data = json.load(f)
        except (json.JSONDecodeError, OSError):
            pass

    # Read FEATURES.md for feature status
    features_path = ws_path / "FEATURES.md"
    done_count = 0
    total_features = 0
    if features_path.exists():
        for line in features_path.read_text(encoding="utf-8").splitlines():
            if line.strip().startswith("| F-"):
                total_features += 1
                if "done" in line.lower():
                    done_count += 1

    # Read ledger
    ledger_path = ws_path / "EVALS" / "ledger.jsonl"
    entries: list[dict[str, Any]] = []
    if ledger_path.exists():
        try:
            for line in ledger_path.read_text(encoding="utf-8").strip().splitlines():
                if line.strip():
                    entries.append(json.loads(line))
        except (json.JSONDecodeError, OSError):
            pass

    keeps = sum(1 for e in entries if e.get("kept", False))
    discards = len(entries) - keeps
    latest_score = entries[-1].get("score_after", "0.0000") if entries else "0.0000"

    panel_content = (
        f"[bold]Product:[/bold] {job_data.get('product_name', 'unknown')}\n"
        f"[bold]Last State:[/bold] {job_data.get('last_state', 'unknown')}\n"
        f"[bold]Features:[/bold] {done_count}/{total_features} done\n"
        f"[bold]Loops:[/bold] {len(entries)} ({keeps} kept, {discards} discarded)\n"
        f"[bold]Score:[/bold] {latest_score}\n"
        f"[bold]Keep Rate:[/bold] {keeps / len(entries):.4f}" if entries else ""
    )
    console.print(Panel(panel_content, title=f"Workspace: {ws_path.name}", border_style="blue"))

    # Show last 5 ledger entries
    if entries:
        table = Table(title="Recent Ledger Entries")
        table.add_column("Loop", justify="right")
        table.add_column("Verdict")
        table.add_column("Before")
        table.add_column("After")
        table.add_column("Hypothesis")

        for entry in entries[-5:]:
            verdict_style = "green" if entry.get("kept") else "red"
            table.add_row(
                str(entry.get("loop", "?")),
                f"[{verdict_style}]{entry.get('verdict', '?')}[/{verdict_style}]",
                str(entry.get("score_before", "")),
                str(entry.get("score_after", "")),
                str(entry.get("hypothesis", ""))[:60],
            )
        console.print(table)


# ---------------------------------------------------------------------------
# forge score
# ---------------------------------------------------------------------------

@app.command()
def score(
    workspace: Annotated[str, typer.Argument(help="Workspace directory to score")],
) -> None:
    """Compute and display the composite score for a workspace."""
    ws_path = Path(workspace)
    if not ws_path.exists():
        ws_path = Path("workspaces") / workspace
    if not ws_path.exists():
        console.print(f"[red]Workspace not found:[/red] {workspace}")
        raise typer.Exit(1)

    # Try to use the scorer module
    try:
        from forge.scorer import compute_composite_score, compute_score_breakdown
        breakdown = compute_score_breakdown(ws_path)

        table = Table(title=f"Score Breakdown: {ws_path.name}")
        table.add_column("Component", style="bold")
        table.add_column("Weight", justify="right")
        table.add_column("Raw Score", justify="right")
        table.add_column("Weighted", justify="right")

        for name, detail in breakdown["components"].items():
            table.add_row(
                name,
                f"{detail['weight']:.2f}",
                f"{detail['raw']:.4f}",
                f"{detail['weighted']:.4f}",
            )

        table.add_section()
        table.add_row(
            "[bold]TOTAL[/bold]",
            "",
            "",
            f"[bold]{breakdown['composite']:.4f}[/bold]",
        )
        console.print(table)
        return
    except (ImportError, AttributeError):
        pass

    # Fallback: read latest score from ledger
    ledger_path = ws_path / "EVALS" / "ledger.jsonl"
    if not ledger_path.exists():
        console.print(f"[yellow]No ledger found in {ws_path}[/yellow]")
        raise typer.Exit(1)

    lines = ledger_path.read_text(encoding="utf-8").strip().splitlines()
    if not lines:
        console.print("[yellow]Ledger is empty.[/yellow]")
        raise typer.Exit(1)

    last_entry = json.loads(lines[-1])
    console.print(Panel(
        f"[bold]Latest score:[/bold] {last_entry.get('score_after', '?')}\n"
        f"[bold]Loop:[/bold] {last_entry.get('loop', '?')}\n"
        f"[bold]Verdict:[/bold] {last_entry.get('verdict', '?')}\n\n"
        "[dim]Install forge.scorer for full breakdown.[/dim]",
        title=f"Score: {ws_path.name}",
        border_style="yellow",
    ))


# ---------------------------------------------------------------------------
# forge continue
# ---------------------------------------------------------------------------

@app.command(name="continue")
def continue_job(
    source_id: Annotated[str, typer.Argument(help="Source workspace ID to extend")],
    features: Annotated[str, typer.Option("--features", help="New features (comma-separated)")] = "",
    output: Annotated[str, typer.Option("--output", "-o", help="Output JSON path")] = "",
) -> None:
    """Generate a continuation job from an existing workspace."""
    try:
        JobConfig, _, _ = _import_models()
    except ImportError as exc:
        console.print(f"[red]Error:[/red] Cannot import models: {exc}")
        raise typer.Exit(1) from None

    # Find source workspace
    source_path = Path("workspaces") / source_id
    if not source_path.exists():
        console.print(f"[red]Source workspace not found:[/red] {source_id}")
        raise typer.Exit(1)

    # Read source job.json
    source_job_path = source_path / "job.json"
    if not source_job_path.exists():
        console.print(f"[red]No job.json in source workspace:[/red] {source_id}")
        raise typer.Exit(1)

    source_job = JobConfig.from_json_file(source_job_path)

    # Generate continuation job ID
    slug = source_job.id.rsplit("-", 1)[0] if "-" in source_job.id else source_job.id
    examples_dir = Path("examples")
    examples_dir.mkdir(exist_ok=True)

    # Find next available ID
    counter = 1
    while True:
        candidate = f"{slug}-{counter:03d}"
        if not (examples_dir / f"{candidate}.json").exists():
            break
        counter += 1

    # Build continuation job
    new_job = JobConfig(
        id=candidate,
        repo=source_job.repo,
        base_ref=source_job.base_ref,
        work_branch=f"forge/{candidate}",
        task=source_job.task,
        time_budget_sec=source_job.time_budget_sec,
        mode="product",
        product_name=source_job.product_name,
        max_loops=source_job.max_loops,
        create_repo=False,
        continue_from=source_id,
        new_features=features,
        commands=source_job.commands,
        program_md=source_job.program_md,
    )

    # Write output
    if not output:
        output = str(examples_dir / f"{candidate}.json")

    out_path = Path(output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    new_job.to_json_file(out_path)

    console.print(Panel(
        f"[bold]ID:[/bold] {candidate}\n"
        f"[bold]Continues:[/bold] {source_id}\n"
        f"[bold]Product:[/bold] {new_job.product_name}\n"
        f"[bold]New features:[/bold] {features or '(none specified)'}\n"
        f"[bold]Output:[/bold] {out_path}",
        title="Continuation Job Created",
        border_style="green",
    ))


# ---------------------------------------------------------------------------
# forge compare
# ---------------------------------------------------------------------------

@app.command()
def compare(
    workspaces: Annotated[list[str], typer.Argument(help="Workspace directories to compare")],
) -> None:
    """Compare metrics across workspace runs."""
    if len(workspaces) < 2:
        console.print("[red]Error:[/red] Need at least 2 workspaces to compare.")
        raise typer.Exit(1)

    table = Table(title="Workspace Comparison")
    table.add_column("Metric", style="bold")
    for ws in workspaces:
        table.add_column(Path(ws).name, justify="right")

    # Collect metrics for each workspace
    all_metrics: list[dict[str, Any]] = []
    for ws in workspaces:
        ws_path = Path(ws)
        if not ws_path.exists():
            ws_path = Path("workspaces") / ws
        if not ws_path.exists():
            console.print(f"[yellow]Warning:[/yellow] Workspace not found: {ws}")
            all_metrics.append({})
            continue

        ledger_path = ws_path / "EVALS" / "ledger.jsonl"
        if not ledger_path.exists():
            all_metrics.append({})
            continue

        entries: list[dict[str, Any]] = []
        try:
            for line in ledger_path.read_text(encoding="utf-8").strip().splitlines():
                if line.strip():
                    entries.append(json.loads(line))
        except (json.JSONDecodeError, OSError):
            all_metrics.append({})
            continue

        keeps = sum(1 for e in entries if e.get("kept", False))
        total = len(entries)
        latest_score = entries[-1].get("score_after", "0.0000") if entries else "0.0000"
        wall_total = sum(e.get("wall_seconds", 0) for e in entries)

        all_metrics.append({
            "Total loops": str(total),
            "Keeps": str(keeps),
            "Discards": str(total - keeps),
            "Keep rate": f"{keeps / total:.4f}" if total > 0 else "N/A",
            "Final score": str(latest_score),
            "Total wall (s)": str(wall_total),
        })

    # Render rows
    if not all_metrics or all(not m for m in all_metrics):
        console.print("[yellow]No metrics found in any workspace.[/yellow]")
        raise typer.Exit(0)

    # Collect all metric keys
    all_keys: list[str] = []
    for m in all_metrics:
        for k in m:
            if k not in all_keys:
                all_keys.append(k)

    for key in all_keys:
        row = [key] + [m.get(key, "N/A") for m in all_metrics]
        table.add_row(*row)

    console.print(table)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app()
