# 5-Loop Real Claude Test — Success Criteria

## Sample: TODO API (Flask CRUD)

**Job file**: `examples/sample-5loop-crud.json`
**Features**: 5 (list, create, get-single, update, delete)
**Max loops**: 5
**Test command**: `python -m pytest tests/ -v --tb=short`

## Pre-run checklist

- [ ] Mock E2E is 10/10 stable
- [ ] Job JSON is valid (`jq . examples/sample-5loop-crud.json`)
- [ ] HARNESS_DIR and WORKSPACES_DIR are set
- [ ] `claude` CLI is accessible and authenticated
- [ ] Time budget is sufficient (7200s = 2h)

## 6 Success Criteria (pass/fail after run)

### 1. PROGRESS.md integrity
PROGRESS.md is updated every loop and never gets corrupted.
- [ ] File exists after each loop
- [ ] Contains "### Current Focus" section
- [ ] No duplicate headers or malformed markdown
- [ ] Loop number advances

### 2. FEATURES.md progression
Feature statuses move forward, never backward.
- [ ] At least 2 features reach "done" status
- [ ] No feature goes from "done" back to "not-started"
- [ ] "in-progress" features don't stay stuck across multiple loops

### 3. PLAN/CODE responsibility separation
PLAN only selects tasks, CODE only implements.
- [ ] PLAN commits contain only PROGRESS.md and FEATURES.md changes
- [ ] CODE commits contain implementation files (.py) and test files
- [ ] No code implementation happens during PLAN state

### 4. init.sh re-executability
init.sh runs successfully on every loop iteration.
- [ ] No errors from init.sh in log
- [ ] Dependencies are installed on first run
- [ ] Subsequent runs are idempotent (no reinstall errors)

### 5. Commit accumulation
Meaningful commits are produced.
- [ ] At least 3 commits total (scaffold + 2 feature implementations)
- [ ] Commit messages follow `<type>(<scope>): <description>` format
- [ ] Each feature commit includes both code and tests

### 6. No infinite loops or repetition
The agent makes forward progress, not circles.
- [ ] No feature is selected twice in PLAN
- [ ] Loop count reaches max (5) OR all features complete
- [ ] No error repetition (same error 5+ times)

## Post-run analysis

After the run, classify any failures into:

| Category | Example |
|----------|---------|
| **prompt** | PLAN writes code, CODE picks different task |
| **state** | PROGRESS.md format breaks, completion detection fails |
| **harness** | State transition wrong, push fails, persist broken |
