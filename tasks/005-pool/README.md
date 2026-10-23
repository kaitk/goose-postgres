# 005: A pool on goose-http's outbound connections

Status: in-progress. Steps 1 and 2 and the pool's part of step 4 are done
(2026-10-23); see "Handover" at the end.

A route that runs one query, as HttpArena's `/async-db` does, sends it on a connection
the worker's loop owns and resumes when the rows arrive, with no lane between
(`docs/decisions.md`). This task is that pool, and task 001's step 5: a Plod
program that answers `/async-db` from it.

## What HttpArena asks

From its `async-db` implementation guide (at `3717e256`, the commit Plod's HttpArena
entry pins; the same at `2d85137`, 2026-10-18): an async driver with a pool sized from
`DATABASE_MAX_CONN` (256), not from the CPU count; settings from `DATABASE_URL`; the
statement prepared once per connection; `limit` clamped to 1 to 50, with defaults of
10, 50, and 50; `{"items":[],"count":0}` when Postgres is unavailable or the query
returns no rows, and a connection made again on a later request, without crashing.
The profile runs 1,024 HTTP connections, limits 5, 10, 20, 35, and 50, and a
Postgres 18 with `max_connections=256`.

## Design questions

Settled 2026-10-23, in `docs/decisions.md` and `docs/architecture.md` ("The pool"):

- **Whose connections.** Each worker owns its own pool of `DATABASE_MAX_CONN /
  workers` connections, opened as requests need them, since goose-http wakes the
  exchange on the worker that armed the socket.
- **Which loop.** `serve_epoll`'s, and `serve`'s on io_uring: goose-http waits on
  sockets there since 2026-10-22 (its task 053). The emulated ring and IOCP fail every
  pooled query with `wait_socket`'s `ENOSYS`.
- **Waiting.** A queue per worker, the waiting exchanges' mail addresses, handed a
  connection by mail as one is given back; no pipelining onto a busy connection, which
  saves only a mail and a send per query against a sequential scan, and would need
  the reading exchange to hand on answers that aren't its own.
- **The request's state.** A `pg::Ticket`: its place (new, queued, holding a
  connection, done), the connection's number, the entry numbers of its query and
  Parse, its exchange's address, and a failure's SQLSTATE, about 60 bytes. The rows
  go straight into the response: the call that finds the whole answer in the
  connection's buffer gives every row to the block.
- **Nonces.** SCRAM's client nonce is 18 bytes from goose-hash's `hash::random_bytes`
  for each connection.

## Steps

1. ~~Settle the pool's waiting, and record the per-worker pools, in
   `docs/decisions.md`.~~ Done 2026-10-23.
2. ~~The pool: connect, authenticate, and prepare HttpArena's statement on each
   connection; hand out and take back; reconnect on failure.~~ Done 2026-10-23:
   `pool.goose`, the module `pg.pool`.
3. The Plod program for `/async-db`, in Plod's entry (its task 047). A sketch is in
   [plod-route.md](plod-route.md).
4. Tests: the pool against a live Postgres in Docker, a server that goes away and
   comes back (done 2026-10-23, `test/live/pool.goose`), and HttpArena's
   `validate.sh` for the profile.
5. Measure the profile on a machine with HttpArena's setup, with the method recorded.

## Acceptance criteria

- [x] The pool's design in `docs/decisions.md` and `docs/architecture.md`
- [ ] `/async-db` answers HttpArena's validation: the limits 7, 18, 33, and 50, the
      content type, and the empty range (the pool's test answers each, with the
      route's JSON, on goose-http directly; Plod's program and `validate.sh` remain)
- [x] A lost Postgres gives the empty answer, and the pool reconnects
- [ ] Results recorded with machine, command, workers, connections, and runs
- [x] `scripts/test.sh` and `scripts/live.sh` pass (macOS, arm64, 2026-10-23)

## Handover

Written 2026-10-23, on the branch `pool`.

### Built

- `pool.goose`, the module `pg.pool`: `pg::pool(cfg, size)`, `pg::Ticket`,
  `pg::query(pool, t, out, kind, data, ms, sql, p1..p8) { r => ... }` returning
  `pg::WAITS`, a count, or `pg::FAILS`, and `pg::close(pool)`. Connections open on
  the loop (`connect_start`, SCRAM, the query in one write after the startup's
  ReadyForQuery), statements are prepared per connection on first use, the whole
  answer is read into the connection's 64 KB buffer before the rows go to the block,
  and a connection goes to the first waiting exchange by mail when its query ends.
- Before it, task 006's `Config.max_message` (a pooled connection takes at most
  `POOL_INPUT - 1`), and the goose-http pin moved to `v0.5.5`, Plod's.
- `socket.goose`: `socket_address` and `cant_connect`, shared with the pool.
- `test/live/pool.goose`, run last by `scripts/live.sh`, with its golden file.

### What passes

On macOS (arm64), Goose `v2026.3`, goose-http `v0.5.5`, `postgres:18` (18.0) in
Docker Desktop, 2026-10-23: `scripts/test.sh` and `scripts/live.sh`, the pool test
included, and the pool test five times in a row with the same output. It covers
HttpArena's limits and the empty range, 80 requests from 8 threads on 2 connections
(the queue and the hand-over), a query past its time limit, an answer longer than
`POOL_INPUT`, clients that go mid-query with the pool told at `CLOSED` and not (the
connection kept, then adopted, on the same backend), a server that ends every session,
refuses new ones (`55000`), and takes them again, and connects refused. `serve`'s loop
was checked only for its `ENOSYS` answer: macOS has no io_uring.

### What remains, in order

1. Run `scripts/test.sh` and `scripts/live.sh` on Linux, where the pool test's last
   request runs on io_uring and must get rows. Docker on Linux forwards ports without
   Docker Desktop's proxy, so the test's 200 ms wait after ending the sessions may be
   more than it needs there.
2. The Plod program (step 3), from [plod-route.md](plod-route.md), on Plod's
   `httparena` branch, then HttpArena's `validate.sh` for the profile. It needs the
   Plod change below for `TIMEOUT`, or accepts a 504 when Postgres stops answering.
3. Measure (step 5), with the method recorded. Candidates to look at then: `pull`
   calls `recv` until `EAGAIN`, one empty call per wake; the statement lookup compares
   the SQL text on each query; `whole_answer` walks the message heads once per wake.
4. A test without a server, for CI: the pool against a backend thread in the program
   that answers from a capture, as `test/fake.goose` does for the facade.

### Needs from other repositories

- **Plod.** A route that waits with `http::wait_socket` gets neither `TIMEOUT` nor
  `CLOSED`: `on_event` answers 504 at a `TIMEOUT` that isn't a pause's, and calls the
  route at `CLOSED` only after `body_in_pieces`, `begin`, `file`, or `upgrade`. The
  pool doesn't depend on either: a connection whose exchange went is adopted by the
  next request. But a route can't answer HttpArena's empty JSON when Postgres stops
  answering, only Plod's 504, and a waiter queued behind such a connection waits for
  the next request to adopt it, or for its own 504. A way for a route to say it waits
  on its own and wants both events, such as a mode bit a `plod::wait_socket` sets,
  would let it answer and give the connection back at once.
- **goose-http.** Nothing. The pool uses `connect_start`, `connected`,
  `wait_socket`, `recv`, `send`, `hangup`, `later`, `mail_send`, and `mail_live`
  as `v0.5.5` has them.
