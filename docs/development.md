# Development

The package is Goose with no C of its own; goose-hash, which it imports for SCRAM, has
a small C shim that `goose build` compiles, and goose-http, which only the modules
`pg.socket` and `pg.pool` import, has its socket calls in C. The replayed tests have
run on macOS on arm64, and the live tests there against Postgres 18.0 in Docker
(2026-10-19; the pool's on 2026-10-23). They haven't run on Linux or Windows yet.

## Toolchain

Use the Goose pin in [README.md](../README.md#pins). The scripts also need:

| Tool | Requirement | Purpose |
|---|---|---|
| C compiler | clang or gcc; on Windows, MSVC or `clang-cl` with Visual Studio Build Tools | `goose build` of goose-hash's shim, goose-http's C, and each test |
| git | on `PATH` | `goose build` and `goose check` fetch goose-hash and goose-http at their pins on first use |
| Python | 3, with its standard library | `test/run_tests.py`, `scripts/relay.py`, and `scripts/unix-forward.py` |
| POSIX shell, curl, shasum or sha256sum | on `PATH`; Git Bash on Windows | `scripts/goose.sh`, `scripts/test.sh`, and `scripts/live.sh` |
| Docker | with the `postgres:18` image, which it pulls | `scripts/live.sh` only |
| CMake | with Make or Ninja | building Goose from source, on Linux arm64 or for `GOOSE_COMMIT` |

## Set up the Goose compiler

The scripts use the Goose release pinned in `scripts/goose.sh` (`v2026.3`, 2026-10-21)
unless told otherwise. The first script that needs the compiler downloads the release's
archive for the platform from
[the releases page](https://github.com/aardappel/goose/releases), checks its SHA-256,
and unpacks it into `build/goose-v2026.3-<platform>/`; later runs reuse it. Run
`scripts/goose.sh` to fetch it and print the compiler's path. Linux on arm64 has no
release archive, so there the script builds the release's tag from source, as
`GOOSE_COMMIT` does below.

Use another compiler only when the release can't do the job, such as a Goose fix not
yet released. `GOOSE` names a binary; `GOOSE_COMMIT` names a full 40-hex commit of
`aardappel/goose`, which the scripts clone into `build/goose-<commit>/` and build with
CMake.

The release's `stdlib/` under `build/` needs no `exclude`: the repository has no
`.build` sidecar. One added later needs `exclude = ["build"]`, as goose-hash's has,
because Goose collects a package's symbol table from every `.goose` file under its root.

## The goose-http pin

`socket.goose` and `pool.goose`, the modules `pg.socket` and `pg.pool`, import
goose-http at its release `v0.5.10` (2026-10-24), the tag Plod pins, so a Plod program
declares one goose-http for both. It has the outbound connections: the blocking
socket, and `wait_socket` on `serve_epoll`'s loop and on `serve`'s io_uring loop
(since 2026-10-22, goose-http's task 053). `test/live/socket.goose`,
`test/live/pool.goose`, the quick start in `README.md`, and `docs/architecture.md`
declare the same reference. Move them all in one commit, with
`scripts/test.sh` and `scripts/live.sh` passing. A commit pin, for a fix not yet
released, is the full 40-hex hash, since git can't fetch an abbreviated one.

## Test

`scripts/test.sh` runs every test that needs no server, and stops at the first step
that fails:

1. `goose check` of `pg.goose` alone, of `socket.goose`, which fetches goose-http,
   of each root file under `test/`, and of each program under `test/live/`.
2. `test/run_tests.py`: the tests under `test/<area>/`, each built with `goose build`
   at `-O0` and `-O2` and run, its output checked against `test/expected/<name>.out`.

```sh
scripts/test.sh
python3 test/run_tests.py session          # one area
python3 test/run_tests.py --bless arena    # rewrite test/expected/arena.out
```

The areas:

- `test/messages/`: the messages the client writes, byte for byte against the
  protocol's layouts, and the server's that recorded sessions lack: messages cut at
  any point, several in one read, an error at a sync, a message at
  `Config.max_message` and one a byte over, and each way a connection fails, from MD5, a cleartext request not allowed, and an iteration count over the cap, to a
  wrong SCRAM signature, a client_encoding other than UTF8, and a server that breaks
  the protocol; strings with a NUL byte, which the writers refuse; and reading a field
  past a row's last.
- `test/scram/`: RFC 7677's example exchange, the server-first-messages the client
  refuses, and a cleartext request after a completed SCRAM, built from `arena`'s
  capture (`after_scram`).
- `test/url/`: `postgres://` URLs, with NUL bytes and `sslmode`.
- `test/session/`: whole sessions with a server, replayed from captures
  ([below](#session-tests)): HttpArena's `/async-db` query in both formats
  (`arena`, and `arena_bytewise`, which hands the server's bytes over one at a time),
  every decoded type and each outcome a pipeline's entry can have (`pipeline`), a
  cleartext login, allowed (`cleartext`) and refused by default
  (`cleartext_refused`), a wrong password (`bad_password`), and the blocking facade's
  calls, errors, and savepoints (`facade`), and its login (`facade_login`).
- `test/facade/`: the facade against a server `test/fake.goose` fakes in the program,
  for what a capture can't show: a connection lost in a result, a FATAL error, a send
  that fails, a row at `Config.max_message`, one over it, and one over the default
  of which only the head arrives, the statement cache's limits and statements the server dropped, and
  what the facade refuses before sending (`refused`); and a `pg::Params` list as
  `Bind` writes it, up to 65535 parameters (`params`).
- `test/compile/`: `// error:` fixtures, programs that must not compile: a facade call
  outside `pg::run`, a query inside another's row block, and a program that imports
  `pg.socket` without declaring goose-http.

`test/run_tests.py` skips `test/live/`, whose programs need a server:
`scripts/live.sh` runs them ([below](#the-socket-test)).

### Session tests

A session test is a program that talks to a server through `test/wire.goose`. Under
`test/run_tests.py` it replays a capture from `test/data/`: it gets the server's
recorded bytes when it asks for input, and each message it sends must equal the
recorded one, or it aborts. SCRAM's client nonce is fixed in the tests, so the client's
proof in a capture replays.

`scripts/live.sh` runs the same programs against a server, and checks that each prints
its `test/expected/` file, so a replay and a live run agree:

```sh
scripts/live.sh             # against a new container on port 55432
PG_PORT=55433 scripts/live.sh
scripts/live.sh --record    # also write test/data/*.cap and test/expected/*.out
scripts/live.sh --record facade    # only the tests named
```

It starts the `postgres:18` image as HttpArena does: user `bench`, password `bench`,
database `benchmark`, seeded with the 100,000 rows of HttpArena's `data/pgdb-seed.sql`
at `2d85137`, which it fetches into `build/arena/` and checks against its SHA-256. The
image authenticates TCP connections with SCRAM-SHA-256. `scripts/live-init.sh` adds a
user `plain` with a `password` line in `pg_hba.conf`, for the cleartext test. The
container's data is on a tmpfs, and the script removes the container when it ends.

Goose has no sockets outside goose-http, so `scripts/relay.py` connects each program to
the server: it starts the program with `--live`, sends what the program writes as
`>hex` lines, answers each `<` line with the server's next bytes in hex, and passes the
other lines through as the test's output. With `--record` it writes the capture. The
facade's tests reach the same relay through `wire::Io`'s transport overloads.

Record again after changing what a session sends, or to move to a new Postgres version,
and read the diff of `test/expected/` before committing: the server's nonce, salt, and
backend key change in every capture, and nothing a test prints may.

### The socket test

`scripts/live.sh` also runs `test/live/socket.goose`, the facade over goose-http's
socket with no relay: connects that fail (refused, a missing Unix socket, a host name
under `.invalid`, which no resolver answers, and a URL that isn't one), then the
session `test/session/facade.goose` replays, through the same `wire::facade`, and
`pg::open` on a connection again. It runs twice, over
TCP to the container's port and over a Unix socket, and both runs must print
`test/expected/socket.out`. `--record` rewrites that file from the TCP run; it has no
capture.

Docker Desktop can't share a Unix socket between its VM and the host: Postgres fails
to start with "could not create any Unix-domain sockets" when its socket directory is
a bind mount (macOS, 2026-10-19). So the Unix run connects to a socket that
`scripts/unix-forward.py` serves in a directory under `/tmp`, which forwards each
connection to the container's TCP port. The run tests the client's side, `pg::open`'s
`unix:` path and goose-http's Unix connect, against a real server, while Postgres
itself sees TCP.

### The pool test

`scripts/live.sh` runs `test/live/pool.goose` last, since it ends the server's
sessions and refuses new ones for a while. The program serves on goose-http's
`serve_epoll` loop, one worker, with pools of two connections, of one, and of one to a
port nothing listens on, and requests from its own threads: HttpArena's `/async-db` at
the limits 7, 18, 33, and 50 and an empty range; 80 requests from 8 threads at once on
the two connections; `pg_sleep(1)` past a 200 ms limit; an answer longer than
`POOL_INPUT`; clients that go while their query runs, with the pool told at `CLOSED`
and not, each followed by a query that must find the same backend; a server that ends
every session (`pg_terminate_backend`), refuses new ones (`ALTER DATABASE benchmark
ALLOW_CONNECTIONS false`), and takes them again, through an admin connection on
`pg.socket` to the database `postgres`; and connects refused. It ends with one request
on `serve`'s loop, which gets rows on io_uring and the empty answer with
`wait_socket`'s reason elsewhere, such as macOS. It must print
`test/expected/pool.out`, which `--record` rewrites.

## Traps

- A fixed-size value passed to an untyped parameter is copied: `decode_into(cfg.user,
  ...)` with `fn decode_into(out, ...)` appended to a copy of the field, and the
  startup message went out without a user. Take such a parameter as `out: B&`.
- `null` is a keyword, so the NULL parameter is `pg::param_null`, and the facade's is
  `pg::NULL`.
- A transport's overloads are declared from another file as `fn pg::send(t:
  wire::Io&, ...)`. The qualifier puts the whole declaration in namespace `pg`, its
  body included, so the body names its own namespace's functions in full
  (`wire::recv`).
- `for e in pg::run() { ... } { ... }` doesn't parse as a loop over the errors: the
  second block is taken as the loop's body and the first as `run`'s missing argument.
  Bind the errors first, `let failed = pg::run() { ... };`.
- goose-http's `Config.address` holds 112 bytes, so a loop listening on a Unix socket
  in a long `TMPDIR`, such as macOS's `/var/folders/...` or an agent's scratch
  directory, aborts with "limited array capacity exceeded". `scripts/live.sh` runs
  the pool test with `TMPDIR` set to its short directory under `/tmp`.
- A block's parameters are taken by value, and a growable array isn't copied
  implicitly, so a block can't take the output buffer itself: the pool's parameter
  writer gets a `Binding`, a struct holding a reference to it.
- A function in `socket.goose` that names a type of `pg.goose` in its signature,
  such as `Config`, fails `goose check socket.goose`, which `scripts/test.sh` runs on
  the file alone; an untyped parameter is checked only where it's called.
- Docker Desktop's port forwarding passes on a backend's last bytes, and its close,
  a little after `pg_stat_activity` shows the backend gone (macOS, 2026-10-23): the
  pool test waits 200 ms after the server ends its sessions.
