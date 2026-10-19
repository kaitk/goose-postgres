# Tasks

Markdown-based task tracking. One file per task, or one folder for a task with
several subtasks or its own supporting files.

## Naming

`NNN-short-slug.md` — zero-padded, sequential number plus a kebab-case slug,
e.g. `001-wire-protocol.md`.

A task with subtasks or supporting files is a folder with the same name,
`NNN-short-slug/`, holding the task itself as `README.md` and one file per
subtask as `NN-short-slug.md`, numbered within the folder. Subtasks use the same format
as tasks.

## Format

```markdown
# NNN: Title

Status: todo | in-progress | done | cancelled

Short description of what and why.

## Acceptance criteria

- [ ] Concrete, verifiable outcome
- [ ] ...
```

Update the status line as work progresses; tick criteria as they are met. A cancelled task
says when it was cancelled and why. A task that measures something links to the
numbers and their method in `docs/results.md` or `docs/results-history.md`.

## Archive

When a task is done and nothing still builds on its file, move it to `000-archive/` with
`git mv`, keeping its name. The main folder then lists only open work. Numbers stay
unique across both folders: pick the next number after the highest in either. Refer to
tasks by number ("task 001"), not by path, so a move breaks no reference.

Archived tasks describe the implementation at completion. Use the README and
`docs/architecture.md` for current behavior, `docs/decisions.md` for why, and results
for the latest measurements.

## Order

Task 001, the wire protocol, is done but for its last step, which is task 005's. Two
lines follow it, both waiting on goose-http's task 053:

- For goose-rest's lane jobs: task 002, the blocking facade, then task 003, queries in
  parallel on one connection, and task 004, the transaction block, which goose-sqlite's
  task 003 matches.
- For HttpArena: task 005, the pool on goose-http's outbound connections, which
  answers `/async-db`.

