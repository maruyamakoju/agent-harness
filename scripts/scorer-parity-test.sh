#!/usr/bin/env bash
# scorer-parity-test.sh — Compare Python and bash scorers on all workspaces
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Scorer Parity Test: Python (forge) vs Bash (run-evals.sh) ==="
echo ""
printf "%-30s %10s %10s %s\n" "Workspace" "Python" "Bash" "Match"
printf "%-30s %10s %10s %s\n" "---------" "------" "----" "-----"

PASS=0
FAIL=0

for ws in "$PROJECT_DIR"/workspaces/*/; do
  ws_name=$(basename "$ws")

  # Python scorer
  py_score=$(python -c "
import sys; sys.path.insert(0, '$PROJECT_DIR')
from forge.scorer import compute_composite_score
from pathlib import Path
s = compute_composite_score(Path(sys.argv[1]))
print(f'{s:.4f}')
" "$ws" 2>/dev/null) || py_score="ERR"

  # Bash scorer
  bash_score=$(PATH="$HOME/bin:$PATH" bash "$SCRIPT_DIR/run-evals.sh" "$ws" --score 2>/dev/null) || bash_score="ERR"
  bash_score=$(echo "$bash_score" | tr -d '\r' | tail -1)

  if [ "$py_score" = "$bash_score" ]; then
    match="OK"
    PASS=$((PASS + 1))
  else
    match="MISMATCH"
    FAIL=$((FAIL + 1))
  fi
  printf "%-30s %10s %10s %s\n" "$ws_name" "$py_score" "$bash_score" "$match"
done

echo ""
echo "Result: $PASS match, $FAIL mismatch out of $((PASS + FAIL)) workspaces"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
