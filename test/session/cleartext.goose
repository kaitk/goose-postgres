// A user whose pg_hba.conf line is `password`: the server asks for the
// password in cleartext.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import wire from "../";

fn main() {
    var io = wire::io(embed_file("../data/cleartext.cap"));
    let cfg, ok = pg::parse_url("postgres://plain:plain%20pass@localhost/benchmark");
    assert(ok);
    var c = pg::Conn { .. };
    var input: u8[>..] = [];
    var out: u8[>..] = [];
    pg::start(c, out, cfg, wire::NONCE);
    wire::until_ready(io, c, input, out);
    guard pg::ready(c);
    pg::parse(c, out, "", "SELECT current_user, count(*) FROM items");
    let b = pg::bind(out, "");
    pg::execute(c, out, b);
    pg::sync(c, out);
    wire::until_ready(io, c, input, out);
    pg::terminate(out);
    wire::send(io, out);
    print("replayed the whole capture: ", wire::finished(io));
}
