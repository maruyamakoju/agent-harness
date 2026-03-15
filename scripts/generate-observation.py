#!/usr/bin/env python3
"""
generate-observation.py
Auto-generate arena observation report from ledger.jsonl + job JSON + workspace.

Usage:
  python scripts/generate-observation.py <job-id>
  python scripts/generate-observation.py costctl-003
  python scripts/generate-observation.py costctl-003 --out logs/costctl-003-observation.md
"""

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


HARNESS_DIR = Path(__file__).parent.parent


def load_ledger(workspace: Path) -> list[dict]:
    ledger_path = workspace / "EVALS" / "ledger.jsonl"
    if not ledger_path.exists():
        return []
    entries = []
    for line in ledger_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            entries.append(json.loads(line))
    return entries


def load_features(workspace: Path) -> list[dict]:
    features_path = workspace / "FEATURES.md"
    if not features_path.exists():
        return []
    features = []
    for line in features_path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\|\s*(F-\d+)\s*\|([^|]+)\|([^|]+)\|", line)
        if m:
            fid = m.group(1).strip()
            name = m.group(2).strip()
            status = m.group(3).strip()
            features.append({"id": fid, "name": name, "status": status})
    return features


def load_job(job_id: str) -> dict:
    examples_dir = HARNESS_DIR / "examples"
    job_path = examples_dir / f"{job_id}.json"
    if not job_path.exists():
        return {}
    return json.loads(job_path.read_text(encoding="utf-8"))


def verdict_emoji(verdict: str) -> str:
    return {
        "keep": "✓ keep",
        "discard_audit": "✗ discard_audit",
        "discard_regression": "✗ discard_regression",
        "discard_plateau": "✗ discard_plateau",
    }.get(verdict, verdict)


def stop_reason(job: dict, entries: list[dict]) -> str:
    if not entries:
        return "unknown"
    last = entries[-1]
    score_final = float(last["score_after"] if last["kept"] else last["score_before"])

    # target_score_reached
    if score_final >= 1.0:
        return f"target_score_reached (1.0000) at loop {last['loop']}"

    # consecutive_discard_stop
    tail = entries[-3:]
    if len(tail) >= 3 and all(not e["kept"] for e in tail):
        max_d = job.get("program_md", "")
        m = re.search(r"max_discards_in_a_row:\s*(\d+)", max_d)
        cap = m.group(1) if m else "3"
        return f"consecutive_discard_stop ({cap}/{cap}) at loop {last['loop']}"

    # plateau_stop
    tail2 = entries[-3:]
    if len(tail2) >= 2 and all(not e["kept"] for e in tail2[-2:]):
        return f"plateau_stop at loop {last['loop']}"

    # max_loops
    max_loops = job.get("max_loops", 12)
    if last["loop"] >= max_loops:
        return f"max_loops_reached ({max_loops}/{max_loops})"

    return f"stopped at loop {last['loop']}"


def compute_metrics(entries: list[dict]) -> dict:
    keeps = [e for e in entries if e["kept"]]
    discards = [e for e in entries if not e["kept"]]
    discard_audits = [e for e in discards if e["verdict"] == "discard_audit"]
    discard_regressions = [e for e in discards if e["verdict"] == "discard_regression"]

    total_seconds = sum(e.get("wall_seconds", 0) for e in entries)

    # DiscrRecovery: fraction of discard_audit loops that were followed by a keep
    recoveries = 0
    for i, e in enumerate(entries):
        if not e["kept"] and i + 1 < len(entries) and entries[i + 1]["kept"]:
            recoveries += 1
    disc_recovery = recoveries / len(discards) if discards else None

    score_start = float(entries[0]["score_before"]) if entries else 0.0
    score_end = float(entries[-1]["score_after"] if entries[-1]["kept"] else entries[-1]["score_before"])

    return {
        "loops": len(entries),
        "keeps": len(keeps),
        "discards": len(discards),
        "discard_audits": len(discard_audits),
        "discard_regressions": len(discard_regressions),
        "keep_rate": len(keeps) / len(entries) if entries else 0,
        "disc_recovery": disc_recovery,
        "total_seconds": total_seconds,
        "score_start": score_start,
        "score_end": score_end,
    }


def generate_report(job_id: str) -> str:
    workspace = HARNESS_DIR / "workspaces" / job_id
    if not workspace.exists():
        sys.exit(f"Workspace not found: {workspace}")

    job = load_job(job_id)
    entries = load_ledger(workspace)
    features = load_features(workspace)

    if not entries:
        sys.exit(f"No ledger entries found in {workspace}/EVALS/ledger.jsonl")

    m = compute_metrics(entries)
    stop = stop_reason(job, entries)
    product_name = job.get("product_name", job_id)
    duration_min = m["total_seconds"] // 60
    diff_lines = re.search(r"Max diff lines per loop:\s*(\d+)", job.get("program_md", ""))
    diff_cap = diff_lines.group(1) if diff_lines else "150"

    # header
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [
        f"# {job_id} Observation Report",
        f"## Experiment: {product_name}",
        f"## Date: {now}",
        f"## Profile: Production (files=3/2, diff={diff_cap}, discards=3, ledger-read first)",
        f"## Duration: {m['total_seconds']}s (~{duration_min} min)",
        "",
        "---",
        "",
        "## Results Summary",
        "",
        "| Loop | Verdict | Score | Hypothesis (truncated) |",
        "|------|---------|-------|------------------------|",
    ]

    for e in entries:
        score_str = f"{float(e['score_before']):.4f}→{float(e['score_after']):.4f}"
        hyp = e.get("hypothesis", "")
        # strip "Last verdict: X | Response: " prefix for brevity
        hyp_short = re.sub(r"^Last verdict:[^|]+\|\s*Response:\s*", "", hyp)
        hyp_short = hyp_short[:70].replace("|", "/").replace("\n", " ").strip()
        lines.append(f"| {e['loop']} | {verdict_emoji(e['verdict'])} | {score_str} | {hyp_short}... |")

    lines += [
        "",
        f"Stop: `{stop}`.",
        f"Final score: {m['score_end']:.4f}",
        "",
        "---",
        "",
        "## Metrics",
        "",
        f"| Metric | Value |",
        f"|--------|-------|",
        f"| Loops | {m['loops']} |",
        f"| KEEPs | {m['keeps']} ({m['keep_rate']:.4f}) |",
        f"| Discards | {m['discards']} ({m['discard_audits']} audit, {m['discard_regressions']} regression) |",
    ]
    if m["disc_recovery"] is not None:
        lines.append(f"| DiscrRecovery | {m['disc_recovery']:.4f} |")
    lines += [
        f"| Duration | {m['total_seconds']}s |",
        f"| Score range | {m['score_start']:.4f}→{m['score_end']:.4f} |",
        "",
        "---",
        "",
        "## Feature Status",
        "",
        "| ID | Feature | Status |",
        "|----|---------|--------|",
    ]
    for f in features:
        lines.append(f"| {f['id']} | {f['name'][:60]} | {f['status']} |")

    # Done features count
    done = [f for f in features if f["status"] == "done"]
    total = len(features)
    lines += [
        "",
        f"**{len(done)}/{total} features done.**",
        "",
        "---",
        "",
        "## Loop Detail",
        "",
    ]
    for e in entries:
        verdict = e["verdict"]
        kept_str = "KEEP" if e["kept"] else "DISCARD"
        delta = float(e["score_after"]) - float(e["score_before"])
        delta_str = f"+{delta:.4f}" if delta >= 0 else f"{delta:.4f}"
        hyp = e.get("hypothesis", "")
        hyp_clean = re.sub(r"\\_\\_", "__", hyp)
        files = e.get("files_touched", "")
        lines += [
            f"### Loop {e['loop']} — {kept_str} ({verdict})",
            f"- Score: {float(e['score_before']):.4f} → {float(e['score_after']):.4f} ({delta_str})",
            f"- Files: `{files}`" if files else "- Files: (rolled back / none)",
            f"- Wall: {e.get('wall_seconds', 0)}s",
            f"- Hypothesis: {hyp_clean[:200]}",
            "",
        ]

    # Arena verdict table
    criteria = [
        ("5+ loops stable forward progress", m["keeps"] >= 5),
        ("All discards recovered", m["disc_recovery"] == 1.0 if m["disc_recovery"] is not None else None),
        ("Target score reached", m["score_end"] >= 1.0),
        ("Human-legible hypothesis→verdict chain", True),
    ]
    lines += [
        "---",
        "",
        "## Arena Verdict",
        "",
        "| Criterion | Result |",
        "|-----------|--------|",
    ]
    for label, result in criteria:
        if result is True:
            icon = "✓"
        elif result is False:
            icon = "✗"
        else:
            icon = "—"
        lines.append(f"| {label} | {icon} |")

    lines += [
        "",
        f"**Workspace**: `workspaces/{job_id}/`",
        "",
        "*Auto-generated by scripts/generate-observation.py*",
    ]

    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate arena observation report")
    parser.add_argument("job_id", help="Job ID (e.g. costctl-003)")
    parser.add_argument("--out", "-o", help="Output path (default: logs/<job-id>-observation.md)")
    args = parser.parse_args()

    report = generate_report(args.job_id)

    out_path = Path(args.out) if args.out else HARNESS_DIR / "logs" / f"{args.job_id}-observation.md"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(report, encoding="utf-8")
    print(f"Report written → {out_path}")


if __name__ == "__main__":
    main()
