// arena's capture, with the server's bytes handed over one at a time, so that
// every message arrives cut at every point.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.3";
import pg from "../../";
import wire from "../";

fn main() {
    var io = wire::io(embed_file("../data/arena.cap"), 1);
    guard !io.live else { return; }
    wire::arena(io);
}
