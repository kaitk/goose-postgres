# 003: Queries in parallel on one connection

Status: todo. After task 002.

The protocol pipelines: any number of entries go out in one write, and every result
comes back matched to its entry by number (`docs/architecture.md`, "Entries"). A lane
job needs that as a library call, as `Promise.all` gives a TypeScript service several
queries "in parallel": one round trip for all of them, on one connection, and the
results in the job's variables (goose-rest's task 052).

## Design questions

- **The call's shape.** A block that queues the queries and a second that reads the
  results, `pg::together(db) { p => a = pg::add(p, ...); b = pg::add(p, ...); }`, or
  one call per result kind that takes several statements. Goose's function values
  can't be stored (spec §7.6), so the facade can't keep callbacks to run as rows
  arrive; it can hand each query's rows to a block in order, or collect them.
- **Errors.** One sync for the batch makes it one implicit transaction: the first error
  fails the call, and the server skips the rest (`SKIPPED`). A sync per query lets the
  others run and commit on their own. `Promise.all` rejects on the first error, but
  the others' effects stay; pick the default and offer the other.
- **The describe each query brings.** Each query describes its portal, which costs the
  server about 25 bytes per column per query (`docs/decisions.md`). A statement the
  connection prepared with `Describe` of the statement has its columns once; with
  those kept per statement, a query can skip its `Describe`, and the decoders read the
  kept columns. Measure the difference on HttpArena's query before choosing.
- **Limits.** `QUEUE` (1,024) entries wait at once; a batch larger than `pg::room`
  needs splitting or an error.

## Steps

1. Settle the shape and the error default in `docs/decisions.md`.
2. The call, over task 002's facade.
3. Tests: a batch of queries in one round trip, replayed and live; one that fails, under
   each error mode; and a batch past `QUEUE`.
4. The describe question measured: HttpArena's query with and without `Describe`, on
   the same machine, with the method recorded.

## Acceptance criteria

- [ ] The API and its error modes in `docs/decisions.md` and `docs/architecture.md`
- [ ] Several queries in one round trip, their results matched in order, with tests
- [ ] The cost of `Describe` per query measured, and the decision recorded
- [ ] `scripts/test.sh` and `scripts/live.sh` pass
