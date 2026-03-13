# A/B Experiment Observation Report
## Experiment: v1-strict vs v2-relaxed (bmark-cli-002 baseline)
## Date: 2026-03-13
## Arena version: v0.6.0 (baseline-pinned feature_coverage)

---

## Setup

| Parameter | v1-strict | v2-relaxed |
|---|---|---|
| `max_files_changed` | 3 | 5 |
| `max_files_created` | 2 | 4 |
| `max_diff_lines` | 150 | 300 |
| `max_discards_in_a_row` | 3 | 5 |
| `min_improvement_delta` | 0.01 | 0.005 |
| `max_plateau_loops` | 2 | 3 |
| `max_loops` | 10 | 10 |
| Baseline (frozen at SCAFFOLD) | 15 features (F-001..F-015) | 15 features (F-001..F-015) |
| Score floor | 0.25 (tests+security=0, lint=0.25) | 0.25 |

Same bmark-cli-002 product spec. Different PROGRAM.md variants.

---

## Summary Results

| Experiment | Loops | Keeps | KeepRate | L→Tgt | T→Tgt(s) | ΔScore/Kp | DiscRecovery | Feat/hr | Score Range |
|---|---|---|---|---|---|---|---|---|---|
| bmark-cli-002-v1 | 9 | 9 | 1.0000 | 9 | 2907 | 0.0833 | N/A | 11.15 | 0.2500 → 1.0000 |
| bmark-cli-002-v2 | 5 | 0 | 0.0000 | ∞ | ∞ | 0.0000 | 0.0000 | N/A | 0.2500 → 0.2500 |

---

## Per-Loop Breakdown

### v1-strict

| Loop | Hypothesis | Files | ΔScore | Verdict | Duration(s) |
|---|---|---|---|---|---|
| 1 | F-001: scaffold + DB init + add cmd | 5 | +0.4133 | keep | 596 |
| 2 | Fix typecheck failure (tmp_path annotation) | 2 | +0.1500 | keep | 204 |
| 3 | F-002: list command | 4 | +0.0134 | keep | 428 |
| 4 | F-003: delete command | 4 | +0.0133 | keep | 167 |
| 5 | F-004: search command | 4 | +0.0133 | keep | 251 |
| 6 | F-005: tag system | 4 | +0.0134 | keep | 389 |
| 7 | F-006: export (JSON+CSV) | 4 | +0.0133 | keep | 302 |
| 8 | F-007: import command | 4 | +0.0133 | keep | 267 |
| 9 | FEATURES.md catch-up (F-008..F-015) | 2 | +0.1067 | keep | 303 |

Stop reason: `target_score_reached (1.0000 >= 1.00)` at loop 9.

### v2-relaxed

| Loop | Hypothesis | files_changed | cap | Verdict | Duration(s) |
|---|---|---|---|---|---|
| 1 | "Implement F-001..F-013 in order" (unchanged) | 6 | 5 | discard_audit | 664 |
| 2 | "Implement F-001..F-013 in order" (unchanged) | 10 | 5 | discard_audit | 311 |
| 3 | "Implement F-001..F-013 in order" (unchanged) | 10 | 5 | discard_audit | 440 |
| 4 | "Implement F-001..F-013 in order" (unchanged) | 9 | 5 | discard_audit | 316 |
| 5 | "Implement F-001..F-013 in order" (unchanged) | 7 | 5 | discard_audit | 221 |

Stop reason: `consecutive_discard_stop (5 >= 5)` at loop 5.

---

## Key Findings

### Finding 1: Tight caps enforce 1-feature-per-loop discipline

v1's `max_files_changed=3` forced the agent to implement one feature per loop.
With src file + test file + PROGRESS.md + FEATURES.md = 4 typical files, the agent
learned to work within the cap (observed: loops 2-8 consistently used 4 files).

v2's `max_files_changed=5` seemed sufficient but was not. The agent attempted to
implement multiple features at once (6–10 files per loop), treating the cap as a
generous allowance rather than a hard discipline constraint.

**Hypothesis**: Tighter caps act as a behavior-shaping signal. The agent calibrates
its scope to the cap. Relaxed caps invite scope creep.

### Finding 2: PROGRESS.md rollback breaks agent memory

In v2, every discard_audit triggered a `git reset --hard` to PRE_CODE_COMMIT.
PROGRESS.md is in the workspace root (not under EVALS/), so it reverts to scaffold
state (Loop: 0, no completed items) on each rollback.

The agent reads PROGRESS.md at the start of each CODE loop and sees zero progress,
so it attempts to implement the entire product from scratch — exactly the behavior
that triggered the cap violation in the first place.

Evidence: All 5 v2 ledger entries have the same hypothesis text (scaffold initial
state: "Implement bmark CLI features in order F-001 through F-013").

The ledger (EVALS/ledger.jsonl) IS preserved across loops (committed in EVAL_BASELINE).
But the agent has no instruction to read the ledger — only PROGRESS.md.

**Implication**: The harness should inject `discard_audit` feedback into the PLAN
prompt so the agent can adapt scope even when PROGRESS.md has rolled back.

### Finding 3: Higher discard tolerance → more damage, not recovery

v2's `max_discards_in_a_row=5` gave the agent 5 chances to fail. Rather than
recovering, the agent compounded: 6 → 10 → 10 → 9 → 7 files across 5 loops.
The extra tolerance only produced longer wasted wall-clock time (35 min for zero
improvement vs. 51 min for complete implementation in v1).

**Implication**: Discard tolerance should be conservative (2-3) by default.
Higher tolerance is only useful when the agent can actually learn from failures —
which requires preserved progress state.

### Finding 4: FEATURES.md catch-up is valid arena behavior

v1 loop 9: agent updated only FEATURES.md to mark F-008..F-015 as `done`
(score: 0.8933 → 1.0000). These are test-coverage and tooling features
(F-008=pyproject.toml, F-009..F-015=pytest test suites for each command feature).
They were implemented as side effects of F-001..F-007 but FEATURES.md status was
never updated. The agent correctly identified the discrepancy.

This is legitimate: the arena contract says "update FEATURES.md status only for
baseline feature IDs" and "KEEP only if score improves and audit passes." Both
conditions were met. No code was fabricated.

**Note**: This behavior could be gamed if an agent marks features done without
implementing them. The harness cannot currently detect this. Consider adding a
test-coverage gate: a feature is only count-as-done if there exists ≥1 test for it.

### Finding 5: Baseline freeze works correctly

v1 FEATURES.md expanded from 7 spec features to 15 features at scaffold time
(Claude added F-008..F-015 test-coverage and tooling features). The frozen baseline
captured all 15. Score delta per feature = 0.20/15 ≈ 0.0133 — confirmed by loops 3-8.

F-001 alone did NOT trigger target_score_reached (score 0.2500 → 0.6633, not 1.0).
Baseline-pinned scoring is working as designed.

---

## Score Trajectory

```
v1: 0.25 → 0.66 → 0.81 → 0.83 → 0.84 → 0.85 → 0.87 → 0.88 → 0.89 → 1.00
v2: 0.25 → 0.25 → 0.25 → 0.25 → 0.25 → 0.25
          ^^^^^^ all discard_audit, no movement
```

---

## Proposed v3 Design

Based on the v2 failure mode:

```markdown
## Changes from v2-relaxed

# Restore tight caps (main lesson: caps shape behavior)
max_files_changed: 3
max_files_created: 2
max_diff_lines: 150

# Keep conservative discard tolerance
max_discards_in_a_row: 3

# Audit feedback in hypothesis: add to Arena Contract
"If the previous loop ended in discard_audit, your next loop MUST change fewer
files. Read EVALS/ledger.jsonl to see the last verdict and files_changed count.
Do not repeat a plan that was rejected — reduce scope."
```

The key addition: direct the agent to read `EVALS/ledger.jsonl` (which survives
rollback) to understand why previous loops failed. This closes the feedback loop
that v2 was missing.

---

## Conclusion

**v1-strict** is the validated working configuration. `max_files_changed=3` is the
critical parameter — it forces 1-feature-per-loop discipline that the arena contract
alone cannot enforce.

**v2-relaxed** is a documented failure mode. The combination of relaxed caps +
PROGRESS.md rollback + no ledger-reading instruction = permanent scope creep.

The arena is ready for PROGRAM.md as a research surface. The human-controlled
variable that matters most is `max_files_changed`, not `min_improvement_delta` or
`max_plateau_loops`.

---

## Artifacts

| File | Description |
|---|---|
| `workspaces/bmark-cli-002-v1/EVALS/ledger.jsonl` | Full v1 experiment ledger |
| `workspaces/bmark-cli-002-v2/EVALS/ledger.jsonl` | Full v2 experiment ledger |
| `logs/bmark-cli-002-v1.log` | Full v1 harness log |
| `logs/bmark-cli-002-v2.log` | Full v2 harness log |
| `examples/program-variants/v1-strict.md` | v1 PROGRAM.md variant |
| `examples/program-variants/v2-relaxed.md` | v2 PROGRAM.md variant |
| `scripts/compare-programs.sh` | Comparison metrics tool |
