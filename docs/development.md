# Development

The package is Goose with no C of its own; goose-hash, which it imports for SCRAM, has
a small C shim that `goose build` compiles. The replayed tests have run on macOS on
arm64, and the live tests there against Postgres 18.0 in Docker (2026-10-19). They
haven't run on Linux or Windows yet.

## Toolchain

Use the Goose pin in [README.md](../README.md#pins). The scripts also need:

| Tool | Requirement | Purpose |
|---|---|---|
| C compiler | clang or gcc; on Windows, MSVC or `clang-cl` with Visual Studio Build Tools | `goose build` of goose-hash's shim and of each test |
| git | on `PATH` | `goose build` fetches goose-hash at its tag on first use |
| Python | 3, with its standard library | `test/run_tests.py` and `scripts/relay.py` |
| POSIX shell, curl, shasum or sha256sum | on `PATH`; Git Bash on Windows | `scripts/goose.sh`, `scripts/test.sh`, and `scripts/live.sh` |
| Docker | with the `postgres:18` image, which it pulls | `scripts/live.sh` only |
| CMake | with Make or Ninja | building Goose from source, on Linux arm64 or for `GOOSE_COMMIT` |

## Set up the Goose compiler

The scripts use the Goose release pinned in `scripts/goose.sh` (`v2026.2`, 2026-10-16)
unless told otherwise. The first script that needs the compiler downloads the release's
archive for the platform from
[the releases page](https://github.com/aardappel/goose/releases), checks its SHA-256,
and unpacks it into `build/goose-v2026.2-<platform>/`; later runs reuse it. Run
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

## Test

`scripts/test.sh` runs every test that needs no server, and stops at the first step
that fails:

1. `goose check` of `pg.goose` alone, and of each root file under `test/`.
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
  any point, several in one read, an error at a sync, and each way a connection fails,
  from MD5 to a wrong SCRAM signature and a server that breaks the protocol.
- `test/scram/`: RFC 7677's example exchange, and the server-first-messages the client
  refuses.
- `test/url/`: `postgres://` URLs.
- `test/session/`: whole sessions with a server, replayed from captures
  ([below](#session-tests)): HttpArena's `/async-db` query in both formats
  (`arena`, and `arena_bytewise`, which hands the server's bytes over one at a time),
  every decoded type and each outcome a pipeline's entry can have (`pipeline`), a
  cleartext login (`cleartext`), and a wrong password (`bad_password`).

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
other lines through as the test's output. With `--record` it writes the capture.

Record again after changing what a session sends, or to move to a new Postgres version,
and read the diff of `test/expected/` before committing: the server's nonce, salt, and
backend key change in every capture, and nothing a test prints may.

## Traps

- A fixed-size value passed to an untyped parameter is copied: `decode_into(cfg.user,
  ...)` with `fn decode_into(out, ...)` appended to a copy of the field, and the
  startup message went out without a user. Take such a parameter as `out: B&`.
- `null` is a keyword, so the NULL parameter is `pg::param_null`.
