// A query on the connection whose rows a block is reading doesn't compile:
// the rows are views into the bytes the next call reuses.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "../../";
import wire from "../";

fn main() {
    var db = pg::Db { t: wire::io(""), .. };
    let failed = pg::run() {
        pg::query(db, "SELECT id FROM orders") { r =>
            pg::exec(db, "UPDATE stock SET n = n - 1 WHERE id = $1", pg::int(r, 0));
        };
    };
}
// error: it shrinks db while db is still used
