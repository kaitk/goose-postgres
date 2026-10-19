// SCRAM-SHA-256 with the wrong password: the server refuses the proof, and
// the connection fails with its error.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "../../";
import wire from "../";

fn main() {
    var io = wire::io(embed_file("../data/bad_password.cap"));
    let cfg, ok = pg::parse_url("postgres://bench:wrong@localhost/benchmark");
    assert(ok);
    var c = pg::Conn { .. };
    var input: u8[>..] = [];
    var out: u8[>..] = [];
    pg::start(c, out, cfg, wire::NONCE);
    wire::until_ready(io, c, input, out);
    print("ready: ", pg::ready(c));
    print("replayed the whole capture: ", wire::finished(io));
}
