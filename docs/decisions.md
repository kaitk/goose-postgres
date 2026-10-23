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
  printable ASCII (2026-10-19). Cleartext is opt-in since 2026-10-19 (below).
- **A cleartext password only when the settings allow it, and never after SCRAM.**
  `Config.allow_cleartext`, `false` by default, decides whether the client answers a
  server's request for the password in cleartext (authentication code 3); without it
  the connection breaks with a reason, as libpq's `require_auth` refuses a method.
  Without TLS, any server or anyone on the path could otherwise ask for the password
  and read it. A request after SCRAM began is refused whatever the setting, since a
  server that proved, or started proving, it knows the password has no reason to ask
  for it again: `Conn` records that SCRAM began. The cost: a `password` line in
  `pg_hba.conf` needs the program to set the field, and a URL can't set it. This
  amends the decision above, which answered every cleartext request (2026-10-19).
- **A URL's `sslmode` is read, and TLS modes are refused.** `parse_url` accepts
  `sslmode` `disable`, `allow`, and `prefer`, and none, all of which connect without
  TLS, and fails on `require`, `verify-ca`, and `verify-full`, and on other values;
  the facade's `connect` and `open` then fail with `"08001"` and a message saying TLS
  isn't supported yet. A program that asked for TLS must not get a connection in the
  clear without knowing. The query string's other parameters are still ignored
  (2026-10-19).
- **SCRAM's iteration count is capped at 1,000,000.** The client's PBKDF2 time grows
  with the count the server sends, so a hostile server could stall a connection, or a
  lane, for as long as it likes. Postgres's default is 4096; a count above the cap
  breaks the connection with a reason. The cost: a server set above 1,000,000
  iterations can't be reached (2026-10-19).
- **A cap on a message's size, per connection: `Config.max_message`, 64 MB by
  default.** A server, or anyone between it and a client without TLS, could announce
  a message of nearly 1 GB, Postgres's limit on a field, on every connection, and the
  facade would hold that much input for each: a pool of 256 connections, or many
  lanes, could be made to hold far more than the host has. `step` checks the length in
  a message's head against the cap the connection took from its `Config` at `start`,
  and breaks the connection with a reason before any caller grows a buffer for the
  rest. One check in the protocol layer covers the facade, and any caller that grows
  its input only as `step` reads it. The check sits in `Conn` rather than in the
  facade's `Db`, so callers of the protocol get it too, and in `Config`, since
  `start` resets `Conn`. 64 MB is far above any row a web program reads (HttpArena's
  50 rows are about 8 KB) and a sixteenth of the 1 GB limit; `MAX_MESSAGE` stays the
  most a program may set. The cost: a program that reads larger rows, such as big
  `bytea` values, must raise it (2026-10-23, task 006).
- **A NUL byte in a name or SQL is refused before anything is sent.** The protocol's
  strings end at a NUL, so `x\0options\0-c` as a user would add startup options the
  program never meant. The protocol layer does no I/O and has no error return in its
  writers, so a writer given such a string appends nothing for its message and breaks
  the connection with a reason: `start` for the user or database, `parse` for the
  name or SQL, which returns -1, and `execute` for a `bind` whose names hold one,
  which returns -1 and drops the Bind from `out`. The facade checks first, so its
  connection stays usable: SQL with a NUL fails the call with `"22021"`, Postgres's
  own code for a NUL in text, and settings with one fail `connect` with `"08001"`.
  `parse_url` refuses a `%00` or a raw NUL in any part. It rejects aborting, as
  queuing past `QUEUE` does, since the strings may come from a request, and a bool
  result on each writer, which changes every caller for a case they rarely meet
  (2026-10-19).
- **A statement the server dropped makes the facade forget its statements.** `DISCARD
  ALL` and `DEALLOCATE ALL`, which a program or a pooler in front of the server may
  run, drop the statements the facade prepared, and the next call on one fails with
  `"26000"` (`invalid_sql_statement_name`). On that error the facade forgets them
  all, so the call after prepares again. The call that found out still fails, rather
  than retry: inside a transaction the error has already aborted it, and a retry
  there would fail too. It rejects tracking those commands in the SQL the
  facade sends, which misses them when another client or a pooler runs them
  (2026-10-19).
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
  overloads, in an optional module of this package that imports goose-http, as
  `http.tls` does goose-tls, so only programs that import that module declare
  goose-http (agreed 2026-10-19, over the adapter in goose-http or in each program).
  It rejects a socket opened
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
  databases (2026-10-19; kept as text, agreed 2026-10-19).
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
- **Parameters are a query's trailing arguments, up to eight, or a `pg::Params`
  list.** Each is bytes, an integer, a bool, or `pg::NULL`, sent in the text format as
  the protocol's `param` sends it. Goose has neither variadic functions nor defaults
  for untyped parameters, so `query` and `exec` have an overload per count from 0 to
  8, the shorthand. For more, or for a list built in a loop, `var p = pg::Params
  { .. }; pg::param(p, v); ... pg::query(db, sql, p) { r => ... }`, and
  `pg::exec(db, sql, p)`, take up to 65535 parameters, Postgres's limit (agreed
  2026-10-19). `Params` is `{ count, bytes: u8[>..] }`: each parameter is kept
  already encoded as `Bind` writes it, its 32-bit length and its text, in the one
  resizable field a struct may have, so a call copies the list into its `Bind` in
  one append, and a list costs one buffer however many it holds. The same `param`
  overload that adds a value to a `Bind` takes a `Params`, so no `query` overload is
  added for it. Adding a parameter past 65535 aborts, as queuing past `QUEUE` does:
  the count can't fit `Bind`'s 16-bit field. It rejects an array of tagged values,
  one element per parameter, which an ADT array would store with a tag and a
  variable-size payload each and encode again at every call (2026-10-19).
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
  integers; the pool, which HttpArena measures, chooses its own format. Text stays
  until a measurement on the facade shows binary matters (agreed 2026-10-19).
- **A failed call leaves the connection ready for the next.** A server's error is
  held until the sync's `READY`, then fails the call, so the next call starts on an
  idle connection. A failure that leaves a call early, from the row block or from a
  transaction's catcher, leaves answers unread, and the next call reads and drops
  them before it sends. A transport that fails, a FATAL error, or a protocol break
  marks the connection broken: every later call fails with `"08003"` until
  `pg::connect` runs on a new transport. `pg::close` sends `Terminate` and closes the
  transport, and never fails, so it runs after any error (2026-10-19).
- **goose-http's outbound socket serves both the facade and the pool.** goose-http's
  task 053 answered what a lane gets (2026-10-19): blocking calls, each with a time
  limit in milliseconds (-1 for none), that report failure by their result rather
  than abort. `http::connect(host, port, ms) -> Socket, Error` opens the connection,
  `http::send_all(s, data, ms) -> Error` sends all of `data`, `http::recv(s, buf, ms)
  -> i64` waits for bytes and returns how many it put into `buf`, 0 once the server
  closed, `-ETIMEDOUT`, or `-code`, and `http::hangup(s&)` closes it. A host is
  `localhost`, an IP address, or `unix:PATH` for a Unix socket. `http::Socket` is a
  fixed-size handle, `{ fd }`, so `Db` holds it by value, and the facade's three
  overloads map onto `send_all`, `recv`, and `hangup`. `recv` fills a slice, not a
  growing buffer, so the overload grows the input before it reads. Task 005's pool
  uses the same socket on the worker's loop, without blocking: `http::connect_start`,
  `http::wait_socket` until the socket is readable or writable, then the
  non-blocking `http::recv(s, buf)` and `http::send(s, data)`. goose-http runs that
  half on `serve_epoll` only; `serve`'s loops fail `wait_socket` with `ENOSYS`.
- **A lane opens its connection with `pg::open`, in module `pg.socket`.** The module
  `socket.goose` declares `pg::Socket`, `{ s: http::Socket, ms }`, with the three
  overloads, and `pg::open(db, cfg or url, ms)`, which closes `db` when it is open,
  connects the socket, and runs `pg::connect`:
  `var db = pg::Db { t: pg::Socket { .. }, .. }; pg::run() { pg::open(db, cfg, 5000);
  ... }`. A connect that fails fails `open` through `pg::run`, with
  `"08001"` and goose-http's call and error, so the program learns why, where a
  transport that couldn't connect would fail the first send with only "sending to the
  server failed". The one call also makes a broken connection again. `ms` limits each
  wait, the connect, every send, and every receive, so a query that runs longer than
  `ms` before its first byte arrives breaks the connection; `-1` waits without limit.
  A host that starts with `/` is a directory holding the server's Unix socket,
  `.s.PGSQL.<port>`, as in libpq, which `open` passes to goose-http as `unix:PATH`.
  It rejects `pg::socket(cfg, ms) -> Socket`, built in `Db`'s initializer outside
  `pg::run`, which can't fail with a reason and leaves the reconnect to the program
  (2026-10-19).
