// Statements prepared once by name, against a faked server: a statement
// parses on its first run only, until STATEMENTS are kept, and past that, or
// past STATEMENT_TEXT bytes of SQL, a query parses as the unnamed statement
// each time. A connection made again prepares its statements again.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "../../";
import check from "../";
import fake from "../";

fn run(db: pg::Db<fake::Server>&, sql: const u8[:]) {
    let before = db.t.parses;
    let failed = pg::run() { pg::exec(db, sql); };
    assert(failed.len == 0);
    if db.t.parses == before { print(sql[..min(sql.len, 24)], ": prepared already"); }
    else { print(sql[..min(sql.len, 24)], ": parsed as \"", db.t.name, "\""); }
}

fn main() {
    var db = pg::Db { t: fake::Server { .. }, .. };
    let failed = pg::run() { pg::connect(db, fake::config()); };
    assert(failed.len == 0);
    run(db, "SELECT 0");
    run(db, "SELECT 0");
    run(db, "SELECT 1");
    for k in 2..pg::STATEMENTS {
        var sql: u8[>..] = [];
        format(sql, "SELECT ", k);
        let errs = pg::run() { pg::exec(db, sql); };
        assert(errs.len == 0);
    }
    print("statements kept: ", db.statements, ", parses: ", db.t.parses);
    run(db, "SELECT 64");
    run(db, "SELECT 64");
    run(db, "SELECT 63");
    run(db, "SELECT 0");

    pg::close(db);
    db.t = fake::Server { .. };
    let again = pg::run() { pg::connect(db, fake::config()); };
    assert(again.len == 0);
    run(db, "SELECT 0");
    var long: u8[>..] = [];
    long.append("SELECT 1 -- ");
    for k in pg::STATEMENT_TEXT { long.push('x'); }
    run(db, long);
    run(db, long);
    run(db, "SELECT 0");
    pg::close(db);
}
