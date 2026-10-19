// A server faked in the program, as the facade's transport (facade.goose),
// for what recorded sessions can't show: a connection lost in the middle of
// a result, a FATAL error, a send that fails, and many statements. It reads
// each message the client sends and queues the answers a Postgres server
// gives, which receive hands over all at once.
namespace fake;

import std;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "../";
import check from "./";

// What the server does when a query executes.
let ROWS = 0;    // sends `rows` rows of one int4 column, n from 1
let CUT = 1;     // sends one row, then closes the connection
let FATAL = 2;   // ends the connection with a FATAL error

struct Server {
    mode: i64 = ROWS,
    rows: i64 = 0,
    // Whether the next send fails.
    fail_send: bool = false,
    closed: bool = false,
    started: bool = false,
    // The Parse messages seen, and the name of the last one.
    parses: i64 = 0,
    name: u8[..16],
    pending: u8[..65536],
}

fn pg::send(s: fake::Server&, bytes: const u8[:]) -> bool {
    guard !s.fail_send && !s.closed else { return false; }
    var answer: u8[>..] = [];
    if !s.started {
        s.started = true;
        check::message(answer, 'R', check::auth(3, ""));
    } else {
        var p = 0;
        while p + 5 <= bytes.len {
            let kind = bytes[p];
            let size = pg::get32(bytes, p + 1);
            fake::reply(s, kind, bytes[p + 5..p + 1 + size], answer);
            p += 1 + size;
            if kind == 'E' && s.mode == fake::CUT { break; }
        }
    }
    s.pending.append(answer);
    return true;
}

fn pg::receive(s: fake::Server&, into: u8[>..]&) -> bool {
    guard s.pending.len > 0 else {
        s.closed = true;
        return false;
    }
    into.append(s.pending);
    s.pending.clear();
    return true;
}

fn pg::close(s: fake::Server&) { s.closed = true; }

fn reply(s: Server&, kind: u8, body: const u8[:], answer: u8[>..]&) {
    if kind == 'p' {
        check::message(answer, 'R', check::auth(0, ""));
        check::message(answer, 'Z', "I");
    } else if kind == 'P' {
        s.parses++;
        s.name.clear();
        s.name.append(body[..pg::cstr_end(body, 0)]);
        check::message(answer, '1', "");
    } else if kind == 'B' {
        check::message(answer, '2', "");
    } else if kind == 'D' {
        if s.rows > 0 || s.mode != ROWS {
            var d: u8[>..] = [];
            pg::put16(d, 1);
            d.append("n\0");
            pg::put32(d, 0);
            pg::put16(d, 0);
            pg::put32(d, 23);
            pg::put16(d, 4);
            pg::put32(d, -1);
            pg::put16(d, 0);
            check::message(answer, 'T', d);
        } else {
            check::message(answer, 'n', "");
        }
    } else if kind == 'E' {
        if s.mode == FATAL {
            check::message(answer, 'E', "SFATAL\0VFATAL\0C57P01\0Mterminating connection due to administrator command\0\0");
            return;
        }
        let n = if s.mode == CUT { 1 } else { s.rows };
        for i in n {
            var v: u8[>..] = [];
            format(v, i + 1);
            var r: u8[>..] = [];
            pg::put16(r, 1);
            pg::put32(r, v.len);
            r.append(v);
            check::message(answer, 'D', r);
        }
        guard s.mode != CUT;
        var tag: u8[>..] = [];
        format(tag, "SELECT ", n, "\0");
        check::message(answer, 'C', tag);
    } else if kind == 'S' {
        check::message(answer, 'Z', "I");
    }
}

// The settings the fake server takes: any password, in cleartext.
fn config() -> pg::Config {
    let cfg, ok = pg::parse_url("postgres://u:pw@localhost/db");
    assert(ok);
    return cfg;
}
