# 001: The wire protocol

Status: todo (waits on outbound connections, goose-http's task 051)

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
- Which authentication method its Postgres container uses isn't checked yet; Postgres
  defaults to SCRAM-SHA-256 from version 14.

## Steps

1. Settle the proposed decisions and where the hashes come from (`docs/decisions.md`).
2. Messages: startup, authentication (SCRAM-SHA-256 and cleartext), `Parse`, `Bind`,
   `Execute`, `Sync`, `RowDescription`, `DataRow`, `CommandComplete`, `ErrorResponse`,
   and `ReadyForQuery`, as bytes in and bytes out.
3. Decoding of `int2`, `int4`, `int8`, `bool`, `text`, `varchar`, and `jsonb` in text and
   binary formats.
4. Tests under `test/`: each message against recorded bytes, and a script that runs
   them against a Postgres in Docker. `scripts/test.sh` runs the first; the second
   needs Docker.
5. With goose-http's outbound connections: a goose-rest program that answers
   `/async-db` from a pool.

## Acceptance criteria

- [ ] The proposed decisions and the hash source recorded in `docs/decisions.md`
- [ ] The API in `README.md` and `docs/architecture.md`
- [ ] The HttpArena query returns the expected rows from a Postgres in Docker
- [ ] `scripts/test.sh` passes
- [ ] HttpArena's `async-db` validation passes for goose-rest's entry
