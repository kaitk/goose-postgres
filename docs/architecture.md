# Architecture

How goose-postgres works, for its users. The decisions behind it, each with its reason
and what it rejected, are in [decisions](decisions.md).

## Layers

The package is PostgreSQL's frontend/backend protocol, version 3.0, in Goose, with no
I/O: a connection's state, `pg::Conn`, appends the messages to send to a buffer the
caller owns, and reads the server's messages from bytes the caller received. The
caller owns the socket, so the same protocol runs under goose-http's event loop, under
a blocking socket, or under a test that replays recorded bytes.

Two layers go on top of it:

- **A blocking facade, for lane jobs** ([below](#the-facade)). A Plod use case
  that runs several queries runs as one job on a lane and calls `pg::query`,
  `pg::exec`, `pg::run`, and `pg::fail`, as goose-sqlite's API does, so its code
  reads top to bottom. It sends and waits on a transport: goose-http's blocking
  socket, through the module `pg.socket`, or one the caller supplies. The
  transaction block and queries "in parallel", pipelined on one connection, are
  still to come.
- **A pool on the worker's loop**, not built yet. A route that runs one query, as
  HttpArena's `/async-db` does, sends it on a connection that goose-http's loop owns,
  through its outbound connections, and resumes when the rows arrive.

## The API

All of it is in namespace `pg`: `pg.goose` holds the connection, the messages the
client writes, and `step`; `scram.goose` the authentication; `decode.goose` the
readers of rows; `url.goose` the settings; `facade.goose` the blocking facade. The
module `socket.goose`, which a program imports as `pg.socket`, is the facade over
goose-http's socket; it is the only part that needs goose-http.

### Settings

- `pg::Config`: `host`, `port` (5432), `user`, `password`, and `database`, each a
  fixed-size field, and `allow_cleartext` (`false`), whether the server may ask for
  the password in cleartext ([Authentication](#authentication)). The host and port
  are for the caller's socket. The connection zeroes its own copy of the password
  once used; the `Config` still holds it, and clearing that is the caller's.
- `pg::parse_url(url) -> Config, bool`: reads
  `postgres://user:password@host:port/database?sslmode=mode` or `postgresql://...`,
  percent-decoding each part but the host, which may be an IPv6 address in brackets.
  The host defaults to `localhost`, the port to 5432, and the database to the user's
  name. `false` for anything else, a part longer than the field (255 bytes for the
  host and password, 63 for the user and database, Postgres's limit on a name), or a
  part with a NUL byte, `%00` or raw.
- `sslmode` may be `disable`, `allow`, or `prefer`, or absent, which all connect
  without TLS. `require`, `verify-ca`, `verify-full`, and any other value make
  `parse_url` return `false`, and the facade's `connect` and `open` fail with
  `"08001"` and a message saying TLS isn't supported yet. The query string's other
  parameters, such as `application_name` or `connect_timeout`, are ignored.
  `pg::url_settings(url) -> Config, const u8[:]` gives the reason a URL can't be used,
  or `""`.

### A connection

- `pg::Conn { .. }`: a fixed-size value, so a pool keeps its connections in an array.
- `pg::start(c, out, cfg, nonce)`: starts `c` over and appends the startup message to
  `out`: protocol 3.0, the user, the database, and `client_encoding` `UTF8`, so every
  text arrives as UTF-8. It keeps the password until authentication uses it. `nonce`
  is SCRAM's client nonce: at least 18 bytes from a secure random source, new for each
  connection, such as goose-hash's `hash::random_bytes`, which `pg::connect` uses;
  the protocol layer has no source of its own. A user or database with a NUL byte
  breaks `c` with a reason and leaves `out` unchanged ([Strings](#strings)).
- `pg::step(c, input, out) -> i64, const u8[:]`: reads the server's messages from the
  front of `input`, appends any reply authentication needs to `out`, and returns at the
  next event with the body of the message it came from, a slice of `input`. `c.used`
  is how much of `input` it consumed: pass the rest next time. It consumes what it can
  without an event, such as ParameterStatus and the authentication exchange, and
  returns `WANT_INPUT` when no whole message is left, with `c.need` the size of the
  next message, so the caller knows how much to read.
- `pg::ready(c)`: whether `c` is authenticated and hasn't failed.
- `pg::room(c)`: how many more entries may be queued.
- `c.status`: ReadyForQuery's transaction status, `'I'` idle, `'T'` in a transaction,
  `'E'` in a failed one. `c.pid` and `c.secret`: the backend's key, for a cancel
  request. `c.reason`: why `c` failed.

A caller's loop, with its own socket:

```goose
var c = pg::Conn { .. };
var out: u8[>..] = [];
var input: u8[>..] = [];
pg::start(c, out, cfg, nonce);
send(out); out.clear();
var at = 0;
loop {
    let e, body = pg::step(c, input[at..], out);
    at += c.used;
    if out.len > 0 { send(out); out.clear(); }
    if e == pg::WANT_INPUT { receive(input); continue; }   // the program's own I/O
    if e == pg::READY { break; }
    if e == pg::FAILED { print(c.reason, ": ", pg::field(body, 'M')); return; }
}
```

### Entries

A query is queued as entries, and the server answers them in order. Each function that
queues one returns its number, counted from 0 on each connection:

- `pg::parse(c, out, name, sql) -> i64`: prepares `sql` as the statement `name`, or
  as the unnamed statement for `""`, which the next `parse` of `""` replaces. The server
  infers the parameters' types. Its event is `PARSED`.
- `pg::bind(out, statement, portal = "") -> Bind`: starts a query on `statement`.
  Then, in order, each parameter, in the text format:
  `pg::param(out, b, v)` takes bytes as they are, an `i64` in decimal, or a `bool` as
  `t` or `f`, and `pg::param_null(out, b)` a NULL. The server converts each to the type
  it inferred for `$n`.
- `pg::execute(c, out, b, format = TEXT, max_rows = 0) -> i64`: ends the query with
  its results' format, `pg::TEXT` or `pg::BINARY` for all its columns, describes its
  portal, and executes it for at most `max_rows` rows, 0 for all. Its events: `COLUMNS`
  for a query that returns rows, a `ROW` per row, then `DONE`, or `SUSPENDED` at
  `max_rows`.
- `pg::sync(c, out) -> i64`: ends the entries since the last sync. Those run in one
  implicit transaction, unless a `BEGIN` among them opened one, and the server sends
  nothing for them until it gets the sync or a flush. Its event is `READY`.
- `pg::terminate(out)`: ends the session; close the socket after sending it.

`QUEUE` (1,024) entries may wait at once; queuing more aborts the program, so a caller
that pipelines without bound checks `pg::room`. The writers append to `out` and send
nothing, so any number of queries, each with its sync or several to one, go out in one
write.

#### Strings

The protocol's strings end at a NUL byte, so a name or SQL holding one would end early
and let the rest pass as the message's next fields. A writer given one appends nothing
for its message and breaks `c`, with `c.reason` saying why: `parse` returns -1 for a
name or SQL with a NUL, and `execute` returns -1, and drops the `Bind` and its
parameters from `out`, for a `bind` whose statement or portal name has one. Don't send
`out` after either. Parameters are sent with their length, so they may hold any byte.

### Events

`step` returns these, and `c.seq` is the number of the entry each belongs to:

| Event | Message | Body |
|---|---|---|
| `WANT_INPUT` | none | empty |
| `READY` | ReadyForQuery: a sync's answers are all in, or startup is done (`c.seq` -1) | the status byte |
| `PARSED` | ParseComplete | empty |
| `COLUMNS` | RowDescription | the columns, for `pg::column_name` |
| `ROW` | DataRow | the row, for the readers below |
| `DONE` | CommandComplete, or EmptyQueryResponse for an empty query | the command tag, such as `SELECT 5`, NUL-terminated |
| `SUSPENDED` | PortalSuspended | empty |
| `ERROR` | ErrorResponse | its fields, for `pg::field` |
| `SKIPPED` | none: the server skipped the entry after an earlier error | empty |
| `NOTICE` | NoticeResponse: `c.seq` is the entry it arrived during | its fields |
| `FAILED` | the connection can't go on | a server's ErrorResponse, or empty |

Every parse and query ends in exactly one of `PARSED`, `DONE`, `SUSPENDED`, `ERROR`,
or `SKIPPED`, and every sync in `READY`, in the order they were queued, so a caller
matches each to its outcome by number. After an error, the server skips the rest of
that sync's entries, and `step` reports each one `SKIPPED` before the sync's `READY`;
the entries after the sync run. An error the server raises at a sync itself, such as a
deferred constraint's at the implicit transaction's commit, comes as `ERROR` with the
sync's number, before its `READY`. NotificationResponse, ParameterStatus, and
NegotiateProtocolVersion are consumed without an event, except a ParameterStatus that
reports `client_encoding` as anything but `UTF8`, as `SET client_encoding` makes the
server send, which fails the connection: the readers take every text as UTF-8.

`FAILED` means the connection is done: authentication failed or was refused, the
server sent a FATAL error, it changed `client_encoding`, or it broke the protocol, as
with a message that doesn't fit the entry waiting or a length out of range. Every later `step` returns `FAILED` too.
Close the socket.

### Reading rows

After `COLUMNS`, the readers know each column's type and format; after `ROW`, where
each field is in its body:

- `pg::column_count(c)`, `pg::column_type(c, i) -> u32` (an OID, such as
  `pg::OID_INT4`), `pg::column_format(c, i)`, and `pg::column_name(body, i)` from
  `COLUMNS`'s body.
- `pg::columns_are(c, [pg::OID_INT4, pg::OID_TEXT, ...])`: whether the columns have
  exactly these types, a check to make once at `COLUMNS`, so that its rows decode
  without one.
- `pg::field_count(c)` and `pg::is_null(c, i)`.
- `pg::int(c, row, i) -> i64`: an `int2`, `int4`, or `int8`, in either format.
- `pg::boolean(c, row, i) -> bool`: a `bool`, in either format.
- `pg::text(c, row, i) -> const u8[:]`: a `text`, `varchar`, `bpchar`, `name`,
  `json`, or `jsonb`, in either format. Binary `jsonb`'s version byte is dropped, so
  `jsonb` gives its JSON text either way, as Postgres formats it.
- `pg::bytes(c, row, i) -> const u8[:]`: a field as the server sent it, for any other
  type.

A NULL reads as 0, false, or empty, and so does a field `i` outside the last `ROW`,
below 0 or from `pg::field_count(c)` on, which `pg::is_null` reports as NULL; a column
outside the last `COLUMNS` has type 0 and format `TEXT`. `int` gives 0 for text that
isn't an integer;
`columns_are` is the check against reading a column as the wrong type. The slices
point into the row's body, which is in the caller's input: read them before reusing
it.

- `pg::field(body, code) -> const u8[:]`: a field of an ErrorResponse's or
  NoticeResponse's body: `'C'` the SQLSTATE code, `'M'` the message, `'V'` the
  severity, `'D'` the detail. Empty when it has none.
- `pg::rows(tag) -> i64`: the count in `DONE`'s tag: 5 for `SELECT 5` or `INSERT 0 5`.

## The facade

The facade runs the protocol for a thread that runs no event loop, such as a
Plod lane: each call writes its entries, sends them, waits for the answers, and
returns. A call that fails leaves through `return ... from pg::run`, so every call
that can fail runs inside a `pg::run`, or the program doesn't compile.

```goose
var db = pg::Db { t: pg::Socket { .. }, .. };   // goose-http's socket, below
var names: u8[>..] = [];
let failed = pg::run() {
    pg::open(db, cfg, 5000);                     // connects, then logs in
    pg::query(db, "SELECT id, name FROM items WHERE price < $1", 50) { r =>
        format(names, pg::int(r, 0), " ", pg::text(r, 1), "\n");
    };
    let n = pg::exec(db, "UPDATE items SET quantity = quantity - $1 WHERE id = $2", 1, 7);
};
for e in failed { print(e.code, ": ", e.message); }
pg::close(db);
```

### goose-http's socket

A program on a lane imports the module `pg.socket`, and declares goose-http in its root
file, at the reference `socket.goose` names: a full commit hash while goose-http's
outbound connections aren't in a tag ([development](development.md#the-goose-http-pin)).

```goose
import pg from "github.com/kaitk/goose-postgres@<tag>";
import http from "github.com/kaitk/goose-http@d5bc0fd6a2e5a703d6f9348da7692329f47fadc2";
import pg.socket;
```

A program that imports `pg` without `pg.socket` needs no goose-http, and one that
imports `pg.socket` without declaring goose-http fails to compile with "pg needs the
package http".

- `pg::Socket`: goose-http's `http::Socket` and `ms`, the limit in milliseconds on each
  wait. Build it empty, `pg::Socket { .. }`, in `pg::Db { t: pg::Socket { .. }, .. }`.
- `pg::open(db, cfg, ms)`, or `pg::open(db, url, ms)`: closes `db` if it is open,
  connects to the `Config`'s host and port within `ms` (-1: no limit), and runs
  `pg::connect`. A connect that fails fails with `"08001"` and the reason, such as
  `can't connect to 127.0.0.1 port 5432: connect ECONNREFUSED`. Call it again to
  connect again after the connection broke.
- The host is `localhost` or an IP address; goose-http resolves no other names yet,
  and fails one with `ENOSYS`. A host that starts with `/` is the directory of the
  server's Unix socket, `.s.PGSQL.<port>`, as in libpq, such as
  `/var/run/postgresql`, on Linux and macOS. `pg::parse_url` doesn't decode a host, so
  set `cfg.host` to the directory.
- `ms` bounds each send and each receive as well as the connect: a query whose first
  result takes longer than `ms` fails with `"08006"` and breaks the connection. Pass
  -1 for a lane that runs long queries.
- Keep one `Db` per connection, and don't copy a `Db` or a `pg::Socket`: a copy keeps
  the socket's fd number after the original closes, and the OS may give that number
  to the next connection the process opens.

### The transport

The facade sends and receives through a value of the caller's, `db.t`, of any
fixed-size type `T`, such as `pg::Socket`. It calls three functions on it, which
whoever provides `T` declares into namespace `pg`:

```goose
fn pg::send(t: T&, bytes: const u8[:]) -> bool    // sends all of bytes; false if it can't
fn pg::receive(t: T&, into: u8[>..]&) -> bool     // waits for at least one byte and
                                                  // appends what arrived; false when
                                                  // the connection closed or failed
fn pg::close(t: T&)                               // closes it; never fails
```

The caller opens its transport to the `Config`'s host and port before
`pg::connect`, and the transport's own timeouts bound each wait. `pg.socket` declares
the three for `pg::Socket`. The tests have two more: `test/wire.goose` replays
captures and runs live through the relay, and `test/fake.goose` fakes a server in the
program.

### Calls

- `pg::Db<T>`: a connection: the transport `t`, the protocol's `Conn` as `c`, the
  statements prepared on it, and the bytes received, which end it, so a struct that
  holds a `Db` holds it last. Build it with `pg::Db { t: transport, .. }`.
- `pg::connect(db, cfg)`, or `pg::connect(db, url)`: starts the session,
  authenticates, and returns when the server is ready. SCRAM's nonce is 18 bytes from
  goose-hash's `hash::random_bytes`. `pg::connect(db, cfg, nonce)` takes the nonce
  given, for a test that replays a recorded session. A connection made again forgets
  its statements.
- `pg::query(db, sql, p1, ..., p8) { r => ... } -> i64`: runs `sql` with up to eight
  parameters, for `$1` to `$8`, calls the block with each row, and returns the
  count. A parameter is bytes, an integer, a bool, or `pg::NULL`, each sent as text,
  which the server converts to the type it inferred for its `$n`.
- `pg::exec(db, sql, p1, ..., p8) -> i64`: runs `sql` as `query` does, drops any rows,
  and returns the count in its command tag: the rows an `INSERT`, `UPDATE`, or
  `DELETE` changed, or a `SELECT` returned; 0 for a command without one, such as
  `CREATE TABLE`.
- `pg::close(db)`: sends `Terminate`, when the session is open, and closes the
  transport. It never fails, so it runs anywhere, after an error too.
- `pg::in_transaction(db) -> bool`: whether the last call left the connection in a
  transaction, failed or not, from ReadyForQuery's status.
- `pg::run() { ... } -> pg::Error[]`: runs the block, and returns an empty array, or
  the error a call inside it failed with. The innermost `run` catches.
- `pg::fail(message)` and `pg::fail(code, message)`: leave the innermost `run` with
  the program's own error, `pg::RAISE_EXCEPTION` (`"P0001"`) or `code`.

For more than eight parameters, or a list built in a loop, a `pg::Params` holds them:

```goose
var p = pg::Params { .. };
for id in ids { pg::param(p, id); }       // bytes, an integer, a bool, or pg::NULL
pg::query(db, sql, p) { r => ... };       // or pg::exec(db, sql, p)
```

It holds up to 65535, Postgres's limit; adding more aborts. `p.count` is how many it
holds. Each is kept encoded, as `Bind` sends it, so a call copies the list in one
append.

### Rows

A query's block gets a `pg::Row`, a view into the connection's input, valid only
inside the block: copy what is kept. Its fields read as the protocol's readers do,
by their column's type, in the text format:

- `pg::int(r, i)`, `pg::boolean(r, i)`, `pg::text(r, i)`, `pg::bytes(r, i)`, and
  `pg::is_null(r, i)`;
- `pg::field_count(r)` and `pg::column_type(r, i)`.

`pg::text` reads any type, such as `numeric` or a date, as Postgres formats it. A
facade call on the same connection inside the block doesn't compile: Goose reports
"it shrinks db while db is still used", since the call reuses the bytes the row
views. Read the rows into variables, then run the next query.

### Statements

The first time a connection runs a SQL text, the facade prepares it as a named
statement, `gp<k>`, in the same round trip as the query; later runs send only its
parameters. A text that fails to parse isn't kept. A `Db` keeps up to `STATEMENTS`
(64) statements and `STATEMENT_TEXT` (16 KB) of their SQL; past either, a query
parses as the unnamed statement each time it runs. A schema change can make a kept
statement fail with `"0A000"` ("cached plan must not change result type"); connect
again to drop them. `DISCARD ALL` and `DEALLOCATE ALL`, run by the program or by a
pooler in front of the server, drop them on the server: the next call on one fails
with `"26000"`, and the facade then forgets them all, so the calls after it prepare
them again.

### Errors

`pg::Error` is `{ code: u8[..5], message: u8[] }`: a SQLSTATE and a message.

| Code | Constant | When |
|---|---|---|
| the server's | | The server's error for the statement, such as `"23505"` for a duplicate key, or the one it ended the connection with, such as `"28P01"` for a wrong password |
| `"P0001"` | `pg::RAISE_EXCEPTION` | `pg::fail(message)`: the program's own |
| `"08006"` | `pg::CONNECTION_FAILURE` | The transport failed, or the server broke the protocol; the message says which |
| `"08003"` | `pg::CONNECTION_DOES_NOT_EXIST` | A call on a connection that isn't open, or broke earlier |
| `"08001"` | `pg::SQLCLIENT_UNABLE_TO_ESTABLISH_SQLCONNECTION` | `pg::connect` or `pg::open` with a URL that isn't a `postgres://` one, one whose `sslmode` needs TLS, settings with a NUL byte, or a socket that can't connect |
| `"22021"` | `pg::CHARACTER_NOT_IN_REPERTOIRE` | SQL with a NUL byte, refused before it is sent; the connection goes on |
| `"26000"` | `pg::INVALID_SQL_STATEMENT_NAME` | The server's, for a prepared statement it dropped ([Statements](#statements)) |

Constants name other codes a program tests for, each by its condition's name in
Postgres's error codes appendix: `pg::UNIQUE_VIOLATION`, `pg::FOREIGN_KEY_VIOLATION`,
`pg::NOT_NULL_VIOLATION`, `pg::CHECK_VIOLATION`, `pg::SERIALIZATION_FAILURE`,
`pg::DEADLOCK_DETECTED`, and `pg::IN_FAILED_SQL_TRANSACTION`. `pg::class(code)` gives
a code's class, such as `"23"` for every integrity constraint violation.

A server's error fails the call once the server is ready again, so the connection
goes on. A call that leaves early, because its row block failed, leaves answers
unread, and the next call reads and drops them first. After the transport fails, the
server sends a FATAL error, or it breaks the protocol, every call fails with
`"08003"` until `pg::connect` runs again on a new transport.

## Authentication

The server chooses, and `step` answers:

- **SCRAM-SHA-256** (RFC 5802, RFC 7677), Postgres's default. The client sends its
  nonce with an empty user name, as libpq does, since the server takes the startup
  message's, and no channel binding (`n,,`). It derives the keys with goose-hash's
  PBKDF2 and HMAC-SHA-256 from the server's salt and iteration count, sends its proof,
  and checks the server's signature with a constant-time compare before it accepts
  AuthenticationOk. A server that skips that step, offers only
  `SCRAM-SHA-256-PLUS`, or sends a nonce that doesn't extend the client's fails the
  connection, as does an iteration count above `MAX_ITERATIONS` (1,000,000; Postgres's
  default is 4096), which would let a hostile server stall the client in PBKDF2. The
  password is used as given, without SASLprep, which changes nothing for printable
  ASCII.
- **A cleartext password**, for a `password` line in `pg_hba.conf`, only when
  `Config.allow_cleartext` is set. Without TLS it crosses the network as it is, so
  by default the client refuses the request and fails the connection, as libpq's
  `require_auth` can. A request after SCRAM began is refused whatever the setting.

MD5, Kerberos, GSSAPI, and SSPI fail the connection with a message saying so. The
password's bytes in `c` are zeroed once the server accepts it, or when the connection
fails; the `Config` the caller passed still holds it.

## Limits

- `MAX_COLUMNS` (128) columns per row: a RowDescription or DataRow with more fails the
  connection.
- `MAX_MESSAGE` (1 GB) per message, Postgres's own limit on a field.
- `MAX_ITERATIONS` (1,000,000) SCRAM iterations.
- `QUEUE` (1,024) entries waiting at once.

## Not yet

- `pg::transaction`, queries in parallel on the facade, and the pool, as
  [Layers](#layers) says.
- Host names other than `localhost` for `pg.socket`, which goose-http doesn't resolve
  yet, and a Unix socket's directory in a `postgres://` URL.
- TLS: the package speaks to the server in the clear, so it suits a server on the same
  host or a private network. A URL whose `sslmode` asks for TLS is refused.
- Binary parameters, and readers for other types: floats, `numeric`, dates and times,
  `uuid`, and arrays. `pg::bytes` gives their raw bytes.
- Closing a prepared statement, cancel requests, COPY, and `LISTEN`.
