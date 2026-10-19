// A facade call that can fail, outside pg::run, doesn't compile.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import wire from "../";

fn main() {
    var db = pg::Db { t: wire::io(""), .. };
    pg::exec(db, "SELECT 1");
    pg::close(db);
}
// error: return from run: no enclosing call of run on this compile-time call path
