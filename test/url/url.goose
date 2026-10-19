// postgres:// URLs: each part, the defaults, percent-decoding, an IPv6 host,
// and URLs that aren't one.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.2";
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
}
