// The transaction block: a block that ends commits; one that calls pg::fail,
// at any depth, or where a statement fails, rolls back and returns the error;
// one that catches an error itself, which failed the transaction, rolls back
// rather than let COMMIT do it silently. Nested blocks are savepoints, each
// undoing only its own work; a block that ends the whole transaction, or
// breaks the connection, stops the outer block too.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import wire from "../lib/wire/";

// The rows of t, in order, as "1 2 3 ".
fn rows<T>(db: pg::Db<T>&) -> u8[>..] {
    var ns: u8[>..] = [];
    pg::query(db, "SELECT n FROM t ORDER BY n") { r => format(ns, pg::int(r, 0), " "); };
    return ns;
}

fn show<T>(label: const u8[:], db: pg::Db<T>&) {
    print(label, ": [", rows(db), "] in a transaction: ", pg::in_transaction(db));
}

// Fails two calls down from the block.
fn reserve<T>(db: pg::Db<T>&, n: i64) {
    pg::exec(db, "INSERT INTO t VALUES ($1)", n);
    check_stock(n);
}

// Untyped, as every function that can fail is: a fully typed one is checked
// as if called outside run.
fn check_stock(n) {
    if n > 5 { pg::fail(str("no stock for ", n)); }
}

fn main() {
    var db = pg::Db { t: wire::io(embed_file("../data/transaction.cap")), .. };
    wire::errors("connect", pg::run() { pg::connect(db, wire::config(), wire::NONCE); });
    wire::errors("run", pg::run() {
        pg::exec(db, "CREATE TEMP TABLE t (n int PRIMARY KEY)");

        print("-- one level");
        wire::errors("commits", pg::transaction(db) {
            print("inside, in a transaction: ", pg::in_transaction(db));
            pg::exec(db, "INSERT INTO t VALUES (1), (2)");
        });
        show("after it", db);
        var after = false;
        wire::errors("pg::fail, two calls down", pg::transaction(db) {
            reserve(db, 3);
            reserve(db, 6);
            after = true;
        });
        print("the block went on: ", after);
        show("3 and 6 rolled back", db);
        wire::errors("a statement fails", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (3)");
            pg::exec(db, "INSERT INTO t VALUES (1)");
            after = true;
        });
        print("the block went on: ", after);
        show("3 rolled back", db);
        wire::errors("the block catches a failed statement", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (4)");
            wire::errors("caught", pg::run() { pg::exec(db, "INSERT INTO t VALUES (1)"); });
        });
        show("4 rolled back", db);
        // The query fails at its third row, after the block has left at its
        // first: the error waits among the answers it didn't read.
        wire::errors("the block catches a failure in a row block", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (4)");
            wire::errors("caught", pg::run() {
                pg::query(db, "SELECT 10 / (3 - n) FROM generate_series(1, 5) n") { r =>
                    pg::fail("enough");
                };
            });
        });
        show("4 rolled back", db);

        print("-- nested");
        wire::errors("three levels", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (3)");
            wire::errors("second", pg::transaction(db) {
                pg::exec(db, "INSERT INTO t VALUES (4)");
                wire::errors("third", pg::transaction(db) {
                    pg::exec(db, "INSERT INTO t VALUES (5)");
                });
                wire::errors("third, failing", pg::transaction(db) {
                    pg::exec(db, "INSERT INTO t VALUES (6)");
                    pg::fail("not 6");
                });
                show("in the second", db);
            });
        });
        show("three levels, committed", db);
        pg::exec(db, "DELETE FROM t WHERE n > 2");

        wire::errors("a statement fails in the inner block", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (3)");
            wire::errors("inner", pg::transaction(db) {
                pg::exec(db, "INSERT INTO t VALUES (4)");
                pg::exec(db, "INSERT INTO t VALUES (1)");
            });
            print("the outer block goes on, in a transaction: ", pg::in_transaction(db));
            pg::exec(db, "INSERT INTO t VALUES (5)");
        });
        show("only 4 undone", db);
        pg::exec(db, "DELETE FROM t WHERE n > 2");

        wire::errors("the inner block catches a failed statement", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (3)");
            wire::errors("inner", pg::transaction(db) {
                pg::exec(db, "INSERT INTO t VALUES (4)");
                wire::errors("caught", pg::run() { pg::exec(db, "INSERT INTO t VALUES (1)"); });
            });
            pg::exec(db, "INSERT INTO t VALUES (5)");
        });
        show("only 4 undone", db);
        pg::exec(db, "DELETE FROM t WHERE n > 2");

        wire::errors("the outer block fails", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (3)");
            wire::errors("inner", pg::transaction(db) {
                pg::exec(db, "INSERT INTO t VALUES (4)");
            });
            pg::fail("not any");
        });
        show("the released inner rows undone too", db);

        pg::exec(db, "BEGIN");
        pg::exec(db, "INSERT INTO t VALUES (3)");
        wire::errors("inside exec's BEGIN", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (4)");
        });
        wire::errors("inside exec's BEGIN, failing", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (5)");
            pg::fail("not 5");
        });
        print("still in exec's transaction: ", pg::in_transaction(db));
        pg::exec(db, "COMMIT");
        show("exec's COMMIT keeps 3 and 4", db);
        pg::exec(db, "DELETE FROM t WHERE n > 2");

        // ROLLBACK in the inner block ends the whole transaction: the inner
        // error fails the outer block at the inner call, rather than let it
        // go on outside a transaction.
        after = false;
        wire::errors("the inner block ends the whole transaction", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (3)");
            wire::errors("inner, not returned", pg::transaction(db) {
                pg::exec(db, "ROLLBACK");
            });
            after = true;
            pg::exec(db, "INSERT INTO t VALUES (4)");
        });
        print("the outer block went on: ", after);
        show("3 rolled back, 4 never inserted", db);

        // Last: the server ends the session inside the inner block.
        wire::errors("the connection breaks in the inner block", pg::transaction(db) {
            pg::exec(db, "INSERT INTO t VALUES (3)");
            wire::errors("inner, not returned", pg::transaction(db) {
                pg::exec(db, "SELECT pg_terminate_backend(pg_backend_pid())");
            });
            after = true;
        });
        print("the outer block went on: ", after);
    });
    wire::errors("after it", pg::run() { pg::exec(db, "SELECT 1"); });
    pg::close(db);
    print("replayed the whole capture: ", wire::finished(db.t));
}
