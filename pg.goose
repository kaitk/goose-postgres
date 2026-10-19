// The package's entry: PostgreSQL's frontend/backend protocol 3.0 as bytes in
// and bytes out. A connection's state, Conn, appends the messages to send to
// the caller's buffer and reads the server's from the bytes the caller
// received; the caller owns the socket (docs/architecture.md).
//
//   var c = pg::Conn { .. };
//   var out: u8[>..] = [];
//   pg::start(c, out, cfg, nonce);     // the startup message
//   // send out, read into input, then:
//   let e, body = pg::step(c, input, out);
//
// Authentication (SCRAM-SHA-256 or a cleartext password) is in scram.goose,
// the decoding of rows in decode.goose, postgres:// URLs in url.goose, and the
// blocking facade over a transport the caller supplies in facade.goose.
namespace pg;

import std;
import base64;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import .scram;
import .decode;
import .url;
import .facade;

// What step returns: an event, with the body of the message it came from.
// Every queued entry ends in exactly one of PARSED, DONE, SUSPENDED, ERROR,
// SKIPPED (a parse or a query), or READY (a sync), in the order queued, and
// c.seq names it.
let WANT_INPUT = 0;  // the input holds no whole message more: read, then step again
let READY = 1;       // ReadyForQuery: a sync's results are all in, or startup is done
let COLUMNS = 2;     // RowDescription: the columns of the rows that follow
let ROW = 3;         // DataRow: the body is the row, which decode.goose reads
let DONE = 4;        // CommandComplete, or EmptyQueryResponse: the body is the tag
let ERROR = 5;       // ErrorResponse for an entry: the body holds its fields
let SKIPPED = 6;     // an entry the server skipped after an earlier error
let PARSED = 7;      // ParseComplete
let SUSPENDED = 8;   // PortalSuspended: Execute's row limit reached
let NOTICE = 9;      // NoticeResponse: the body holds its fields
let FAILED = 10;     // the connection can't go on: c.reason says why, and a
                     // server's error is in the body

// Result formats, one for all of a query's columns.
let TEXT = 0;
let BINARY = 1;

// A connection's states.
let NEW = 0;         // before start
let STARTING = 1;    // the startup message sent; authenticating
let SASL = 2;        // SCRAM's first message sent
let SASL_FINAL = 3;  // SCRAM's final message sent
let AUTHED = 4;      // AuthenticationOk received; waiting for ReadyForQuery
let OPEN = 5;        // ready for queries, or answering them
let BROKEN = 6;      // failed: c.reason says why

// The kinds of queued entries.
let PARSE = 1;
let QUERY = 2;
let SYNC = 3;

// The most entries that wait at once, and the most columns a row may have.
let QUEUE = 1024;
let MAX_COLUMNS = 128;
// The longest message step accepts: Postgres's own limit on a field is 1 GB.
let MAX_MESSAGE = 1 << 30;

// A connection: its state, the entries queued and not yet answered, and the
// columns of the rows arriving. A fixed-size value, so a pool keeps its
// connections in an array.
struct Conn {
    state: i64 = NEW,
    // What the last step consumed from the front of its input, and, when it
    // returned WANT_INPUT, how many bytes from there the next message needs.
    used: i64 = 0,
    need: i64 = 0,
    // The entry the last event belongs to; -1 for startup's READY.
    seq: i64 = -1,
    // ReadyForQuery's transaction status: 'I' idle, 'T' in a transaction,
    // 'E' in a failed one.
    status: u8 = 0,
    // BackendKeyData, for a cancel request.
    pid: i32 = 0,
    secret: u32 = 0,
    reason: u8[..120],
    // Authentication: the password until it's used, whether the server may
    // ask for it in cleartext, whether SCRAM began, after which it may not,
    // SCRAM's client nonce, and the server signature it expects.
    password: u8[..256],
    cleartext: bool = false,
    sasl: bool = false,
    nonce: u8[..64],
    server_signature: u8[32],
    // The queue: kinds[head], and the count after it, wait for answers; the
    // next entry queued gets number next.
    kinds: u8[QUEUE],
    head: i64 = 0,
    count: i64 = 0,
    next: i64 = 0,
    // The last RowDescription's columns: type and format.
    columns: i64 = 0,
    oid: u32[MAX_COLUMNS],
    format: u8[MAX_COLUMNS],
    // The last DataRow's fields: offset and length in its body, -1 for NULL.
    fields: i64 = 0,
    at: i32[MAX_COLUMNS],
    len: i32[MAX_COLUMNS],
}

// A Bind message being written: where its length and its parameter count
// are, and whether its names were written, which execute checks.
struct Bind { at: i64, count_at: i64, ok: bool }

// Starts c on a connection the caller opened: appends the startup message to
// out, for protocol 3.0 with client_encoding UTF8, and keeps cfg's password
// for the authentication the server asks for. nonce is SCRAM's client nonce:
// at least 18 bytes the caller drew from a secure source, used once. A user
// or database with a NUL breaks c, with out unchanged.
fn start(c: Conn&, out: u8[>..]&, cfg: Config, nonce: const u8[:]) {
    c = Conn { .. };
    c.state = STARTING;
    c.cleartext = cfg.allow_cleartext;
    c.password.append(cfg.password);
    var n: u8[>..] = [];
    base64::encode(n, nonce[..min(nonce.len, 45)]);
    c.nonce.append(n);
    let at = out.len;
    put32(out, 0);
    put32(out, 196608);
    cstr(out, "user");
    var ok = cstr(out, cfg.user);
    if cfg.database.len > 0 {
        cstr(out, "database");
        ok = ok && cstr(out, cfg.database);
    }
    guard ok else {
        out.resize(at);
        broken(c, "the user or database name holds a NUL byte");
        return;
    }
    cstr(out, "client_encoding");
    cstr(out, "UTF8");
    out.push(0);
    patch32(out, at, out.len - at);
}

// Whether c is ready for entries: authenticated and not failed. Entries may
// be queued from the startup's READY on.
fn ready(c: const Conn&) -> bool { c.state == OPEN }

// How many more entries may be queued now.
fn room(c: const Conn&) -> i64 { QUEUE - c.count }

// Queues a Parse of sql as the statement name, "" for the unnamed one, and
// returns its number. The server infers the parameters' types. A name or
// SQL with a NUL breaks c, and returns -1 with out unchanged.
fn parse(c: Conn&, out: u8[>..]&, name: const u8[:], sql: const u8[:]) -> i64 {
    let at = begin(out, 'P');
    guard cstr(out, name) && cstr(out, sql) else {
        out.resize(at - 1);
        broken(c, "a statement's name or SQL holds a NUL byte");
        return -1;
    }
    put16(out, 0);
    end(out, at);
    return queue(c, PARSE);
}

// Starts a Bind of statement to portal ("" for the unnamed ones). Add each
// parameter in order with param or param_null, then queue the query with
// execute, which breaks c, and returns -1 with the Bind dropped from out,
// when either name has a NUL.
fn bind(out: u8[>..]&, statement: const u8[:], portal: const u8[:] = "") -> Bind {
    let at = begin(out, 'B');
    let ok = cstr(out, portal) && cstr(out, statement);
    if !ok {
        // Empty names keep the message's layout for the parameters that
        // follow, until execute drops it all.
        out.resize(at + 4);
        cstr(out, "");
        cstr(out, "");
    }
    put16(out, 0);              // no format codes: every parameter is text
    let count_at = out.len;
    put16(out, 0);
    return Bind { at: at, count_at: count_at, ok: ok };
}

// Adds a parameter to b, in the text format: bytes as they are, an integer
// in decimal, a bool as t or f.
fn param(out: u8[>..]&, b: Bind, v: const u8[:]) {
    put32(out, v.len);
    out.append(v);
    count(out, b);
}

fn param(out: u8[>..]&, b: Bind, v: i64) {
    let at = out.len;
    put32(out, 0);
    format(out, v);
    patch32(out, at, out.len - at - 4);
    count(out, b);
}

fn param(out: u8[>..]&, b: Bind, v: bool) { param(out, b, if v { "t" } else { "f" }); }

// Adds a NULL parameter to b.
fn param_null(out: u8[>..]&, b: Bind) {
    put32(out, -1);
    count(out, b);
}

// Ends b with its results' format, TEXT or BINARY, then describes and
// executes its portal, returning at most max_rows rows (0 for all), and
// returns the query's number. Its events: COLUMNS, a ROW per row, then DONE,
// or SUSPENDED at max_rows; ERROR or SKIPPED in place of any of them.
fn execute(c: Conn&, out: u8[>..]&, b: Bind, format: i64 = TEXT, max_rows: i64 = 0) -> i64 {
    guard b.ok else {
        out.resize(b.at - 1);
        broken(c, "a statement's or portal's name holds a NUL byte");
        return -1;
    }
    put16(out, 1);
    put16(out, format);
    end(out, b.at);
    // The portal's name is Bind's first string.
    var p = b.at + 4;
    while out[p] != 0 { p++; }
    let name_end = p;
    let d = begin(out, 'D');
    out.push('P');
    for i in b.at + 4..name_end + 1 { out.push(out[i]); }
    end(out, d);
    let e = begin(out, 'E');
    for i in b.at + 4..name_end + 1 { out.push(out[i]); }
    put32(out, max_rows);
    end(out, e);
    return queue(c, QUERY);
}

// Queues a Sync, which ends the implicit transaction the entries since the
// last one ran in, and returns its number. Its event is READY.
fn sync(c: Conn&, out: u8[>..]&) -> i64 {
    let at = begin(out, 'S');
    end(out, at);
    return queue(c, SYNC);
}

// Appends Terminate. Close the socket after sending it.
fn terminate(out: u8[>..]&) {
    let at = begin(out, 'X');
    end(out, at);
}

// Reads the server's messages from the front of input, appending any reply
// authentication needs to out, up to the next event, and returns it with the
// body of its message, a slice of input. c.used says how much of input it
// consumed: pass the rest to the next call. WANT_INPUT consumes what it
// could, and c.need says how many bytes the next message needs from there.
fn step(c: Conn&, input: const u8[:], out: u8[>..]&) -> i64, const u8[:] {
    c.used = 0;
    c.need = 0;
    let none = input[..0];
    guard c.state != BROKEN else { return FAILED, none; }
    guard c.state != NEW else { return broken(c, "step before start"), none; }
    loop {
        let rest = input[c.used..];
        if rest.len < 5 {
            c.need = 5;
            return WANT_INPUT, none;
        }
        let kind = rest[0];
        let size = get32(rest, 1);
        guard size >= 4 && size <= MAX_MESSAGE else {
            return broken(c, "a message's length is out of range"), none;
        }
        if rest.len < 1 + size {
            c.need = 1 + size;
            return WANT_INPUT, none;
        }
        let body = rest[5..1 + size];
        // ReadyForQuery ends a sync's entries: those the server skipped come
        // first, each its own event, with the message left for the next call.
        if kind == 'Z' && c.state == OPEN && c.count > 0 && front(c) != SYNC {
            pop(c);
            return SKIPPED, none;
        }
        c.used += 1 + size;
        let e = message(c, kind, body, out);
        if e == FAILED && kind != 'E' { return e, none; }
        if e != WANT_INPUT { return e, body; }
    }
}

// One message: an event, or WANT_INPUT for one that needs none.
fn message(c: Conn&, kind: u8, body: const u8[:], out: u8[>..]&) -> i64 {
    if kind == 'N' {
        if c.count > 0 { c.seq = c.next - c.count; }
        return NOTICE;
    }
    if kind == 'S' { return parameter(c, body); }
    if kind == 'A' || kind == 'v' || kind == 't' { return WANT_INPUT; }
    if c.state != OPEN { return startup(c, kind, body, out); }
    if kind == 'E' {
        if fatal(body) || c.count == 0 { return broken(c, "the server ended the connection"); }
        // An error at a sync, such as a deferred constraint's at the commit
        // of the implicit transaction, belongs to the sync, whose READY
        // follows.
        if front(c) == SYNC {
            c.seq = c.next - c.count;
            return ERROR;
        }
        pop(c);
        return ERROR;
    }
    if kind == 'Z' {
        guard c.count > 0 && body.len == 1 else { return broken(c, "an unexpected ReadyForQuery"); }
        c.status = body[0];
        pop(c);
        return READY;
    }
    if kind == '1' {
        guard c.count > 0 && front(c) == PARSE else { return broken(c, "an unexpected ParseComplete"); }
        pop(c);
        return PARSED;
    }
    guard c.count > 0 && front(c) == QUERY else {
        return unexpected(c, "an unexpected message", kind);
    }
    c.seq = c.next - c.count;
    if kind == '2' { return WANT_INPUT; }
    if kind == 'n' {
        c.columns = 0;
        return WANT_INPUT;
    }
    if kind == 'T' { return columns(c, body); }
    if kind == 'D' { return row(c, body); }
    if kind == 'C' || kind == 'I' {
        pop(c);
        return DONE;
    }
    if kind == 's' {
        pop(c);
        return SUSPENDED;
    }
    return unexpected(c, "an unknown message", kind);
}

// The messages before the first ReadyForQuery: authentication, then the
// server's parameters and key.
fn startup(c: Conn&, kind: u8, body: const u8[:], out: u8[>..]&) -> i64 {
    if kind == 'E' { return broken(c, "the server refused the connection"); }
    if kind == 'R' && body.len >= 4 && c.state != AUTHED { return authenticate(c, get32(body, 0), body[4..], out); }
    if kind == 'K' && c.state == AUTHED && body.len >= 8 {
        c.pid = get32(body, 0) as! i32;
        c.secret = get32(body, 4) as! u32;
        return WANT_INPUT;
    }
    if kind == 'Z' && c.state == AUTHED && body.len == 1 {
        c.state = OPEN;
        c.status = body[0];
        c.seq = -1;
        return READY;
    }
    return unexpected(c, "an unexpected message while starting:", kind);
}

// An Authentication message's request.
fn authenticate(c: Conn&, code: i64, data: const u8[:], out: u8[>..]&) -> i64 {
    if code == 0 {
        // A server that asked for SCRAM must prove it knows the password
        // before the client accepts it.
        guard c.state == STARTING else { return broken(c, "the server skipped SCRAM's last message"); }
        c.state = AUTHED;
        forget_password(c);
        return WANT_INPUT;
    }
    if code == 3 {
        // A server, or anyone between, that asks for the password in the
        // clear after SCRAM began is downgrading the login.
        guard !c.sasl else { return broken(c, "the server asks for a cleartext password after SCRAM"); }
        guard c.cleartext else {
            return broken(c, "the server asks for a cleartext password, which Config.allow_cleartext doesn't allow");
        }
        let at = begin(out, 'p');
        guard cstr(out, c.password) else {
            out.resize(at - 1);
            return broken(c, "the password holds a NUL byte");
        }
        end(out, at);
        return WANT_INPUT;
    }
    if code == 10 && c.state == STARTING && !c.sasl {
        guard offers_scram(data) else { return broken(c, "the server offers no SASL mechanism but SCRAM-SHA-256-PLUS"); }
        scram_first(c, out);
        c.state = SASL;
        c.sasl = true;
        return WANT_INPUT;
    }
    if code == 11 && c.state == SASL {
        let why = scram_continue(c, data, out);
        guard why.len == 0 else { return broken(c, why); }
        c.state = SASL_FINAL;
        return WANT_INPUT;
    }
    if code == 12 && c.state == SASL_FINAL {
        guard scram_verify(c, data) else { return broken(c, "the server's SCRAM signature is wrong"); }
        c.state = STARTING;
        return WANT_INPUT;
    }
    if code == 5 { return broken(c, "MD5 password authentication isn't supported"); }
    return broken(c, str("authentication request ", code, " isn't supported"));
}

// ParameterStatus: the text readers take every text as UTF-8, so a
// client_encoding other than the UTF8 the startup message set, as `SET
// client_encoding` gives, breaks the connection.
fn parameter(c: Conn&, body: const u8[:]) -> i64 {
    let e = cstr_end(body, 0);
    guard body[..e] == "client_encoding" else { return WANT_INPUT; }
    let v = min(e + 1, body.len);
    guard body[v..cstr_end(body, v)] == "UTF8" else {
        return broken(c, "the server's client_encoding isn't UTF8, which the package reads text as");
    }
    return WANT_INPUT;
}

// Whether an ErrorResponse ends the connection: severity FATAL or PANIC.
fn fatal(body: const u8[:]) -> bool {
    let s = field(body, 'V');
    return s == "FATAL" || s == "PANIC";
}

fn broken(c: Conn&, why: const u8[:]) -> i64 {
    c.state = BROKEN;
    forget_password(c);
    set_reason(c, why);
    return FAILED;
}

// Zeroes the password's bytes before dropping it, so a copy of the Conn, or
// memory reused later, doesn't hold it.
fn forget_password(c: Conn&) {
    for k in c.password.len { c.password[k] = 0; }
    c.password.clear();
}

fn unexpected(c: Conn&, what: const u8[:], kind: u8) -> i64 {
    let k: u8[1] = [kind];
    return broken(c, str(what, " '", k[..], "'"));
}

fn set_reason(c: Conn&, why: const u8[:]) {
    c.reason.clear();
    c.reason.append(why[..min(why.len, 120)]);
}

fn queue(c: Conn&, kind: i64) -> i64 {
    if c.count == QUEUE { abort("pg: more than QUEUE entries queued; check pg::room"); }
    c.kinds[(c.head + c.count) % QUEUE] = kind as! u8;
    c.count++;
    c.next++;
    return c.next - 1;
}

fn front(c: const Conn&) -> u8 { c.kinds[c.head % QUEUE] }

fn pop(c: Conn&) {
    c.seq = c.next - c.count;
    c.head = (c.head + 1) % QUEUE;
    c.count--;
}

// The message writers: a kind and a length to patch at end.
fn begin(out: u8[>..]&, kind: u8) -> i64 {
    out.push(kind);
    let at = out.len;
    put32(out, 0);
    return at;
}

fn end(out: u8[>..]&, at: i64) { patch32(out, at, out.len - at); }

// Adds added to b's parameter count, an unsigned 16-bit field: Postgres takes
// up to 65535 parameters.
fn count(out: u8[>..]&, b: Bind, added: i64 = 1) {
    let n = ((out[b.count_at] as i64) << 8 | out[b.count_at + 1]) + added;
    if n > 65535 { abort("pg: more than 65535 parameters"); }
    out[b.count_at] = (n >> 8) as! u8;
    out[b.count_at + 1] = n as! u8;
}

// Appends s and its NUL, or nothing, returning false, when s holds a NUL:
// the server would read s as ending there, and the rest as the message's
// next fields. A writer given such a string appends nothing for its message,
// breaks c with a reason, and returns -1 for the entry's number.
fn cstr(out: u8[>..]&, s: const u8[:]) -> bool {
    guard !has_nul(s) else { return false; }
    out.append(s);
    out.push(0);
    return true;
}

fn has_nul(s: const u8[:]) -> bool {
    for b in s { if b == 0 { return true; } }
    return false;
}

fn put16(out: u8[>..]&, v: i64) {
    out.push((v >> 8) as! u8);
    out.push(v as! u8);
}

fn put32(out: u8[>..]&, v: i64) {
    out.push((v >> 24) as! u8);
    out.push((v >> 16) as! u8);
    out.push((v >> 8) as! u8);
    out.push(v as! u8);
}

fn patch32(out: u8[>..]&, at: i64, v: i64) {
    out[at] = (v >> 24) as! u8;
    out[at + 1] = (v >> 16) as! u8;
    out[at + 2] = (v >> 8) as! u8;
    out[at + 3] = v as! u8;
}

// A signed big-endian 16- or 32-bit integer at b[at..].
fn get16(b: const u8[:], at: i64) -> i64 { ((b[at] as u16) << 8 | b[at + 1]) as! i16 }

fn get32(b: const u8[:], at: i64) -> i64 {
    ((b[at] as u32) << 24 | (b[at + 1] as u32) << 16 | (b[at + 2] as u32) << 8 | b[at + 3]) as! i32
}
