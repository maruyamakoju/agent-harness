#!/usr/bin/env python3
"""
import-anthropic-usage.py
Convert Anthropic Console usage export to costctl CSV format.

Usage:
  python scripts/import-anthropic-usage.py input.csv [--out costctl-usage.csv]
  python scripts/import-anthropic-usage.py --from-jobs    # estimate from arena job logs

Anthropic Console export format (console.anthropic.com → Settings → Usage → Export):
  date,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens
  2026-03-15,claude-sonnet-4-6,125000,32000,0,0

Outputs costctl CSV format:
  provider,model,project,input_tokens,output_tokens,cost_usd,timestamp
"""

import argparse
import csv
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# Anthropic pricing (USD per 1M tokens) as of early 2026
# Update these if pricing changes
PRICING = {
    "claude-opus-4-6":             {"input": 15.00, "output": 75.00},
    "claude-sonnet-4-6":           {"input":  3.00, "output": 15.00},
    "claude-haiku-4-5-20251001":   {"input":  0.80, "output":  4.00},
    "claude-haiku-4-5":            {"input":  0.80, "output":  4.00},
    # fallback for unknown models
    "_default":                    {"input":  3.00, "output": 15.00},
}


def compute_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    pricing = PRICING.get(model, PRICING["_default"])
    return (input_tokens * pricing["input"] + output_tokens * pricing["output"]) / 1_000_000


def from_anthropic_console(input_path: Path, project: str) -> list[dict]:
    """
    Convert Anthropic Console CSV export to costctl rows.
    Console format: date,model,input_tokens,output_tokens,[cache cols...]
    One row per (date, model) aggregate — we emit one costctl row per aggregate.
    """
    rows = []
    with open(input_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for i, row in enumerate(reader):
            # Normalize column names (console may vary)
            date = row.get("date") or row.get("Date") or row.get("timestamp", "")
            model = (row.get("model") or row.get("Model") or "").strip().lower()
            try:
                input_tokens = int(row.get("input_tokens") or row.get("Input Tokens") or 0)
                output_tokens = int(row.get("output_tokens") or row.get("Output Tokens") or 0)
            except ValueError:
                print(f"  [SKIP] row {i+1}: invalid token counts", file=sys.stderr)
                continue

            if not date or not model:
                print(f"  [SKIP] row {i+1}: missing date or model", file=sys.stderr)
                continue

            # Parse date → ISO8601 timestamp (noon UTC for daily aggregates)
            try:
                dt = datetime.fromisoformat(date.replace("Z", "+00:00"))
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                # If date-only, use noon UTC
                if len(date) <= 10:
                    dt = dt.replace(hour=12, minute=0, second=0)
            except ValueError:
                print(f"  [SKIP] row {i+1}: unparseable date '{date}'", file=sys.stderr)
                continue

            cost = compute_cost(model, input_tokens, output_tokens)
            rows.append({
                "provider": "anthropic",
                "model": model,
                "project": project,
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "cost_usd": f"{cost:.6f}",
                "timestamp": dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            })
    return rows


def from_arena_jobs(harness_dir: Path, project: str) -> list[dict]:
    """
    Estimate usage from arena job JSONs + ledger files.
    Uses known model (claude-sonnet-4-6) and rough per-loop token estimates.
    Loops: each CODE invocation ≈ 50k input + 8k output tokens for sonnet.
    SCAFFOLD: ≈ 20k input + 4k output. PLAN: ≈ 15k input + 3k output.
    """
    # Per-loop token estimates (conservative)
    LOOP_INPUT  = 50_000
    LOOP_OUTPUT =  8_000
    SCAFFOLD_INPUT  = 20_000
    SCAFFOLD_OUTPUT =  4_000

    rows = []
    examples_dir = harness_dir / "examples"
    workspaces_dir = harness_dir / "workspaces"

    for job_file in sorted(examples_dir.glob("*.json")):
        try:
            job = json.loads(job_file.read_text(encoding="utf-8"))
        except Exception:
            continue

        job_id = job.get("id", "")
        loop_count = job.get("loop_count", 0)
        last_ts = job.get("last_state_ts")
        if not last_ts or loop_count == 0:
            continue

        try:
            end_dt = datetime.fromisoformat(last_ts.replace("Z", "+00:00"))
        except ValueError:
            continue

        model = "claude-sonnet-4-6"

        # SCAFFOLD row
        scaffold_cost = compute_cost(model, SCAFFOLD_INPUT, SCAFFOLD_OUTPUT)
        rows.append({
            "provider": "anthropic",
            "model": model,
            "project": project,
            "input_tokens": SCAFFOLD_INPUT,
            "output_tokens": SCAFFOLD_OUTPUT,
            "cost_usd": f"{scaffold_cost:.6f}",
            "timestamp": end_dt.strftime("%Y-%m-%dT00:30:00Z"),
        })

        # Per-loop rows (back-calculate timing from end timestamp and duration)
        duration = job.get("last_state_ts")  # we don't have per-loop timestamps
        for loop_i in range(1, loop_count + 1):
            # Spread loops across the day: use end_dt as anchor
            loop_cost = compute_cost(model, LOOP_INPUT, LOOP_OUTPUT)
            # Use job end date with sequential minute offsets
            ts = end_dt.replace(hour=1, minute=loop_i % 60, second=0)
            rows.append({
                "provider": "anthropic",
                "model": model,
                "project": project,
                "input_tokens": LOOP_INPUT,
                "output_tokens": LOOP_OUTPUT,
                "cost_usd": f"{loop_cost:.6f}",
                "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
            })

        print(f"  {job_id}: {loop_count} loops → {loop_count + 1} rows", file=sys.stderr)

    return rows


def write_csv(rows: list[dict], out_path: Path | None) -> None:
    fieldnames = ["provider", "model", "project", "input_tokens", "output_tokens", "cost_usd", "timestamp"]
    if out_path:
        with open(out_path, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames)
            w.writeheader()
            w.writerows(rows)
        print(f"Written {len(rows)} rows → {out_path}")
    else:
        w = csv.DictWriter(sys.stdout, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert Anthropic usage data to costctl CSV")
    parser.add_argument("input", nargs="?", help="Anthropic Console CSV export file")
    parser.add_argument("--out", "-o", help="Output CSV path (default: stdout)")
    parser.add_argument("--project", default="agent-harness", help="Project name (default: agent-harness)")
    parser.add_argument("--from-jobs", action="store_true",
                        help="Estimate usage from arena job JSONs (no input file needed)")
    parser.add_argument("--harness-dir", default=".",
                        help="Harness root dir for --from-jobs (default: current dir)")
    args = parser.parse_args()

    out_path = Path(args.out) if args.out else None

    if args.from_jobs:
        harness_dir = Path(args.harness_dir)
        print(f"Estimating usage from arena jobs in {harness_dir}/examples/ ...", file=sys.stderr)
        rows = from_arena_jobs(harness_dir, args.project)
    elif args.input:
        input_path = Path(args.input)
        print(f"Converting {input_path} ...", file=sys.stderr)
        rows = from_anthropic_console(input_path, args.project)
    else:
        parser.print_help()
        sys.exit(1)

    print(f"Total rows: {len(rows)}", file=sys.stderr)
    write_csv(rows, out_path)


if __name__ == "__main__":
    main()
