# Soak Test Observation

## Experiment

| Field | Value |
|-------|-------|
| Job ID | |
| Product | |
| Date | |
| max_loops | |
| time_budget_sec | |

---

## Stop Condition

| Field | Value |
|-------|-------|
| **stop_reason** | `target_score_reached` / `plateau_stop` / `consecutive_discard_stop` / `max_loops_reached` |
| **final_loop** | N / max_loops |
| **final_score** | 0.0000 |
| **duration_sec** | |

---

## Score Progression

| Loop | SCORE_BEFORE | SCORE_AFTER | Verdict |
|------|-------------|-------------|---------|
| 1 | | | keep / discard_regression / discard_audit |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |

*(ledger: `cat EVALS/ledger.jsonl | jq -r '[.loop,.score_before,.score_after,.verdict] | @tsv'`)*

---

## Eval Breakdown (final loop)

| Eval | pass |
|------|------|
| unit (tests) | true / false |
| lint | true / false |
| typecheck | true / false |
| security-scan | true / false |

---

## Keep / Discard Counts

| | Count |
|---|---|
| keep | |
| discard_regression | |
| discard_audit | |
| **CONSECUTIVE_DISCARDS max** | |
| **PLATEAU_COUNT max** | |

---

## Ledger Integrity

| Check | Result |
|-------|--------|
| ledger.jsonl line count | N lines |
| All lines valid JSON | yes / no |
| No missing loops | yes / no |

*(check: `wc -l EVALS/ledger.jsonl && cat EVALS/ledger.jsonl | jq . > /dev/null && echo "valid"`)*

---

## Time-Dependent Issues Observed

- [ ] ledger corruption mid-run
- [ ] eval JSON parse error (jq fails)
- [ ] init.sh failure worsens over loops
- [ ] rollback leaves stale state
- [ ] plateau/discard priority out of order
- [ ] workspace cleanup missed files

**Notes:**

---

## Verdict

| | |
|---|---|
| **Result** | PASS / FAIL / PARTIAL |
| **Next action** | freeze v0.5.1 / investigate X / fix Y |

---

## Quick Extract Commands

```bash
# Stop reason
grep "Target score reached\|plateau_stop\|Consecutive discard\|max_loops" logs/<job-id>.log | tail -3

# Score progression
grep "SCORE_BEFORE\|SCORE_AFTER" logs/<job-id>.log

# Ledger
PATH="$HOME/bin:$PATH" jq -r '[.loop, .score_before, .score_after, .verdict] | @tsv' \
  workspaces/<job-id>/EVALS/ledger.jsonl

# Eval failures (final baseline)
ls -t workspaces/<job-id>/EVALS/*.json | head -5 | xargs -I{} sh -c \
  'PATH="$HOME/bin:$PATH" jq -r "\"\\(.type): \\(.pass)\"" {}'
```
