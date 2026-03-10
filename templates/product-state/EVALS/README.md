# Evaluation Results

Automated evaluation results are stored here as JSON files.

## File Naming Convention

`<type>-<timestamp>.json`

## Evaluation Types

| Type | Description |
|------|-------------|
| `unit` | Unit test results |
| `e2e` | End-to-end test results |
| `lint` | Linter output |
| `typecheck` | Type checker results |
| `security-scan` | Security vulnerability scan |
| `perf-benchmark` | Performance benchmark results |

## JSON Schema

```json
{
  "type": "unit",
  "timestamp": "2026-01-01T12:00:00Z",
  "pass": true,
  "summary": "42 passed, 0 failed",
  "details": { ... },
  "duration_sec": 12.5
}
```

The evaluation framework (`run-evals.sh`) writes results here.
The planner agent reads them to adjust priorities.

## Experiment Ledger

`ledger.jsonl` records each experiment loop as a JSON-lines file:

```json
{
  "loop": 1,
  "hypothesis": "If we implement F-001, then tests and lint score will improve",
  "files_touched": "src/F-001.py,tests/test_F-001.py",
  "wall_seconds": 45,
  "score_before": "0.5000",
  "score_after": "0.6000",
  "kept": true,
  "commit_sha": "abc1234",
  "timestamp": "2026-01-01T12:01:00Z",
  "verdict": "keep"
}
```

Verdicts: `keep`, `discard_regression`, `discard_audit`, `discard_test_fail`
