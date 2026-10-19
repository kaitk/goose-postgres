# goose-postgres

A PostgreSQL client for [Goose](https://github.com/aardappel/goose), in Goose: the
frontend/backend protocol (version 3.0) as bytes in and bytes out, so the program's event
loop owns the sockets and one thread can keep many connections busy. Queries pipeline:
any number go out in one write, and each result comes back matched to its query. Its
first user is [goose-rest](https://github.com/kaitk/goose-rest), on goose-http's
outbound connections ([architecture](docs/architecture.md)).

The protocol works against Postgres 18. The layers a program calls come next: a
blocking facade for goose-rest's lanes, and a pool on goose-http's loop
([tasks](tasks/README.md)). The repository isn't published yet.

## Status

🟢 works · 🟡 partial or next · 🔴 not yet

| | Feature | Notes |
|---|---|---|
| 🟢 | Startup and authentication | SCRAM-SHA-256 and cleartext passwords, with settings from a `postgres://` URL. |
| 🟢 | Queries | The extended protocol: parse once, then bind with parameters and execute; results in text or binary. |
| 🟢 | Pipelining | Many queries queued before any result. Each parse, query, and sync ends in one event carrying its number, including those the server skips after an error. |
| 🟢 | Decoding | `int2`, `int4`, `int8`, `bool`, `text`, `varchar`, `bpchar`, `name`, `json`, and `jsonb`, in either format. |
| 🟡 | A blocking facade | `pg::run`, `pg::fail`, and a `pg::transaction` block, for goose-rest's lane jobs (tasks 002 to 004). |
| 🟡 | A pool | On goose-http's outbound connections, sized from `DATABASE_MAX_CONN`, for HttpArena's `/async-db` (task 005). |
| 🔴 | TLS | Through goose-tls's client mode, for servers that ask for it. |
| 🔴 | More types | Floats, `numeric`, dates and times, `uuid`, and arrays; `pg::bytes` gives their raw bytes. |

The protocol is tested against bytes recorded from Postgres 18.0, the version HttpArena
runs, and against a live server in Docker ([development](docs/development.md#test)).

## Quick start

The package does no I/O. A program connects a socket, then moves bytes between it and
the connection's state:

```goose
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "github.com/kaitk/goose-postgres@v0.0.1";

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

## API

All in namespace `pg`. [Architecture](docs/architecture.md#the-api) has each function's
contract and the events' table.

- `pg::parse_url(url) -> Config, bool`: the host, port, user, password, and database.
- `pg::Conn { .. }`: a connection's state, fixed-size, so a pool keeps an array of them.
- `pg::start(c, out, cfg, nonce)`: the startup message; `nonce` is SCRAM's client
  nonce, such as 18 bytes from goose-hash's `hash::random_bytes` (from v0.0.3).
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
test/          unit tests, and session tests that replay captures from Postgres
scripts/       the Goose pin, the test scripts, and the live run in Docker with its relay
docs/          architecture, decisions, development setup, Goose findings
tasks/         task tracking (tasks/README.md)
```

## Pins

| What | Pin | Why |
|---|---|---|
| Goose compiler | `aardappel/goose` release `v2026.2` (`3ee3871`), which the scripts fetch ([setup](docs/development.md#set-up-the-goose-compiler)) | An official release builds the same on every platform; a commit is pinned only for a fix not yet released |
| goose-hash | `github.com/kaitk/goose-hash@v0.0.3`, in each file that imports it | SHA-256, HMAC-SHA-256, and PBKDF2 for SCRAM, and `hash::random_bytes` for its nonce |
| Postgres | `postgres:18` in `scripts/live.sh`; the captures are from 18.0 | The version HttpArena runs |
| Test data | HttpArena `2d85137`'s `data/pgdb-seed.sql`, checked by SHA-256 in `scripts/live.sh` | The `/async-db` profile's table |

Move a pin in its own commit, with the tests that still pass.
