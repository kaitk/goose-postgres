// The pool (pool.goose) on goose-http's loop, against a server that
// scripts/live.sh starts: HttpArena's /async-db at its limits, many requests
// on two connections, a query past its time limit, clients that go while
// their query runs, with the pool told and not told, a server that ends its
// connections, refuses new ones, and takes them again, and a server nothing
// listens for. The routes run on serve_epoll's loop; on serve's, each
// answers as wait_socket allows there: on io_uring as on epoll, elsewhere
// with the empty answer.
//
//   pool postgres://bench:bench@127.0.0.1:55432/benchmark
import std;
import os;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http from "github.com/kaitk/goose-http@v0.5.6";
import pg from "../../";
import pg.socket;
import pg.pool;

let ARENA_SQL = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
let EMPTY = "{\"items\":[],\"count\":0}";

let ARENA: u8 = 0;
let REFUSED: u8 = 1;
let PID: u8 = 2;
let SLOW: u8 = 3;
let SLEEP: u8 = 4;
let UNHEARD: u8 = 5;
let BIG: u8 = 6;

struct St {
    t: pg::Ticket = pg::Ticket { .. },
    route: u8 = ARENA,
    lo: i64 = 10,
    hi: i64 = 50,
    limit: i64 = 50,
}

// A query's integer, or its default.
fn int_or(target: const u8[:], key: const u8[:], default: i64) -> i64 {
    let v, ok = http::query_int(target, key);
    return if ok { v } else { default };
}

fn handle(ev: http::Event, st: St&, out: http::Reply, db: pg::Pool&, one: pg::Pool&, refused: pg::Pool&) {
    if ev.kind == http::REQUEST {
        let path = http::path_of(ev.req.target);
        if path == "/async-db" || path == "/refused" {
            st.route = if path == "/refused" { REFUSED } else { ARENA };
            st.lo = int_or(ev.req.target, "min", 10);
            st.hi = int_or(ev.req.target, "max", 50);
            st.limit = min(max(int_or(ev.req.target, "limit", 50), 1), 50);
        } else if path == "/open" {
            var text: u8[>..] = [];
            format(text, open_count(db));
            http::respond(out, 200, "text/plain", text);
            return;
        } else if path == "/pid" { st.route = PID; }
        else if path == "/slow" { st.route = SLOW; }
        else if path == "/sleep" { st.route = SLEEP; }
        else if path == "/sleep-unheard" { st.route = UNHEARD; }
        else if path == "/big" { st.route = BIG; }
        else {
            http::respond(out, 404, "text/plain", "");
            return;
        }
    }
    // As a framework that doesn't pass CLOSED on to the route.
    if ev.kind == http::CLOSED && st.route == UNHEARD { return; }
    if st.route == ARENA { arena(ev, st, out, db); }
    else if st.route == REFUSED { arena(ev, st, out, refused); }
    else if st.route == PID { scalar(ev, st, out, one, "SELECT pg_backend_pid()", 5000); }
    else if st.route == SLOW { scalar(ev, st, out, one, "SELECT pg_sleep(1)", 200); }
    else if st.route == BIG { scalar(ev, st, out, one, "SELECT repeat('x', 1000) FROM generate_series(1, 100)", 5000); }
    else { scalar(ev, st, out, one, "SELECT pg_sleep(0.3)", 5000); }
}

fn arena(ev: http::Event, st: St&, out: http::Reply, p: pg::Pool&) {
    var body: u8[>..] = [];
    body.append("{\"items\":[");
    let n = pg::query(p, st.t, out, ev.kind, ev.data, 5000, ARENA_SQL, st.lo, st.hi, st.limit) { r =>
        if body.len > 10 { body.push(','); }
        item(body, r);
    };
    if n == pg::WAITS { return; }
    if n == pg::FAILS {
        failed(st, out, p);
        return;
    }
    format(body, "],\"count\":", n, "}");
    http::respond(out, 200, "application/json", body);
}

// HttpArena's item: the row with its rating nested. The text format gives
// the integers and the tags' JSON as they go into the answer.
fn item(out: u8[>..]&, r: pg::Row) {
    format(out, "{\"id\":", pg::text(r, 0), ",\"name\":");
    json_string(out, pg::text(r, 1));
    out.append(",\"category\":");
    json_string(out, pg::text(r, 2));
    format(out, ",\"price\":", pg::text(r, 3), ",\"quantity\":", pg::text(r, 4), ",\"active\":",
           if pg::boolean(r, 5) { "true" } else { "false" }, ",\"tags\":", pg::text(r, 6),
           ",\"rating\":{\"score\":", pg::text(r, 7), ",\"count\":", pg::text(r, 8), "}}");
}

fn json_string(out: u8[>..]&, s: const u8[:]) {
    let hex = "0123456789abcdef";
    out.push('"');
    for b in s {
        if b == '"' || b == '\\' {
            out.push('\\');
            out.push(b);
        } else if b < 32 {
            out.append("\\u00");
            out.push(hex[b >> 4]);
            out.push(hex[b & 15]);
        } else {
            out.push(b);
        }
    }
    out.push('"');
}

// The empty answer, with why in a field, for the test to print.
fn failed(st: St&, out: http::Reply, p: pg::Pool&) {
    var why: u8[>..] = [];
    format(why, st.t.code, " ", p.reason);
    http::start(out, 200);
    http::field(out, "X-Pg", why);
    http::finish(out, http::JSON, EMPTY);
}

fn scalar(ev: http::Event, st: St&, out: http::Reply, p: pg::Pool&, sql: const u8[:], ms: i64) {
    var v: u8[>..] = [];
    let n = pg::query(p, st.t, out, ev.kind, ev.data, ms, sql) { r => v.append(pg::text(r, 0)); };
    if n == pg::WAITS { return; }
    if n == pg::FAILS {
        failed(st, out, p);
        return;
    }
    http::respond(out, 200, "text/plain", v);
}

fn open_count(p: const pg::Pool&) -> i64 {
    var n = 0;
    for k in p.slots.len { if p.slots[k].phase == pg::SLOT_OPEN { n++; } }
    return n;
}

fn pools(dbcfg: pg::Config) -> pg::Config {
    var dead = dbcfg;
    dead.host.clear();
    dead.host.append("127.0.0.1");
    dead.port = 1;
    return dead;
}

thread_fn worker(cfg: http::Config, dbcfg: pg::Config) {
    var db = pg::pool(dbcfg, 2);
    var one = pg::pool(dbcfg, 1);
    var refused = pg::pool(pools(dbcfg), 1);
    let e = http::serve_epoll(cfg, St { .. }) { ev, st, out => handle(ev, st, out, db, one, refused); };
    pg::close(db);
    pg::close(one);
    pg::close(refused);
    http::report(e);
}

thread_fn ring_worker(cfg: http::Config, dbcfg: pg::Config) {
    var db = pg::pool(dbcfg, 2);
    var one = pg::pool(dbcfg, 1);
    var refused = pg::pool(pools(dbcfg), 1);
    let e = http::serve(cfg, St { .. }) { ev, st, out => handle(ev, st, out, db, one, refused); };
    pg::close(db);
    pg::close(one);
    pg::close(refused);
    http::report(e);
}

// A Unix socket's address in TMPDIR, or in the working directory without it.
fn unix_address(name: const u8[:]) -> u8[>..] {
    var dir: u8[>..] = [];
    var a: u8[>..] = [];
    if env("TMPDIR", dir) && dir.len > 0 { format(a, "unix:", dir, "/", name); }
    else { format(a, "unix:", name); }
    return a;
}

fn connected(address: const u8[:]) -> http::Socket {
    for i in 500 {
        let c, e = http::connect(address, 0, 1000);
        if e.code == 0 { return c; }
        sleep_ms(10);
    }
    abort("can't connect to the loop");
}

// A GET's status code, its X-Pg field, and its body.
fn get(address: const u8[:], path: const u8[:]) -> i64, u8[>..], u8[>..] {
    let s = connected(address);
    var req: u8[>..] = [];
    format(req, "GET ", path, " HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n");
    assert(http::send_all(s, req, 5000).code == 0);
    var got: u8[>..] = [];
    var buf: u8[16384] = [0; 16384];
    loop {
        let n = http::recv(s, buf, 10000);
        assert(n >= 0);
        if n == 0 { break; }
        got.append(buf[..n]);
    }
    var sock = s;
    http::hangup(sock);
    let head = find(got, "\r\n\r\n");
    assert(head > 12);
    let status, ok = parse_int(got[9..12]);
    var why: u8[>..] = [];
    let at = find(got[..head], "X-Pg: ");
    if at >= 0 {
        let end = find(got[at..head + 2], "\r\n");
        why.append(got[at + 6..at + end]);
    }
    var body: u8[>..] = [];
    body.append(got[head + 4..]);
    return status, why, body;
}

// Sends a GET and goes without waiting for the answer.
fn get_and_go(address: const u8[:], path: const u8[:]) {
    var s = connected(address);
    var req: u8[>..] = [];
    format(req, "GET ", path, " HTTP/1.1\r\nHost: test\r\n\r\n");
    assert(http::send_all(s, req, 5000).code == 0);
    sleep_ms(50);
    http::hangup(s);
}

// What /async-db answered for limit: whether its count and items agree with
// it and every price is within lo and hi.
fn arena_ok(body: const u8[:], lo: i64, hi: i64, limit: i64) -> bool {
    var items = 0;
    var at = 0;
    loop {
        let p = find(body[at..], "\"price\":");
        if p < 0 { break; }
        at += p + 8;
        var end = at;
        while end < body.len && body[end] >= '0' && body[end] <= '9' { end++; }
        let price, ok = parse_int(body[at..end]);
        guard ok && price >= lo && price <= hi else { return false; }
        items++;
    }
    var tail: u8[>..] = [];
    format(tail, "],\"count\":", limit, "}");
    return items == limit && ends_with(body, tail) && starts_with(body, "{\"items\":[{\"id\":");
}

fn show_arena(address: const u8[:], limit: i64) {
    var path: u8[>..] = [];
    format(path, "/async-db?min=10&max=50&limit=", limit);
    let status, why, body = get(address, path);
    let ok = status == 200 && arena_ok(body, 10, 50, limit);
    print("limit ", limit, ": ", if ok { "ok" } else { "FAILED" });
    if !ok { print("  ", status, " ", why, " ", body); }
}

fn show(label: const u8[:], address: const u8[:], path: const u8[:]) -> u8[>..] {
    let status, why, body = get(address, path);
    print(label, ": ", status, " ", body, if why.len > 0 { " (" } else { "" }, why, if why.len > 0 { ")" } else { "" });
    return body;
}

struct Address { a: u8[..200] }
struct Done { ok: i64 }

thread_fn client(at: Address, k: i64) {
    var ok = 0;
    for i in 10 {
        let limit = 1 + (k * 10 + i) % 50;
        var path: u8[>..] = [];
        format(path, "/async-db?limit=", limit);
        let status, why, body = get(at.a, path);
        if status == 200 && arena_ok(body, 10, 50, limit) { ok++; }
        else { print("client ", k, " limit ", limit, ": ", status, " ", why); }
    }
    qput(Done { ok: ok });
}

// Runs sql on the admin connection, and returns the first column of its last
// row.
fn admin(db: pg::Db<pg::Socket>&, sql: const u8[:]) -> u8[>..] {
    var v: u8[>..] = [];
    let failed = pg::run() { pg::query(db, sql) { r => v.clear(); v.append(pg::text(r, 0)); }; };
    for e in failed { abort(str("admin: ", e.code, " ", e.message)); }
    return v;
}

// Ends the pools' sessions, and waits until the server has.
fn end_sessions(db: pg::Db<pg::Socket>&) {
    admin(db, "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname = 'benchmark'");
    for i in 200 {
        if admin(db, "SELECT count(*) FROM pg_stat_activity WHERE datname = 'benchmark'") == "0" {
            // The backends have gone; Docker Desktop's port forwarding may
            // pass their last bytes on a little later.
            sleep_ms(200);
            return;
        }
        sleep_ms(25);
    }
    abort("the sessions didn't end");
}

fn main() {
    let a = args();
    guard a.len >= 2 else { abort("usage: pool postgres://..."); }
    let dbcfg, why = pg::url_settings(a[1]);
    guard why.len == 0 else { abort(why); }

    let epoll = unix_address("pool_epoll.sock");
    let cfg = http::Config { address: epoll, workers: 1, mail_slots: 64, max_waiting: 64, .. };
    let w = thread_spawn(worker, cfg, dbcfg);

    print("-- HttpArena's /async-db");
    for limit in [7, 18, 33, 50] { show_arena(epoll, limit); }
    let status, why, body = get(epoll, "/async-db?min=600&max=700");
    print("an empty range: ", status, " ", body);
    show("connections open", epoll, "/open");

    print("-- 8 clients, 10 requests each, on 2 connections");
    var addr = Address { a: [] };
    addr.a.append(epoll);
    var ids: i64[>..] = [];
    for k in 8 { ids.push(thread_spawn(client, addr, k)); }
    var ok = 0;
    for k in 8 { ok += qget<Done>().ok; }
    for id in ids { thread_wait(id); }
    print("answered with their limit: ", ok, " of 80");
    show("connections open", epoll, "/open");

    print("-- a query past its time limit, then one on the same pool");
    show("pg_sleep(1) with 200 ms", epoll, "/slow");
    let s1, w1, pid = get(epoll, "/pid");
    print("then a query: ", s1, w1);

    print("-- an answer longer than POOL_INPUT, then a query");
    show("100 rows of 1000 bytes", epoll, "/big");
    let s4, w4, again = get(epoll, "/pid");
    print("then a query: ", s4, w4, ", on a new backend: ", again != pid);

    print("-- clients that go while their query runs");
    get_and_go(epoll, "/sleep");
    let s2, w2, after = get(epoll, "/pid");
    print("the next query: ", s2, w2, ", on the same backend: ", after == again);
    get_and_go(epoll, "/sleep-unheard");
    let s3, w3, unheard = get(epoll, "/pid");
    print("the next, the pool not told: ", s3, w3, ", on the same backend: ", unheard == again);

    var acfg = dbcfg;
    acfg.database.clear();
    acfg.database.append("postgres");
    var db = pg::Db { t: pg::Socket { .. }, .. };
    let opened = pg::run() { pg::open(db, acfg, 5000); };
    for e in opened { abort(str("admin: ", e.code, " ", e.message)); }

    print("-- the server ends every session");
    end_sessions(db);
    show_arena(epoll, 20);
    show("connections open", epoll, "/open");

    print("-- the server refuses new sessions");
    admin(db, "ALTER DATABASE benchmark ALLOW_CONNECTIONS false");
    end_sessions(db);
    show("a request", epoll, "/async-db?limit=5");
    show("another", epoll, "/async-db?limit=5");
    show("connections open", epoll, "/open");

    print("-- and takes them again");
    admin(db, "ALTER DATABASE benchmark ALLOW_CONNECTIONS true");
    show_arena(epoll, 5);
    show_arena(epoll, 50);
    show("connections open", epoll, "/open");
    pg::close(db);

    print("-- a server nothing listens for");
    show("a request", epoll, "/refused");
    show("another", epoll, "/refused");

    print("-- serve's loop");
    let ring = unix_address("pool_ring.sock");
    let r = thread_spawn(ring_worker, http::Config { address: ring, workers: 1, mail_slots: 64, max_waiting: 64, .. },
                         dbcfg);
    let rs, rwhy, rbody = get(ring, "/async-db?min=10&max=50&limit=9");
    let native = http::ring_probe() == 0;
    let ring_ok = if native { rs == 200 && arena_ok(rbody, 10, 50, 9) } else { rbody == EMPTY && find(rwhy, "wait_socket") >= 0 };
    if !ring_ok { print("serve: ", rs, " ", rwhy, " ", rbody); }
    print("serve: ", ring_ok);

    http::stop();
    thread_wait(w);
    thread_wait(r);
}
