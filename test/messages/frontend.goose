// The messages the client writes, byte for byte, against the layouts in
// PostgreSQL's "Message Formats", and the entry numbers they're queued with.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.2";
import pg from "../../";
import check from "../";

fn main() {
    var c = pg::Conn { .. };
    var out: u8[>..] = [];
    let cfg, ok = pg::parse_url("postgres://bench:bench@localhost/benchmark");
    assert(ok);
    pg::start(c, out, cfg, "0123456789abcdefgh");
    check::bytes("StartupMessage", out,
                 "\0\0\0\x3c\0\x03\0\0user\0bench\0database\0benchmark\0client_encoding\0UTF8\0\0");
    check::text("the client nonce, base64", c.nonce, "MDEyMzQ1Njc4OWFiY2RlZmdo");
    out.clear();

    let nodb, nodb_ok = pg::parse_url("postgres://bench@localhost");
    assert(nodb_ok);
    pg::start(c, out, nodb, "0123456789abcdefgh");
    check::bytes("StartupMessage without a database", out,
                 "\0\0\0\x29\0\x03\0\0user\0bench\0client_encoding\0UTF8\0\0");
    out.clear();

    c.state = pg::OPEN;
    check::eq("room", pg::room(c), pg::QUEUE);
    check::eq("Parse's entry", pg::parse(c, out, "s", "SELECT $1"), 0);
    check::bytes("Parse", out, "P\0\0\0\x12s\0SELECT $1\0\0\0");
    out.clear();

    let b = pg::bind(out, "s");
    pg::param(out, b, "ab");
    pg::param(out, b, -7);
    pg::param(out, b, true);
    pg::param_null(out, b);
    check::eq("the query's entry", pg::execute(c, out, b, pg::BINARY), 1);
    check::bytes("Bind, Describe, and Execute", out,
                 str("B\0\0\0\x24\0s\0\0\0\0\x04\0\0\0\x02ab\0\0\0\x02-7\0\0\0\x01t\xff\xff\xff\xff\0\x01\0\x01",
                     "D\0\0\0\x06P\0",
                     "E\0\0\0\x09\0\0\0\0\0"));
    out.clear();

    let p = pg::bind(out, "", "portal");
    pg::execute(c, out, p, pg::TEXT, 100);
    check::bytes("a named portal, with a row limit", out,
                 str("B\0\0\0\x14portal\0\0\0\0\0\0\0\x01\0\0",
                     "D\0\0\0\x0cPportal\0",
                     "E\0\0\0\x0fportal\0\0\0\0\x64"));
    out.clear();

    check::eq("Sync's entry", pg::sync(c, out), 3);
    check::bytes("Sync", out, "S\0\0\0\x04");
    out.clear();
    pg::terminate(out);
    check::bytes("Terminate", out, "X\0\0\0\x04");
    check::eq("room after four entries", pg::room(c), pg::QUEUE - 4);
}
