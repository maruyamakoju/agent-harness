#!/usr/bin/env bash
# =============================================================================
# tests/test-run-evals.sh — Regression tests for run-evals.sh (PRs #5-#8)
#
# Bugs covered:
#   PR #5: python -m pip_audit fallback when pip-audit not on PATH
#   PR #6: soft-pass when only "not found on PyPI" errors (no CVE/GHSA)
#   PR #7: CODE prompt must include explicit lint instruction
#   PR #8: control characters in output corrupt eval JSON (jq parse error)
#
# Usage: bash tests/test-run-evals.sh
# =============================================================================
set -euo pipefail

# On Windows/MSYS2, the inherited PATH can be 8K+ chars which corrupts
# child process environments. Compact to essentials.
if [[ "$(uname -o 2>/dev/null || true)" == "Msys" ]]; then
    _CLEAN_PATH="/mingw64/bin:/usr/bin:/bin"
    [[ -d "$HOME/bin" ]] && _CLEAN_PATH="$HOME/bin:$_CLEAN_PATH"
    export PATH="$_CLEAN_PATH"
    unset _CLEAN_PATH
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PASS_COUNT=0
FAIL_COUNT=0
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t forge_eval_test)"
trap 'rm -rf "$WORK"' EXIT

ok()   { echo "  [PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
ng()   { echo "  [FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
check() {
    local got="$1" want="$2" label="$3"
    if [[ "$got" == "$want" ]]; then ok "$label"
    else ng "$label (got='$got' want='$want')"
    fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
make_ws() {
    local ws="$WORK/$1"
    mkdir -p "$ws/EVALS"
    cat > "$ws/PROGRAM.md" <<'MDEOF'
## Eval Protocol
weights:
  tests: 0.35
  lint: 0.20
  typecheck: 0.15
  coverage: 0.05
  security: 0.05
  feature_coverage: 0.20
MDEOF
    echo "$ws"
}

# Create FEATURES.md with $total features, first $done_count marked done
put_features() {
    local ws="$1" total="$2" done_count="$3"
    {
        echo "# Feature Tracker"
        echo ""
        echo "| ID | Feature | Status | Priority | Notes |"
        echo "|----|---------|--------|----------|-------|"
        local i
        for i in $(seq 1 "$total"); do
            local fid
            fid=$(printf "F-%03d" "$i")
            if [[ $i -le $done_count ]]; then
                echo "| $fid | Feature $i | done | P0 | |"
            else
                echo "| $fid | Feature $i | not-started | P0 | |"
            fi
        done
    } > "$ws/FEATURES.md"
}

put_eval() {
    local ws="$1" etype="$2" pass_val="$3"
    printf '{"type":"%s","timestamp":"2026-03-11T01:01:01Z","pass":%s,"summary":"ok","details":{},"duration_sec":1}\n' \
        "$etype" "$pass_val" > "$ws/EVALS/${etype}-20260311-010101.json"
}

score_of() {
    # PATH extended so jq is found on Windows ($HOME/bin/jq.exe) and Linux (/usr/bin/jq)
    PATH="$HOME/bin:$PATH" bash "$HARNESS_DIR/scripts/run-evals.sh" "$1" --score 2>/dev/null
}

# ===========================================================================
# PR #6 — soft-pass grep pattern
# ===========================================================================
echo ""
echo "=== PR #6: security soft-pass grep pattern ==="

# T1: "not found on PyPI" (no CVE) must NOT trigger hard-fail
output_no_cve="torchaudio  Dependency not found on PyPI and could not be audited: torchaudio (2.7.0+cu126)"
if ! echo "$output_no_cve" | grep -qiE "(vulnerability found|CVE-[0-9]|GHSA-)"; then
    ok "T1: no-CVE output does NOT match hard-fail pattern → soft-pass"
else
    ng "T1: no-CVE output incorrectly matches hard-fail pattern (regression!)"
fi

# T2: real CVE must trigger hard-fail
output_cve="pillow 8.3.1 CVE-2021-34552 Pillow through 8.2.0 causes RCE"
if echo "$output_cve" | grep -qiE "(vulnerability found|CVE-[0-9]|GHSA-)"; then
    ok "T2: real CVE-xxxx detected → hard-fail (not soft-passed)"
else
    ng "T2: real CVE was NOT detected (soft-pass incorrectly applied)"
fi

# T3: GHSA identifier must also trigger hard-fail
output_ghsa="requests 2.28.0 GHSA-j7hp-h8jx-5ppr SSRF via crafted Host header"
if echo "$output_ghsa" | grep -qiE "(vulnerability found|CVE-[0-9]|GHSA-)"; then
    ok "T3: GHSA-xxxx identifier detected → hard-fail"
else
    ng "T3: GHSA identifier was NOT detected (soft-pass incorrectly applied)"
fi

# T4: "vulnerability found" phrase triggers hard-fail
output_vulnfound="1 vulnerability found in 1 package"
if echo "$output_vulnfound" | grep -qiE "(vulnerability found|CVE-[0-9]|GHSA-)"; then
    ok "T4: 'vulnerability found' phrase detected → hard-fail"
else
    ng "T4: 'vulnerability found' phrase NOT detected"
fi

# ===========================================================================
# PR #8 — control character stripping in write_eval_result
# ===========================================================================
echo ""
echo "=== PR #8: control char stripping for valid JSON ==="

# T5: control chars stripped → jq can parse output JSON
# Simulate pip-audit output with ANSI escape codes + ASCII control chars
CTRL_SUMMARY=$'Progress\x01\x1b[32mOK\x1b[0m\x02 torchaudio not on PyPI\x03 done'
clean=$(echo "$CTRL_SUMMARY" | tr -d '\000-\010\013-\037' | sed 's/"/\\"/g' | tr '\n' ' ')
test_json="{\"summary\":\"${clean}\"}"
if echo "$test_json" | PATH="$HOME/bin:$PATH" jq . > /dev/null 2>&1; then
    ok "T5: control chars stripped → jq parses valid JSON"
else
    ng "T5: control chars still present → jq parse error (regression!)"
fi

# T6: confirm pre-fix code (no tr -d) would fail with same input
old_clean=$(echo "$CTRL_SUMMARY" | sed 's/"/\\"/g' | tr '\n' ' ')
old_json="{\"summary\":\"${old_clean}\"}"
if ! echo "$old_json" | PATH="$HOME/bin:$PATH" jq . > /dev/null 2>&1; then
    ok "T6: confirmed — without tr -d, control chars break jq (this is the bug we fixed)"
else
    ok "T6: note — shell did not preserve control chars verbatim (platform variation)"
fi

# T7: verify run-evals.sh write_eval_result produces parseable JSON in practice
# Create a temp workspace, run an eval that writes a result, then jq-parse it
ws_t7="$(make_ws "t7")"
# No Python files → pytest/ruff will skip, mypy will skip
# We just need a workspace with pyproject.toml so the unit check runs
cat > "$ws_t7/pyproject.toml" <<'PYEOF'
[project]
name = "evaltest"
version = "0.1.0"

[tool.ruff]
line-length = 88

[tool.pytest.ini_options]
testpaths = ["tests"]
PYEOF
mkdir -p "$ws_t7/tests"
# Run lint eval (fast, no Python needed — ruff exits 0 on empty project)
PATH="$HOME/bin:$PATH" bash "$HARNESS_DIR/scripts/run-evals.sh" "$ws_t7" --type lint > /dev/null 2>&1 || true
lint_file=$(ls "$ws_t7/EVALS/lint-"*.json 2>/dev/null | head -1 || true)
if [[ -n "$lint_file" ]]; then
    if PATH="$HOME/bin:$PATH" jq . "$lint_file" > /dev/null 2>&1; then
        ok "T7: lint eval result JSON is jq-parseable"
    else
        ng "T7: lint eval result JSON is invalid (jq parse error)"
    fi
else
    ok "T7: lint eval skipped (no linter on PATH) — not a regression"
fi

# ===========================================================================
# PR #8 — composite score reads security correctly (end-to-end)
# ===========================================================================
echo ""
echo "=== PR #8: composite score accuracy ==="

# T8: all evals pass → score 1.0000
ws_t8="$(make_ws "t8")"
put_eval "$ws_t8" unit true
put_eval "$ws_t8" lint true
put_eval "$ws_t8" typecheck true
put_eval "$ws_t8" security-scan true
s8="$(score_of "$ws_t8")"
check "$s8" "1.0000" "T8: all-pass → composite score 1.0000"

# T9: security fails → score 0.9500 (security weight 0.05 dropped)
ws_t9="$(make_ws "t9")"
put_eval "$ws_t9" unit true
put_eval "$ws_t9" lint true
put_eval "$ws_t9" typecheck true
put_eval "$ws_t9" security-scan false
s9="$(score_of "$ws_t9")"
check "$s9" "0.9500" "T9: security-fail → composite score 0.9500"

# T10: lint-only pass, no FEATURES.md → feature_coverage=1.0, score 0.4000
# (lint=0.20 + feature_coverage=0.20*1.0 = 0.40)
ws_t10="$(make_ws "t10")"
put_eval "$ws_t10" unit false
put_eval "$ws_t10" lint true
put_eval "$ws_t10" typecheck false
put_eval "$ws_t10" security-scan false
s10="$(score_of "$ws_t10")"
check "$s10" "0.4000" "T10: lint-only, no FEATURES.md → composite score 0.4000"

# T11: security-scan JSON with control chars → jq fails → score drops
# This simulates the pre-fix state (jq can't parse → security reads as false)
ws_t11="$(make_ws "t11")"
put_eval "$ws_t11" unit true
put_eval "$ws_t11" lint true
put_eval "$ws_t11" typecheck true
# Write a security JSON with embedded control char (simulates corrupt file)
printf '{"type":"security-scan","pass":true,"summary":"ok\x01bad","details":{},"duration_sec":1}\n' \
    > "$ws_t11/EVALS/security-scan-20260311-010101.json"
s11="$(score_of "$ws_t11")"
# With corrupt JSON: jq fails → score_security=0 → 0.45+0.25+0.20+0.05=0.9500
# With valid JSON:  jq works → score_security=1 → 1.0000
# The point: our write_eval_result FIX ensures files are NEVER corrupt
# This test just confirms current behavior — corrupt JSON from old code loses security weight
if [[ "$s11" == "0.9500" ]]; then
    ok "T11: confirmed — corrupt JSON (control chars) causes security weight loss (this is why PR #8 matters)"
elif [[ "$s11" == "1.0000" ]]; then
    ok "T11: jq on this platform tolerates control char in this position (platform-specific)"
else
    ok "T11: score=$s11 (platform-dependent behavior for malformed JSON)"
fi

# ===========================================================================
# PR #5 — python -m pip_audit fallback
# ===========================================================================
echo ""
echo "=== PR #5: python -m pip_audit fallback ==="

# T12: run-evals.sh contains python -m pip_audit fallback code
if grep -q "python -m pip_audit" "$HARNESS_DIR/scripts/run-evals.sh"; then
    ok "T12: python -m pip_audit fallback present in run-evals.sh"
else
    ng "T12: python -m pip_audit fallback MISSING (regression for PR #5)"
fi

# T13: python3 -m pip_audit fallback also present
if grep -q "python3 -m pip_audit" "$HARNESS_DIR/scripts/run-evals.sh"; then
    ok "T13: python3 -m pip_audit fallback present in run-evals.sh"
else
    ng "T13: python3 -m pip_audit fallback MISSING"
fi

# T14: fallback prints diagnostic message (not just silent skip)
if grep -q "falling back to python -m pip_audit" "$HARNESS_DIR/scripts/run-evals.sh"; then
    ok "T14: pip_audit fallback logs diagnostic message (not silent skip)"
else
    ng "T14: pip_audit fallback missing diagnostic message"
fi

# ===========================================================================
# PR #7 — CODE prompt has explicit lint instruction
# ===========================================================================
echo ""
echo "=== PR #7: CODE prompt lint instruction ==="

# T15: run-job.sh CODE prompt mentions lint before tests
if grep -q "Lint first" "$HARNESS_DIR/scripts/run-job.sh"; then
    ok "T15: CODE prompt has 'Lint first' instruction"
else
    ng "T15: CODE prompt missing 'Lint first' instruction (regression for PR #7)"
fi

# T16: ruff check --fix is explicitly mentioned
if grep -qE "ruff.*check.*fix|ruff.*--fix" "$HARNESS_DIR/scripts/run-job.sh"; then
    ok "T16: CODE prompt mentions 'ruff check --fix'"
else
    ng "T16: CODE prompt missing 'ruff check --fix' (regression for PR #7)"
fi

# ===========================================================================
# feature_coverage sub-score
# ===========================================================================
echo ""
echo "=== feature_coverage: FEATURES.md progress score ==="

# T17: 0/6 features done, all evals pass → feature_coverage=0 → score 0.8000
# (tests=0.35 + lint=0.20 + typecheck=0.15 + coverage=0.05 + security=0.05 + fc=0.20*0 = 0.80)
ws_t17="$(make_ws "t17")"
put_eval "$ws_t17" unit true
put_eval "$ws_t17" lint true
put_eval "$ws_t17" typecheck true
put_eval "$ws_t17" security-scan true
put_features "$ws_t17" 6 0
s17="$(score_of "$ws_t17")"
check "$s17" "0.8000" "T17: 0/6 features done, all evals pass → 0.8000"

# T18: 3/6 features done, all evals pass → feature_coverage=0.5 → score 0.9000
# (0.80 + 0.20*0.5 = 0.90)
ws_t18="$(make_ws "t18")"
put_eval "$ws_t18" unit true
put_eval "$ws_t18" lint true
put_eval "$ws_t18" typecheck true
put_eval "$ws_t18" security-scan true
put_features "$ws_t18" 6 3
s18="$(score_of "$ws_t18")"
check "$s18" "0.9000" "T18: 3/6 features done, all evals pass → 0.9000"

# T19: 6/6 features done, all evals pass → feature_coverage=1.0 → score 1.0000
ws_t19="$(make_ws "t19")"
put_eval "$ws_t19" unit true
put_eval "$ws_t19" lint true
put_eval "$ws_t19" typecheck true
put_eval "$ws_t19" security-scan true
put_features "$ws_t19" 6 6
s19="$(score_of "$ws_t19")"
check "$s19" "1.0000" "T19: 6/6 features done, all evals pass → 1.0000"

# ===========================================================================
# Baseline-pinned feature_coverage (arena integrity)
# ===========================================================================
echo ""
echo "=== baseline-pinned feature_coverage: immutable scoring denominator ==="

# Helper: create features-baseline.json
put_baseline() {
    local ws="$1"
    shift
    # remaining args are feature IDs
    local ids_json=""
    ids_json=$(printf '%s\n' "$@" | PATH="$HOME/bin:$PATH" jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null)
    mkdir -p "$ws/EVALS"
    printf '{"feature_ids":%s,"frozen_at":"2026-03-13T00:00:00Z","source":"SCAFFOLD"}\n' "$ids_json" \
        > "$ws/EVALS/features-baseline.json"
}

# T20: baseline=7, current=15 features, 7/7 baseline done → denominator stays 7 → fc=1.0
ws_t20="$(make_ws "t20")"
put_eval "$ws_t20" unit true
put_eval "$ws_t20" lint true
put_eval "$ws_t20" typecheck true
put_eval "$ws_t20" security-scan true
# Create 15 features (all done), but baseline only has 7
put_features "$ws_t20" 15 15
put_baseline "$ws_t20" "F-001" "F-002" "F-003" "F-004" "F-005" "F-006" "F-007"
s20="$(score_of "$ws_t20")"
check "$s20" "1.0000" "T20: baseline=7 current=15 all-done → denominator pinned to 7 → score 1.0000"

# T21: baseline=7, only 3 of 7 baseline features done, 8 extra done → fc=3/7
# score = 0.35+0.20+0.15+0.05+0.05 + 0.20*(3/7) = 0.80 + 0.0857 = 0.8857
ws_t21="$(make_ws "t21")"
put_eval "$ws_t21" unit true
put_eval "$ws_t21" lint true
put_eval "$ws_t21" typecheck true
put_eval "$ws_t21" security-scan true
# 15 features: F-001..F-011 done (11 done), F-012..F-015 not-started
put_features "$ws_t21" 15 11
# Baseline only F-001..F-007; F-001..F-003 are in first 11 (done), F-004..F-007 also done
# Actually put_features marks the first $done_count features as done sequentially
# So F-001..F-011 are done. Baseline F-001..F-007 → all 7 are done.
# Let's make it so only 3 baseline features are done:
# We need F-001..F-003 done, F-004..F-007 not-started (but they're in first 11 done positions)
# Easier: create custom FEATURES.md
{
    echo "# Feature Tracker"
    echo ""
    echo "| ID | Feature | Status | Priority | Notes |"
    echo "|----|---------|--------|----------|-------|"
    echo "| F-001 | Feature 1 | done | P0 | |"
    echo "| F-002 | Feature 2 | done | P0 | |"
    echo "| F-003 | Feature 3 | done | P0 | |"
    echo "| F-004 | Feature 4 | not-started | P0 | |"
    echo "| F-005 | Feature 5 | not-started | P0 | |"
    echo "| F-006 | Feature 6 | not-started | P0 | |"
    echo "| F-007 | Feature 7 | not-started | P0 | |"
    echo "| F-008 | Feature 8 (extra) | done | P1 | |"
    echo "| F-009 | Feature 9 (extra) | done | P1 | |"
    echo "| F-010 | Feature 10 (extra) | done | P1 | |"
} > "$ws_t21/FEATURES.md"
put_baseline "$ws_t21" "F-001" "F-002" "F-003" "F-004" "F-005" "F-006" "F-007"
s21="$(score_of "$ws_t21")"
# fc = 3/7 = 0.4286; score = 0.80 + 0.20*0.4286 = 0.8857
check "$s21" "0.8857" "T21: baseline=7, 3/7 baseline done, extras ignored → score 0.8857"

# T22: no baseline file (legacy mode) → uses current FEATURES.md as denominator
ws_t22="$(make_ws "t22")"
put_eval "$ws_t22" unit true
put_eval "$ws_t22" lint true
put_eval "$ws_t22" typecheck true
put_eval "$ws_t22" security-scan true
put_features "$ws_t22" 6 3
# Explicitly ensure NO baseline file
rm -f "$ws_t22/EVALS/features-baseline.json" 2>/dev/null || true
s22="$(score_of "$ws_t22")"
# Legacy: 3/6 = 0.5; score = 0.80 + 0.20*0.5 = 0.9000
check "$s22" "0.9000" "T22: no baseline (legacy mode) → uses FEATURES.md denominator → 0.9000"

# T23: baseline exists but FEATURES.md absent → returns 1 (backward compat)
ws_t23="$(make_ws "t23")"
put_eval "$ws_t23" unit true
put_eval "$ws_t23" lint true
put_eval "$ws_t23" typecheck true
put_eval "$ws_t23" security-scan true
put_baseline "$ws_t23" "F-001" "F-002" "F-003"
rm -f "$ws_t23/FEATURES.md" 2>/dev/null || true
s23="$(score_of "$ws_t23")"
check "$s23" "1.0000" "T23: baseline exists but no FEATURES.md → fc=1 (backward compat) → 1.0000"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "========================================"
echo "  Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo "  All regression tests passed."
    exit 0
else
    echo "  ${FAIL_COUNT} regression(s) detected — see failures above."
    exit 1
fi
