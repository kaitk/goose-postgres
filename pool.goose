// A pool of connections on goose-http's loop, for a route that runs one
// query and answers from its rows, as HttpArena's /async-db does
// (docs/architecture.md, "The pool"). Each worker keeps a Pool of its own:
// the worker whose exchange waits on a socket owns it. A request that finds
// no idle connection opens one, up to the pool's size, or waits in a queue
// until one is handed back. A program imports the module pg.pool, and
// declares goose-http in its root file at the reference this file names.
//
//   import http from "github.com/kaitk/goose-http@v0.5.16";
//   import pg.pool;
//
//   var db = pg::pool(cfg, per_worker);        // in the worker, before serve
//   // the request's state holds a pg::Ticket { .. }, and at each of the
//   // route's events, REQUEST, WAKE, TIMEOUT, and CLOSED:
//   let n = pg::query(db, st.ticket, out, ev.kind, ev.data, 5000, sql, lo, hi) { r =>
//       ... pg::int(r, 0), pg::text(r, 1) ...
//   };
//   if n == pg::WAITS { return; }              // called again at the next event
//   if n == pg::FAILS { ... }                  // st.ticket.code, db.reason
//
// The whole answer to the query is read into its connection's buffer,
// POOL_INPUT bytes, before the block sees the first row, so the block runs
// for every row within one call and the route answers in that call.
namespace pg;

import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http from "github.com/kaitk/goose-http@v0.5.16";
import .socket;

// Each connection's buffer: the most one query's answer may take, and so
// the longest message a pooled connection accepts.
let POOL_INPUT = 65536;
// The most requests that wait for a connection on one worker at once.
let POOL_WAITERS = 1024;
// The tag of the mail that hands a connection to a request that waits for
// one; its bytes are the connection's number.
let POOL_TAG: i32 = 0x7067;

// What query returns, besides a count of rows.
let WAITS = -1;   // the exchange waits: return from the handler
let FAILS = -2;   // no answer: Ticket.code and Pool.reason say why

// The code of a request that found every connection busy and the queue full,
// Postgres's too_many_connections.
let TOO_MANY_CONNECTIONS = "53300";

// A connection's phases.
let SLOT_CLOSED: u8 = 0;
let SLOT_CONNECTING: u8 = 1;   // connect_start's connect going on
let SLOT_STARTING: u8 = 2;     // the startup message sent; authenticating
let SLOT_OPEN: u8 = 3;

// A request's place with the pool, in the request's state.
let TICKET_NEW: u8 = 0;
let TICKET_QUEUED: u8 = 1;     // waits for a connection to be handed over
let TICKET_HAVE: u8 = 2;       // owns connection `conn`
let TICKET_DONE: u8 = 3;

struct Ticket {
    state: u8 = TICKET_NEW,
    conn: i64 = -1,
    // The first entry of the request's query once sent, and its Parse's
    // entry and statement when it sent one; -1 for none.
    first: i64 = -1,
    parse: i64 = -1,
    statement: i64 = -1,
    // The exchange's address, which owns the connection or waits in the queue.
    addr: http::MailAddress = http::MailAddress { .. },
    // Why query returned FAILS: a SQLSTATE, the server's or one of the
    // facade's codes.
    code: u8[..5],
}

// A connection of the pool. owner is the address of the exchange that drives
// it, key 0 for none: idle when open, free to connect when closed. A
// connection whose owner no longer waits, as after a TIMEOUT or CLOSED the
// program didn't pass on, is adopted by the next request that finds none
// idle, which reads and drops the answers to queries it didn't send.
struct Slot {
    s: http::Socket = http::Socket { .. },
    phase: u8 = SLOT_CLOSED,
    owner: http::MailAddress = http::MailAddress { .. },
    // Bit k: the pool's statement k is prepared on this connection.
    prepared: u64 = 0,
    // input[at..len] holds what has arrived and step hasn't read.
    at: i64 = 0,
    len: i64 = 0,
    c: Conn,
    input: u8[POOL_INPUT],
}

// A worker's connections, with the settings to open them, the statements
// prepared on them by name, and the requests waiting for one. Build it in
// the worker that serves, with pool, and keep it last in the worker's state:
// the connections end it.
struct Pool {
    cfg: Config,
    // Statement k is named "gp<k>"; its SQL is sql[ends[k - 1]..ends[k]].
    statements: i64 = 0,
    ends: i32[STATEMENTS],
    sql: u8[..STATEMENT_TEXT],
    // A ring of the addresses of the requests waiting, from waiters[head].
    head: i64 = 0,
    waiting: i64 = 0,
    waiters: http::MailAddress[POOL_WAITERS],
    // Why the last query that failed did.
    reason: u8[..120],
    slots: Slot[>..],
}

// A pool of size connections, at least one, to cfg's server, none open yet:
// each opens when a request needs it. A pooled connection takes messages up
// to POOL_INPUT - 1 bytes, or cfg.max_message if lower. A host that starts
// with / is the directory of the server's Unix socket, as for pg::open; a
// host name fails: goose-http's loop doesn't resolve names.
fn pool(cfg: Config, size: i64) -> Pool {
    var p = Pool { cfg: cfg, .. };
    p.cfg.max_message = min(cfg.max_message, POOL_INPUT - 1);
    for i in max(size, 1) { p.slots.push(Slot { c: Conn { .. }, .. }); }
    return p;
}

// Ends each open session and closes every socket, when the worker's loop has
// returned.
fn close(p: Pool&) {
    for k in p.slots.len {
        let s .= p.slots[k];
        if s.phase == SLOT_OPEN {
            var out: u8[>..] = [];
            terminate(out);
            let n = http::send(s.s, out);
        }
        hang_up(s);
        s.owner = http::MailAddress { .. };
    }
}

// Runs sql on a connection of p for the request t belongs to, with up to
// eight parameters as the facade's query takes them, and calls F with each
// row, in the text format. Call it at the route's request and at each of
// its later events, kind and data being the event's (http::Event.kind and
// .data): it connects, waits for a connection, sends, and reads as each
// event allows, and returns WAITS while the exchange waits, the count of
// rows once F has seen them all, or FAILS. ms limits each wait. At TIMEOUT
// or CLOSED it gives up the connection and returns FAILS.
fn query<F>(p: Pool&, t: Ticket&, out: http::Reply, kind: u8, data: const u8[:], ms: i64,
            sql: const u8[:]) -> i64 {
    return pooled(p, t, out, kind, data, ms, sql, F) { w => };
}

fn query<F>(p: Pool&, t: Ticket&, out: http::Reply, kind: u8, data: const u8[:], ms: i64,
            sql: const u8[:], p1) -> i64 {
    return pooled(p, t, out, kind, data, ms, sql, F) { w => param(w, p1); };
}

fn query<F>(p: Pool&, t: Ticket&, out: http::Reply, kind: u8, data: const u8[:], ms: i64,
            sql: const u8[:], p1, p2) -> i64 {
    return pooled(p, t, out, kind, data, ms, sql, F) { w =>
        param(w, p1);
        param(w, p2);
    };
}

fn query<F>(p: Pool&, t: Ticket&, out: http::Reply, kind: u8, data: const u8[:], ms: i64,
            sql: const u8[:], p1, p2, p3) -> i64 {
    return pooled(p, t, out, kind, data, ms, sql, F) { w =>
        param(w, p1);
        param(w, p2);
        param(w, p3);
    };
}

fn query<F>(p: Pool&, t: Ticket&, out: http::Reply, kind: u8, data: const u8[:], ms: i64,
            sql: const u8[:], p1, p2, p3, p4) -> i64 {
    return pooled(p, t, out, kind, data, ms, sql, F) { w =>
        param(w, p1);
        param(w, p2);
        param(w, p3);
        param(w, p4);
    };
}

fn query<F>(p: Pool&, t: Ticket&, out: http::Reply, kind: u8, data: const u8[:], ms: i64,
            sql: const u8[:], p1, p2, p3, p4, p5) -> i64 {
    return pooled(p, t, out, kind, data, ms, sql, F) { w =>
        param(w, p1);
        param(w, p2);
        param(w, p3);
        param(w, p4);
        param(w, p5);
    };
}

fn query<F>(p: Pool&, t: Ticket&, out: http::Reply, kind: u8, data: const u8[:], ms: i64,
            sql: const u8[:], p1, p2, p3, p4, p5, p6) -> i64 {
    return pooled(p, t, out, kind, data, ms, sql, F) { w =>
        param(w, p1);
        param(w, p2);
        param(w, p3);
        param(w, p4);
        param(w, p5);
        param(w, p6);
    };
}

fn query<F>(p: Pool&, t: Ticket&, out: http::Reply, kind: u8, data: const u8[:], ms: i64,
            sql: const u8[:], p1, p2, p3, p4, p5, p6, p7) -> i64 {
    return pooled(p, t, out, kind, data, ms, sql, F) { w =>
        param(w, p1);
        param(w, p2);
        param(w, p3);
        param(w, p4);
        param(w, p5);
        param(w, p6);
        param(w, p7);
    };
}

fn query<F>(p: Pool&, t: Ticket&, out: http::Reply, kind: u8, data: const u8[:], ms: i64,
            sql: const u8[:], p1, p2, p3, p4, p5, p6, p7, p8) -> i64 {
    return pooled(p, t, out, kind, data, ms, sql, F) { w =>
        param(w, p1);
        param(w, p2);
        param(w, p3);
        param(w, p4);
        param(w, p5);
        param(w, p6);
        param(w, p7);
        param(w, p8);
    };
}

// The Bind a query's parameters go into, for the block that writes them.
struct Binding { out: u8[>..]&, b: Bind }

fn param(w: Binding, v) { param(w.out, w.b, v); }

// query's work, with R the rows' block and W the writer of the parameters.
fn pooled<R, W>(p: Pool&, t: Ticket&, out: http::Reply, kind: u8, data: const u8[:], ms: i64,
                sql: const u8[:]) -> i64 {
    if kind == http::TIMEOUT || kind == http::CLOSED {
        if t.state == TICKET_HAVE && owns(p, t) {
            // A server that doesn't answer in time may not answer at all;
            // a client that went leaves a connection the next owner reads on.
            if kind == http::TIMEOUT { hang_up(p.slots[t.conn]); }
            release(p, t.conn);
        }
        let timed_out = kind == http::TIMEOUT;
        return fails(p, t, CONNECTION_FAILURE,
                     if timed_out { "the database didn't answer in time" } else { "the client went" });
    }
    if t.state == TICKET_QUEUED {
        guard kind == http::WAKE else { return WAITS; }
        let k = handed(data);
        // Other mail leaves t in the queue, where it is.
        guard k >= 0 && k < p.slots.len && p.slots[k].owner.key == t.addr.key else {
            http::later(out, ms);
            return WAITS;
        }
        t.state = TICKET_HAVE;
        t.conn = k;
    }
    if t.state == TICKET_NEW {
        guard !has_nul(sql) else { return fails(p, t, CHARACTER_NOT_IN_REPERTOIRE, "the SQL holds a NUL byte"); }
        let r = acquire(p, t, out, ms);
        guard r == 0 else { return r; }
    }
    guard t.state == TICKET_HAVE else { return fails(p, t, CONNECTION_DOES_NOT_EXIST, "the query has ended"); }
    return drive(p, t, out, ms, sql, R, W);
}

// Gives t a connection: an idle open one, then one without an owner to open
// or to go on opening, then one whose owner no longer waits, which goes to
// the queue's first request when there is one; or queues t, or fails when
// the queue is full. 0 when t has one.
fn acquire(p: Pool&, t: Ticket&, out: http::Reply, ms: i64) -> i64 {
    let me = http::later(out, ms);
    t.addr = me;
    loop {
        var idle = -1;
        var unowned = -1;
        var abandoned = -1;
        for k in p.slots.len {
            let s .= p.slots[k];
            if s.owner.key == 0 {
                if s.phase == SLOT_OPEN {
                    idle = k;
                    break;
                }
                if unowned < 0 { unowned = k; }
            } else if abandoned < 0 && !http::mail_live(s.owner) {
                abandoned = k;
            }
        }
        if idle < 0 && unowned < 0 && abandoned >= 0 && p.waiting > 0 {
            // Leaves it with a waiter, or with no owner if none still waits.
            release(p, abandoned);
            continue;
        }
        // An idle connection while requests wait is one a full box kept from
        // the first of them: it goes to the queue, unless the box is still full.
        if idle >= 0 && p.waiting > 0 {
            release(p, idle);
            if p.slots[idle].owner.key != 0 { continue; }
        }
        let k = if idle >= 0 { idle } else if unowned >= 0 { unowned } else { abandoned };
        guard k < 0 else {
            p.slots[k].owner = me;
            t.state = TICKET_HAVE;
            t.conn = k;
            return 0;
        }
        break;
    }
    if p.waiting == POOL_WAITERS { forget_gone_waiters(p); }
    guard p.waiting < POOL_WAITERS else {
        return fails(p, t, TOO_MANY_CONNECTIONS, "every connection is busy, and POOL_WAITERS requests wait");
    }
    p.waiters[(p.head + p.waiting) % POOL_WAITERS] = me;
    p.waiting++;
    t.state = TICKET_QUEUED;
    return WAITS;
}

// Drops the waiters that no longer wait from p's queue, keeping the order.
fn forget_gone_waiters(p: Pool&) {
    var kept = 0;
    for i in p.waiting {
        let w = p.waiters[(p.head + i) % POOL_WAITERS];
        if http::mail_live(w) {
            p.waiters[(p.head + kept) % POOL_WAITERS] = w;
            kept++;
        }
    }
    p.waiting = kept;
}

// Whether t's exchange still owns its connection.
fn owns(p: const Pool&, t: const Ticket&) -> bool {
    return t.conn >= 0 && t.conn < p.slots.len && p.slots[t.conn].owner.key == t.addr.key;
}

// Hands connection k to the first request in the queue that still waits, or
// leaves it idle.
fn release(p: Pool&, k: i64) {
    let s .= p.slots[k];
    s.owner = http::MailAddress { .. };
    var number: u8[8] = [0; 8];
    for i in 8 { number[i] = (k >> (i * 8)) as! u8; }
    while p.waiting > 0 {
        let w = p.waiters[p.head];
        let sent = http::mail_send(w, POOL_TAG, number);
        // A full box may take the mail later: w stays first.
        guard sent != http::FULL else { return; }
        p.head = (p.head + 1) % POOL_WAITERS;
        p.waiting--;
        if sent == http::SENT {
            s.owner = w;
            return;
        }
    }
}

// The connection's number in the mail that handed it over, or -1.
fn handed(data: const u8[:]) -> i64 {
    guard data.len == 8 else { return -1; }
    var k = 0;
    for i in 8 { k |= (data[i] as i64) << (i * 8); }
    return k;
}

// Drives t's connection as far as it can go without waiting: connects,
// authenticates, sends the query, and reads its answer.
fn drive<R, W>(p: Pool&, t: Ticket&, out: http::Reply, ms: i64, sql: const u8[:]) -> i64 {
    let s .= p.slots[t.conn];
    loop {
        if s.phase == SLOT_CLOSED {
            let where = socket_address(p.cfg);
            let sock, e = http::connect_start(where, p.cfg.port);
            guard e.code == 0 else { return down(p, t, SQLCLIENT_UNABLE_TO_ESTABLISH_SQLCONNECTION, cant_connect(where, p.cfg.port, e)); }
            s.s = sock;
            s.phase = SLOT_CONNECTING;
            return wait(p, t, out, http::WRITABLE, ms);
        }
        if s.phase == SLOT_CONNECTING {
            let e = http::connected(s.s);
            if e.code == http::EINPROGRESS { return wait(p, t, out, http::WRITABLE, ms); }
            guard e.code == 0 else {
                let where = socket_address(p.cfg);
                return down(p, t, SQLCLIENT_UNABLE_TO_ESTABLISH_SQLCONNECTION, cant_connect(where, p.cfg.port, e));
            }
            var nonce: u8[18] = [0; 18];
            hash::random_bytes(nonce);
            var o: u8[>..] = [];
            start(s.c, o, p.cfg, nonce);
            s.at = 0;
            s.len = 0;
            s.prepared = 0;
            guard s.c.state != BROKEN else { return down(p, t, SQLCLIENT_UNABLE_TO_ESTABLISH_SQLCONNECTION, s.c.reason); }
            guard http::send(s.s, o) == o.len else { return down(p, t, CONNECTION_FAILURE, "sending to the server failed"); }
            s.phase = SLOT_STARTING;
            return wait(p, t, out, http::READABLE, ms);
        }
        let open = pull(s);
        if s.phase == SLOT_OPEN && t.first < 0 {
            // A connection the server ended while it was idle is opened
            // again for this query.
            if !open || room(s.c) < 3 || !idle_ok(s) {
                hang_up(s);
                continue;
            }
            return send_query(p, t, out, ms, sql, W);
        }
        // What arrived before the server closed may say why it did.
        if s.phase == SLOT_STARTING {
            var o: u8[>..] = [];
            let e, body = step(s.c, s.input[s.at..s.len], o);
            s.at += s.c.used;
            if o.len > 0 && http::send(s.s, o) != o.len { return down(p, t, CONNECTION_FAILURE, "sending to the server failed"); }
            if e == READY {
                s.phase = SLOT_OPEN;
                continue;
            }
            if e == FAILED { return lost_slot(p, t, body); }
            if e == WANT_INPUT { return more(p, t, out, ms, open); }
            continue;
        }
        return answer(p, t, out, ms, open, R);
    }
}

// Writes t's query, a Parse first when the connection hasn't prepared sql,
// sends it, and waits for the answer.
fn send_query<W>(p: Pool&, t: Ticket&, out: http::Reply, ms: i64, sql: const u8[:]) -> i64 {
    let s .= p.slots[t.conn];
    var o: u8[>..] = [];
    var name: u8[..24] = [];
    let k = pool_statement(p, sql);
    if k >= 0 { format(name, "gp", k); }
    if k < 0 || (s.prepared & bit(k)) == 0 {
        t.parse = parse(s.c, o, name, sql);
        t.first = t.parse;
        if k >= 0 {
            // Set before the answer, so a query sent behind this one on the
            // connection binds the name rather than parse it again.
            s.prepared |= bit(k);
            t.statement = k;
        }
    }
    let b = bind(o, name);
    W(Binding { out: o, b: b });
    let q = execute(s.c, o, b);
    let y = sync(s.c, o);
    // A message longer than MAX_MESSAGE broke the connection: none is sent.
    guard s.c.state != BROKEN else { return down(p, t, CONNECTION_FAILURE, s.c.reason); }
    if t.first < 0 { t.first = if q >= 0 { q } else { y }; }
    // More than 65535 parameters: the Bind is dropped, and the query fails
    // with this code once the server has answered the rest.
    if q < 0 { t.code.append("54023"); }
    guard http::send(s.s, o) == o.len else { return down(p, t, CONNECTION_FAILURE, "sending to the server failed"); }
    return wait(p, t, out, http::READABLE, ms);
}

fn bit(k: i64) -> u64 { (1 as u64) << k }

// The number of p's statement for sql, kept from now on if it's new, or -1
// when STATEMENTS or STATEMENT_TEXT has no room for it.
fn pool_statement(p: Pool&, sql: const u8[:]) -> i64 {
    var from = 0;
    for k in p.statements {
        let to = p.ends[k] as i64;
        if p.sql[from..to] == sql { return k; }
        from = to;
    }
    guard p.statements < STATEMENTS && p.sql.len + sql.len <= STATEMENT_TEXT else { return -1; }
    p.sql.append(sql);
    p.ends[p.statements] = p.sql.len as! i32;
    p.statements++;
    return p.statements - 1;
}

// Reads the answers on t's connection: those to queries sent before t's,
// dropped, then, once t's answer has arrived whole, each of its rows to R.
fn answer<R>(p: Pool&, t: Ticket&, out: http::Reply, ms: i64, open: bool) -> i64 {
    let s .= p.slots[t.conn];
    var count = 0;
    var failed = false;
    var code: u8[..5] = [];
    var message: u8[>..] = [];
    loop {
        guard s.c.count > 0 else { return down(p, t, CONNECTION_FAILURE, "the connection lost track of the query"); }
        if s.c.next - s.c.count >= t.first && !whole_answer(s) {
            guard s.at > 0 || s.len < POOL_INPUT else {
                return down(p, t, CONNECTION_FAILURE, "the answer is longer than POOL_INPUT");
            }
            return more(p, t, out, ms, open);
        }
        var o: u8[>..] = [];
        let e, body = step(s.c, s.input[s.at..s.len], o);
        s.at += s.c.used;
        if e == WANT_INPUT { return more(p, t, out, ms, open); }
        if e == FAILED { return lost_slot(p, t, body); }
        if e == ERROR && field(body, 'C') == INVALID_SQL_STATEMENT_NAME { s.prepared = 0; }
        guard s.c.seq >= t.first else { continue; }
        if e == ROW {
            R(Row { c: s.c, body: body });
        } else if e == DONE {
            count = rows(body);
        } else if e == ERROR {
            // 42P05 says the connection has the statement, which the mask may
            // have lost to a 26000 after a gone request's Parse failed.
            if s.c.seq == t.parse && t.statement >= 0 && field(body, 'C') != "42P05" {
                s.prepared &= ~bit(t.statement);
            }
            if !failed {
                failed = true;
                code.append(field(body, 'C')[..min(field(body, 'C').len, 5)]);
                message.append(field(body, 'M'));
            }
        } else if e == READY {
            compact(s);
            release(p, t.conn);
            if failed { return fails(p, t, code, message); }
            guard t.code.len == 0 else { return fails(p, t, "54023", "more than 65535 parameters, Postgres's limit"); }
            t.state = TICKET_DONE;
            return count;
        }
    }
}

// Reads what arrived on s with no query waiting, such as a notice, or the
// FATAL error of a server that ends the session: false for that.
fn idle_ok(s: Slot&) -> bool {
    guard s.c.count == 0 else { return true; }
    loop {
        var o: u8[>..] = [];
        let e, body = step(s.c, s.input[s.at..s.len], o);
        s.at += s.c.used;
        if e == FAILED { return false; }
        if e == WANT_INPUT { return true; }
    }
}

// Waits for more of the answer on t's connection, or, once the server has
// closed it, fails with the error it sent before, if any.
fn more(p: Pool&, t: Ticket&, out: http::Reply, ms: i64, open: bool) -> i64 {
    let s .= p.slots[t.conn];
    if open {
        compact(s);
        return wait(p, t, out, http::READABLE, ms);
    }
    loop {
        var o: u8[>..] = [];
        let e, body = step(s.c, s.input[s.at..s.len], o);
        s.at += s.c.used;
        if e == FAILED { return lost_slot(p, t, body); }
        if e == WANT_INPUT { return down(p, t, CONNECTION_FAILURE, "the server closed the connection, or receiving failed"); }
    }
}

// Whether s's input holds a whole ReadyForQuery: the end of the answer to
// the last query sent, when no other is waiting before it.
fn whole_answer(s: const Slot&) -> bool {
    var at = s.at;
    while at + 5 <= s.len {
        let size = get32(s.input, at + 1);
        guard size >= 4 && at + 1 + size <= s.len else { return false; }
        if s.input[at] == 'Z' { return true; }
        at += 1 + size;
    }
    return false;
}

// Reads what the socket holds into s's input, while there is room: false
// once the server has closed it, or it failed.
fn pull(s: Slot&) -> bool {
    loop {
        if s.len == POOL_INPUT {
            guard s.at > 0 else { return true; }
            compact(s);
        }
        let n = http::recv(s.s, s.input[s.len..]);
        if n == -http::EAGAIN { return true; }
        guard n > 0 else { return false; }
        s.len += n;
    }
}

// Moves what step hasn't read to the front of s's input.
fn compact(s: Slot&) {
    guard s.at > 0 else { return; }
    let keep = s.len - s.at;
    for i in keep { s.input[i] = s.input[s.at + i]; }
    s.at = 0;
    s.len = keep;
}

// Waits for t's connection to be ready for events.
fn wait(p: Pool&, t: Ticket&, out: http::Reply, events: u32, ms: i64) -> i64 {
    let e = http::wait_socket(out, p.slots[t.conn].s, events, ms);
    guard e.code == 0 else {
        var why: u8[>..] = [];
        format(why, "wait_socket fails with ", e.code, ": the loop must be serve_epoll's, or serve's on io_uring");
        return down(p, t, CONNECTION_FAILURE, why);
    }
    return WAITS;
}

// Closes s's socket, which the next request to take it connects again.
fn hang_up(s: Slot&) {
    http::hangup(s.s);
    s.phase = SLOT_CLOSED;
    s.at = 0;
    s.len = 0;
    s.prepared = 0;
}

// t's connection failed: closes it, hands it on, and fails t.
fn down(p: Pool&, t: Ticket&, code: const u8[:], why: const u8[:]) -> i64 {
    hang_up(p.slots[t.conn]);
    release(p, t.conn);
    return fails(p, t, code, why);
}

// t's connection broke in step: with the server's error, when it sent one.
fn lost_slot(p: Pool&, t: Ticket&, body: const u8[:]) -> i64 {
    var why: u8[>..] = [];
    let code = field(body, 'C');
    why.append(if code.len > 0 { field(body, 'M') } else { p.slots[t.conn].c.reason });
    return down(p, t, if code.len > 0 { code } else { CONNECTION_FAILURE }, why);
}

// Ends t with code and why.
fn fails(p: Pool&, t: Ticket&, code: const u8[:], why: const u8[:]) -> i64 {
    t.state = TICKET_DONE;
    t.code.clear();
    t.code.append(code[..min(code.len, 5)]);
    p.reason.clear();
    p.reason.append(why[..min(why.len, 120)]);
    return FAILS;
}
