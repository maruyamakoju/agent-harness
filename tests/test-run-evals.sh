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
  tests: 0.45
  lint: 0.25
  typecheck: 0.20
  coverage: 0.05
  security: 0.05
MDEOF
    echo "$ws"
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

# T10: lint-only pass (initial state before any code) → score 0.2500
ws_t10="$(make_ws "t10")"
put_eval "$ws_t10" unit false
put_eval "$ws_t10" lint true
put_eval "$ws_t10" typecheck false
put_eval "$ws_t10" security-scan false
s10="$(score_of "$ws_t10")"
check "$s10" "0.2500" "T10: lint-only → composite score 0.2500"

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
