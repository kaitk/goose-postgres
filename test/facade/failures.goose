// The ways a facade connection fails, against a faked server: lost in the
// middle of a result, ended by a FATAL error, a send that fails, and calls
// after each, which fail without touching the transport until it connects
// again.
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
    var db = pg::Db { t: fake::Server { rows: 3, .. }, .. };
    errors("connect", pg::run() { pg::connect(db, fake::config()); });
    errors("three rows", pg::run() {
        var sum = 0;
        print("rows: ", pg::query(db, "SELECT n") { r => sum += pg::int(r, 0); }, ", sum ", sum);
    });

    db.t.mode = fake::CUT;
    var seen = 0;
    errors("lost in a result", pg::run() { pg::query(db, "SELECT n") { r => seen++; }; });
    print("rows before it: ", seen);
    errors("a call after it", pg::run() { pg::exec(db, "SELECT 1"); });
    pg::close(db);
    errors("a call after close", pg::run() { pg::exec(db, "SELECT 1"); });

    db.t = fake::Server { mode: fake::FATAL, .. };
    errors("connect again", pg::run() { pg::connect(db, fake::config()); });
    errors("a FATAL error", pg::run() { pg::exec(db, "SELECT n"); });
    errors("a call after it", pg::run() { pg::exec(db, "SELECT 1"); });

    db.t = fake::Server { .. };
    errors("connect by URL, which allows no cleartext password", pg::run() {
        pg::connect(db, "postgres://u:pw@localhost/db");
    });
    db.t = fake::Server { .. };
    errors("connect again", pg::run() { pg::connect(db, fake::config()); });
    db.t.fail_send = true;
    errors("a send that fails", pg::run() { pg::exec(db, "SELECT 1"); });
    errors("a call after it", pg::run() { pg::exec(db, "SELECT 1"); });
    pg::close(db);
}
