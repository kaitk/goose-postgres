# Sketch: `/async-db` in Plod's HttpArena entry

Task 005's step 3, as Plod's entry (its `bench/httparena/plod/`, on the `httparena`
branch at `e234436`) would write it with `pg.pool`. Not built or compiled: the
pool's own test (`test/live/pool.goose`) runs the same query, JSON, and calls on
goose-http directly. What Plod lacks for it is under "Gaps".

## The root file

`server.goose` declares goose-postgres beside the packages it declares already, and
`app.goose` imports the module:

```goose
import pg from "github.com/kaitk/goose-postgres@<tag>";
import pg.pool;
```

## Settings, read once in `main`

Each worker copies the globals `main` set before `http::run`, as it copies `dataset`.

```goose
var db_cfg: pg::Config;
var db_ok = false;
var per_worker = 1;

// DATABASE_URL and DATABASE_MAX_CONN, the pool's size over all workers. Without a
// usable URL, /async-db answers the empty JSON, as HttpArena asks of a database
// that can't be reached.
fn load_database(workers: i64) {
    var url: u8[>..] = [];
    guard env("DATABASE_URL", url) else { return; }
    let cfg, why = pg::url_settings(url);
    guard why.len == 0 else { return; }
    db_cfg = cfg;
    db_ok = true;
    var max: u8[>..] = [];
    var total = 256;
    if env("DATABASE_MAX_CONN", max) {
        let n, ok = parse_int(max);
        if ok && n > 0 { total = n; }
    }
    per_worker = max(total / workers, 1);
}
```

`main` calls `load_database(cfg.workers)` with the worker count `http::run` starts,
`hardware_threads()` when `Config.workers` is 0. With 256 connections and 64 workers,
each worker opens up to 4.

## The worker's state

The pool ends the worker's state, since its connections are a growable array, so the
entry gains an app state of its own, built in the worker; today it serves with
`plod::NoState`:

```goose
struct App { db: pg::Pool }

thread_fn worker(cfg: http::Config) {
    var app = App { db: pg::pool(db_cfg, per_worker) };
    let e = plod::serve(cfg, app, St { .. }) { cx => on_call(cx); };
    pg::close(app.db);
    if e.code != 0 { http::report(e); }
}
```

`plod::serve` runs on io_uring on Linux, where goose-http waits on sockets; the
emulated ring would fail each query with `wait_socket`'s `ENOSYS`, and the route
would answer the empty JSON.

## The route

The variant carries the request's integers, which every later call needs, and the
request state the pool's ticket:

```goose
enum Use {
    None,
    Delay { ms: i64 },
    File,
    Echo,
    Items { lo: i64, hi: i64, limit: i64 },
}

struct St {
    use: Use = Use.None,
    file: http::FileBody = http::FileBody { .. },
    ws: http::WebSocket = http::WebSocket { .. },
    ticket: pg::Ticket = pg::Ticket { .. },
}

let ITEMS = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
let NO_ITEMS = "{\"items\":[],\"count\":0}";

// In handle's routes:
//     plod::get(cx, "/async-db") { async_db(cx); };

fn async_db(cx) {
    var lo, has_lo = plod::query_int(cx, "min");
    var hi, has_hi = plod::query_int(cx, "max");
    var limit, has_limit = plod::query_int(cx, "limit");
    if !has_lo { lo = 10; }
    if !has_hi { hi = 50; }
    limit = if has_limit { min(max(limit, 1), 50) } else { 50 };
    guard db_ok else {
        http::respond(cx.out, 200, "application/json", NO_ITEMS);
        return;
    }
    cx.state.use = Use.Items { lo: lo, hi: hi, limit: limit };
    resume(cx.state.use, cx);   // the request's own call starts the query
}

// At the request, and at each WAKE: a connection handed over, or the socket
// ready. Rows go into the answer in the call that finds them all.
fn resume(u: Use.Items, cx) {
    var body: u8[>..] = [];
    body.append("{\"items\":[");
    let n = pg::query(cx.app.db, cx.state.ticket, cx.out, cx.kind, cx.reply, 5000, ITEMS,
                      u.lo, u.hi, u.limit) { r =>
        if body.len > 10 { body.push(','); }
        format(body, "{\"id\":", pg::text(r, 0), ",\"name\":");
        http::json_string(body, pg::text(r, 1));
        body.append(",\"category\":");
        http::json_string(body, pg::text(r, 2));
        format(body, ",\"price\":", pg::text(r, 3), ",\"quantity\":", pg::text(r, 4),
               ",\"active\":", if pg::boolean(r, 5) { "true" } else { "false" },
               ",\"tags\":", pg::text(r, 6),
               ",\"rating\":{\"score\":", pg::text(r, 7), ",\"count\":", pg::text(r, 8), "}}");
    };
    if n == pg::WAITS { return; }
    if n == pg::FAILS {
        http::respond(cx.out, 200, "application/json", NO_ITEMS);
        return;
    }
    format(body, "],\"count\":", n, "}");
    http::respond(cx.out, 200, "application/json", body);
}
```

The text format gives the integers and `tags`' `jsonb` as their JSON text, so the
row goes into the answer without decoding: `tags` comes as Postgres prints `jsonb`,
`["fast", "new"]`, which is JSON. The block's `return`s are in `resume`, a function,
so they don't leave Plod's handler block.

`on_call` stays as it is: `plod::on_reply(cx) { resume(cx.state.use, cx); }` sends
the pool's `WAKE`s to `resume(u: Use.Items, cx)`. `cx.reply` is the WAKE's bytes for
a wait that isn't a lane's, which is where the pool reads the connection it was
handed. The pool's tag, `pg::POOL_TAG`, and goose-http's `SOCKET_READY` carry none of
Plod's `REPLY_*` bits, so `on_event` passes both to the route.

`server.goose`'s `config()` already sets `mail_slots` and `max_waiting`, which the
pool's waits need; one hand-over is one message to the worker's own box.

## Gaps

- **`TIMEOUT` and `CLOSED`.** Plod answers 504 at a `TIMEOUT` that isn't a pause's,
  without calling the route, and gives `CLOSED` only to routes that read a body in
  pieces, began a response, sent a file, or upgraded. So `resume` never sees either
  for a socket wait. The pool doesn't need them: the next request adopts a connection
  whose exchange went. But when Postgres stops answering, the route answers 504 where
  HttpArena asks for the empty JSON, and a request queued behind such a connection
  waits until a new request adopts it, or for its own 504. A Plod call that marks the
  wait as the route's own, so that `on_event` hands it both events, would close
  both gaps; goose-postgres needs no change for it.
- **`plod::pause` would be a workaround, untested.** Called at the request before
  `pg::query`, it sets the mode that makes `on_event` pass a `TIMEOUT` on, and the
  pool's own waits would then replace its timer. It gives no `CLOSED`, and it leans
  on how Plod clears that mode, so the sketch doesn't use it.
