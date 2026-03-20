# AGENT.md - Product Forge Agent Rules (Autoresearch Mode)

You are an autonomous coding agent in **Product Mode**, building a complete product
through hypothesis-driven experimentation across multiple loops.

## Core Principles

1. **One hypothesis per loop.** Each loop tests a single hypothesis from PROGRAM.md sources.
2. **State files are your memory.** Always read PROGRESS.md, FEATURES.md, DECISIONS.md, and PROGRAM.md before starting work.
3. **Tests are mandatory.** Never commit code without passing tests. If no tests exist, write them first.
4. **Log every decision.** Append to DECISIONS.md when you make architectural choices.
5. **Small, atomic commits.** Each commit = one logical change with a descriptive message.
6. **init.sh is your bootstrap.** Run it at the start of each session to set up the dev environment.
7. **Respect mutation caps.** PROGRAM.md defines limits on files changed/created and diff size per loop.

## Workflow Per Loop Iteration

1. Read PROGRESS.md — what was done last, what failed, what's next
2. Read PROGRAM.md — understand mutation scope, weights, and keep/discard policy
3. Read FEATURES.md — find hypothesis sources (not-started features, regressions)
4. Read DECISIONS.md — understand past architectural choices
5. Formulate a hypothesis (update PROGRESS.md "### Hypothesis")
6. Implement the hypothesis within mutation caps
7. Run tests (init.sh should set up the test environment)
8. If tests pass: commit, update FEATURES.md status, update PROGRESS.md
9. If tests fail: debug (max 3 attempts), log failure in PROGRESS.md
10. The harness judges: score_after > score_before → keep; otherwise → discard (rollback)

## Commit Message Format

```
<type>(<scope>): <description>

Types: feat, fix, test, refactor, docs, chore
```

## File Rules

- **DO** modify source code, tests, configuration, and documentation
- **DO** update PROGRESS.md, FEATURES.md, DECISIONS.md after each action
- **DO NOT** modify AGENT.md or PROGRAM.md (these are harness-controlled)
- **DO NOT** modify EVALS/features-baseline.json, eval scripts, or scoring files
- **DO NOT** delete or overwrite DECISIONS.md entries
- **DO NOT** skip tests to save time
- **DO NOT** create scratch, debug, or temp files

## Quality Standards

- All new code must have corresponding tests
- All tests must pass before committing
- No known security vulnerabilities (run security checks if available)
- Code should follow the project's existing style and conventions
- Stay within mutation caps defined in PROGRAM.md

### Code Quality (Non-Negotiable)

1. **Modular architecture**: Separate database layer (db.py), CLI commands (cli.py or main.py),
   and data models (models.py). Do NOT put everything in one file.
2. **Input validation**: Every user-facing command must validate its arguments. Use try/except
   with clear error messages. Never expose raw Python tracebacks to the user.
3. **Edge-case tests**: Each feature must have at least one test for invalid input or boundary
   conditions (e.g., bad date, empty list, missing required field).
4. **Database indexes**: Add CREATE INDEX statements for columns used in WHERE or ORDER BY.
5. **pytest-cov**: Always include `pytest-cov` in `[project.optional-dependencies] dev`.
   The harness measures coverage automatically — target ≥80%.
