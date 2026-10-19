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
  `pg::fail`, `pg::transaction`, and the `Error` they carry, but for its code's type
  (below), match goose-sqlite's, so a program's data access reads the same on either
  database. The protocol is events over
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
  active attacker, so the facade and the pool take them from the system, through
  goose-hash's `hash::random_bytes` (2026-10-19).
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
- **The facade runs over a transport the caller supplies.** `pg::Db<T>` holds a
  transport of any fixed-size type `T`, and the facade calls three functions on it by
  name: `pg::send(t, bytes) -> bool`, which sends all of `bytes`;
  `pg::receive(t, into) -> bool`, which waits and appends at least one byte; and
  `pg::close(t)`. `false` means the connection is gone, and the facade turns it into an
  error through `pg::run`. Goose checks a generic body per instantiation and resolves
  its names where it is defined, so the overloads for `T` are declared into namespace
  `pg` (`fn pg::send(t: Socket&, ...)`) by whoever provides `T`, as goose-http's loop
  reaches TLS through overloads that its module `http.tls` adds. The package keeps no
  socket and imports no goose-http; the tests' transport replays captures and runs live
  through the relay (`test/wire.goose`), and a faked server tests the failures
  (`test/fake.goose`). goose-http's blocking socket plugs in with three one-line
  overloads, in a module of this package that imports goose-http, as `http.tls` does
  goose-tls, so only programs that use it declare goose-http. It rejects a socket opened
  by the facade, which would make the package depend on goose-http before goose-http's
  task 053 settles that socket, and function values the caller passes, which Goose
  can't store in `Db` (spec §7.6). The cost: a transport's overloads live in another
  package's namespace, and a type without them fails to compile where the facade
  calls them, with "no matching overload for call to send" (2026-10-19).
- **An error's code is the SQLSTATE, as text.** `pg::Error` is `{ code: u8[..5],
  message: u8[] }`, goose-sqlite's two fields, with the code as Postgres sends it,
  such as `"23505"`. SQLSTATEs have letters (`"28P01"`, `"P0001"`, `"XX000"`), so an
  integer would need an encoding a program decodes before comparing against
  Postgres's documentation, and the code would print as a number nobody can look up.
  Constants name the codes a program tests for (`pg::UNIQUE_VIOLATION`), and
  `pg::class(code)` gives the class, `"23"`, as `sqlite::primary` gives SQLite's
  primary code. The facade's own errors take SQLSTATEs too: `pg::fail(message)`
  raises `"P0001"`, Postgres's `raise_exception`; a transport that fails, or a server
  that breaks the protocol, `"08006"`; a call on a connection that broke or isn't
  open, `"08003"`; a server that ends the connection with an error, its own code. The
  cost: comparing codes compares five bytes, not one integer, and `Error.code` has
  another type than goose-sqlite's, so code that tests codes differs between the two
  databases (2026-10-19).
- **A query hands each row to a block.** `pg::query(db, sql, params...) { r => ... }`
  calls the block with a `pg::Row` for each row as it arrives, and returns the count.
  A row is a view into the connection's input, valid inside the block, so a large
  result is never held whole, and the block copies what it keeps into the caller's
  variables, as goose-sqlite's `step` loop does. Goose itself rejects a facade call on
  the same connection inside the block ("it shrinks db while db is still used"),
  since the next call reuses the bytes the row views. It rejects collecting rows into
  an array the facade returns, which would allocate every row, and an iterator the
  caller steps, which Goose's lack of stored function values and of references held
  across calls makes awkward (2026-10-19).
- **Parameters are a query's trailing arguments, up to eight.** Each is bytes, an
  integer, a bool, or `pg::NULL`, sent in the text format as the protocol's `param`
  sends it. Goose has neither variadic functions nor defaults for untyped parameters,
  so `query` and `exec` have an overload per count from 0 to 8. A statement with more
  parameters goes through the protocol's `bind` and `param`. It rejects an array of
  tagged values, which every call would build (2026-10-19).
- **Statements are prepared once per connection, by name.** The first time a
  connection runs a SQL text, the facade sends `Parse` with the name `gp<k>`, in the
  same write as the query, and keeps the text once the server answers `PARSED`; later
  runs send only `Bind` and `Execute`. A parse that fails isn't kept. `Db` keeps up to
  `STATEMENTS` (64) names and `STATEMENT_TEXT` (16 KB) of SQL inline, since a struct
  has one resizable field and the input is it; past either, a query parses as the
  unnamed statement each time, which costs a parse but stays correct. Prepared
  statements outlive a rolled-back transaction in Postgres, so a savepoint's
  `ROLLBACK TO` loses none of them. A connection made again forgets them
  (2026-10-19).
- **The facade asks for rows in the text format.** Every type then reads as
  `pg::text`, including those the decoders don't know yet (`numeric`, dates, `uuid`),
  where binary would give bytes a program would have to decode. Binary saves parsing
  integers; the pool, which HttpArena measures, chooses its own format (2026-10-19).
- **A failed call leaves the connection ready for the next.** A server's error is
  held until the sync's `READY`, then fails the call, so the next call starts on an
  idle connection. A failure that leaves a call early, from the row block or from a
  transaction's catcher, leaves answers unread, and the next call reads and drops
  them before it sends. A transport that fails, a FATAL error, or a protocol break
  marks the connection broken: every later call fails with `"08003"` until
  `pg::connect` runs on a new transport. `pg::close` sends `Terminate` and closes the
  transport, and never fails, so it runs after any error (2026-10-19).

## Open

- What goose-http's task 053 offers a lane: a blocking client socket, opened to a
  host and port with a timeout, that sends all of a buffer, receives what has arrived
  into a growing buffer (waiting for at least one byte, with a timeout), and closes,
  each reporting failure by its result rather than aborting. The facade's three
  overloads map onto those calls one to one. Its type must be a fixed-size value, such
  as a handle, since `Db` holds it by value.
