// Reading what the server sent: a row's fields by the types and formats of
// the last RowDescription, a RowDescription's names, an ErrorResponse's
// fields, and CommandComplete's tag.
namespace pg;

import std;

// Type OIDs the decoders read, from Postgres's pg_type.
let OID_BOOL: u32 = 16;
let OID_NAME: u32 = 19;
let OID_INT8: u32 = 20;
let OID_INT2: u32 = 21;
let OID_INT4: u32 = 23;
let OID_TEXT: u32 = 25;
let OID_JSON: u32 = 114;
let OID_BPCHAR: u32 = 1042;
let OID_VARCHAR: u32 = 1043;
let OID_JSONB: u32 = 3802;

// The last RowDescription's column count, and column i's type and format.
fn column_count(c: const Conn&) -> i64 { c.columns }
fn column_type(c: const Conn&, i: i64) -> u32 { c.oid[i] }
fn column_format(c: const Conn&, i: i64) -> i64 { c.format[i] }

// Whether the last RowDescription's columns have exactly these types: a check
// for COLUMNS, so that the rows after it decode without one each.
fn columns_are(c: const Conn&, types: const u32[:]) -> bool {
    guard c.columns == types.len else { return false; }
    for t, i in types { guard c.oid[i] == t else { return false; } }
    return true;
}

// The name of column i in a RowDescription's body, COLUMNS's.
fn column_name(description: const u8[:], i: i64) -> const u8[:] {
    var p = 2;
    for k in i { p = cstr_end(description, p) + 19; }
    return description[p..cstr_end(description, p)];
}

// The number of fields in the last ROW.
fn field_count(c: const Conn&) -> i64 { c.fields }

// Whether field i of the last ROW is NULL.
fn is_null(c: const Conn&, i: i64) -> bool { c.len[i] < 0 }

// Field i of row, the last ROW's body, as the server sent it; empty for NULL.
fn bytes(c: const Conn&, row: const u8[:], i: i64) -> const u8[:] {
    guard c.len[i] >= 0 else { return row[..0]; }
    return row[c.at[i]..c.at[i] + c.len[i]];
}

// Field i as an integer: an int2, int4, or int8 column, in either format. 0
// for NULL, or for text that isn't an integer.
fn int(c: const Conn&, row: const u8[:], i: i64) -> i64 {
    let v = bytes(c, row, i);
    if c.format[i] == BINARY {
        if v.len == 2 { return get16(v, 0); }
        if v.len == 4 { return get32(v, 0); }
        if v.len == 8 { return (get32(v, 0) << 32) | (get32(v, 4) & 0xffffffff); }
        return 0;
    }
    let n, ok = parse_int(v);
    return if ok { n } else { 0 };
}

// Field i as a bool column's value, in either format; false for NULL.
fn boolean(c: const Conn&, row: const u8[:], i: i64) -> bool {
    let v = bytes(c, row, i);
    guard v.len == 1 else { return false; }
    return if c.format[i] == BINARY { v[0] != 0 } else { v[0] == 't' };
}

// Field i as text: a text, varchar, bpchar, name, json, or jsonb column, in
// either format. Binary jsonb's leading version byte is dropped, so jsonb
// gives its JSON text in both. Empty for NULL.
fn text(c: const Conn&, row: const u8[:], i: i64) -> const u8[:] {
    let v = bytes(c, row, i);
    if c.format[i] == BINARY && c.oid[i] == OID_JSONB && v.len > 0 && v[0] == 1 { return v[1..]; }
    return v;
}

// The field of type code in an ErrorResponse's or NoticeResponse's body:
// 'C' the SQLSTATE code, 'M' the message, 'V' the severity, 'D' the detail.
// Empty when it has none.
fn field(body: const u8[:], code: u8) -> const u8[:] {
    var p = 0;
    while p < body.len && body[p] != 0 {
        let e = cstr_end(body, p + 1);
        if body[p] == code { return body[p + 1..e]; }
        p = e + 1;
    }
    return body[..0];
}

// The rows a command's tag counts, DONE's body: "SELECT 5" or "INSERT 0 5"
// give 5. 0 for a tag without a count.
fn rows(tag: const u8[:]) -> i64 {
    let t = tag[..cstr_end(tag, 0)];
    let space = rfind(t, " ");
    guard space >= 0 else { return 0; }
    let n, ok = parse_int(t[space + 1..]);
    return if ok { n } else { 0 };
}

// RowDescription: the columns' types and formats into c.
fn columns(c: Conn&, body: const u8[:]) -> i64 {
    guard body.len >= 2 else { return broken(c, "a RowDescription is cut short"); }
    let n = get16(body, 0);
    guard n >= 0 && n <= MAX_COLUMNS else { return broken(c, "a RowDescription has more than MAX_COLUMNS columns"); }
    var p = 2;
    for i in n {
        p = cstr_end(body, p) + 1;
        guard p + 18 <= body.len else { return broken(c, "a RowDescription is cut short"); }
        c.oid[i] = get32(body, p + 6) as! u32;
        c.format[i] = get16(body, p + 16) as! u8;
        p += 18;
    }
    c.columns = n;
    return COLUMNS;
}

// DataRow: where each field is in its body.
fn row(c: Conn&, body: const u8[:]) -> i64 {
    guard body.len >= 2 else { return broken(c, "a DataRow is cut short"); }
    let n = get16(body, 0);
    guard n >= 0 && n <= MAX_COLUMNS else { return broken(c, "a DataRow has more than MAX_COLUMNS fields"); }
    var p = 2;
    for i in n {
        guard p + 4 <= body.len else { return broken(c, "a DataRow is cut short"); }
        let len = get32(body, p);
        p += 4;
        c.at[i] = p as! i32;
        c.len[i] = len as! i32;
        if len > 0 { p += len; }
        guard p <= body.len else { return broken(c, "a DataRow is cut short"); }
    }
    c.fields = n;
    return ROW;
}

// Where the NUL-terminated string at b[p..] ends: its NUL, or b.len.
fn cstr_end(b: const u8[:], p: i64) -> i64 {
    var e = p;
    while e < b.len && b[e] != 0 { e++; }
    return e;
}
