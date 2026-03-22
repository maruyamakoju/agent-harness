#!/usr/bin/env bash
# =============================================================================
# run-evals.sh - Evaluation runner for Product Mode
# Runs configured evaluation suites and writes results to EVALS/ directory.
# Usage: run-evals.sh <workspace-path> [--type <eval-type>] [--score]
# =============================================================================
set -euo pipefail

WORKSPACE="${1:-}"
EVAL_TYPE="all"  # unit, e2e, lint, typecheck, security-scan, perf-benchmark, all
SCORE_MODE=false

if [[ -z "$WORKSPACE" || ! -d "$WORKSPACE" ]]; then
    echo "Usage: run-evals.sh <workspace-path> [--type <eval-type>] [--score]"
    echo "Types: unit, e2e, lint, typecheck, security-scan, perf-benchmark, all"
    echo "Flags: --score  Output composite weighted score (0.0-1.0) only"
    exit 1
fi

# Parse optional flags
shift  # consume workspace arg
while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) EVAL_TYPE="${2:-all}"; shift 2 ;;
        --score) SCORE_MODE=true; shift ;;
        *) shift ;;
    esac
done

EVALS_DIR="$WORKSPACE/EVALS"
mkdir -p "$EVALS_DIR"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TS_SLUG=$(date -u +%Y%m%d-%H%M%S)

cd "$WORKSPACE"

# ---------------------------------------------------------------------------
# Helper: write eval result JSON
# ---------------------------------------------------------------------------
write_eval_result() {
    local etype="$1"
    local passed="$2"
    local summary="$3"
    local duration="${4:-0}"
    local details="$5"
    [[ -z "$details" ]] && details='{}'

    # Sanitize: ensure duration is numeric
    [[ "$duration" =~ ^[0-9]+$ ]] || duration=0

    # Sanitize: ensure passed is valid JSON boolean
    [[ "$passed" == "true" ]] && passed=true || passed=false

    local result_file="${EVALS_DIR}/${etype}-${TS_SLUG}.json"
    # Strip control characters and escape quotes for valid JSON string
    local clean_summary
    clean_summary=$(echo "$summary" | tr -d '\000-\010\013-\037' | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | tr '\n' ' ')
    cat > "$result_file" <<EVALEOF
{"type":"${etype}","timestamp":"${TIMESTAMP}","pass":${passed},"summary":"${clean_summary}","details":${details},"duration_sec":${duration}}
EVALEOF
    echo "[eval] Wrote: $result_file"
}

# ---------------------------------------------------------------------------
# Eval: Unit Tests
# ---------------------------------------------------------------------------
run_unit_tests() {
    echo "[eval] Running unit tests..."
    local start_time
    start_time=$(date +%s)
    local output="" exit_code=0

    local cov_pct=""

    if [[ -f "package.json" ]] && grep -q '"test"' package.json 2>/dev/null; then
        output=$(npm test 2>&1 | tail -50) || exit_code=$?
    elif [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]] || [[ -f "pytest.ini" ]]; then
        # Try with --cov for actual coverage measurement; fall back to plain pytest
        local cov_target="."
        [[ -d "src" ]] && cov_target="src"
        if python -m pytest --co -q --cov="$cov_target" > /dev/null 2>&1; then
            output=$(python -m pytest --tb=short -q --cov="$cov_target" --cov-report=term 2>&1 | tail -80) || exit_code=$?
            # Parse coverage percentage from "TOTAL ... NN%" line
            cov_pct=$(echo "$output" | grep -E '^TOTAL\s' | grep -oE '[0-9]+%' | tr -d '%' || true)
        else
            echo "[eval] pytest-cov not available, running without coverage"
            output=$(python -m pytest --tb=short -q 2>&1 | tail -50) || exit_code=$?
        fi
    elif [[ -f "Cargo.toml" ]]; then
        output=$(cargo test 2>&1 | tail -50) || exit_code=$?
    elif [[ -f "go.mod" ]]; then
        output=$(go test ./... 2>&1 | tail -50) || exit_code=$?
    else
        echo "[eval] No test framework detected, skipping unit tests"
        return
    fi

    local duration=$(( $(date +%s) - start_time ))
    local passed=true
    [[ $exit_code -ne 0 ]] && passed=false

    local summary
    summary=$(echo "$output" | tail -5 | tr '\n' ' ' | head -c 200)

    # Build details JSON with optional coverage_pct
    local details_json
    if [[ -n "$cov_pct" && "$cov_pct" =~ ^[0-9]+$ ]]; then
        details_json="{\"exit_code\": $exit_code, \"coverage_pct\": $cov_pct}"
        echo "[eval] Coverage measured: ${cov_pct}%"
    else
        details_json="{\"exit_code\": $exit_code}"
    fi

    write_eval_result "unit" "$passed" "$summary" "$duration" "$details_json"
}

# ---------------------------------------------------------------------------
# Eval: Lint
# ---------------------------------------------------------------------------
run_lint() {
    echo "[eval] Running lint..."
    local start_time
    start_time=$(date +%s)
    local output="" exit_code=0

    if python -m ruff --version &>/dev/null && [[ -f "pyproject.toml" || -f "setup.py" ]]; then
        output=$(python -m ruff check . 2>&1 | tail -30) || exit_code=$?
    elif [[ -f "package.json" ]] && grep -q '"lint"' package.json 2>/dev/null; then
        output=$(npm run lint 2>&1 | tail -30) || exit_code=$?
    elif command -v eslint &>/dev/null && [[ -f "package.json" ]]; then
        output=$(eslint . 2>&1 | tail -30) || exit_code=$?
    elif command -v shellcheck &>/dev/null; then
        output=$(find . -name "*.sh" -exec shellcheck --severity=error {} + 2>&1 | tail -30) || exit_code=$?
    else
        echo "[eval] No linter detected, skipping"
        return
    fi

    local duration=$(( $(date +%s) - start_time ))
    local passed=true
    [[ $exit_code -ne 0 ]] && passed=false

    local summary
    summary=$(echo "$output" | tail -3 | tr '\n' ' ' | head -c 200)

    write_eval_result "lint" "$passed" "$summary" "$duration" '{"exit_code": '"$exit_code"'}'
}

# ---------------------------------------------------------------------------
# Eval: Type Check
# ---------------------------------------------------------------------------
run_typecheck() {
    echo "[eval] Running type check..."
    local start_time
    start_time=$(date +%s)
    local output="" exit_code=0

    if python -m mypy --version &>/dev/null && [[ -f "pyproject.toml" || -f "setup.py" ]]; then
        # Target src/ when it exists (standard Python layout) to avoid
        # type-checking test files.  --ignore-missing-imports prevents
        # failures caused by missing third-party library stubs, which are
        # outside the project's control.
        local mypy_target="."
        [[ -d "src" ]] && mypy_target="src/"
        output=$(python -m mypy "$mypy_target" --ignore-missing-imports 2>&1 | tail -30) || exit_code=$?
    elif command -v tsc &>/dev/null && [[ -f "tsconfig.json" ]]; then
        output=$(tsc --noEmit 2>&1 | tail -30) || exit_code=$?
    else
        echo "[eval] No type checker detected, skipping"
        return
    fi

    local duration=$(( $(date +%s) - start_time ))
    local passed=true
    [[ $exit_code -ne 0 ]] && passed=false

    local summary
    summary=$(echo "$output" | tail -3 | tr '\n' ' ' | head -c 200)

    write_eval_result "typecheck" "$passed" "$summary" "$duration" '{"exit_code": '"$exit_code"'}'
}

# ---------------------------------------------------------------------------
# Eval: Security Scan
# ---------------------------------------------------------------------------
run_security_scan() {
    echo "[eval] Running security scan..."
    local start_time
    start_time=$(date +%s)
    local output="" exit_code=0

    if command -v npm &>/dev/null && [[ -f "package-lock.json" ]]; then
        output=$(npm audit --json 2>&1 | tail -50) || exit_code=$?
    elif command -v pip-audit &>/dev/null; then
        output=$(pip-audit 2>&1 | tail -30) || exit_code=$?
    elif python -m pip_audit --version &>/dev/null 2>&1; then
        # pip-audit not on PATH but importable as module (e.g. Windows Store Python)
        echo "[eval] pip-audit command not on PATH, falling back to python -m pip_audit"
        output=$(python -m pip_audit 2>&1 | tail -30) || exit_code=$?
    elif python3 -m pip_audit --version &>/dev/null 2>&1; then
        echo "[eval] pip-audit command not on PATH, falling back to python3 -m pip_audit"
        output=$(python3 -m pip_audit 2>&1 | tail -30) || exit_code=$?
    elif command -v cargo-audit &>/dev/null; then
        output=$(cargo audit 2>&1 | tail -30) || exit_code=$?
    else
        # Distinguish: installed but PATH issue vs genuinely not installed
        if python -c "import pip_audit" 2>/dev/null || python3 -c "import pip_audit" 2>/dev/null; then
            echo "[eval] pip_audit module found but not runnable — check Python version or PATH"
        else
            echo "[eval] No security scanner detected (pip-audit not installed), skipping"
        fi
        return
    fi

    # Soft-pass: if exit_code != 0 but no actual CVEs found (only "not found on PyPI" packages)
    if [[ $exit_code -ne 0 ]] && ! echo "$output" | grep -qiE "(vulnerability found|CVE-[0-9]|GHSA-)"; then
        echo "[eval] security: no CVEs found (unauditable packages only), treating as pass"
        exit_code=0
    fi

    local duration=$(( $(date +%s) - start_time ))
    local passed=true
    [[ $exit_code -ne 0 ]] && passed=false

    local summary
    summary=$(echo "$output" | tail -3 | tr '\n' ' ' | head -c 200)

    write_eval_result "security-scan" "$passed" "$summary" "$duration" '{"exit_code": '"$exit_code"'}'
}

# ---------------------------------------------------------------------------
# Eval: Performance Benchmark (placeholder)
# ---------------------------------------------------------------------------
run_perf_benchmark() {
    echo "[eval] Running performance benchmark..."
    local start_time
    start_time=$(date +%s)

    # Check for project-specific benchmark scripts
    if [[ -f "package.json" ]] && grep -q '"bench"' package.json 2>/dev/null; then
        local output exit_code=0
        output=$(npm run bench 2>&1 | tail -30) || exit_code=$?
        local duration=$(( $(date +%s) - start_time ))
        local passed=true
        [[ $exit_code -ne 0 ]] && passed=false
        local summary
        summary=$(echo "$output" | tail -3 | tr '\n' ' ' | head -c 200)
        write_eval_result "perf-benchmark" "$passed" "$summary" "$duration" '{"exit_code": '"$exit_code"'}'
    else
        echo "[eval] No benchmark detected, skipping"
    fi
}

# ---------------------------------------------------------------------------
# Feature coverage: fraction of baseline features marked "done"
# Uses EVALS/features-baseline.json as denominator when present (arena mode).
# Falls back to current FEATURES.md row count (legacy/non-arena mode).
# Returns 1 if FEATURES.md is absent (mode=job backward compat).
# ---------------------------------------------------------------------------
compute_feature_coverage() {
    local features_file="$WORKSPACE/FEATURES.md"
    local baseline_file="$WORKSPACE/EVALS/features-baseline.json"

    if [[ ! -f "$features_file" ]]; then
        echo "1"
        return
    fi

    local total done_count

    if [[ -f "$baseline_file" ]]; then
        # Arena mode: denominator is baseline feature count (immutable)
        total=$(PATH="$HOME/bin:$PATH" jq -r '.feature_ids | length' "$baseline_file" 2>/dev/null || echo 0)

        # Count only baseline feature IDs that are marked done in current FEATURES.md
        done_count=0
        local fid
        while IFS= read -r fid; do
            fid=$(echo "$fid" | tr -d '\r')
            [[ -z "$fid" ]] && continue
            if grep -qE "^\| ${fid} .*\| done" "$features_file" 2>/dev/null; then
                done_count=$((done_count + 1))
            fi
        done < <(PATH="$HOME/bin:$PATH" jq -r '.feature_ids[]' "$baseline_file" 2>/dev/null)

        # Warn about extra features (not in baseline) — informational only
        local current_total
        current_total=$(grep -cE '^\| F-[0-9]+' "$features_file" 2>/dev/null || echo 0)
        if [[ "$current_total" -gt "$total" ]]; then
            local extra=$((current_total - total))
            echo "[eval] WARNING: $extra extra feature(s) added beyond baseline (not counted in score)" >&2
        fi
    else
        # Legacy mode: use current FEATURES.md as denominator
        total=$(grep -cE '^\| F-[0-9]+' "$features_file" 2>/dev/null || echo 0)
        done_count=$(grep -cE '^\| F-[0-9]+.*\| done' "$features_file" 2>/dev/null || echo 0)
    fi

    if [[ "$total" -eq 0 ]]; then
        echo "0"
        return
    fi
    awk "BEGIN { printf \"%.4f\", $done_count / $total }"
}

# ---------------------------------------------------------------------------
# Composite score: read PROGRAM.md weights + latest eval results → 0.0-1.0
# ---------------------------------------------------------------------------
compute_composite_score() {
    local evals_dir="$WORKSPACE/EVALS"

    # Default weights (sum = 1.0)
    local w_tests=0.30 w_lint=0.15 w_typecheck=0.10 w_coverage=0.15 w_security=0.05 w_feature_coverage=0.25

    # Try reading weights from PROGRAM.md
    if [[ -f "$WORKSPACE/PROGRAM.md" ]]; then
        local line
        while IFS= read -r line; do
            case "$line" in
                *tests:*)            w_tests=$(echo "$line"            | awk -F: '{gsub(/[ \t]/,"",$2); print $2}') ;;
                *lint:*)             w_lint=$(echo "$line"             | awk -F: '{gsub(/[ \t]/,"",$2); print $2}') ;;
                *typecheck:*)        w_typecheck=$(echo "$line"        | awk -F: '{gsub(/[ \t]/,"",$2); print $2}') ;;
                *feature_coverage:*) w_feature_coverage=$(echo "$line" | awk -F: '{gsub(/[ \t]/,"",$2); print $2}') ;;
                *coverage:*)         w_coverage=$(echo "$line"         | awk -F: '{gsub(/[ \t]/,"",$2); print $2}') ;;
                *security:*)         w_security=$(echo "$line"         | awk -F: '{gsub(/[ \t]/,"",$2); print $2}') ;;
            esac
        done < <(sed -n '/^## Eval Protocol/,/^## /p' "$WORKSPACE/PROGRAM.md" 2>/dev/null || true)
    fi

    # Find latest eval result for each type
    local score_tests=0 score_lint=0 score_typecheck=0 score_coverage=0 score_security=0
    local found_any=false

    for etype in unit lint typecheck security-scan; do
        local latest
        latest=$(find "$evals_dir" -name "${etype}-*.json" -type f 2>/dev/null | sort -r | head -1)
        [[ -z "$latest" ]] && continue

        found_any=true
        local passed
        passed=$(jq -r '.pass' "$latest" 2>/dev/null || echo "false")

        local val=0
        [[ "$passed" == "true" ]] && val=1

        case "$etype" in
            unit)          score_tests=$val ;;
            lint)          score_lint=$val ;;
            typecheck)     score_typecheck=$val ;;
            security-scan) score_security=$val ;;
        esac
    done

    # Coverage: check if unit result has coverage info in details
    local latest_unit
    latest_unit=$(find "$evals_dir" -name "unit-*.json" -type f 2>/dev/null | sort -r | head -1)
    if [[ -n "$latest_unit" ]]; then
        local cov_pct
        cov_pct=$(jq -r '.details.coverage_pct // empty' "$latest_unit" 2>/dev/null || true)
        if [[ -n "$cov_pct" ]]; then
            # Saturate at 80%: ≥80% → 1.0, below → linear (cov_pct / 80)
            score_coverage=$(awk "BEGIN {v = $cov_pct / 80.0; if (v > 1) v = 1; printf \"%.4f\", v}")
        else
            # If tests pass, assume baseline coverage
            [[ "$score_tests" -eq 1 ]] && score_coverage=1
        fi
    fi

    if [[ "$found_any" == "false" ]]; then
        echo "0.0000"
        return
    fi

    # Feature coverage (0.0–1.0 fraction of FEATURES.md rows marked done)
    local score_feature_coverage
    score_feature_coverage=$(compute_feature_coverage)

    # Weighted composite
    awk "BEGIN {
        score = ($w_tests * $score_tests) + ($w_lint * $score_lint) + ($w_typecheck * $score_typecheck) + ($w_coverage * $score_coverage) + ($w_security * $score_security) + ($w_feature_coverage * $score_feature_coverage)
        printf \"%.4f\", score
    }"
}

# ---------------------------------------------------------------------------
# --score mode: output composite score and exit
# ---------------------------------------------------------------------------
if [[ "$SCORE_MODE" == "true" ]]; then
    compute_composite_score
    exit 0
fi

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------
echo "[eval] Starting evaluation suite (type: $EVAL_TYPE)"
echo "[eval] Workspace: $WORKSPACE"

case "$EVAL_TYPE" in
    unit)           run_unit_tests ;;
    lint)           run_lint ;;
    typecheck)      run_typecheck ;;
    security-scan)  run_security_scan ;;
    perf-benchmark) run_perf_benchmark ;;
    all)
        run_unit_tests
        run_lint
        run_typecheck
        run_security_scan
        run_perf_benchmark
        ;;
    *)
        echo "[eval] Unknown eval type: $EVAL_TYPE"
        exit 1
        ;;
esac

echo "[eval] Evaluation complete. Results in: $EVALS_DIR"
ls -la "$EVALS_DIR"/*.json 2>/dev/null || echo "(no results generated)"
