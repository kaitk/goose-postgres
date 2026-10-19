# 005: A pool on goose-http's outbound connections

Status: todo. Waits on outbound connections, goose-http's task 053.

A route that runs one query, as HttpArena's `/async-db` does, sends it on a connection
the worker's loop owns and resumes when the rows arrive, with no lane between
(`docs/decisions.md`). This task is that pool, and task 001's step 5: a goose-rest
program that answers `/async-db` from it.

## What HttpArena asks

From its `async-db` implementation guide (at `2d85137`, 2026-10-18): an async driver
with a pool sized from `DATABASE_MAX_CONN` (256), not from the CPU count; settings from
`DATABASE_URL`; the statement prepared once per connection; `limit` clamped to 1 to 50,
with defaults of 10, 50, and 50; `{"items":[],"count":0}` when Postgres is unavailable,
and a connection made again on a later request, without crashing.

## Design questions

- **Whose connections.** Each worker owns `DATABASE_MAX_CONN / workers` connections on
  its loop, so a query never crosses threads, or a lane holds the pool and the workers
  ask it. The first matches the "single queries on the worker's loop" decision; the
  second shares idle connections between workers. goose-http's task 053 decides which
  thread owns an outbound connection.
- **Waiting.** A request whose worker has no idle connection waits in a queue, or
  pipelines onto a busy connection: the protocol allows several queries per
  connection, each with its sync, and one connection's pipeline may serve many
  requests.
- **The request's state.** The route waits on the loop with the entry's number and
  its connection, and resumes on `READY`; the rows are decoded straight into the JSON
  response, so none are kept. The state per request is measured against goose-rest's
  tiers.
- **Nonces.** SCRAM's client nonce comes from goose-hash's `hash::random_bytes` for
  each connection, as in task 002.

## Steps

1. Settle the pool's owner and its waiting in `docs/decisions.md`, with goose-http's
   task 053.
2. The pool: connect, authenticate, and prepare HttpArena's statement on each
   connection; hand out and take back; reconnect on failure.
3. The goose-rest program for `/async-db`, in goose-rest's entry (its task 047).
4. Tests: the pool against a live Postgres in Docker, a server that goes away and comes
   back, and HttpArena's `validate.sh` for the profile.
5. Measure the profile on a machine with HttpArena's setup, with the method recorded.

## Acceptance criteria

- [ ] The pool's design in `docs/decisions.md` and `docs/architecture.md`
- [ ] `/async-db` answers HttpArena's validation: the limits 7, 18, 33, and 50, the
      content type, and the empty range
- [ ] A lost Postgres gives the empty answer, and the pool reconnects
- [ ] Results recorded with machine, command, workers, connections, and runs
- [ ] `scripts/test.sh` and `scripts/live.sh` pass
