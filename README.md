# goose-postgres

A PostgreSQL client for [Goose](https://github.com/aardappel/goose), in Goose: the
frontend/backend protocol (version 3.0) as bytes in and bytes out, so the program's event
loop owns the sockets and one thread can keep many connections busy. Queries pipeline:
any number go out in one write, and each result comes back matched to its query. Its
first user is [Plod](https://github.com/kaitk/plod), on goose-http's
outbound connections ([architecture](docs/architecture.md)).

The protocol works against Postgres 18, and so does a blocking facade for Plod's
lanes, over goose-http's blocking socket or a transport the program supplies:
`pg::query` with a block per row, `pg::exec`, and errors through `pg::run`. A pool
on goose-http's loop, a pool per worker, runs single queries for a route without a
lane, as HttpArena's `/async-db` asks. A transaction block comes next
([tasks](tasks/README.md)).

## Status

🟢 works · 🟡 partial or next · 🔴 not yet

| | Feature | Notes |
|---|---|---|
| 🟢 | Startup and authentication | SCRAM-SHA-256, with at most 1,000,000 iterations, and cleartext passwords where `Config.allow_cleartext` allows them, with settings from a `postgres://` URL. |
| 🟢 | Queries | The extended protocol: parse once, then bind with parameters and execute; results in text or binary. |
| 🟢 | Pipelining | Many queries queued before any result. Each parse, query, and sync ends in one event carrying its number, including those the server skips after an error. |
| 🟢 | Decoding | `int2`, `int4`, `int8`, `bool`, `text`, `varchar`, `bpchar`, `name`, `json`, and `jsonb`, in either format. |
| 🟢 | A blocking facade | For Plod's lane jobs: `pg::connect`, `pg::query` with a block per row, `pg::exec`, statements prepared once per connection, and errors through `pg::run` and `pg::fail`, over the program's transport. |
| 🟡 | Transactions and queries in parallel | A `pg::transaction` block with savepoints, and several queries in one round trip on the facade (tasks 003 and 004). |
| 🟢 | goose-http's blocking socket as the facade's transport | The module `pg.socket`: `pg::open` over TCP or a Unix socket, with a time limit on each wait. |
| 🟡 | A pool | The module `pg.pool`: a pool per worker on goose-http's loop, `serve_epoll`'s or io_uring's, opened as requests need it, with a queue for requests that find no idle connection and reconnects after failures. Tested live on macOS; the Plod program for HttpArena's `/async-db` and its measurement are next (task 005). |
| 🔴 | TLS | Through goose-tls's client mode, for servers that ask for it. Until then a URL with `sslmode=require`, `verify-ca`, or `verify-full` is refused. |
| 🔴 | More types | Floats, `numeric`, dates and times, `uuid`, and arrays; `pg::bytes` gives their raw bytes. |

The protocol is tested against bytes recorded from Postgres 18.0, the version HttpArena
runs, and against a live server in Docker ([development](docs/development.md#test)).

## Quick start

The package does no I/O. A program connects a socket, then moves bytes between it and
the connection's state:

```goose
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "github.com/kaitk/goose-postgres@v0.0.6";

fn main() {
    let cfg, ok = pg::parse_url("postgres://bench:bench@localhost:5432/benchmark");
    var c = pg::Conn { .. };
    var out: u8[>..] = [];
    var input: u8[>..] = [];
    pg::start(c, out, cfg, nonce);         // nonce: 18 or more random bytes, new each time
    // ... send out, then read into input and step until READY, as below

    pg::parse(c, out, "items", "SELECT id, name FROM items WHERE price BETWEEN $1 AND $2");
    for lo in [10, 100] {
        let b = pg::bind(out, "items");
        pg::param(out, b, lo);
        pg::param(out, b, lo + 40);
        pg::execute(c, out, b, pg::BINARY);
    }
    pg::sync(c, out);
    send_to_socket(out);                   // the program's own I/O: four entries, one write
    out.clear();

    var at = 0;
    loop {
        let e, body = pg::step(c, input[at..], out);
        at += c.used;
        if e == pg::WANT_INPUT { recv_from_socket(input); continue; }
        if e == pg::ROW { print(c.seq, ": ", pg::int(c, body, 0), " ", pg::text(c, body, 1)); }
        if e == pg::ERROR { print(c.seq, " failed: ", pg::field(body, 'M')); }
        if e == pg::READY || e == pg::FAILED { break; }
    }
}
```

```sh
goose build app.goose
```

The root file declares goose-hash, as Goose asks of each package another package
needs. `goose build` fetches it and compiles its small C shim with the C compiler it
already uses.

### The blocking facade

A thread that runs no event loop, such as a
Plod lane, calls the facade, which sends and waits on goose-http's blocking
socket through the module `pg.socket`. The root file declares goose-http too, at the
tag `socket.goose` names
([architecture](docs/architecture.md#goose-https-socket)):

```goose
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http from "github.com/kaitk/goose-http@v0.5.9";
import pg from "github.com/kaitk/goose-postgres@v0.0.6";
import pg.socket;
```

```goose
var db = pg::Db { t: pg::Socket { .. }, .. };
var stock = 0;
let failed = pg::run() {
    pg::open(db, "postgres://bench:bench@localhost:5432/benchmark", 5000);   // ms per wait
    pg::query(db, "SELECT quantity FROM items WHERE id = $1", 7) { r => stock = pg::int(r, 0); };
    if stock == 0 { pg::fail("out of stock"); }
    pg::exec(db, "UPDATE items SET quantity = quantity - 1 WHERE id = $1", 7);
};
for e in failed { print(e.code, ": ", e.message); }   // "23505", "P0001", ...
pg::close(db);
```

Without `pg.socket`, a program needs no goose-http, and the facade runs over any
fixed-size value with `pg::send`, `pg::receive`, and `pg::close` overloads
([architecture](docs/architecture.md#the-transport)), connected with
`pg::connect(db, cfg)`.

## API

All in namespace `pg`. [Architecture](docs/architecture.md#the-api) has each function's
contract and the events' table.

- `pg::parse_url(url) -> Config, bool`: the host, port, user, password, and database.
  `sslmode` `disable`, `allow`, or `prefer` connects without TLS; `require`,
  `verify-ca`, and `verify-full` are refused, since TLS isn't supported yet. Other
  query parameters are ignored.
- `pg::Config`: those fields, and `allow_cleartext`, `false` by default: whether the
  server may ask for the password in cleartext, which it can read on the way. Set it
  for a `password` line in `pg_hba.conf`. A request for it after SCRAM began is
  refused either way. The `Config` keeps the password for as long as the program
  keeps it; the connection zeroes its own copy once used. `max_message`, 64 MB by
  default, is the longest message the connection accepts: a longer one breaks it
  before any buffer grows for it. Raise it for larger rows.
- `pg::Conn { .. }`: a connection's state, fixed-size, so a pool keeps an array of them.
- `pg::start(c, out, cfg, nonce)`: the startup message; `nonce` is SCRAM's client
  nonce, such as 18 bytes from goose-hash's `hash::random_bytes`.
- `pg::step(c, input, out) -> event, body`: reads the server's messages up to the next
  event, answering authentication itself. `c.used` is what it consumed, and `c.seq` the
  entry the event belongs to.
- Entries, each returning its number: `pg::parse(c, out, name, sql)`;
  `pg::bind(out, statement)` with `pg::param(out, b, v)` (bytes, `i64`, or `bool`) and
  `pg::param_null(out, b)`, then `pg::execute(c, out, b, format, max_rows)`; and
  `pg::sync(c, out)`. `pg::terminate(out)` ends the session.
- Events: `WANT_INPUT`, `READY`, `PARSED`, `COLUMNS`, `ROW`, `DONE`, `SUSPENDED`,
  `ERROR`, `SKIPPED`, `NOTICE`, and `FAILED`, with `c.reason`.
- Rows: `pg::int`, `pg::boolean`, `pg::text`, `pg::bytes`, and `pg::is_null` read a
  field by its column's type and format, and `pg::columns_are(c, [pg::OID_INT4, ...])`
  checks the types once. `pg::column_name` names a column, `pg::field` reads an
  error's fields, and `pg::rows` a command's count.

The facade ([architecture](docs/architecture.md#the-facade)):

- `pg::Db { t: transport, .. }`: a connection over a transport, such as
  `pg::Socket { .. }` from `pg.socket`.
- `pg::open(db, cfg or url, ms)`, in `pg.socket`: connects goose-http's socket, over
  TCP, or a Unix socket for a host that starts with `/`, then runs `pg::connect`.
- `pg::connect(db, cfg or url)`: authenticates, with SCRAM's nonce from
  `hash::random_bytes`.
- `pg::query(db, sql, p1, ..., p8) { r => ... } -> i64`: up to eight parameters (bytes,
  integers, bools, or `pg::NULL`), each row to the block, read with `pg::int(r, i)`,
  `pg::text(r, i)`, and the other readers; returns the count.
- `pg::exec(db, sql, p1, ..., p8) -> i64`: the count in the command's tag.
- `pg::Params { .. }` with `pg::param(p, v)`: a list of up to 65535 parameters, for
  `pg::query(db, sql, p)` and `pg::exec(db, sql, p)`.
- `pg::run() { ... } -> pg::Error[]`, `pg::fail(message)`, and
  `pg::fail(code, message)`. `pg::Error` holds a SQLSTATE `code` and a `message`.
- `pg::close(db)` and `pg::in_transaction(db)`.

The pool, in `pg.pool` ([architecture](docs/architecture.md#the-pool)):

- `pg::pool(cfg, size) -> Pool`: a worker's connections, opened as requests need them.
- `pg::Ticket { .. }`: a request's place with the pool, in its state.
- `pg::query(pool, t, out, kind, data, ms, sql, p1, ..., p8) { r => ... } -> i64`:
  called at the request and at each later event; `pg::WAITS` while the exchange
  waits, the count once the block has seen every row, or `pg::FAILS`, with `t.code`
  and `pool.reason`.
- `pg::close(pool)`.

## Credits

The package implements PostgreSQL's
[frontend/backend protocol](https://www.postgresql.org/docs/current/protocol.html) and
RFCs 5802 and 7677 for SCRAM-SHA-256 from their text, and is tested with RFC 7677's
example exchange. The live tests load HttpArena's `items` table
([MDA2AV/HttpArena](https://github.com/MDA2AV/HttpArena), `data/pgdb-seed.sql`).

## Layout

```text
pg.goose       the package's entry: the connection, the messages the client writes,
               and step, which reads the server's
scram.goose    SCRAM-SHA-256
decode.goose   reading rows, columns, errors, and command tags
url.goose      Config, and postgres:// URLs
facade.goose   the blocking facade: Db, connect, query, exec, run, and fail
socket.goose   the module pg.socket: the facade over goose-http's socket, and open
pool.goose     the module pg.pool: a pool per worker on goose-http's loop
test/          unit tests, session tests that replay captures from Postgres, and
               test/live/, which needs one
scripts/       the Goose pin, the test scripts, and the live run in Docker with its relay
docs/          architecture, decisions, development setup, Goose findings
tasks/         task tracking (tasks/README.md)
```

## Pins

| What | Pin | Why |
|---|---|---|
| Goose compiler | `aardappel/goose` release `v2026.3` (`8511ae3`), which the scripts fetch ([setup](docs/development.md#set-up-the-goose-compiler)) | An official release builds the same on every platform; a commit is pinned only for a fix not yet released |
| goose-hash | `github.com/kaitk/goose-hash@v0.0.4`, in each file that imports it | SHA-256, HMAC-SHA-256, and PBKDF2 for SCRAM, and `hash::random_bytes` for its nonce |
| goose-http | `github.com/kaitk/goose-http@v0.5.9`, in `socket.goose`, `pool.goose`, and the programs that import them ([pin](docs/development.md#the-goose-http-pin)) | Its outbound connections: the blocking socket for `pg.socket`, and waiting on a socket on the worker's loop, epoll's and io_uring's; Plod's pin |
| Postgres | `postgres:18` in `scripts/live.sh`; the captures are from 18.0 | The version HttpArena runs |
| Test data | HttpArena `2d85137`'s `data/pgdb-seed.sql`, checked by SHA-256 in `scripts/live.sh` | The `/async-db` profile's table |

Move a pin in its own commit, with the tests that still pass.
