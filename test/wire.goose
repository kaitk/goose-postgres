// The session tests' I/O: the bytes a test program sends and receives, from a
// capture recorded from Postgres, or, with --live, from scripts/relay.py,
// which connects the program to a server.
//
// A capture is a run of records, each a direction ('C' sent by the client,
// 'S' received from the server), a 4-byte big-endian length, and the bytes.
// Replaying it, send checks that the client sends each 'C' record's bytes, in
// order, and recv hands over each 'S' record's, split into pieces of at most
// split bytes when split is above 0. Live, the program speaks to the relay
// in lines on stdout and stdin: ">hex" to send, "<" to ask for the server's
// next bytes, answered by a line of hex, or "eof". Every other line is the
// test's output, which the relay passes on.
namespace wire;

import std;
import os;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "../";

let DIGITS = "0123456789abcdef";

struct Io {
    live: bool,
    capture: const u8[:],
    pos: i64 = 0,
    // In replay, what's left of the 'S' record being handed over.
    left: i64 = 0,
    split: i64 = 0,
}

// The I/O for a test: live when the program was started with --live, else
// replaying capture.
fn io(capture: const u8[:], split: i64 = 0) -> Io {
    var live = false;
    for a in args() { if a == "--live" { live = true; } }
    return Io { live: live, capture: capture, split: split };
}

// The settings every session test connects with: HttpArena's.
fn config() -> pg::Config {
    let cfg, ok = pg::parse_url("postgres://bench:bench@localhost/benchmark");
    assert(ok);
    return cfg;
}

// SCRAM's client nonce for the tests: fixed, so that a capture replays.
let NONCE = "goose-postgres test nonce";

// Sends out, and clears it.
fn send(io: Io&, out: u8[>..]&) {
    guard out.len > 0;
    send_bytes(io, out);
    out.clear();
}

// Io as the facade's transport (facade.goose): sending checks the bytes
// against the capture, receiving hands over its next bytes, and closing does
// nothing, since the relay closes the socket when the program ends.
fn pg::send(io: wire::Io&, bytes: const u8[:]) -> bool {
    wire::send_bytes(io, bytes);
    return true;
}

fn pg::receive(io: wire::Io&, into: u8[>..]&) -> bool { wire::recv(io, into) }

fn pg::close(io: wire::Io&) {}

// Prints each error in failed, or that there was none.
fn errors(label: const u8[:], failed: const pg::Error[:]) {
    if failed.len == 0 { print(label, ": no error"); }
    for e in failed { print(label, ": ", e.code, " ", e.message); }
}

// The facade's calls on a connected db, over any transport, then its close:
// queries with parameters of each kind, each statement prepared once,
// commands' counts, errors through pg::run with the connection usable after
// each, a failure in a row block, and the transaction status a transaction
// block reads, savepoints included.
fn facade<T>(db: pg::Db<T>&) {
    print("-- HttpArena's query, twice: prepared once");
    errors("arena", pg::run() {
        for lo in [10, 20] {
            var line: u8[>..] = [];
            let n = pg::query(db, ARENA_SQL, lo, lo + 5, 3) { r =>
                format(line, " ", pg::int(r, 0), ":", pg::text(r, 1), ":", pg::boolean(r, 5));
            };
            print(n, " rows:", line);
        }
    });

    print("-- parameters of each kind");
    errors("parameters", pg::run() {
        let s: u8[>..] = str("bytes");
        pg::query(db, "SELECT $1::int8 + 1, NOT $2::bool, $3::text || '!', $4::text IS NULL, $5::int4",
                  -9000000000, false, s, pg::NULL, 7) { r =>
            print(pg::field_count(r), " fields: ", pg::int(r, 0), " ", pg::boolean(r, 1), " ",
                  pg::text(r, 2), " ", pg::boolean(r, 3), " ", pg::int(r, 4), " null ",
                  pg::is_null(r, 4));
        };
        pg::query(db, "SELECT NULL::text, $1::text", "") { r =>
            print("NULL: ", pg::is_null(r, 0), ", empty: ", pg::is_null(r, 1));
        };
    });

    print("-- commands' counts");
    errors("commands", pg::run() {
        print("create: ", pg::exec(db, "CREATE TEMP TABLE t (n int PRIMARY KEY, s text NOT NULL)"));
        print("insert: ", pg::exec(db, "INSERT INTO t SELECT g, 'n' || g FROM generate_series(1, $1::int) g", 5));
        print("update: ", pg::exec(db, "UPDATE t SET s = $1 WHERE n > $2", "big", 3));
        print("delete: ", pg::exec(db, "DELETE FROM t WHERE n = $1", 1));
        print("select: ", pg::exec(db, "SELECT * FROM t"));
    });

    print("-- a parameter list, past eight");
    errors("params", pg::run() {
        var p = pg::Params { .. };
        for k in 1..11 { pg::param(p, k); }
        pg::param(p, "eleven");
        pg::param(p, true);
        pg::param(p, pg::NULL);
        pg::query(db, """
            SELECT $1::int + $2::int + $3::int + $4::int + $5::int + $6::int + $7::int
                   + $8::int + $9::int + $10::int, $11::text, $12::bool, $13::text IS NULL
            """, p) { r =>
            print(p.count, " parameters: ", pg::int(r, 0), " ", pg::text(r, 1), " ",
                  pg::boolean(r, 2), " ", pg::boolean(r, 3));
        };
        var rows = pg::Params { .. };
        for k in 100..110 { pg::param(rows, k); }
        print("insert: ", pg::exec(db, """
            INSERT INTO t SELECT n, 'p' || n
            FROM unnest(ARRAY[$1, $2, $3, $4, $5, $6, $7, $8, $9, $10]::int[]) n
            """, rows));
        print("delete: ", pg::exec(db, "DELETE FROM t WHERE n >= $1", 100));
    });

    print("-- errors, each leaving the connection usable");
    errors("division", pg::run() { pg::exec(db, "SELECT 10 / $1::int", 0); });
    errors("syntax", pg::run() { pg::exec(db, "SELEC 1"); });
    errors("syntax again, parsed again", pg::run() { pg::exec(db, "SELEC 1"); });
    let dup = pg::run() { pg::exec(db, "INSERT INTO t VALUES ($1, $2)", 2, "two"); };
    errors("duplicate", dup);
    for e in dup {
        print("unique violation: ", e.code == pg::UNIQUE_VIOLATION, ", class ", pg::class(e.code));
    }
    errors("the program's own", pg::run() {
        pg::exec(db, "SELECT 1");
        pg::fail("not enough stock");
    });
    var seen = 0;
    errors("a failure in a row block", pg::run() {
        pg::query(db, "SELECT n FROM t ORDER BY n") { r =>
            seen++;
            if pg::int(r, 0) == 3 { pg::fail("23514", "three is too many"); }
        };
    });
    print("rows seen before it: ", seen);
    errors("after it", pg::run() {
        pg::query(db, "SELECT count(*) FROM t") { r => print("count: ", pg::int(r, 0)); };
    });

    print("-- the transaction status, and savepoints");
    errors("transaction", pg::run() {
        print("in a transaction: ", pg::in_transaction(db));
        pg::exec(db, "BEGIN");
        print("after BEGIN: ", pg::in_transaction(db));
        pg::exec(db, "INSERT INTO t VALUES (10, 'ten')");
        pg::exec(db, "SAVEPOINT goose_pg");
        errors("in the savepoint", pg::run() { pg::exec(db, "INSERT INTO t VALUES (10, 'again')"); });
        print("failed: ", pg::in_transaction(db), " ", pg::exec(db, "SELECT 1") == 1);
    });
    errors("rolled back to the savepoint", pg::run() {
        pg::exec(db, "ROLLBACK TO goose_pg");
        pg::exec(db, "RELEASE goose_pg");
        pg::exec(db, "COMMIT");
        print("after COMMIT: ", pg::in_transaction(db), ", ten kept: ",
              pg::exec(db, "SELECT 1 FROM t WHERE n = 10"));
    });

    pg::close(db);
    errors("after close", pg::run() { pg::exec(db, "SELECT 1"); });
}

fn send_bytes(io: Io&, out: const u8[:]) {
    guard out.len > 0;
    if io.live {
        var line: u8[>..] = [];
        line.push('>');
        hex(line, out);
        print(line);
    } else {
        guard io.left == 0 && io.pos + 5 <= io.capture.len && io.capture[io.pos] == 'C' else {
            print("the client sent ", out.len, " bytes where the capture has none");
            abort("replay");
        }
        let n = length(io.capture, io.pos + 1);
        let want = io.capture[io.pos + 5..io.pos + 5 + n];
        guard want == out else {
            print("the client sent other bytes than the capture's:");
            var got: u8[>..] = [];
            hex(got, out);
            print("  sent     ", got);
            var rec: u8[>..] = [];
            hex(rec, want);
            print("  captured ", rec);
            abort("replay");
        }
        io.pos += 5 + n;
    }
}

// Appends the server's next bytes to input: false when it closed.
fn recv(io: Io&, input: u8[>..]&) -> bool {
    if io.live {
        print("<");
        var line: u8[>..] = [];
        guard read_line(line) && line != "eof" else { return false; }
        for k in line.len / 2 { input.push((digit(line[2 * k]) * 16 + digit(line[2 * k + 1])) as! u8); }
        return true;
    }
    if io.left == 0 {
        guard io.pos + 5 <= io.capture.len else { return false; }
        guard io.capture[io.pos] == 'S' else {
            print("the client waits for the server where the capture has it send");
            abort("replay");
        }
        io.left = length(io.capture, io.pos + 1);
        io.pos += 5;
    }
    let n = if io.split > 0 { min(io.split, io.left) } else { io.left };
    input.append(io.capture[io.pos..io.pos + n]);
    io.pos += n;
    io.left -= n;
    return true;
}

// Whether the whole capture was replayed.
fn finished(io: const Io&) -> bool { io.live || (io.left == 0 && io.pos == io.capture.len) }

// Steps c, sending what it writes and receiving when it wants input, and
// calls F(event, body) on each event until F returns false. The bytes after
// that event stay at the front of input for the next call; input grows
// within a call, since the bodies F gets are slices of it.
fn pump<F>(io: Io&, c: pg::Conn&, input: u8[>..]&, out: u8[>..]&) {
    var pos = 0;
    loop {
        send(io, out);
        let e, body = pg::step(c, input[pos..], out);
        pos += c.used;
        if e == pg::WANT_INPUT {
            send(io, out);
            guard recv(io, input) else {
                print("the server closed the connection");
                return;
            }
            continue;
        }
        guard F(e, body) else { break; }
    }
    send(io, out);
    drop_front(input, pos);
}

// Steps c to its next READY, printing each event.
fn until_ready(io: Io&, c: pg::Conn&, input: u8[>..]&, out: u8[>..]&) {
    pump(io, c, input, out) { e, body =>
        show(c, e, body);
        e != pg::READY && e != pg::FAILED
    };
}

// HttpArena's /async-db query (its async-db implementation guide at 2d85137).
let ARENA_SQL = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";

// Logs in as HttpArena's user, prepares its query once, and runs it as its
// validation does: two queries pipelined in one sync, one per format, then
// the empty range and a third range in another.
fn arena(io: Io&) {
    var c = pg::Conn { .. };
    var input: u8[>..] = [];
    var out: u8[>..] = [];
    pg::start(c, out, config(), NONCE);
    until_ready(io, c, input, out);
    guard pg::ready(c);
    pg::parse(c, out, "items", ARENA_SQL);
    arena_query(c, out, 5, 80, 7, pg::BINARY);
    arena_query(c, out, 10, 50, 5, pg::TEXT);
    pg::sync(c, out);
    var checked = false;
    pump(io, c, input, out) { e, body =>
        show(c, e, body);
        if e == pg::COLUMNS && !checked {
            print("the columns are HttpArena's: ", pg::columns_are(c, [pg::OID_INT4, pg::OID_TEXT,
                  pg::OID_TEXT, pg::OID_INT4, pg::OID_INT4, pg::OID_BOOL, pg::OID_JSONB,
                  pg::OID_INT4, pg::OID_INT4]));
            checked = true;
        }
        e != pg::READY && e != pg::FAILED
    };
    arena_query(c, out, 9999, 9999, 50, pg::BINARY);
    arena_query(c, out, 20, 150, 18, pg::BINARY);
    pg::sync(c, out);
    until_ready(io, c, input, out);
    pg::terminate(out);
    send(io, out);
    print("replayed the whole capture: ", finished(io));
}

fn arena_query(c: pg::Conn&, out: u8[>..]&, lo: i64, hi: i64, limit: i64, format: i64) {
    let b = pg::bind(out, "items");
    pg::param(out, b, lo);
    pg::param(out, b, hi);
    pg::param(out, b, limit);
    pg::execute(c, out, b, format);
}

// Prints an event, and what its body holds.
fn show(c: const pg::Conn&, e: i64, body: const u8[:]) {
    if e == pg::READY {
        let s: u8[1] = [c.status];
        print("READY ", c.seq, " status ", s[..]);
    } else if e == pg::COLUMNS {
        var line: u8[>..] = [];
        format(line, "COLUMNS ", c.seq, ":");
        for i in pg::column_count(c) {
            format(line, " ", pg::column_name(body, i), " ", type_name(pg::column_type(c, i)),
                   if pg::column_format(c, i) == pg::BINARY { "/binary" } else { "/text" });
        }
        print(line);
    } else if e == pg::ROW {
        var line: u8[>..] = [];
        format(line, "ROW ", c.seq, ":");
        for i in pg::field_count(c) {
            line.append(if i == 0 { " " } else { " | " });
            field(line, c, body, i);
        }
        print(line);
    } else if e == pg::DONE {
        print("DONE ", c.seq, " \"", body[..pg::cstr_end(body, 0)], "\" rows ", pg::rows(body));
    } else if e == pg::SUSPENDED {
        print("SUSPENDED ", c.seq);
    } else if e == pg::PARSED {
        print("PARSED ", c.seq);
    } else if e == pg::SKIPPED {
        print("SKIPPED ", c.seq);
    } else if e == pg::ERROR {
        print("ERROR ", c.seq, " ", pg::field(body, 'C'), " ", pg::field(body, 'M'));
    } else if e == pg::NOTICE {
        print("NOTICE ", pg::field(body, 'C'), " ", pg::field(body, 'M'));
    } else if e == pg::FAILED {
        if body.len > 0 {
            print("FAILED ", c.reason, ": ", pg::field(body, 'C'), " ", pg::field(body, 'M'));
        } else {
            print("FAILED ", c.reason);
        }
    } else {
        print("event ", e);
    }
}

// Appends field i of a row, decoded by its column's type.
fn field(line: u8[>..]&, c: const pg::Conn&, row: const u8[:], i: i64) {
    if pg::is_null(c, i) {
        line.append("NULL");
        return;
    }
    let t = pg::column_type(c, i);
    if t == pg::OID_INT2 || t == pg::OID_INT4 || t == pg::OID_INT8 {
        format(line, pg::int(c, row, i));
    } else if t == pg::OID_BOOL {
        format(line, pg::boolean(c, row, i));
    } else {
        line.append(pg::text(c, row, i));
    }
}

fn type_name(t: u32) -> const u8[:] {
    if t == pg::OID_BOOL { return "bool"; }
    if t == pg::OID_INT2 { return "int2"; }
    if t == pg::OID_INT4 { return "int4"; }
    if t == pg::OID_INT8 { return "int8"; }
    if t == pg::OID_TEXT { return "text"; }
    if t == pg::OID_NAME { return "name"; }
    if t == pg::OID_VARCHAR { return "varchar"; }
    if t == pg::OID_JSON { return "json"; }
    if t == pg::OID_JSONB { return "jsonb"; }
    return "other";
}

fn drop_front(input: u8[>..]&, n: i64) {
    guard n > 0;
    let keep = input.len - n;
    for k in keep { input[k] = input[n + k]; }
    input.resize(keep);
}

fn length(b: const u8[:], at: i64) -> i64 {
    ((b[at] as i64) << 24) | ((b[at + 1] as i64) << 16) | ((b[at + 2] as i64) << 8) | b[at + 3]
}

fn hex(out: u8[>..]&, data: const u8[:]) {
    for b in data {
        out.push(DIGITS[b >> 4]);
        out.push(DIGITS[b & 15]);
    }
}

fn digit(b: u8) -> i64 { if b >= 'a' { b - 'a' + 10 } else { b - '0' } }
