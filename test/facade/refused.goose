// What the facade refuses before sending, against a faked server: settings
// whose names hold a NUL, SQL with a NUL, and more than 65535 parameters,
// which leave the connection usable.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import check from "../";
import fake from "../";

fn errors(label: const u8[:], failed: const pg::Error[:]) {
    if failed.len == 0 { print(label, ": no error"); }
    for e in failed { print(label, ": ", e.code, " ", e.message); }
}

fn main() {
    var db = pg::Db { t: fake::Server { rows: 1, .. }, .. };
    errors("a URL user with a NUL", pg::run() { pg::connect(db, "postgres://x%00options%00-c@localhost/db"); });
    var cfg = fake::config();
    cfg.user.clear();
    cfg.user.append("x\0options\0-c");
    errors("a Config user with a NUL", pg::run() { pg::connect(db, cfg); });
    check::that("nothing sent", !db.t.started);

    errors("connect", pg::run() { pg::connect(db, fake::config()); });
    let parses = db.t.parses;
    errors("SQL with a NUL", pg::run() { pg::exec(db, "SELECT 1\0; DROP TABLE t"); });
    check::that("nothing sent", db.t.parses == parses && db.t.pending.len == 0);
    errors("a query after it", pg::run() {
        print("rows: ", pg::query(db, "SELECT n") { r => });
    });

    var many = pg::Params { .. };
    for k in 65536 { pg::param(many, k); }
    let before = db.t.parses;
    errors("65536 parameters", pg::run() { pg::exec(db, "SELECT n WHERE n > $1", many); });
    check::that("its Parse sent", db.t.parses == before + 1);
    errors("the statement after it, with one", pg::run() {
        print("rows: ", pg::query(db, "SELECT n WHERE n > $1", 0) { r => });
    });
    check::that("bound, not parsed again", db.t.parses == before + 1);
    pg::close(db);
}
