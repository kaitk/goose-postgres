# 002: A blocking facade for lane jobs

Status: todo. Waits on a blocking socket for a thread that runs no event loop
(`docs/decisions.md`, Open; goose-http's task 053).

goose-rest runs a use case with several queries as one job on a lane (its task 052):
the job's code calls the database and gets rows back, top to bottom, as in Hono,
Elysia, or Spring. This facade is that API, over the protocol: it writes the entries,
sends them on the lane's socket, blocks until the events it waits for arrive, and
returns the rows. It follows goose-sqlite's API where the two databases allow it
(`docs/decisions.md`).

## Design

- **Errors**: `pg::run() { ... } -> Error[]` catches, and every call that fails leaves
  through `return [e] from` its catcher, as `sqlite::run` does: a server's
  ErrorResponse (its SQLSTATE and message) or a broken connection (`c.reason`).
  `pg::fail(code, message)` leaves with the program's own. The `Error` struct matches
  goose-sqlite's where it can: a `code` and a `message`; Postgres's code is a
  five-character SQLSTATE where SQLite's is an integer, so the task decides between
  `code: u8[..5]` and an integer encoding.
- **A connection**: `pg::connect(url)` opens the socket, runs `start` and `step` to
  `READY`, and takes SCRAM's nonce, 18 bytes, from goose-hash's
  `hash::random_bytes`, the OS's secure random source, which aborts rather than
  return weaker bytes. It's in goose-hash v0.0.3, so this task moves the goose-hash
  pin to v0.0.3. Goose's own `random_seed` won't do: at `v2026.2` it mixes the
  clocks on Windows (goose-hash's `docs/goose-findings.md`, 2026-10-19).
- **Queries**: a call that runs one query and hands its rows to a block,
  `pg::query(db, sql) { row => ... }` or a statement with parameters, and one that
  returns a command's count. Parameters are the protocol's `param` overloads. Rows
  are views into the connection's input buffer, valid inside the block, so the rows
  of a large result needn't be held at once.
- **Statements**: each connection prepares a statement once, by name, the first time
  the facade runs its SQL, and keeps the names it has prepared.
- **Buffers**: the connection's input and output buffers belong to the lane's job,
  which owns the connection; the facade grows them to `c.need` when a message is
  larger than the buffer.

The trap goose-sqlite recorded applies: a fully typed function that can fail breaks
`goose check` of the package and of programs that import it, so each facade function
that can fail keeps one untyped parameter (goose-sqlite's `docs/goose-findings.md`).

## Steps

1. Settle the API above in `docs/decisions.md`, with the `Error` struct and how a
   block receives rows.
2. The facade over the protocol and a blocking socket.
3. Tests: the session tests' relay serves the facade as it serves the protocol, so
   each call is replayed from captures and run live with `scripts/live.sh`; a
   `// error:` fixture shows that a call that can fail doesn't compile outside
   `pg::run`.
4. `docs/architecture.md` and `README.md`.

## Acceptance criteria

- [ ] The API recorded in `docs/decisions.md` and `docs/architecture.md`
- [ ] Queries with parameters, commands, and errors through `pg::run`, replayed and live
- [ ] `pg::connect` takes SCRAM's nonce from `hash::random_bytes`, with goose-hash
      pinned at v0.0.3
- [ ] A call that can fail, outside `pg::run`, doesn't compile, with a test
- [ ] goose-rest's best practices can port a multi-query use case on it (its task 052)
- [ ] `scripts/test.sh` and `scripts/live.sh` pass
