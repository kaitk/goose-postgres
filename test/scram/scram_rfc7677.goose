// SCRAM-SHA-256's client-final-message and server signature for RFC 7677
// §3's example exchange, and the server-first-messages the client refuses.
import std;
import hash from "github.com/kaitk/goose-hash@v0.0.2";
import pg from "../../";
import check from "../";

let NONCE = "rOprNGfwEbeRWgbNEkqO";
let SERVER_FIRST = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";

fn refused(label: const u8[:], server_first: const u8[:]) {
    var out: u8[>..] = [];
    let sig, why = pg::scram_final(out, "pencil", "n=user,r=rOprNGfwEbeRWgbNEkqO", NONCE, server_first);
    print(label, ": ", if why.len > 0 && out.len == 0 { why } else { "FAILED" });
    assert(why.len > 0 && out.len == 0);
}

fn main() {
    var bare: u8[>..] = [];
    pg::client_first_bare(bare, "user", NONCE);
    check::text("client-first-message-bare", bare, "n=user,r=rOprNGfwEbeRWgbNEkqO");
    var out: u8[>..] = [];
    let signature, why = pg::scram_final(out, "pencil", bare, NONCE, SERVER_FIRST);
    check::text("no error", why, "");
    check::text("client-final-message", out,
                "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=");

    var c = pg::Conn { .. };
    c.server_signature = signature;
    check::that("the server's signature verifies",
                pg::scram_verify(c, "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
    check::that("another signature doesn't",
                !pg::scram_verify(c, "v=7rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
    check::that("an error doesn't", !pg::scram_verify(c, "e=invalid-proof"));
    check::that("bad base64 doesn't", !pg::scram_verify(c, "v=****"));

    refused("a nonce that doesn't extend the client's", "r=XOprNGfwEbeRWgbNEkqO%hvY,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    refused("a nonce equal to the client's", "r=rOprNGfwEbeRWgbNEkqO,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096");
    refused("a salt that isn't base64", "r=rOprNGfwEbeRWgbNEkqO%hvY,s=W22Z*,i=4096");
    refused("no salt", "r=rOprNGfwEbeRWgbNEkqO%hvY,i=4096");
    refused("no iteration count", "r=rOprNGfwEbeRWgbNEkqO%hvY,s=W22ZaJ0SNY7soEsUEjb6gQ==");
    refused("an iteration count of 0", "r=rOprNGfwEbeRWgbNEkqO%hvY,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=0");

    check::that("SCRAM-SHA-256 offered", pg::offers_scram("SCRAM-SHA-256-PLUS\0SCRAM-SHA-256\0\0"));
    check::that("only the PLUS variant offered", !pg::offers_scram("SCRAM-SHA-256-PLUS\0\0"));
    check::that("nothing offered", !pg::offers_scram("\0"));
}
