// What the unit tests under test/ share. Each check prints what it checked,
// for the test's golden file in test/expected/, then asserts it, so a failure
// shows in the output as well as in the exit code.
namespace check;

import std;
import pg from "../";

let DIGITS = "0123456789abcdef";

// Prints "label: ok", or "label: FAILED".
fn that(label: const u8[:], ok: bool) {
    print(label, if ok { ": ok" } else { ": FAILED" });
    assert(ok);
}

// Prints the value, and what was expected if it differs.
fn eq(label: const u8[:], got: i64, want: i64) {
    if got == want { print(label, ": ", got); }
    else { print(label, ": ", got, ", expected ", want, ": FAILED"); }
    assert(got == want);
}

// Prints the text, and what was expected if it differs.
fn text(label: const u8[:], got: const u8[:], want: const u8[:]) {
    let ok = got == want;
    if ok { print(label, ": ", got); }
    else { print(label, ": \"", got, "\", expected \"", want, "\": FAILED"); }
    assert(ok);
}

// Prints the bytes as text, with each byte outside printable ASCII as \xx in
// hexadecimal, and what was expected if they differ.
fn bytes(label: const u8[:], got: const u8[:], want: const u8[:]) {
    let ok = got == want;
    var line: u8[>..] = [];
    format(line, label, ": ");
    escaped(line, got);
    if !ok {
        line.append(", expected ");
        escaped(line, want);
        line.append(": FAILED");
    }
    print(line);
    assert(ok);
}

fn escaped(line: u8[>..]&, data: const u8[:]) {
    for b in data {
        if b >= 32 && b < 127 && b != '\\' {
            line.push(b);
        } else {
            line.push('\\');
            line.push(DIGITS[b >> 4]);
            line.push(DIGITS[b & 15]);
        }
    }
}

// The event names, for printing.
fn event(e: i64) -> const u8[:] {
    match e {
        pg::WANT_INPUT => "WANT_INPUT",
        pg::READY => "READY",
        pg::COLUMNS => "COLUMNS",
        pg::ROW => "ROW",
        pg::DONE => "DONE",
        pg::ERROR => "ERROR",
        pg::SKIPPED => "SKIPPED",
        pg::PARSED => "PARSED",
        pg::SUSPENDED => "SUSPENDED",
        pg::NOTICE => "NOTICE",
        pg::FAILED => "FAILED",
        _ => "?",
    }
}

// Appends a backend message of kind with body to out.
fn message(out: u8[>..]&, kind: u8, body: const u8[:]) {
    out.push(kind);
    pg::put32(out, body.len + 4);
    out.append(body);
}

// A backend message of kind with body.
fn message_of(kind: u8, body: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    message(out, kind, body);
    return out;
}

// The body of an Authentication message with code and data.
fn auth(code: i64, data: const u8[:]) -> u8[>..] {
    var b: u8[>..] = [];
    pg::put32(b, code);
    b.append(data);
    return b;
}
