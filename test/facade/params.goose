// A parameter list as Bind writes it: each kind's bytes, and a count past
// 32767, which Bind's 16-bit field holds unsigned, up to Postgres's 65535.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import check from "../";

fn main() {
    var p = pg::Params { .. };
    pg::param(p, "ab");
    pg::param(p, -12);
    pg::param(p, false);
    pg::param(p, pg::NULL);
    check::eq("count", p.count, 4);
    check::bytes("bytes", p.bytes, "\0\0\0\x02ab\0\0\0\x03-12\0\0\0\x01f\xff\xff\xff\xff");

    var out: u8[>..] = [];
    let b = pg::bind(out, "s");
    pg::param(out, b, 7);
    pg::param(out, b, p);
    check::eq("parameters in the Bind", pg::get16(out, b.count_at), 5);

    var many = pg::Params { .. };
    for k in 40000 { pg::param(many, k); }
    var big: u8[>..] = [];
    let m = pg::bind(big, "");
    pg::param(big, m, many);
    check::eq("40000 parameters, unsigned", (big[m.count_at] as i64) << 8 | big[m.count_at + 1], 40000);
    for k in 65535 - 40000 { pg::param(many, k); }
    check::eq("the most Postgres takes", many.count, 65535);
}
