// postgres:// URLs: each part, the defaults, percent-decoding, an IPv6 host,
// URLs that aren't one, NUL bytes, and sslmode.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";

fn show(url: const u8[:]) {
    let cfg, ok = pg::parse_url(url);
    if ok {
        print(url, " -> user \"", cfg.user, "\" password \"", cfg.password, "\" host \"", cfg.host,
              "\" port ", cfg.port, " database \"", cfg.database, "\"");
    } else {
        print(url, " -> not a URL");
    }
}

fn main() {
    show("postgres://bench:bench@localhost:5432/benchmark");
    show("postgresql://bench@db.example/app?sslmode=disable");
    show("postgres://localhost");
    show("postgres://");
    show("postgres://us%40er:p%3Ass%2Fw@[::1]:6543/d%20b");
    show("postgres://u:p:q@h/db");
    show("postgres://u@h:0/db");
    show("postgres://u@h:65536/db");
    show("postgres://u@h:x/db");
    show("postgres://u%4@h/db");
    show("postgres://u%zz@h/db");
    show("postgres://u@[::1/db");
    show("mysql://u@h/db");
    show("postgres://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@h/db");

    print("-- a NUL byte, which would end a name in the startup message");
    show("postgres://x%00options%00-c@h/db");
    show("postgres://u@h/d%00b");
    show("postgres://u:p%00w@h/db");
    let raw, raw_ok = pg::parse_url(str("postgres://u", "\0", "@h/db"));
    print("postgres://u\\0@h/db, a raw NUL -> ", if raw_ok { "a URL" } else { "not a URL" });

    print("-- sslmode: TLS isn't supported yet");
    for mode in ["disable", "allow", "prefer", "require", "verify-ca", "verify-full", "on"] {
        reason(str("postgres://u@h/db?sslmode=", mode));
    }
    reason("postgres://u@h/db?application_name=app&sslmode=prefer&connect_timeout=5");
    reason("postgres://u@h/db?sslmode=disable&sslmode=require");
    reason("postgres://u@h/db?sslmodex=require");
}

// Prints whether url can be used, and why not.
fn reason(url: const u8[:]) {
    let cfg, why = pg::url_settings(url);
    print(url, " -> ", if why.len == 0 { "ok" } else { why });
}
