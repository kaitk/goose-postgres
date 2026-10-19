// Connection settings, and reading them from a postgres:// URL.
namespace pg;

import std;

// Where to connect and as whom. The host and port are for the caller's
// socket; the rest go into the startup message and authentication. A server
// that asks for the password in cleartext is refused unless allow_cleartext
// is set: without TLS, anyone on the path could read it. The password stays
// in Config for as long as the caller keeps it.
struct Config {
    host: u8[..255],
    port: i64 = 5432,
    user: u8[..63],
    password: u8[..255],
    database: u8[..63],
    allow_cleartext: bool = false,
}

// The settings in a URL of the form
// postgres://user:password@host:port/database?sslmode=mode (or
// postgresql://), with each part but the host percent-decoded. The host
// defaults to localhost, the port to 5432, and the database to the user's
// name. sslmode may be disable, allow, or prefer, which all connect without
// TLS; require, verify-ca, and verify-full, which need TLS, give false, as
// does any other mode. The query string's other parameters are ignored.
// false for a URL that isn't one, or a part longer than Config holds.
fn parse_url(url: const u8[:]) -> Config, bool {
    let cfg, why = url_settings(url);
    return cfg, why.len == 0;
}

// parse_url's settings, with "" or why the URL can't be used.
fn url_settings(url: const u8[:]) -> Config, const u8[:] {
    var cfg = Config { .. };
    let not_url = "not a postgres:// URL";
    var rest = url[..0];
    if starts_with(url, "postgres://") { rest = url[11..]; }
    else if starts_with(url, "postgresql://") { rest = url[13..]; }
    else { return cfg, not_url; }
    let q = find(rest, "?");
    if q >= 0 {
        let why = sslmode(rest[q + 1..]);
        guard why.len == 0 else { return cfg, why; }
        rest = rest[..q];
    }
    let slash = find(rest, "/");
    let authority = if slash >= 0 { rest[..slash] } else { rest };
    let path = if slash >= 0 { rest[slash + 1..] } else { rest[..0] };
    let at = rfind(authority, "@");
    var hostport = authority;
    if at >= 0 {
        let info = authority[..at];
        hostport = authority[at + 1..];
        let colon = find(info, ":");
        let user = if colon >= 0 { info[..colon] } else { info };
        guard decode_into(cfg.user, user, 63) else { return cfg, not_url; }
        if colon >= 0 {
            guard decode_into(cfg.password, info[colon + 1..], 255) else { return cfg, not_url; }
        }
    }
    guard decode_into(cfg.database, path, 63) else { return cfg, not_url; }
    var host = hostport;
    if hostport.len > 0 && hostport[0] == '[' {
        let close = find(hostport, "]");
        guard close > 0 else { return cfg, not_url; }
        host = hostport[1..close];
        let after = hostport[close + 1..];
        if after.len > 0 {
            guard after[0] == ':' else { return cfg, not_url; }
            let port, ok = parse_int(after[1..]);
            guard ok && port > 0 && port < 65536 else { return cfg, not_url; }
            cfg.port = port;
        }
    } else {
        let colon = rfind(hostport, ":");
        if colon >= 0 {
            host = hostport[..colon];
            let port, ok = parse_int(hostport[colon + 1..]);
            guard ok && port > 0 && port < 65536 else { return cfg, not_url; }
            cfg.port = port;
        }
    }
    guard host.len <= 255 else { return cfg, not_url; }
    cfg.host.append(if host.len > 0 { host } else { "localhost" });
    return cfg, "";
}

// "" when the query string's sslmode, the last one given, connects without
// TLS, or it has none; else why the URL can't be used.
fn sslmode(query: const u8[:]) -> const u8[:] {
    var mode = query[..0];
    each_split(query, '&') {
        if starts_with(it, "sslmode=") { mode = it[8..]; }
    };
    if mode.len == 0 || mode == "disable" || mode == "allow" || mode == "prefer" { return ""; }
    if mode == "require" || mode == "verify-ca" || mode == "verify-full" {
        return "the URL's sslmode needs TLS, which goose-postgres doesn't support yet";
    }
    return "the URL's sslmode isn't disable, allow, prefer, require, verify-ca, or verify-full";
}

// Percent-decodes s into out, which holds at most cap bytes: false for a
// malformed escape, a NUL byte, which would end the name in the startup
// message, or too many bytes.
fn decode_into<B>(out: B&, s: const u8[:], cap: i64) -> bool {
    var i = 0;
    while i < s.len {
        guard out.len < cap && s[i] != 0 else { return false; }
        if s[i] == '%' {
            guard i + 2 < s.len else { return false; }
            let hi = hex_digit(s[i + 1]);
            let lo = hex_digit(s[i + 2]);
            guard hi >= 0 && lo >= 0 && hi + lo > 0 else { return false; }
            out.push((hi * 16 + lo) as! u8);
            i += 3;
        } else {
            out.push(s[i]);
            i++;
        }
    }
    return true;
}

fn hex_digit(b: u8) -> i64 {
    if b >= '0' && b <= '9' { return b - '0'; }
    if b >= 'a' && b <= 'f' { return b - 'a' + 10; }
    if b >= 'A' && b <= 'F' { return b - 'A' + 10; }
    return -1;
}
