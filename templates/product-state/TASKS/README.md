# Tasks Queue

Individual task files are stored here as `task-NNN.md`.

## Task File Format

```markdown
# Task: <title>
- **ID**: task-NNN
- **Feature**: F-NNN
- **Priority**: P0 | P1 | P2
- **Status**: pending | in-progress | done | failed
- **Assigned Loop**: <loop number>

## Description
<detailed description>

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Implementation Notes
<notes added during implementation>
```

The planner agent creates tasks here. The implementer agent picks them up.
