// The blocking facade, for a thread that runs no event loop, such as a
// goose-rest lane: each call writes its entries, sends them on the
// connection's transport, waits for the answers, and returns, so a use case's
// queries read top to bottom (docs/architecture.md, "The facade").
//
//   var db = pg::Db { t: socket, .. };
//   let failed = pg::run() {
//       pg::connect(db, cfg);
//       pg::query(db, "SELECT id, name FROM items WHERE price < $1", 50) { r =>
//           print(pg::int(r, 0), " ", pg::text(r, 1));
//       };
//       let n = pg::exec(db, "UPDATE items SET quantity = quantity - 1 WHERE id = $1", 7);
//   };
//   for e in failed { print(e.code, ": ", e.message); }
//   pg::close(db);
//
// A call that fails leaves through `return ... from pg::run`, so each one
// runs inside run, or the program doesn't compile. close never fails.
//
// The transport is the caller's: a fixed-size value of any type T for which
// namespace pg has these three overloads, which the facade calls by name and
// Goose resolves per T, as goose-http's loop reaches TLS:
//
//   fn pg::send(t: T&, bytes: const u8[:]) -> bool   // all of bytes, or false
//   fn pg::receive(t: T&, into: u8[>..]&) -> bool    // waits; appends at least
//                                                    // one byte, or false
//   fn pg::close(t: T&)                              // never fails
//
// Each function that can fail is generic, so it is checked only where a
// program calls it: `goose check` of this file alone checks a fully typed
// function as a caller of fail outside run, and rejects it.
namespace pg;

import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";

// Why a call failed: a SQLSTATE code, Postgres's own or one of the facade's
// below, and a message.
struct Error { code: u8[..5], message: u8[] }

// The codes of the errors the facade raises itself, and some of Postgres's
// that a program tests for; the full list is Postgres's ("PostgreSQL Error
// Codes" in its documentation). Each is the condition's name there.
let RAISE_EXCEPTION = "P0001";            // fail(message): the program's own
let CONNECTION_FAILURE = "08006";         // the transport failed, or the
                                          // connection broke
let CONNECTION_DOES_NOT_EXIST = "08003";  // a call on a connection that isn't
                                          // connected, or broke earlier
let SQLCLIENT_UNABLE_TO_ESTABLISH_SQLCONNECTION = "08001";   // settings that can't
                                                             // be used, or a socket
                                                             // that can't connect
let UNIQUE_VIOLATION = "23505";
let FOREIGN_KEY_VIOLATION = "23503";
let NOT_NULL_VIOLATION = "23502";
let CHECK_VIOLATION = "23514";
let SERIALIZATION_FAILURE = "40001";
let DEADLOCK_DETECTED = "40P01";
let IN_FAILED_SQL_TRANSACTION = "25P02";

// The most statements a connection prepares by name, and the bytes of SQL
// they hold together. Past either, a query parses as the unnamed statement
// each time it runs.
let STATEMENTS = 64;
let STATEMENT_TEXT = 16384;

// A connection for the facade: the transport, the protocol's state, the
// statements prepared on it, and the bytes received. Build it with the
// transport, `pg::Db { t: socket, .. }`, then connect. Its input ends it, so
// a struct that holds a Db holds it last.
struct Db<T> {
    t: T,
    c: Conn,
    // How much of input step has consumed.
    at: i64 = 0,
    // Statement k is named "gp<k>"; its SQL is sql[ends[k - 1]..ends[k]].
    statements: i64 = 0,
    ends: i32[STATEMENTS],
    sql: u8[..STATEMENT_TEXT],
    input: u8[>..],
}

// A row, as a query's block gets it: its fields, by the types of its columns.
// Valid only inside the block: copy what is kept.
struct Row { c: const Conn&, body: const u8[:] }

// A NULL parameter: pg::query(db, sql, pg::NULL).
struct Null {}
let NULL = Null {};

// Runs F, and returns an empty array when it returned, or the error that a
// call inside it failed with. F's results are discarded; it writes what it
// reads into variables of the caller's. The innermost run catches.
fn run<F>() -> Error[] {
    F();
    return [];
}

// Leaves the innermost run with an Error of code, the first five bytes of
// it, and message.
fn fail(code: const u8[:], message: const u8[:]) {
    var e = Error { message: str(message), .. };
    e.code.append(code[..min(code.len, 5)]);
    return [e] from run;
}

// Leaves the innermost run with an Error of RAISE_EXCEPTION and message.
fn fail(message) { fail(RAISE_EXCEPTION, message); }

// A SQLSTATE code's class, its first two characters: "23" for any integrity
// constraint violation.
fn class(code: const u8[:]) -> const u8[:] { code[..min(code.len, 2)] }

// Connects db, whose transport the caller opened to cfg's host and port:
// sends the startup message, authenticates, and returns when the server is
// ready for queries. SCRAM's client nonce is 18 bytes from the OS's secure
// random source. Forgets the statements of an earlier connection.
fn connect<T>(db: Db<T>&, cfg: Config) {
    var nonce: u8[18] = [0; 18];
    hash::random_bytes(nonce);
    connect(db, cfg, nonce);
}

// Connects db with the settings in a postgres:// URL (parse_url).
fn connect<T>(db: Db<T>&, url: const u8[:]) {
    let cfg, why = url_settings(url);
    guard why.len == 0 else { fail(SQLCLIENT_UNABLE_TO_ESTABLISH_SQLCONNECTION, why); }
    connect(db, cfg);
}

// Connects db with the nonce given, for a test that replays a recorded
// session; a program takes connect(db, cfg).
fn connect<T>(db: Db<T>&, cfg: Config, nonce: const u8[:]) {
    var out: u8[>..] = [];
    start(db.c, out, cfg, nonce);
    db.at = 0;
    db.statements = 0;
    db.sql.clear();
    db.input.clear();
    transmit(db, out);
    loop {
        let e, body = next(db);
        if e == READY { return; }
        if e == FAILED { lost(db, body); }
    }
}

// Ends the session, when one is open, and closes the transport. Never fails,
// so it runs anywhere, after an error too.
fn close<T>(db: Db<T>&) {
    if db.c.state == OPEN {
        var out: u8[>..] = [];
        terminate(out);
        let sent = send(db.t, out);
    }
    close(db.t);
    forget_password(db.c);
    db.c = Conn { .. };
}

// Whether db's last answer left it in a transaction, failed or not: what a
// transaction block checks to begin a savepoint rather than a transaction.
fn in_transaction<T>(db: const Db<T>&) -> bool { db.c.status == 'T' || db.c.status == 'E' }

// Runs sql with the parameters given, in order for $1, $2, and so on, and
// calls F with each row, in the text format. Returns the rows' count. A
// parameter is bytes, an integer, a bool, or NULL, each sent as text, which
// the server converts to the type it inferred for its $n. When F fails, the
// rows still to come are read and dropped by db's next call. A Params value
// in place of p1 gives all of its parameters.
fn query<F, T>(db: Db<T>&, sql: const u8[:]) -> i64 {
    var out: u8[>..] = [];
    let b = entry(db, out, sql);
    return finish(db, out, b, F);
}

fn query<F, T>(db: Db<T>&, sql: const u8[:], p1) -> i64 {
    var out: u8[>..] = [];
    let b = entry(db, out, sql);
    param(out, b, p1);
    return finish(db, out, b, F);
}

fn query<F, T>(db: Db<T>&, sql: const u8[:], p1, p2) -> i64 {
    var out: u8[>..] = [];
    let b = entry(db, out, sql);
    param(out, b, p1);
    param(out, b, p2);
    return finish(db, out, b, F);
}

fn query<F, T>(db: Db<T>&, sql: const u8[:], p1, p2, p3) -> i64 {
    var out: u8[>..] = [];
    let b = entry(db, out, sql);
    param(out, b, p1);
    param(out, b, p2);
    param(out, b, p3);
    return finish(db, out, b, F);
}

fn query<F, T>(db: Db<T>&, sql: const u8[:], p1, p2, p3, p4) -> i64 {
    var out: u8[>..] = [];
    let b = entry(db, out, sql);
    param(out, b, p1);
    param(out, b, p2);
    param(out, b, p3);
    param(out, b, p4);
    return finish(db, out, b, F);
}

fn query<F, T>(db: Db<T>&, sql: const u8[:], p1, p2, p3, p4, p5) -> i64 {
    var out: u8[>..] = [];
    let b = entry(db, out, sql);
    param(out, b, p1);
    param(out, b, p2);
    param(out, b, p3);
    param(out, b, p4);
    param(out, b, p5);
    return finish(db, out, b, F);
}

fn query<F, T>(db: Db<T>&, sql: const u8[:], p1, p2, p3, p4, p5, p6) -> i64 {
    var out: u8[>..] = [];
    let b = entry(db, out, sql);
    param(out, b, p1);
    param(out, b, p2);
    param(out, b, p3);
    param(out, b, p4);
    param(out, b, p5);
    param(out, b, p6);
    return finish(db, out, b, F);
}

fn query<F, T>(db: Db<T>&, sql: const u8[:], p1, p2, p3, p4, p5, p6, p7) -> i64 {
    var out: u8[>..] = [];
    let b = entry(db, out, sql);
    param(out, b, p1);
    param(out, b, p2);
    param(out, b, p3);
    param(out, b, p4);
    param(out, b, p5);
    param(out, b, p6);
    param(out, b, p7);
    return finish(db, out, b, F);
}

fn query<F, T>(db: Db<T>&, sql: const u8[:], p1, p2, p3, p4, p5, p6, p7, p8) -> i64 {
    var out: u8[>..] = [];
    let b = entry(db, out, sql);
    param(out, b, p1);
    param(out, b, p2);
    param(out, b, p3);
    param(out, b, p4);
    param(out, b, p5);
    param(out, b, p6);
    param(out, b, p7);
    param(out, b, p8);
    return finish(db, out, b, F);
}

// Runs sql with the parameters given, as query does, dropping any rows, and
// returns the count in its command tag: the rows an INSERT, UPDATE, or
// DELETE changed, or a SELECT returned; 0 for a command without one.
fn exec<T>(db: Db<T>&, sql: const u8[:]) -> i64 { return query(db, sql) { r => }; }
fn exec<T>(db: Db<T>&, sql: const u8[:], p1) -> i64 { return query(db, sql, p1) { r => }; }
fn exec<T>(db: Db<T>&, sql: const u8[:], p1, p2) -> i64 { return query(db, sql, p1, p2) { r => }; }
fn exec<T>(db: Db<T>&, sql: const u8[:], p1, p2, p3) -> i64 {
    return query(db, sql, p1, p2, p3) { r => };
}
fn exec<T>(db: Db<T>&, sql: const u8[:], p1, p2, p3, p4) -> i64 {
    return query(db, sql, p1, p2, p3, p4) { r => };
}
fn exec<T>(db: Db<T>&, sql: const u8[:], p1, p2, p3, p4, p5) -> i64 {
    return query(db, sql, p1, p2, p3, p4, p5) { r => };
}
fn exec<T>(db: Db<T>&, sql: const u8[:], p1, p2, p3, p4, p5, p6) -> i64 {
    return query(db, sql, p1, p2, p3, p4, p5, p6) { r => };
}
fn exec<T>(db: Db<T>&, sql: const u8[:], p1, p2, p3, p4, p5, p6, p7) -> i64 {
    return query(db, sql, p1, p2, p3, p4, p5, p6, p7) { r => };
}
fn exec<T>(db: Db<T>&, sql: const u8[:], p1, p2, p3, p4, p5, p6, p7, p8) -> i64 {
    return query(db, sql, p1, p2, p3, p4, p5, p6, p7, p8) { r => };
}

fn param(out: u8[>..]&, b: Bind, v: Null) { param_null(out, b); }

// A list of parameters for a statement with more than query's eight, or built
// in a loop: pg::param(p, v) adds each in order, and pg::query(db, sql, p) or
// pg::exec(db, sql, p) runs the statement with them. Each is kept as Bind
// writes it, its length and its text, so a call copies them in one append.
// Up to 65535, Postgres's limit; adding more aborts.
struct Params {
    count: i64 = 0,
    bytes: u8[>..],
}

fn param(p: Params&, v: const u8[:]) {
    room_for_one(p);
    put32(p.bytes, v.len);
    p.bytes.append(v);
}

fn param(p: Params&, v: i64) {
    room_for_one(p);
    let at = p.bytes.len;
    put32(p.bytes, 0);
    format(p.bytes, v);
    patch32(p.bytes, at, p.bytes.len - at - 4);
}

fn param(p: Params&, v: bool) { param(p, if v { "t" } else { "f" }); }

fn param(p: Params&, v: Null) {
    room_for_one(p);
    put32(p.bytes, -1);
}

// Adds p's parameters to b, in order.
fn param(out: u8[>..]&, b: Bind, p: const Params&) {
    out.append(p.bytes);
    count(out, b, p.count);
}

fn room_for_one(p: Params&) {
    if p.count == 65535 { abort("pg: more than 65535 parameters"); }
    p.count++;
}

// A row's fields, as the protocol's readers give them (decode.goose).
fn field_count(r: Row) -> i64 { r.c.fields }
fn column_type(r: Row, i: i64) -> u32 { column_type(r.c, i) }
fn is_null(r: Row, i: i64) -> bool { is_null(r.c, i) }
fn int(r: Row, i: i64) -> i64 { int(r.c, r.body, i) }
fn boolean(r: Row, i: i64) -> bool { boolean(r.c, r.body, i) }
fn text(r: Row, i: i64) -> const u8[:] { text(r.c, r.body, i) }
fn bytes(r: Row, i: i64) -> const u8[:] { bytes(r.c, r.body, i) }

// Readies db for a call, and writes the call's first entries to out: a Parse
// of sql the first time db runs it, and the Bind its parameters go into.
fn entry<T>(db: Db<T>&, out: u8[>..]&, sql: const u8[:]) -> Bind {
    guard db.c.state == OPEN else {
        if db.c.state == BROKEN { fail(CONNECTION_DOES_NOT_EXIST, str("the connection broke: ", db.c.reason)); }
        fail(CONNECTION_DOES_NOT_EXIST, "the connection isn't open");
    }
    // A call that failed in its block, or in a transaction's, left its
    // answers unread.
    while db.c.count > 0 {
        let e, body = next(db);
        if e == PARSED { prepared(db); }
        if e == FAILED { lost(db, body); }
    }
    var name: u8[>..] = [];
    let k = statement(db, sql);
    if k >= 0 {
        format(name, "gp", k);
    } else {
        // Kept as statement `statements` once the server parses it.
        let kept = if db.statements > 0 { db.ends[db.statements - 1] as i64 } else { 0 };
        db.sql.resize(kept);
        if db.statements < STATEMENTS && kept + sql.len <= STATEMENT_TEXT {
            db.sql.append(sql);
            format(name, "gp", db.statements);
        }
        parse(db.c, out, name, sql);
    }
    return bind(out, name);
}

// The number of the statement db prepared for sql, or -1.
fn statement<T>(db: const Db<T>&, sql: const u8[:]) -> i64 {
    var from = 0;
    for k in db.statements {
        let to = db.ends[k] as i64;
        if db.sql[from..to] == sql { return k; }
        from = to;
    }
    return -1;
}

// A Parse succeeded: keeps the statement entry named, if it named one.
fn prepared<T>(db: Db<T>&) {
    let kept = if db.statements > 0 { db.ends[db.statements - 1] as i64 } else { 0 };
    guard db.sql.len > kept;
    db.ends[db.statements] = db.sql.len as! i32;
    db.statements++;
}

// Executes b, syncs, sends out, and reads the answers up to the sync's
// READY: each row to F, and the first error, which fails the call once the
// connection is ready again. Returns the count in the command tag.
fn finish<F, T>(db: Db<T>&, out: u8[>..]&, b: Bind) -> i64 {
    execute(db.c, out, b);
    sync(db.c, out);
    transmit(db, out);
    var count = 0;
    var failed = false;
    var code: u8[..5] = [];
    var message: u8[>..] = [];
    loop {
        let e, body = next(db);
        if e == ROW {
            F(Row { c: db.c, body: body });
        } else if e == DONE {
            count = rows(body);
        } else if e == PARSED {
            prepared(db);
        } else if e == ERROR {
            if !failed {
                failed = true;
                code.append(field(body, 'C')[..min(field(body, 'C').len, 5)]);
                message.append(field(body, 'M'));
            }
        } else if e == FAILED {
            lost(db, body);
        } else if e == READY {
            break;
        }
    }
    if failed { fail(code, message); }
    return count;
}

// db's next event, sending what authentication answers, and receiving when
// step wants input.
fn next<T>(db: Db<T>&) -> i64, const u8[:] {
    var out: u8[>..] = [];
    loop {
        let e, body = step(db.c, db.input[db.at..], out);
        db.at += db.c.used;
        if out.len > 0 {
            transmit(db, out);
            out.clear();
        }
        if e != WANT_INPUT { return e, body; }
        if db.at > 0 {
            let keep = db.input.len - db.at;
            for k in keep { db.input[k] = db.input[db.at + k]; }
            db.input.resize(keep);
            db.at = 0;
        }
        guard receive(db.t, db.input) else {
            gone(db, "receiving from the server failed, or it closed the connection");
            return FAILED, db.input[..0];
        }
    }
}

fn transmit<T>(db: Db<T>&, out: const u8[:]) {
    guard send(db.t, out) else {
        gone(db, "sending to the server failed");
        lost(db, out[..0]);
    }
}

fn gone<T>(db: Db<T>&, why: const u8[:]) { broken(db.c, why); }

// Fails with the error that ended the connection: the server's, when it
// sent one, or CONNECTION_FAILURE with the reason.
fn lost<T>(db: Db<T>&, body: const u8[:]) {
    let code = field(body, 'C');
    if code.len > 0 { fail(code, field(body, 'M')); }
    fail(CONNECTION_FAILURE, db.c.reason);
}
