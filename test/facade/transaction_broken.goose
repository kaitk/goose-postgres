// A transaction on a connection that breaks, against a faked server: lost in
// the middle of the block's query, the rollback fails too, and the block's
// error is returned; a send of COMMIT that fails leaves the outcome unknown,
// and the error says so. Neither waits for a server that is gone.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import check from "../lib/check/";
import fake from "../lib/fake/";

fn errors(label: const u8[:], failed: const pg::Error[:]) {
    if failed.len == 0 { print(label, ": no error"); }
    for e in failed { print(label, ": ", e.code, " ", e.message); }
}

fn main() {
    var db = pg::Db { t: fake::Server { rows: 1, .. }, .. };
    errors("connect", pg::run() { pg::connect(db, fake::config()); });
    errors("run", pg::run() {
        errors("lost in the block", pg::transaction(db) {
            pg::exec(db, "INSERT 1");
            db.t.mode = fake::CUT;
            pg::exec(db, "INSERT 2");
        });
        errors("a call after it", pg::run() { pg::exec(db, "SELECT 1"); });
    });

    db.t = fake::Server { rows: 1, .. };
    errors("connect again", pg::run() { pg::connect(db, fake::config()); });
    errors("run", pg::run() {
        errors("COMMIT's send fails", pg::transaction(db) {
            pg::exec(db, "INSERT 1");
            db.t.fail_send = true;
        });
    });
    pg::close(db);
}
