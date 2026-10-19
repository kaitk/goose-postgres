# Decisions

The record of goose-postgres's design decisions, for contributors and agents: each
dated, with its reason and the trade-off that matters. How the package works, for its
users, is [architecture](architecture.md).

## Settled

- **After goose-sqlite.** SQLite needs no network code; this package waits on outbound
  connections in goose-http (2026-10-19).
- **SCRAM-SHA-256's hashes from goose-hash (2026-10-19).** SHA-256, HMAC, and PBKDF2
  come from that package, which WebSocket and JWT share.
- **The protocol in Goose, not libpq.** The wire protocol is message framing and type
  decoding, the byte work Goose is measured on. libpq does its own socket I/O, and in
  the Goose packages sockets are goose-http's. HttpArena's `async-db` rules also ask for
  an async driver with a pool of `DATABASE_MAX_CONN` connections (256 at `2d85137`,
  2026-10-18), which blocking calls on a lane can't give without a thread per
  connection. The cost is a client to write and keep correct, where libpq is the
  reference (2026-10-19).
- **The protocol without I/O.** As in goose-tls, a connection's state takes the bytes
  the program read and appends the bytes to send. The package opens no socket and
  never blocks, so one protocol serves three callers: goose-http's loop on epoll,
  io_uring, kqueue, and IOCP; the blocking facade below; and the tests, which replay
  bytes recorded from a server. It rejects an API that owns its sockets, which would
  tie the package to one of those (2026-10-19, goose-rest's task 052).
- **A blocking facade over the protocol, for lane jobs.** A use case that runs several
  queries, with business rules between them, runs as one job on a goose-rest lane and
  calls the facade, which sends, waits on the lane's socket, and returns rows, so its
  code reads top to bottom as in Hono, Elysia, or Spring. Its cost stays one job per
  use case, however many queries it runs. The alternative, each query a wait on the
  worker's loop, adds a request state per query to the route, and a repository
  function that runs two queries could no longer be called from a service function.
  A lane runs no event loop, so the facade's socket blocks (2026-10-19, goose-rest's
  task 052).
- **Single queries on the worker's loop.** A route that runs one query, as HttpArena's
  `/async-db` does, sends it on a connection the worker's loop owns and resumes when
  the rows arrive, with no lane between. That is the path HttpArena measures, and a
  lane would add two queue hops to it. The pool sits on goose-http's outbound
  connections (its task 053) (2026-10-19, goose-rest's task 052).
- **Pipelining in the protocol.** A program may queue many queries, each closed by a
  sync or sharing one, before reading any result; the server answers in order. Each
  queued entry (a parse, a query, or a sync) gets a sequence number, and the results
  come back as events carrying it, ending in exactly one of `PARSED`, `DONE`,
  `SUSPENDED`, `ERROR`, `SKIPPED`, or `READY`. After an error the server skips the
  rest of that sync's entries, and the protocol reports each one `SKIPPED`, so a
  caller matches every query to its outcome. The facade builds queries "in parallel"
  on one connection on it, as `Promise.all` does, in one round trip and without a
  connection per query (2026-10-19, goose-rest's task 052).
- **A transaction is a block whose failure path the compiler checks.**
  `pg::transaction(db) { tx => ... }` runs the block between `BEGIN` and `COMMIT`;
  `pg::fail`, and every facade call that fails, does `return e from` the catcher
  inside it, which rolls back and returns the error. A function that calls `pg::fail`
  compiles only where a transaction or `pg::run` encloses its calls: TypeScript
  libraries' convention of the transaction as the last parameter, enforced. It follows
  goose-rest's `rest::route` and `rest::fail` and goose-sqlite's `sqlite::transaction`.
  Goose can't name the block's result type before calling it, so a block that returns
  a value names a fixed-size type at the call, `pg::transaction<Order>(db) { ... }`,
  and one that builds a non-fixed value writes it into the caller's variables; the
  facade's task settles the form. It rejects errors returned by value through each
  repository function, which a caller can forget to check, and the stdlib's
  `exception`, for goose-sqlite's reason: a program's own `try` would catch the
  package's errors at the wrong type (2026-10-19, goose-rest's task 052).
- **The facade's API follows goose-sqlite's; the protocol's doesn't.** `pg::run`,
  `pg::fail`, `pg::transaction`, and the `Error` they carry match goose-sqlite's, so a
  program's data access reads the same on either database. The protocol is events over
  bytes, which SQLite's synchronous calls have no counterpart for (2026-10-19).
- **The package is `pg`.** The entry is `pg.goose`, and programs write `pg::`, as task
  052's sketch does (2026-10-19).
- **The extended query protocol only.** Each query is `Bind`, `Describe` of the
  portal, and `Execute`, on a statement that `Parse` prepared, named or unnamed. The
  simple query protocol's `Query` isn't sent: it takes no parameters, and the several
  statements one message may hold can't be matched to entries. `BEGIN` and `COMMIT`
  go through `Parse` like any statement (2026-10-19).
- **Parameters as text, results in text or binary per query.** `Bind` sends every
  parameter in the text format, which the server converts to whatever type it inferred
  for `$n`. A binary parameter must match that type's width exactly, which the caller
  would have to know: in HttpArena's query `LIMIT $3` is `int8` and `price BETWEEN $1`
  is `int4`. The results' format is the caller's choice, one for all of a query's
  columns. Binary decodes integers without parsing; both decode to the same values
  (2026-10-19).
- **Every query describes its portal.** The `RowDescription` it brings gives the
  column types and formats the decoders read, per query, so pipelined queries on
  different statements decode right. It costs the server about 25 bytes per column per
  query; skipping it for a statement whose description the caller holds is the
  pipelining task's (2026-10-19).
- **The caller supplies SCRAM's client nonce.** The package does no I/O and has no
  source of entropy, and a nonce from the caller makes a recorded exchange replayable
  in tests. The cost: a caller that passes predictable bytes weakens SCRAM against an
  active attacker, so the facade and the pool take them from the system (2026-10-19).
- **Authentication by SCRAM-SHA-256 or a cleartext password only.** Postgres hashes
  passwords with SCRAM by default since version 14, and HttpArena's Postgres 18
  container authenticates with it. Cleartext serves `password` lines in
  `pg_hba.conf`. MD5, deprecated from Postgres 18, fails with a message, as do
  Kerberos, GSSAPI, SSPI, and `SCRAM-SHA-256-PLUS`, which needs TLS's channel binding.
  The password goes into SCRAM as given, without SASLprep, which changes nothing for
  printable ASCII (2026-10-19).
- **A fixed-size connection state.** `pg::Conn` holds the queue of waiting entries
  (1,024), the current columns (up to 128), and the authentication state inline, so a
  pool keeps its connections in one array of slots. A row with more columns, or more
  entries queued, is a limit for the program to raise, not a reallocation
  (2026-10-19).
- **Tests replay bytes recorded from Postgres 18, the version HttpArena runs.** Each
  test program talks to the server through a small relay: under `test/run_tests.py` it
  replays a capture from `test/data/`, checking each message the client sends against
  the recorded one, and in the live run `scripts/relay.py` connects it to a Postgres in
  Docker and can record a new capture. The relay is test-only Python, because Goose has
  no sockets outside goose-http and the package keeps none (2026-10-19).

## Open

- How the facade's socket is opened and blocks: goose-http's outbound connections
  with a blocking mode for lanes, or a socket module of goose-http's for threads that
  run no loop. goose-http's task 053 decides.
