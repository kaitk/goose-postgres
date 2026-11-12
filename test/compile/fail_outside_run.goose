// pg::fail outside pg::run, or a transaction, doesn't compile.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";

fn main() {
    pg::fail("out of stock");
}
// error: return from run: no enclosing call of run on this compile-time call path
