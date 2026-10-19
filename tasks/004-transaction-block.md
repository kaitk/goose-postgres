# 004: The transaction block

Status: todo. After task 002; goose-sqlite's task 003 takes the same block.

A transaction is a block whose failure path the compiler checks (`docs/decisions.md`,
from goose-rest's task 052): `pg::transaction` runs the block between `BEGIN` and
`COMMIT`, and `pg::fail`, or any facade call in it that fails, leaves it through
`return e from`; the transaction rolls back and returns the error. A function that
calls `pg::fail` compiles only where a transaction encloses its calls, as TypeScript
libraries' "transaction as the last parameter" convention asks, enforced.

Task 052's sketch:

```rust
fn run(u: Use.PlaceOrder, db: pg::Conn&, a) {
    let order, err = pg::transaction(db) { tx =>
        let o = orders::insert(tx, u.items);  // may pg::fail at any depth
        stock::reserve(tx, u.items);
        o
    };
    ...
}
```

## What the spec allows

Checked against the pinned release's `docs/goose_spec.md` (`v2026.2`) with a spike
(2026-10-19):

- **The sketch doesn't compile as written.** `transaction` must hold the block's
  value across the catcher it runs it in, and Goose has no way to name the type of a
  block's result before calling it: a `let` without an initializer needs a type
  ("a declaration without an initializer needs a type"), and an omitted result type
  is taken from the first `return` checked (§7.1), which the catcher's `return []`
  path can't give.
- **A fixed-size result works when the call names its type**:
  `let order, err = pg::transaction<Order>(db) { tx => ... o };` with
  `fn transaction<T, F>(db) -> T, Error[]` holding `var r = default<T>();` and
  assigning `r = F(tx)` inside the catcher. On failure `order` is `T`'s default.
- **A non-fixed result can't be returned that way**: `default<T>()` needs a
  fixed-size type, so `pg::transaction<u8[>..]>` is rejected. Such a block writes into
  the caller's `var`, declared before it, as `sqlite::transaction`'s blocks do, and
  `transaction` returns only `Error[]`.
- **"Only inside a transaction" holds** when `pg::fail` returns from a catcher only
  `transaction` calls (`return e from tx_attempt`), while facade calls that fail
  return from the catcher `pg::run` shares; `transaction` moves an error from the
  inner catcher to its own. `pg::fail` inside `pg::run` alone is then a compile error:
  "return from tx_attempt: no enclosing call of tx_attempt on this compile-time call
  path". The message names the catcher, not the rule; the docs say what it means.
- **The block's parameter can be a type of its own**, `pg::Tx`, not the connection:
  a repository function that takes `tx: pg::Tx` can only be called with one a
  transaction's block handed out.

## To decide

- The two forms, `pg::transaction<T>(db) { tx => ... value }` returning `T, Error[]`
  and `pg::transaction(db) { tx => ... }` returning `Error[]`, as overloads, or one.
- A transaction inside another is a savepoint (agreed 2026-10-19, as Drizzle and other
  ORMs do): the inner block runs `SAVEPOINT`, and `RELEASE` on success or `ROLLBACK TO`
  on failure, so its failure undoes only its own work. Postgres would otherwise warn on
  a second `BEGIN` and go on inside the first transaction. goose-sqlite does the same
  (its task 003). Its `sqlite::transaction`, in v0.0.2, is the reference: it checks
  whether the connection is in a transaction, runs one savepoint name at every depth,
  `ROLLBACK TO` then `RELEASE` on failure, fails the enclosing block rather than
  return the error when the whole transaction has ended (so the outer block never
  goes on in autocommit), and tests the cases in `test/transactions/savepoint.goose`
  (its decisions record, 2026-10-19).
- Whether `BEGIN` is pipelined with the block's first query, which saves a round
  trip, and what happens when the connection breaks before `COMMIT`'s answer: the
  outcome is unknown, and the error must say so.
- Isolation levels and read-only transactions, as parameters of `transaction`.

The trap goose-sqlite recorded applies: a fully typed function that can fail breaks
`goose check` of a library, so each function that can fail keeps an untyped parameter.

## Steps

1. Settle the forms and the nesting rule in `docs/decisions.md`, replacing the
   2026-10-19 decision's open parts.
2. The block, over task 002's facade.
3. Tests, replayed and live: a block that commits, one that calls `pg::fail` at depth,
   one where a query fails, a broken connection, nesting, and `// error:` fixtures for
   `pg::fail` outside a transaction and a `Tx` parameter given a connection.
4. `docs/architecture.md`, `README.md`, and the example goose-rest's best practices
   port (its task 052).

## Acceptance criteria

- [ ] The block's forms and nesting recorded in `docs/decisions.md` and
      `docs/architecture.md`
- [ ] Commit, rollback on `pg::fail` and on a failed query, each tested live and
      replayed
- [ ] `pg::fail` outside a transaction doesn't compile, with a fixture
- [ ] goose-sqlite's task 003 gives the same block, or records where it differs
- [ ] `scripts/test.sh` and `scripts/live.sh` pass
