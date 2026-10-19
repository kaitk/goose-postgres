// The blocking facade over the session tests' I/O: a connection, queries with
// parameters of each kind, each statement prepared once, commands' counts,
// errors through pg::run with the connection usable after each, a failure in
// a row block, and the transaction status a transaction block reads,
// savepoints included.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "../../";
import wire from "../";

fn errors(label: const u8[:], failed: const pg::Error[:]) {
    if failed.len == 0 { print(label, ": no error"); }
    for e in failed { print(label, ": ", e.code, " ", e.message); }
}

fn main() {
    var db = pg::Db { t: wire::io(embed_file("../data/facade.cap")), .. };
    errors("before connecting", pg::run() { pg::exec(db, "SELECT 1"); });
    errors("connect", pg::run() { pg::connect(db, wire::config(), wire::NONCE); });

    print("-- HttpArena's query, twice: prepared once");
    errors("arena", pg::run() {
        for lo in [10, 20] {
            var line: u8[>..] = [];
            let n = pg::query(db, wire::ARENA_SQL, lo, lo + 5, 3) { r =>
                format(line, " ", pg::int(r, 0), ":", pg::text(r, 1), ":", pg::boolean(r, 5));
            };
            print(n, " rows:", line);
        }
    });

    print("-- parameters of each kind");
    errors("parameters", pg::run() {
        let s: u8[>..] = str("bytes");
        pg::query(db, "SELECT $1::int8 + 1, NOT $2::bool, $3::text || '!', $4::text IS NULL, $5::int4",
                  -9000000000, false, s, pg::NULL, 7) { r =>
            print(pg::field_count(r), " fields: ", pg::int(r, 0), " ", pg::boolean(r, 1), " ",
                  pg::text(r, 2), " ", pg::boolean(r, 3), " ", pg::int(r, 4), " null ",
                  pg::is_null(r, 4));
        };
        pg::query(db, "SELECT NULL::text, $1::text", "") { r =>
            print("NULL: ", pg::is_null(r, 0), ", empty: ", pg::is_null(r, 1));
        };
    });

    print("-- commands' counts");
    errors("commands", pg::run() {
        print("create: ", pg::exec(db, "CREATE TEMP TABLE t (n int PRIMARY KEY, s text NOT NULL)"));
        print("insert: ", pg::exec(db, "INSERT INTO t SELECT g, 'n' || g FROM generate_series(1, $1::int) g", 5));
        print("update: ", pg::exec(db, "UPDATE t SET s = $1 WHERE n > $2", "big", 3));
        print("delete: ", pg::exec(db, "DELETE FROM t WHERE n = $1", 1));
        print("select: ", pg::exec(db, "SELECT * FROM t"));
    });

    print("-- errors, each leaving the connection usable");
    errors("division", pg::run() { pg::exec(db, "SELECT 10 / $1::int", 0); });
    errors("syntax", pg::run() { pg::exec(db, "SELEC 1"); });
    errors("syntax again, parsed again", pg::run() { pg::exec(db, "SELEC 1"); });
    let dup = pg::run() { pg::exec(db, "INSERT INTO t VALUES ($1, $2)", 2, "two"); };
    errors("duplicate", dup);
    for e in dup {
        print("unique violation: ", e.code == pg::UNIQUE_VIOLATION, ", class ", pg::class(e.code));
    }
    errors("the program's own", pg::run() {
        pg::exec(db, "SELECT 1");
        pg::fail("not enough stock");
    });
    var seen = 0;
    errors("a failure in a row block", pg::run() {
        pg::query(db, "SELECT n FROM t ORDER BY n") { r =>
            seen++;
            if pg::int(r, 0) == 3 { pg::fail("23514", "three is too many"); }
        };
    });
    print("rows seen before it: ", seen);
    errors("after it", pg::run() {
        pg::query(db, "SELECT count(*) FROM t") { r => print("count: ", pg::int(r, 0)); };
    });

    print("-- the transaction status, and savepoints");
    errors("transaction", pg::run() {
        print("in a transaction: ", pg::in_transaction(db));
        pg::exec(db, "BEGIN");
        print("after BEGIN: ", pg::in_transaction(db));
        pg::exec(db, "INSERT INTO t VALUES (10, 'ten')");
        pg::exec(db, "SAVEPOINT goose_pg");
        errors("in the savepoint", pg::run() { pg::exec(db, "INSERT INTO t VALUES (10, 'again')"); });
        print("failed: ", pg::in_transaction(db), " ", pg::exec(db, "SELECT 1") == 1);
    });
    errors("rolled back to the savepoint", pg::run() {
        pg::exec(db, "ROLLBACK TO goose_pg");
        pg::exec(db, "RELEASE goose_pg");
        pg::exec(db, "COMMIT");
        print("after COMMIT: ", pg::in_transaction(db), ", ten kept: ",
              pg::exec(db, "SELECT 1 FROM t WHERE n = 10"));
    });

    pg::close(db);
    errors("after close", pg::run() { pg::exec(db, "SELECT 1"); });
    print("replayed the whole capture: ", wire::finished(db.t));
}
