# Agent rules

## Project context

- What this is, its API, and its pin: `README.md`
- The decisions, each dated with its reason and trade-off: `docs/decisions.md`. A new
  decision goes there. `docs/architecture.md`, written with the first code, describes
  how the package works for its users and changes with each decision that changes it
- Toolchain, local setup, and tests: `docs/development.md`
- Goose compiler and stdlib gaps found here: `docs/goose-findings.md`
- Task tracking: `tasks/` (see `tasks/README.md`)
- Substantial doc drafts and requested prose reviews:
  `.claude/skills/google-style/SKILL.md`; other writing follows "Writing" below
- The protocol: PostgreSQL's "Frontend/Backend Protocol" chapter (protocol 3.0), and
  RFC 5802 and RFC 7677 for SCRAM-SHA-256.
- Its first user: goose-rest, through goose-http's outbound connections.
- The language: the pinned Goose release's `docs/tutorial.md`, `docs/goose_spec.md`,
  `docs/stdlib.md`, and `docs/packages.md` (how a package declares the packages it
  needs). Read the tutorial before writing Goose; check the spec before assuming a
  feature exists.

Follow the recorded decisions; if a change contradicts one, update the doc in the same
change or ask first. Record setup facts and environment traps you find (paths, shell
quirks, Postgres versions, Docker setup) in `docs/development.md`, not
in agent memory, so the next agent finds them. Docs and commits name no people: date a
decision or a request (`(2026-10-19)`), and describe the setup without anyone's machine,
checkouts, or home directory. What only one machine needs, such as where its Goose
checkout is, goes in `CLAUDE.local.md`, which git ignores. Benchmark results still name
their machine.

## Writing

- Lead with the decision, behavior, or action, then explain why. Name the responsible
  component and use concrete facts. Cut filler and repeated summaries.
- Preserve technical meaning when editing: actors, negations, conditions, numbers,
  versions, commands, paths, and identifiers. Keep decided/proposed/open,
  implemented/planned, and must/should/can distinct. Flag contradictions instead of
  silently resolving them while copyediting.
- Record a decision with its reason and the trade-off that matters. Keep each fact in
  one place and link to it elsewhere. Use absolute dates for dated events.
- Match the document's format. Tasks follow `tasks/README.md`, with concrete acceptance
  criteria. Use sentence-case headings, backticks for code identifiers and commands,
  and descriptive links. Wrap prose at about 90 characters.
- Say what doesn't work yet, plainly.

## Goose, not an addition to Goose

- Build with the official Goose release that `scripts/goose.sh` pins. Check for a newer
  release at the start of a session and move the pin to it. Pin a commit
  (`GOOSE_COMMIT`) only when a fix this repository needs isn't released yet, and return
  to a release once one has it (2026-10-15).
- Don't edit a Goose checkout. When the compiler rejects something it should accept,
  miscompiles, or the stdlib lacks something, reduce it to a minimal program, record it
  in `docs/goose-findings.md`, and work around it here. Report blockers to the maintainer.
- Every finding names the Goose commit it was found on, the pin at the time (for a
  release, its commit).
- `docs/goose-findings.md` lists bugs first and feature requests after, each part from
  the least work a fix is expected to take to the most. Place a new entry by that
  order, and delete an entry once the pin has its fix (2026-10-14).
- Write Goose the way the pinned release's `samples/` and `stdlib/` do: flat data,
  references into growing arrays, `return ... from` for errors, untyped parameters for
  generics.

## Goose, with no C

- The package is Goose with no C. Sockets are goose-http's: the package does no I/O of
  its own, and a gap there is fixed in goose-http, not worked around here.

## Code conventions

- Comment only where the code is hard to follow without it, and say only what a reader
  of that code needs: why, a constraint, or a contract the code can't show. Don't restate
  the next line, and don't describe earlier versions or the task that added the code;
  history belongs in git.
- Edit files with the Edit tool, not with `sed` or a Python or PowerShell script. On
  Windows, line endings differ by file type and a shell adds a layer of escaping, and
  scripted edits break on both.
- Tests follow Goose's own convention: a top-level `test/` by area, each test a small
  program whose printed output a golden file in `test/expected/` checks, `// error:`
  fixtures for code that must not compile, and a runner that batches them with
  `goose --multi-test`. Messages are checked against bytes recorded from a real
  Postgres server.

## Commits

- One lean sentence in imperative mood, at most 72 characters.
- No body, no `Co-Authored-By` or any other trailers.
- Fetch and rebase before pushing a finished commit to `origin`.
