# FEATURES.md — TaskForge CLI

## F-001: Project scaffold with database schema
Create `src/taskforge/` package with `__init__.py`, `db.py`, `models.py`.
SQLite database with `tasks` table: id (INTEGER PK), title (TEXT NOT NULL),
description (TEXT), priority (INTEGER 1-4, default 2), status (TEXT: todo/doing/done),
created_at (TEXT ISO8601), updated_at (TEXT ISO8601).
Include `db.py` with `get_connection()`, `init_db()`, and `tests/test_db.py`.

## F-002: Add task command
`taskforge add "title" --priority 2 --description "desc"`
Validates: title non-empty, priority 1-4. Prints created task with rich Panel.
Test: add succeeds, missing title errors, invalid priority errors.

## F-003: List tasks command with table output
`taskforge list` — shows all tasks in a rich Table (columns: ID, Title, Priority, Status, Created).
`taskforge list --status done` — filter by status.
`taskforge list --priority 1` — filter by priority.
Test: list empty, list with data, filter by status, filter by priority.

## F-004: Complete and delete commands
`taskforge done <id>` — sets status to "done", prints confirmation.
`taskforge delete <id>` — removes task, prints confirmation.
Both error on invalid ID (not found).
Test: complete existing, complete missing, delete existing, delete missing.

## F-005: Tag system
New `tags` table: task_id (FK), tag (TEXT). Composite unique on (task_id, tag).
`taskforge add "title" --tag work --tag urgent` — attach tags on creation.
`taskforge tag <id> <tag>` — add tag to existing task.
`taskforge untag <id> <tag>` — remove tag.
`taskforge list --tag work` — filter by tag.
Test: add with tags, tag/untag, filter by tag.

## F-006: Due dates and overdue detection
Add `due_date` column (TEXT ISO8601, nullable) to tasks table.
`taskforge add "title" --due 2026-04-01`
`taskforge list --overdue` — show tasks past due date.
`taskforge list` — overdue tasks shown in red.
Date validation: reject past dates on add, accept any format parseable by datetime.
Test: add with due date, overdue filter, date validation, display coloring.

## F-007: Edit and status transitions
`taskforge edit <id> --title "new" --priority 3 --description "new desc" --due 2026-05-01`
At least one field required. Updates `updated_at`.
`taskforge start <id>` — sets status to "doing".
Status transitions enforced: todo→doing→done (no skipping, no backwards).
Test: edit fields, status transitions valid/invalid, updated_at changes.

## F-008: Statistics and summary view
`taskforge stats` — shows:
  - Total tasks, by status (todo/doing/done counts)
  - By priority breakdown
  - Overdue count
  - Tags frequency (top 5)
  - Completion rate (done / total * 100)
Output as rich Panel with formatted sections.
Test: stats with empty db, stats with mixed data, completion rate math.

## F-009: Export and import (JSON)
`taskforge export --format json > tasks.json` — exports all tasks with tags.
`taskforge import tasks.json` — imports tasks, skips duplicates by title.
JSON schema: `{"tasks": [{"title": "...", "priority": 2, "tags": ["work"], ...}]}`
Test: export round-trip, import duplicates skipped, invalid JSON errors.

## F-010: Configuration file
`~/.taskforge/config.toml` with defaults:
  - `default_priority = 2`
  - `date_format = "%Y-%m-%d"`
  - `db_path = "~/.taskforge/tasks.db"`
  - `color_theme = "monokai"` (used by rich)
`taskforge config show` — display current config.
`taskforge config set key value` — update config.
Config loaded at startup, merged with CLI args (CLI wins).
Test: default config creation, config set/get, CLI override.
