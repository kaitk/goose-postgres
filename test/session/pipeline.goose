// Each decoded type in both formats, parameters of each kind, and the
// outcomes a pipeline's entries can have: an error and the entries skipped
// after it, recovery at the next sync, a failed parse, an empty query, a
// command's count, a row limit, a notice, and the transaction status.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "../../";
import wire from "../";

let TYPES = """
    SELECT 1::int2 AS i2, (-32768)::int2 AS i2min, (-2147483648)::int4 AS i4min,
           2147483647::int4 AS i4max, (-9223372036854775808)::int8 AS i8min,
           9223372036854775807::int8 AS i8max, true AS t, false AS f,
           'text, with ünicode'::text AS txt, 'var'::varchar(10) AS vc,
           '{"b": [1, 2], "a": "x"}'::jsonb AS jb, '{"b": [1, 2], "a": "x"}'::json AS js,
           NULL::int4 AS n, ''::text AS empty
    """;

fn main() {
    var io = wire::io(embed_file("../data/pipeline.cap"));
    var c = pg::Conn { .. };
    var input: u8[>..] = [];
    var out: u8[>..] = [];
    pg::start(c, out, wire::config(), wire::NONCE);
    wire::until_ready(io, c, input, out);
    guard pg::ready(c);

    print("-- types, binary then text, on the unnamed statement");
    pg::parse(c, out, "", TYPES);
    pg::execute(c, out, pg::bind(out, ""), pg::BINARY);
    pg::execute(c, out, pg::bind(out, ""), pg::TEXT);
    print("-- parameters: integers, a bool, text, and NULL");
    pg::parse(c, out, "params", "SELECT $1::int4 + $2::int8 AS sum, NOT $3::bool AS nb, $4::text || '!' AS s, $5::text IS NULL AS isnull");
    let b = pg::bind(out, "params");
    pg::param(out, b, 2);
    pg::param(out, b, -9000000000);
    pg::param(out, b, false);
    pg::param(out, b, "hi");
    pg::param_null(out, b);
    pg::execute(c, out, b, pg::BINARY);
    pg::sync(c, out);
    wire::until_ready(io, c, input, out);

    print("-- an error, then a query the server skips");
    pg::parse(c, out, "div", "SELECT 10 / $1::int4 AS q");
    let z = pg::bind(out, "div");
    pg::param(out, z, 0);
    pg::execute(c, out, z);
    let one = pg::bind(out, "div");
    pg::param(out, one, 1);
    pg::execute(c, out, one);
    pg::sync(c, out);
    wire::until_ready(io, c, input, out);
    print("-- the next sync goes on");
    let two = pg::bind(out, "div");
    pg::param(out, two, 2);
    pg::execute(c, out, two);
    pg::sync(c, out);
    wire::until_ready(io, c, input, out);

    print("-- a parse that fails, and a query on it");
    pg::parse(c, out, "bad", "SELEC 1");
    pg::execute(c, out, pg::bind(out, "bad"));
    pg::sync(c, out);
    wire::until_ready(io, c, input, out);

    print("-- an empty query, a command's count, a row limit, and a notice");
    pg::parse(c, out, "", "");
    pg::execute(c, out, pg::bind(out, ""));
    pg::parse(c, out, "", "CREATE TEMP TABLE t (n int)");
    pg::execute(c, out, pg::bind(out, ""));
    pg::parse(c, out, "", "INSERT INTO t SELECT generate_series(1, 3)");
    pg::execute(c, out, pg::bind(out, ""));
    pg::parse(c, out, "", "SELECT n FROM t ORDER BY n");
    pg::execute(c, out, pg::bind(out, ""), pg::BINARY, 2);
    pg::parse(c, out, "", "DO $$ BEGIN RAISE NOTICE 'hello'; END $$");
    pg::execute(c, out, pg::bind(out, ""));
    pg::sync(c, out);
    wire::until_ready(io, c, input, out);

    print("-- the transaction status");
    pg::parse(c, out, "", "BEGIN");
    pg::execute(c, out, pg::bind(out, ""));
    pg::sync(c, out);
    wire::until_ready(io, c, input, out);
    pg::parse(c, out, "", "ROLLBACK");
    pg::execute(c, out, pg::bind(out, ""));
    pg::sync(c, out);
    wire::until_ready(io, c, input, out);

    pg::terminate(out);
    wire::send(io, out);
    print("replayed the whole capture: ", wire::finished(io));
}
