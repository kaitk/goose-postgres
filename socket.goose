// goose-http's blocking socket as the facade's transport, for a thread that
// runs no event loop, such as a goose-rest lane. Only a program that imports
// this module needs goose-http, which its root file declares at the
// reference this file names:
//
//   import pg from "github.com/kaitk/goose-postgres@<tag>";
//   import http from "github.com/kaitk/goose-http@d5bc0fd6a2e5a703d6f9348da7692329f47fadc2";
//   import pg.socket;
//
//   var db = pg::Db { t: pg::Socket { .. }, .. };
//   let failed = pg::run() {
//       pg::open(db, cfg, 5000);     // the socket, then the session
//       pg::query(db, ...) { r => ... };
//   };
//   pg::close(db);
//
// Each wait, the connect, a send, or a receive, lasts at most the limit
// given; one that runs out fails the call and breaks the connection.
namespace pg;

import std;
import http from "github.com/kaitk/goose-http@d5bc0fd6a2e5a703d6f9348da7692329f47fadc2";

// The bytes a receive makes room for at once.
let RECEIVE_CHUNK = 16384;

// A connection to the server, and the limit in milliseconds on each wait
// (-1: none). Build it empty, `pg::Socket { .. }`, and let open connect it.
struct Socket { s: http::Socket, ms: i64 = -1 }

fn pg::send(t: pg::Socket&, bytes: const u8[:]) -> bool {
    t.s.fd >= 0 && http::send_all(t.s, bytes, t.ms).code == 0
}

fn pg::receive(t: pg::Socket&, into: u8[>..]&) -> bool {
    guard t.s.fd >= 0 else { return false; }
    // The facade passes into from the Db that holds t, which rules out
    // resizing it, so the bytes come through buf.
    var buf: u8[pg::RECEIVE_CHUNK] = [0; pg::RECEIVE_CHUNK];
    let n = http::recv(t.s, buf, t.ms);
    guard n > 0 else { return false; }
    into.append(buf[..n]);
    return true;
}

fn pg::close(t: pg::Socket&) { http::hangup(t.s); }

// Connects db's socket to cfg's host and port, each wait limited to ms
// milliseconds (-1: none), then starts the session as connect does. A host
// that starts with / is a directory holding the server's Unix socket,
// .s.PGSQL.<port>, as in libpq. Closes db first when it is open, so a
// connection that broke is made again with open. A socket that can't connect
// fails with SQLCLIENT_UNABLE_TO_ESTABLISH_SQLCONNECTION.
fn open(db: Db<Socket>&, cfg: Config, ms) {
    close(db);
    let unix = cfg.host.len > 0 && cfg.host[0] == '/';
    var where: u8[>..] = [];
    if unix {
        format(where, "unix:", cfg.host, if cfg.host[cfg.host.len - 1] == '/' { "" } else { "/" },
               ".s.PGSQL.", cfg.port);
    } else {
        where.append(cfg.host);
    }
    let s, e = http::connect(where, cfg.port, ms);
    guard e.code == 0 else {
        var message: u8[>..] = [];
        format(message, "can't connect to ", where);
        if !unix { format(message, " port ", cfg.port); }
        format(message, ": ", e.call, " ", reason(e.code));
        fail(SQLCLIENT_UNABLE_TO_ESTABLISH_SQLCONNECTION, message);
    }
    db.t = Socket { s: s, ms: ms };
    connect(db, cfg);
}

// Connects db with the settings in a postgres:// URL (parse_url), as open
// does with a Config.
fn open(db: Db<Socket>&, url: const u8[:], ms) {
    let cfg, ok = parse_url(url);
    guard ok else { fail(SQLCLIENT_UNABLE_TO_ESTABLISH_SQLCONNECTION, "not a postgres:// URL"); }
    open(db, cfg, ms);
}

// The common reasons a connect fails, by name; others by their number.
fn reason(code: i64) -> u8[] {
    var r: u8[>..] = [];
    if code == http::ECONNREFUSED { r.append("ECONNREFUSED"); }
    else if code == http::ETIMEDOUT { r.append("ETIMEDOUT"); }
    else if code == http::ENOENT { r.append("ENOENT"); }
    else if code == http::ENOSYS { r.append("ENOSYS (the host must be localhost or an IP address)"); }
    else { format(r, "error ", code); }
    return str(r);
}
