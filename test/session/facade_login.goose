// The facade's connect with a URL that isn't one, then with the wrong
// password: each error through pg::run, and no call works after.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "../../";
import wire from "../";

fn errors(label: const u8[:], failed: const pg::Error[:]) {
    if failed.len == 0 { print(label, ": no error"); }
    for e in failed { print(label, ": ", e.code, " ", e.message); }
}

fn main() {
    var db = pg::Db { t: wire::io(embed_file("../data/facade_login.cap")), .. };
    errors("not a URL", pg::run() { pg::connect(db, "mysql://bench@localhost/benchmark"); });
    let cfg, ok = pg::parse_url("postgres://bench:wrong@localhost/benchmark");
    assert(ok);
    errors("wrong password", pg::run() { pg::connect(db, cfg, wire::NONCE); });
    errors("a query after it", pg::run() { pg::exec(db, "SELECT 1"); });
    pg::close(db);
    print("replayed the whole capture: ", wire::finished(db.t));
}
