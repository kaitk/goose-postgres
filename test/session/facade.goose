// The blocking facade over the session tests' I/O: a call before connecting,
// a connection, and the facade's calls in wire::facade.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "../../";
import wire from "../";

fn main() {
    var db = pg::Db { t: wire::io(embed_file("../data/facade.cap")), .. };
    wire::errors("before connecting", pg::run() { pg::exec(db, "SELECT 1"); });
    wire::errors("connect", pg::run() { pg::connect(db, wire::config(), wire::NONCE); });
    wire::facade(db);
    print("replayed the whole capture: ", wire::finished(db.t));
}
