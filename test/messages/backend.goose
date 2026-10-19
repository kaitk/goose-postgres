// The server's messages that recorded sessions don't have: messages cut at
// any point, several in one read, and each way a connection fails, from an
// unsupported authentication to a server that breaks the protocol.
import std;
import base64;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import check from "../";

fn started(c: pg::Conn&, cleartext: bool = true) {
    var out: u8[>..] = [];
    let parsed, ok = pg::parse_url("postgres://u:pw@localhost/db");
    assert(ok);
    var cfg = parsed;
    cfg.allow_cleartext = cleartext;
    pg::start(c, out, cfg, "0123456789abcdefgh");
}

// Steps c once over input, printing the event, what it consumed, and why it
// failed.
fn step(label: const u8[:], c: pg::Conn&, input: const u8[:]) -> i64 {
    var out: u8[>..] = [];
    let e, body = pg::step(c, input, out);
    var line: u8[>..] = [];
    format(line, label, ": ", check::event(e), ", used ", c.used);
    if e == pg::WANT_INPUT { format(line, ", need ", c.need); }
    if e == pg::FAILED { format(line, ": ", c.reason); }
    if e == pg::ERROR || (e == pg::FAILED && body.len > 0) { format(line, " [", pg::field(body, 'C'), "]"); }
    if out.len > 0 { format(line, ", sent ", out.len, " bytes"); }
    print(line);
    return e;
}

// A connection through a cleartext login, ready for entries; the first time,
// with what it checked.
var logins = 0;

fn opened(c: pg::Conn&) {
    logins++;
    started(c);
    var input: u8[>..] = [];
    check::message(input, 'R', check::auth(3, ""));
    check::message(input, 'R', check::auth(0, ""));
    check::message(input, 'S', "server_version\x0018.0\0");
    check::message(input, 'K', "\0\0\x01\x02\0\0\0\x07");
    check::message(input, 'Z', "I");
    var out: u8[>..] = [];
    let e, body = pg::step(c, input, out);
    let ok = e == pg::READY && c.used == input.len && pg::ready(c);
    guard logins == 1 else {
        assert(ok);
        return;
    }
    check::bytes("the password, sent in cleartext", out, "p\0\0\0\x07pw\0");
    check::that("five messages in one read, then READY", ok);
    check::that("BackendKeyData kept", c.pid == 258 && c.secret == 7);
    check::that("the password dropped once used", c.password.len == 0);
}

fn main() {
    var c = pg::Conn { .. };
    step("step before start", c, "");

    print("-- messages cut short");
    started(c);
    step("3 bytes", c, "R\0\0");
    var r: u8[>..] = [];
    check::message(r, 'R', check::auth(0, ""));
    step("6 of AuthenticationOk's 9 bytes", c, r[..6]);
    step("a length of 3", c, "R\0\0\0\x03");

    print("-- authentication the client refuses");
    started(c);
    step("MD5", c, check::message_of('R', check::auth(5, "salt")));
    started(c);
    step("GSSAPI", c, check::message_of('R', check::auth(7, "")));
    started(c, false);
    step("a cleartext password, by default", c, check::message_of('R', check::auth(3, "")));
    check::that("the password dropped when the connection broke", c.password.len == 0);
    started(c);
    step("SASL with only SCRAM-SHA-256-PLUS", c, check::message_of('R', check::auth(10, "SCRAM-SHA-256-PLUS\0\0")));
    started(c);
    step("SASL", c, check::message_of('R', check::auth(10, "SCRAM-SHA-256\0\0")));
    step("then AuthenticationOk without SCRAM's final message", c, check::message_of('R', check::auth(0, "")));
    started(c);
    step("SASL", c, check::message_of('R', check::auth(10, "SCRAM-SHA-256\0\0")));
    step("a server nonce that doesn't extend the client's", c,
         check::message_of('R', check::auth(11, "r=abc,s=c2FsdA==,i=4096")));
    started(c);
    step("SASL", c, check::message_of('R', check::auth(10, "SCRAM-SHA-256\0\0")));
    step("an iteration count above MAX_ITERATIONS", c,
         check::message_of('R', check::auth(11, str("r=", c.nonce, "xyz,s=c2FsdA==,i=1000001"))));
    started(c);
    step("SASL", c, check::message_of('R', check::auth(10, "SCRAM-SHA-256\0\0")));
    step("SASLContinue", c, check::message_of('R', check::auth(11, str("r=", c.nonce, "xyz,s=c2FsdA==,i=4096"))));
    let zero: u8[32] = [0; 32];
    var zeros: u8[>..] = [];
    base64::encode(zeros, zero);
    step("a wrong server signature", c, check::message_of('R', check::auth(12, str("v=", zeros))));
    started(c);
    step("an ErrorResponse at startup", c,
         check::message_of('E', "SFATAL\0VFATAL\0C28P01\0Mpassword authentication failed\0\0"));
    step("and after it", c, check::message_of('R', check::auth(0, "")));

    print("-- a connection that's open");
    opened(c);
    step("a DataRow with nothing queued", c, check::message_of('D', "\0\0"));
    opened(c);
    step("a ReadyForQuery with nothing queued", c, check::message_of('Z', "I"));
    opened(c);
    var out: u8[>..] = [];
    pg::execute(c, out, pg::bind(out, ""));
    step("an unknown message", c, check::message_of('q', ""));
    opened(c);
    pg::execute(c, out, pg::bind(out, ""));
    step("a FATAL error while a query waits", c,
         check::message_of('E', "SFATAL\0VFATAL\0C57P01\0Mterminating connection\0\0"));
    opened(c);
    pg::execute(c, out, pg::bind(out, ""));
    step("a RowDescription of 129 columns", c, check::message_of('T', "\0\x81"));
    opened(c);
    pg::execute(c, out, pg::bind(out, ""));
    step("a DataRow cut short", c, check::message_of('D', "\0\x01\0\0\0\x05ab"));
    step("and after it", c, check::message_of('Z', "I"));

    print("-- an error at a sync, after its query's results");
    opened(c);
    pg::execute(c, out, pg::bind(out, ""));
    pg::sync(c, out);
    var input: u8[>..] = [];
    check::message(input, '2', "");
    check::message(input, 'n', "");
    check::message(input, 'C', "INSERT 0 1\0");
    check::message(input, 'N', "SWARNING\0VWARNING\0C01000\0Mcareful\0\0");
    check::message(input, 'E', "SERROR\0VERROR\0C23503\0Mdeferred constraint\0\0");
    check::message(input, 'Z', "I");
    var at = 0;
    for k in 4 {
        let e = step(str("event ", k), c, input[at..]);
        print("  entry ", c.seq);
        at += c.used;
    }
    check::that("all of input consumed", at == input.len);
}
