# Architecture

How goose-postgres works, for its users. The decisions behind it, each with its reason
and what it rejected, are in [decisions](decisions.md).

## Layers

The package is PostgreSQL's frontend/backend protocol, version 3.0, in Goose, with no
I/O: a connection's state, `pg::Conn`, appends the messages to send to a buffer the
caller owns, and reads the server's messages from bytes the caller received. The
caller owns the socket, so the same protocol runs under goose-http's event loop, under
a blocking socket, or under a test that replays recorded bytes.

Two layers go on top of it, neither built yet:

- **A blocking facade, for lane jobs.** A goose-rest use case that runs several
  queries runs as one job on a lane and calls `pg::run`, `pg::fail`, and
  `pg::transaction`, as goose-sqlite's API does, so its code reads top to bottom.
  Queries "in parallel" are pipelined on one connection.
- **A pool on the worker's loop.** A route that runs one query, as HttpArena's
  `/async-db` does, sends it on a connection that goose-http's loop owns, through its
  outbound connections, and resumes when the rows arrive.

## The API

All of it is in namespace `pg`: `pg.goose` holds the connection, the messages the
client writes, and `step`; `scram.goose` the authentication; `decode.goose` the
readers of rows; `url.goose` the settings.

### Settings

- `pg::Config`: `host`, `port` (5432), `user`, `password`, and `database`, each a
  fixed-size field. The host and port are for the caller's socket.
- `pg::parse_url(url) -> Config, bool`: reads `postgres://user:password@host:port/database`
  or `postgresql://...`, percent-decoding each part but the host, which may be an
  IPv6 address in brackets. The host defaults to `localhost`, the port to 5432, and the
  database to the user's name. A query string, such as `?sslmode=disable`, is ignored.
  `false` for anything else, or a part longer than the field: 255 bytes for the host and
  password, 63 for the user and database, Postgres's limit on a name.

### A connection

- `pg::Conn { .. }`: a fixed-size value, so a pool keeps its connections in an array.
- `pg::start(c, out, cfg, nonce)`: starts `c` over and appends the startup message to
  `out`: protocol 3.0, the user, the database, and `client_encoding` `UTF8`, so every
  text arrives as UTF-8. It keeps the password until authentication uses it. `nonce`
  is SCRAM's client nonce: at least 18 bytes from a secure random source, new for each
  connection; the package has no source of its own.
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
NegotiateProtocolVersion are consumed without an event.

`FAILED` means the connection is done: authentication failed or was refused, the
server sent a FATAL error, or it broke the protocol, as with a message that doesn't fit
the entry waiting or a length out of range. Every later `step` returns `FAILED` too.
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

A NULL reads as 0, false, or empty. `int` gives 0 for text that isn't an integer;
`columns_are` is the check against reading a column as the wrong type. The slices
point into the row's body, which is in the caller's input: read them before reusing
it.

- `pg::field(body, code) -> const u8[:]`: a field of an ErrorResponse's or
  NoticeResponse's body: `'C'` the SQLSTATE code, `'M'` the message, `'V'` the
  severity, `'D'` the detail. Empty when it has none.
- `pg::rows(tag) -> i64`: the count in `DONE`'s tag: 5 for `SELECT 5` or `INSERT 0 5`.

## Authentication

The server chooses, and `step` answers:

- **SCRAM-SHA-256** (RFC 5802, RFC 7677), Postgres's default. The client sends its
  nonce with an empty user name, as libpq does, since the server takes the startup
  message's, and no channel binding (`n,,`). It derives the keys with goose-hash's
  PBKDF2 and HMAC-SHA-256 from the server's salt and iteration count, sends its proof,
  and checks the server's signature with a constant-time compare before it accepts
  AuthenticationOk. A server that skips that step, offers only
  `SCRAM-SHA-256-PLUS`, or sends a nonce that doesn't extend the client's fails the
  connection. The password is used as given, without SASLprep, which changes nothing
  for printable ASCII.
- **A cleartext password**, for a `password` line in `pg_hba.conf`. Without TLS it
  crosses the network as it is.

MD5, Kerberos, GSSAPI, and SSPI fail the connection with a message saying so. The
password is cleared from `c` once the server accepts it.

## Limits

- `MAX_COLUMNS` (128) columns per row: a RowDescription or DataRow with more fails the
  connection.
- `MAX_MESSAGE` (1 GB) per message, Postgres's own limit on a field.
- `QUEUE` (1,024) entries waiting at once.

## Not yet

- The blocking facade, `pg::transaction`, and the pool, as [Layers](#layers) says.
- TLS: the package speaks to the server in the clear, so it suits a server on the same
  host or a private network.
- Binary parameters, and readers for other types: floats, `numeric`, dates and times,
  `uuid`, and arrays. `pg::bytes` gives their raw bytes.
- Closing a prepared statement, cancel requests, COPY, and `LISTEN`.
