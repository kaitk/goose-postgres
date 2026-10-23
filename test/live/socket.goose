// The blocking facade over goose-http's socket (socket.goose), against a
// server that scripts/live.sh starts: connects that fail, then a session as
// test/session/facade.goose runs it, and a connection made again.
//
//   socket postgres://bench:bench@127.0.0.1:55432/benchmark [UNIX_DIR]
//
// With UNIX_DIR, the session connects through the server's Unix socket in
// that directory instead of TCP; its output is the same.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http from "github.com/kaitk/goose-http@v0.5.6";
import pg from "../../";
import pg.socket;
import wire from "../";

let LIMIT = 10000;

fn main() {
    var url = "";
    var dir = "";
    var k = 0;
    for a in args() {
        if k == 1 { url = a; }
        if k == 2 { dir = a; }
        k++;
    }
    var cfg, ok = pg::parse_url(url);
    guard ok else { abort("usage: socket postgres://... [UNIX_DIR]"); }
    if dir.len > 0 {
        cfg.host.clear();
        cfg.host.append(dir);
    }

    var db = pg::Db { t: pg::Socket { .. }, .. };
    var bad = cfg;
    bad.host.clear();
    bad.host.append("127.0.0.1");
    bad.port = 1;
    wire::errors("refused", pg::run() { pg::open(db, bad, LIMIT); });
    bad.host.clear();
    bad.host.append("/nonexistent");
    wire::errors("no Unix socket", pg::run() { pg::open(db, bad, LIMIT); });
    bad.host.clear();
    bad.host.append("db.invalid");
    wire::errors("a host name", pg::run() { pg::open(db, bad, LIMIT); });
    wire::errors("not a URL", pg::run() { pg::open(db, "mysql://bench@localhost/benchmark", LIMIT); });

    wire::errors("before connecting", pg::run() { pg::exec(db, "SELECT 1"); });
    wire::errors("connect", pg::run() { pg::open(db, cfg, LIMIT); });
    wire::facade(db);
    print("socket closed: ", db.t.s.fd == -1);

    wire::errors("open again", pg::run() {
        pg::open(db, cfg, LIMIT);
        pg::query(db, "SELECT count(*) FROM items WHERE id <= $1", 10) { r =>
            print("items: ", pg::int(r, 0));
        };
        pg::open(db, cfg, LIMIT);
        print("open on an open connection: ", pg::exec(db, "SELECT 1"));
    });
    pg::close(db);
}
