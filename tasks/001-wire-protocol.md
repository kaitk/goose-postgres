# 001: The wire protocol

Status: in-progress. Steps 1 to 4 are done (2026-10-19); step 5 is task 005's, and
waits on outbound connections, goose-http's task 053.

Startup, authentication, and the extended query protocol, enough for HttpArena's
`/async-db` (goose-rest's task 047): api-4, api-16, gateway-64, gateway-h3, and
production-stack all serve it.

## What HttpArena asks

From its `async-db` implementation guide (at `2d85137`, 2026-10-18):

- `DATABASE_URL` is `postgres://bench:bench@localhost:5432/benchmark`, and the pool size
  comes from `DATABASE_MAX_CONN` (256).
- The query is `SELECT id, name, category, price, quantity, active, tags, rating_score,
  rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3`, with `integer`,
  `text`, `boolean`, and `jsonb` columns.
- Its Postgres is the `postgres:18` image with `POSTGRES_PASSWORD` set
  (`scripts/lib/postgres.sh`), which authenticates TCP connections with SCRAM-SHA-256:
  the captures under `test/data/` show it (2026-10-19).
- The guide marks the `async-db` profile itself "reference-only": measured and
  published, not counted in the composite score. The api and gateway profiles that
  query the same table are scored.

## Steps

1. Settle the proposed decisions (`docs/decisions.md`). The hashes come from goose-hash.
2. Messages: startup, authentication (SCRAM-SHA-256 and cleartext), `Parse`, `Bind`,
   `Execute`, `Sync`, `RowDescription`, `DataRow`, `CommandComplete`, `ErrorResponse`,
   and `ReadyForQuery`, as bytes in and bytes out, pipelined.
3. Decoding of `int2`, `int4`, `int8`, `bool`, `text`, `varchar`, and `jsonb` in text and
   binary formats.
4. Tests under `test/`: each message against recorded bytes, and a script that runs
   them against a Postgres in Docker. `scripts/test.sh` runs the first; the second
   needs Docker.
5. With goose-http's outbound connections: a goose-rest program that answers
   `/async-db` from a pool (task 005).

## State

Steps 1 to 4 are done (2026-10-19). The decisions add goose-rest's task 052's split:
the protocol without I/O, a blocking facade for lane jobs, the worker's loop for single
queries, pipelining, and the transaction block. The protocol is `pg.goose`,
`scram.goose`, `decode.goose`, and `url.goose`. `scripts/live.sh` runs the session
tests against `postgres:18` (18.0) seeded with HttpArena's table, through
`scripts/relay.py`, and records the captures that `scripts/test.sh` replays; both pass
on macOS arm64. HttpArena's query returns the rows its validation expects: 7, 18, and
0 rows for its limits of 7 and 18 and its empty range, in both formats.

## Acceptance criteria

- [x] The proposed decisions settled in `docs/decisions.md`
- [x] The API in `README.md` and `docs/architecture.md`
- [x] The HttpArena query returns the expected rows from a Postgres in Docker
- [x] `scripts/test.sh` passes
- [ ] HttpArena's `async-db` validation passes for goose-rest's entry (task 005)
