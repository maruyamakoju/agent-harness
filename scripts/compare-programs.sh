#!/usr/bin/env bash
# =============================================================================
# compare-programs.sh — Compare program.md variants from experiment ledgers
#
# Reads ledger.jsonl files from completed experiments and computes comparison
# metrics to determine which program.md variant produces the best results.
#
# Usage:
#   bash scripts/compare-programs.sh <workspace1> [<workspace2> ...]
#   bash scripts/compare-programs.sh logs/soak-cli-001 logs/soak-fastapi-001
#   bash scripts/compare-programs.sh workspaces/*/
#
# Each workspace must contain EVALS/ledger.jsonl (and optionally PROGRAM.md).
#
# Metrics computed per experiment:
#   loops_to_target        — loops until target_score reached (∞ if never)
#   time_to_target         — wall seconds until target_score reached
#   keep_rate              — fraction of loops that were kept
#   discard_recovery_rate  — fraction of discards followed by a keep
#   mean_score_delta       — average score improvement per keep
#   feature_rate_per_hour  — features completed per wall-clock hour
# =============================================================================
set -euo pipefail

PATH="$HOME/bin:$PATH"

if [[ $# -lt 1 ]]; then
    echo "Usage: compare-programs.sh <workspace1> [<workspace2> ...]"
    echo ""
    echo "Each workspace must contain EVALS/ledger.jsonl."
    echo "Optionally includes PROGRAM.md for variant labeling."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: compute metrics for a single ledger
# ---------------------------------------------------------------------------
compute_metrics() {
    local ws="$1"
    local ledger="$ws/EVALS/ledger.jsonl"
    local program="$ws/PROGRAM.md"
    local label=""

    if [[ ! -f "$ledger" ]]; then
        echo "[SKIP] No ledger found: $ledger" >&2
        return 1
    fi

    # Label from workspace path or PROGRAM.md
    label=$(basename "$ws")
    if [[ -f "$program" ]]; then
        local product_line
        product_line=$(grep -m1 '## Product:' "$program" 2>/dev/null | sed 's/## Product: //' || echo "")
        [[ -n "$product_line" ]] && label="$label ($product_line)"
    fi

    local total_loops kept_count discard_count
    total_loops=$(wc -l < "$ledger" | tr -d ' ')
    kept_count=$(jq -s '[.[] | select(.kept == true)] | length' "$ledger" 2>/dev/null || echo 0)
    discard_count=$(jq -s '[.[] | select(.kept == false)] | length' "$ledger" 2>/dev/null || echo 0)

    # Keep rate
    local keep_rate="0.0000"
    if [[ "$total_loops" -gt 0 ]]; then
        keep_rate=$(awk "BEGIN { printf \"%.4f\", $kept_count / $total_loops }")
    fi

    # Loops to target (first loop where verdict contains "target" or kept and score >= target)
    local loops_to_target="∞"
    local time_to_target="∞"
    local target_line
    target_line=$(jq -s 'to_entries[] | select(.value.verdict == "keep" or (.value.verdict | test("target";"i"))) | .key + 1' "$ledger" 2>/dev/null | tail -1 || echo "")
    # Check for target_score_reached in final verdict
    local final_verdict
    final_verdict=$(jq -s '.[-1].verdict // ""' "$ledger" 2>/dev/null | tr -d '"' || echo "")
    if [[ "$final_verdict" == *"target"* ]]; then
        loops_to_target="$total_loops"
        time_to_target=$(jq -s '[.[].wall_seconds] | add' "$ledger" 2>/dev/null || echo "0")
    elif [[ -n "$target_line" ]]; then
        loops_to_target="$target_line"
        time_to_target=$(jq -s "[.[:$target_line] | .[].wall_seconds] | add" "$ledger" 2>/dev/null || echo "0")
    fi

    # Mean score delta per keep
    local mean_score_delta="0.0000"
    if [[ "$kept_count" -gt 0 ]]; then
        local raw_delta
        raw_delta=$(jq -s '
            [.[] | select(.kept == true) |
                ((.score_after | tonumber) - (.score_before | tonumber))] |
            add / length
        ' "$ledger" 2>/dev/null || echo "0")
        mean_score_delta=$(awk "BEGIN { printf \"%.4f\", $raw_delta }")
    fi

    # Discard recovery rate: fraction of discards followed by a keep
    local discard_recovery_rate="N/A"
    if [[ "$discard_count" -gt 0 ]]; then
        discard_recovery_rate=$(jq -s '
            [range(length - 1) as $i |
                select(.[$i].kept == false and .[$i + 1].kept == true)] |
            length
        ' "$ledger" 2>/dev/null || echo 0)
        discard_recovery_rate=$(awk "BEGIN { printf \"%.4f\", $discard_recovery_rate / $discard_count }")
    fi

    # Total wall time
    local total_wall_seconds
    total_wall_seconds=$(jq -s '[.[].wall_seconds] | add // 0' "$ledger" 2>/dev/null || echo 0)

    # Feature completion rate per hour (based on score progression)
    local feature_rate="N/A"
    if [[ "$total_wall_seconds" -gt 0 && "$kept_count" -gt 0 ]]; then
        # Approximate: each keep = ~1 feature completed
        feature_rate=$(awk "BEGIN { printf \"%.2f\", ($kept_count / $total_wall_seconds) * 3600 }")
    fi

    # Score progression
    local first_score last_score
    first_score=$(jq -s '.[0].score_before // "0"' "$ledger" 2>/dev/null | tr -d '"')
    last_score=$(jq -s '.[-1].score_after // "0"' "$ledger" 2>/dev/null | tr -d '"')

    # Output as pipe-delimited row
    printf "| %-30s | %3s | %5s | %8s | %6s | %10s | %10s | %12s | %7s | %s → %s |\n" \
        "$label" \
        "$total_loops" \
        "$kept_count" \
        "$keep_rate" \
        "$loops_to_target" \
        "$time_to_target" \
        "$mean_score_delta" \
        "$discard_recovery_rate" \
        "$feature_rate" \
        "$first_score" "$last_score"
}

# ---------------------------------------------------------------------------
# Main: iterate workspaces and print comparison table
# ---------------------------------------------------------------------------
echo ""
echo "# Program Variant Comparison"
echo ""
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# Table header
printf "| %-30s | %3s | %5s | %8s | %6s | %10s | %10s | %12s | %7s | %s |\n" \
    "Experiment" "Lps" "Keeps" "KeepRate" "L→Tgt" "T→Tgt(s)" "ΔScore/Kp" "DiscRecovery" "Feat/hr" "Score Range"
printf "|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|\n" \
    "$(printf '%.0s-' {1..32})" \
    "$(printf '%.0s-' {1..5})" \
    "$(printf '%.0s-' {1..7})" \
    "$(printf '%.0s-' {1..10})" \
    "$(printf '%.0s-' {1..8})" \
    "$(printf '%.0s-' {1..12})" \
    "$(printf '%.0s-' {1..12})" \
    "$(printf '%.0s-' {1..14})" \
    "$(printf '%.0s-' {1..9})" \
    "$(printf '%.0s-' {1..20})"

EXPERIMENT_COUNT=0
SKIP_COUNT=0

for ws in "$@"; do
    # Strip trailing slash
    ws="${ws%/}"

    # Support both workspace dirs and log dirs
    if [[ -f "$ws/EVALS/ledger.jsonl" ]]; then
        compute_metrics "$ws" || { SKIP_COUNT=$((SKIP_COUNT + 1)); continue; }
        EXPERIMENT_COUNT=$((EXPERIMENT_COUNT + 1))
    else
        echo "[SKIP] No ledger: $ws" >&2
        SKIP_COUNT=$((SKIP_COUNT + 1))
    fi
done

echo ""
echo "Experiments compared: $EXPERIMENT_COUNT (skipped: $SKIP_COUNT)"

# If we have 2+ experiments, add winner summary
if [[ $EXPERIMENT_COUNT -ge 2 ]]; then
    echo ""
    echo "## Key Observations"
    echo ""
    echo "Compare keep_rate (higher = more efficient mutations), loops_to_target"
    echo "(lower = faster convergence), and discard_recovery_rate (higher = better"
    echo "learning from failures). These metrics reveal which program.md variant"
    echo "produces the most efficient arena behavior."
fi

echo ""
