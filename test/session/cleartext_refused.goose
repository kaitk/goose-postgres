// cleartext's user, with settings that don't allow a cleartext password: the
// client refuses the server's request, and sends no password.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import wire from "../";

fn main() {
    var io = wire::io(embed_file("../data/cleartext_refused.cap"));
    let cfg, ok = pg::parse_url("postgres://plain:plain%20pass@localhost/benchmark");
    assert(ok);
    var c = pg::Conn { .. };
    var input: u8[>..] = [];
    var out: u8[>..] = [];
    pg::start(c, out, cfg, wire::NONCE);
    wire::until_ready(io, c, input, out);
    print("ready: ", pg::ready(c), ", password kept: ", c.password.len > 0);
}
