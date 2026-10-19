// HttpArena's /async-db query against its items table, logged in with
// SCRAM-SHA-256: the rows decoded in both formats, two queries to a sync.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "../../";
import wire from "../";

fn main() {
    var io = wire::io(embed_file("../data/arena.cap"));
    wire::arena(io);
}
