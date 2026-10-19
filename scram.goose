// SCRAM-SHA-256 (RFC 5802, RFC 7677), as Postgres runs it over SASL: without
// channel binding ("n,,"), and with an empty user name, since the server takes
// the startup message's.
namespace pg;

import std;
import base64;
import hash from "github.com/kaitk/goose-hash@v0.0.4";

// The most PBKDF2 iterations a server may ask for: the client's time grows
// with the count, so a hostile server could stall it. Postgres's default is
// 4096 (scram_iterations).
let MAX_ITERATIONS = 1000000;

// Whether AuthenticationSASL's list of mechanisms has SCRAM-SHA-256.
fn offers_scram(mechanisms: const u8[:]) -> bool {
    var p = 0;
    while p < mechanisms.len && mechanisms[p] != 0 {
        let e = cstr_end(mechanisms, p);
        if mechanisms[p..e] == "SCRAM-SHA-256" { return true; }
        p = e + 1;
    }
    return false;
}

// SASLInitialResponse: the mechanism, and the client-first-message.
fn scram_first(c: Conn&, out: u8[>..]&) {
    let at = begin(out, 'p');
    cstr(out, "SCRAM-SHA-256");
    let n_at = out.len;
    put32(out, 0);
    out.append("n,,");
    client_first_bare(out, "", c.nonce);
    patch32(out, n_at, out.len - n_at - 4);
    end(out, at);
}

// SASLResponse to the server-first-message: the client-final-message, or the
// reason it can't be made.
fn scram_continue(c: Conn&, server_first: const u8[:], out: u8[>..]&) -> u8[>..] {
    var bare: u8[>..] = [];
    client_first_bare(bare, "", c.nonce);
    var final: u8[>..] = [];
    let signature, why = scram_final(final, c.password, bare, c.nonce, server_first);
    guard why.len == 0 else { return str(why); }
    c.server_signature = signature;
    let at = begin(out, 'p');
    out.append(final);
    end(out, at);
    return [];
}

// Whether the server-final-message proves the server knows the password.
fn scram_verify(c: const Conn&, server_final: const u8[:]) -> bool {
    guard server_final.len > 2 && server_final[..2] == "v=" else { return false; }
    var v: u8[>..] = [];
    guard base64::decode(v, server_final[2..]) else { return false; }
    return hash::equal(v, c.server_signature);
}

// "n=user,r=nonce"; Postgres sends an empty user.
fn client_first_bare(out: u8[>..]&, user: const u8[:], nonce: const u8[:]) {
    out.append("n=");
    out.append(user);
    out.append(",r=");
    out.append(nonce);
}

// Appends the client-final-message for server_first to out, and returns the
// ServerSignature the server-final-message must carry, with "" or the reason
// server_first can't be answered.
fn scram_final(out: u8[>..]&, password: const u8[:], bare: const u8[:], nonce: const u8[:],
               server_first: const u8[:]) -> u8[32], const u8[:] {
    var none: u8[32] = [0; 32];
    var r = server_first[..0];
    var s = server_first[..0];
    var i = server_first[..0];
    each_split(server_first, ',') {
        if it.len >= 2 && it[1] == '=' {
            if it[0] == 'r' { r = it[2..]; }
            if it[0] == 's' { s = it[2..]; }
            if it[0] == 'i' { i = it[2..]; }
        }
    };
    guard r.len > nonce.len && r[..nonce.len] == nonce else {
        return none, "the server's SCRAM nonce doesn't extend the client's";
    }
    var salt: u8[>..] = [];
    guard s.len > 0 && base64::decode(salt, s) else { return none, "the server's SCRAM salt isn't base64"; }
    let iterations, ok = parse_int(i);
    guard ok && iterations >= 1 else { return none, "the server's SCRAM iteration count is invalid"; }
    guard iterations <= MAX_ITERATIONS else { return none, "the server's SCRAM iteration count is above 1,000,000"; }

    var salted: u8[32] = [0; 32];
    hash::pbkdf2_sha256(salted, password, salt, iterations);
    let client_key = hash::hmac_sha256(salted, "Client Key");
    let stored_key = hash::sha256(client_key);
    let start = out.len;
    out.append("c=biws,r=");
    out.append(r);
    var auth: u8[>..] = [];
    auth.append(bare);
    auth.push(',');
    auth.append(server_first);
    auth.push(',');
    auth.append(out[start..]);
    let client_signature = hash::hmac_sha256(stored_key, auth);
    var proof: u8[32] = [0; 32];
    for k in 32 { proof[k] = client_key[k] ^ client_signature[k]; }
    out.append(",p=");
    base64::encode(out, proof);
    let server_key = hash::hmac_sha256(salted, "Server Key");
    return hash::hmac_sha256(server_key, auth), "";
}
