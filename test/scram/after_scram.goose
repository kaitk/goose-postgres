// A server that completes SCRAM, proving it knows the password, then asks for
// it in cleartext: arena's recorded login up to SASLFinal, with a cleartext
// request in place of AuthenticationOk. The client refuses it even with
// cleartext allowed, and sends nothing more.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import check from "../";
import wire from "../";

fn main() {
    let cap = embed_file("../data/arena.cap");
    var crafted: u8[>..] = [];
    var pos = 0;
    // The startup, SASL, and SCRAM's two exchanges, as recorded.
    for k in 5 {
        let n = wire::length(cap, pos + 1);
        crafted.append(cap[pos..pos + 5 + n]);
        pos += 5 + n;
    }
    // The next server record starts with SASLFinal.
    let record = cap[pos + 5..];
    check::that("the record starts with SASLFinal", record[0] == 'R' && pg::get32(record, 5) == 12);
    let final = record[..1 + pg::get32(record, 1)];
    var answer: u8[>..] = [];
    answer.append(final);
    check::message(answer, 'R', check::auth(3, ""));
    crafted.push('S');
    pg::put32(crafted, answer.len);
    crafted.append(answer);

    var io = wire::io(crafted);
    var cfg = wire::config();
    cfg.allow_cleartext = true;
    var c = pg::Conn { .. };
    var input: u8[>..] = [];
    var out: u8[>..] = [];
    pg::start(c, out, cfg, wire::NONCE);
    wire::until_ready(io, c, input, out);
    print("ready: ", pg::ready(c), ", sent all the client's records: ", wire::finished(io));
}
