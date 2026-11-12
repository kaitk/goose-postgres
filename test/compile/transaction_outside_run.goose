// A transaction can fail its caller, nested in another, so it compiles only
// inside pg::run or another transaction, as a facade call does.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import wire from "../lib/wire/";

fn main() {
    var db = pg::Db { t: wire::io(""), .. };
    let failed = pg::transaction(db) { pg::exec(db, "SELECT 1"); };
    pg::close(db);
}
// error: call to fail requires an enclosing call of run
