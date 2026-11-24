const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

pub const Kind = enum { api_key, jwt, pem, assignment, bearer, url_credentials, high_entropy };

const marker_prefix = "[REDACTED:";

const max_passes = 4;

pub fn redact(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var current = text;
    for (0..max_passes) |_| {
        const next = try redactPass(arena, current);
        if (next.ptr == current.ptr) break;
        current = next;
    }
    return current;
}

fn redactPass(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var s: Scanner = .{ .arena = arena, .text = text };
    try scanPem(&s);
    try scanTokens(&s);
    try scanUrlCredentials(&s);
    try scanAssignments(&s);
    try scanHighEntropy(&s);
    if (s.spans.items.len == 0) return text;

    const spans = s.spans.items;
    std.mem.sort(Span, spans, {}, Span.lessThan);
    const markers = try findMarkers(arena, text);
    var out: Output = .{ .arena = arena, .text = text };
    var m: usize = 0;
    var i: usize = 0;
    while (i < spans.len) {
        const kind = spans[i].kind;
        var cur = spans[i].start;
        var end = spans[i].end;
        i += 1;
        while (i < spans.len and spans[i].start < end) : (i += 1) end = @max(end, spans[i].end);
        while (cur < end) {
            while (m < markers.len and markers[m].end <= cur) m += 1;
            if (m < markers.len and markers[m].start < end) {
                try out.replace(cur, markers[m].start, kind);
                cur = @max(cur, markers[m].end);
            } else {
                try out.replace(cur, end, kind);
                cur = end;
            }
        }
    }
    return out.finish();
}

const Output = struct {
    arena: Allocator,
    text: []const u8,
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,

    fn replace(o: *Output, start: usize, end: usize, kind: Kind) Allocator.Error!void {
        if (end <= start) return;
        if (o.buf.capacity == 0) try o.buf.ensureTotalCapacity(o.arena, o.text.len);
        try o.buf.appendSlice(o.arena, o.text[o.pos..start]);
        try o.buf.appendSlice(o.arena, marker_prefix);
        try o.buf.appendSlice(o.arena, @tagName(kind));
        try o.buf.append(o.arena, ']');
        o.pos = end;
    }

    fn finish(o: *Output) Allocator.Error![]const u8 {
        if (o.pos == 0 and o.buf.items.len == 0) return o.text;
        try o.buf.appendSlice(o.arena, o.text[o.pos..]);
        return o.buf.items;
    }
};

fn findMarkers(arena: Allocator, text: []const u8) Allocator.Error![]const Range {
    var markers: std.ArrayList(Range) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, marker_prefix)) |start| {
        const tag_start = start + marker_prefix.len;
        var e = tag_start;
        while (e < text.len and (std.ascii.isLower(text[e]) or text[e] == '_')) e += 1;
        if (e > tag_start and e < text.len and text[e] == ']') {
            try markers.append(arena, .{ .start = start, .end = e + 1 });
            i = e + 1;
        } else {
            i = tag_start;
        }
    }
    return markers.items;
}

const Span = struct {
    start: usize,
    end: usize,
    kind: Kind,

    fn lessThan(_: void, a: Span, b: Span) bool {
        if (a.start != b.start) return a.start < b.start;
        if (a.end != b.end) return a.end > b.end;
        return @backingInt(a.kind) < @backingInt(b.kind);
    }
};

const Scanner = struct {
    arena: Allocator,
    text: []const u8,
    spans: std.ArrayList(Span) = .empty,
    runs: [3]Range = @splat(.{ .start = 0, .end = 0 }),
    plain_body_end: usize = 0,

    fn bodyEnd(s: *Scanner, comptime chars: BodyChars, from: usize) usize {
        const slot = &s.runs[@backingInt(chars)];
        if (from >= slot.start and from < slot.end) return slot.end;
        const end = switch (chars) {
            .dashed => runEnd(s.text, from, isB64UrlChar),
            .word => runEnd(s.text, from, isWordChar),
            .upper => runEnd(s.text, from, isUpperAlnum),
        };
        slot.* = .{ .start = from, .end = end };
        return end;
    }

    fn add(s: *Scanner, start: usize, end: usize, kind: Kind) Allocator.Error!void {
        if (end <= start) return;
        try s.spans.append(s.arena, .{ .start = start, .end = end, .kind = kind });
    }
};

fn scanPem(s: *Scanner) Allocator.Error!void {
    const t = s.text;
    const begin = "-----BEGIN ";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, t, i, begin)) |b| {
        const label_start = b + begin.len;
        var j = label_start;
        while (j < t.len and j - label_start < 64 and isPemLabelChar(t[j])) j += 1;
        if (j == label_start or !std.mem.startsWith(u8, t[j..], "-----")) {
            i = label_start;
            continue;
        }
        const end = findPemEnd(t, j + 5, t[label_start..j]) orelse t.len;
        try s.add(b, end, .pem);
        i = end;
    }
}

fn findPemEnd(t: []const u8, from: usize, label: []const u8) ?usize {
    const end_tag = "-----END ";
    var i = from;
    while (std.mem.indexOfPos(u8, t, i, end_tag)) |e| {
        const l = e + end_tag.len;
        if (std.mem.startsWith(u8, t[l..], label) and std.mem.startsWith(u8, t[l + label.len ..], "-----"))
            return l + label.len + 5;
        i = l;
    }
    return null;
}

fn isPemLabelChar(c: u8) bool {
    return std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == ' ';
}

const BodyChars = enum { dashed, word, upper };

const KeyPrefix = struct {
    prefix: []const u8,
    body: BodyChars,
    min_body: usize,
    random_body: bool = false,
};

const key_prefixes = [_]KeyPrefix{
    .{ .prefix = "sk-ant-", .body = .dashed, .min_body = 20 },
    .{ .prefix = "sk-proj-", .body = .dashed, .min_body = 20 },
    .{ .prefix = "sk-", .body = .dashed, .min_body = 20, .random_body = true },
    .{ .prefix = "sk_live_", .body = .word, .min_body = 16 },
    .{ .prefix = "sk_test_", .body = .word, .min_body = 16 },
    .{ .prefix = "rk_live_", .body = .word, .min_body = 16 },
    .{ .prefix = "rk_test_", .body = .word, .min_body = 16 },
    .{ .prefix = "ghp_", .body = .word, .min_body = 20 },
    .{ .prefix = "gho_", .body = .word, .min_body = 20 },
    .{ .prefix = "ghu_", .body = .word, .min_body = 20 },
    .{ .prefix = "ghs_", .body = .word, .min_body = 20 },
    .{ .prefix = "ghr_", .body = .word, .min_body = 20 },
    .{ .prefix = "github_pat_", .body = .word, .min_body = 20 },
    .{ .prefix = "glpat-", .body = .dashed, .min_body = 20 },
    .{ .prefix = "xoxa-", .body = .dashed, .min_body = 10 },
    .{ .prefix = "xoxb-", .body = .dashed, .min_body = 10 },
    .{ .prefix = "xoxe-", .body = .dashed, .min_body = 10 },
    .{ .prefix = "xoxo-", .body = .dashed, .min_body = 10 },
    .{ .prefix = "xoxp-", .body = .dashed, .min_body = 10 },
    .{ .prefix = "xoxr-", .body = .dashed, .min_body = 10 },
    .{ .prefix = "xoxs-", .body = .dashed, .min_body = 10 },
    .{ .prefix = "xapp-", .body = .dashed, .min_body = 20 },
    .{ .prefix = "AKIA", .body = .upper, .min_body = 16 },
    .{ .prefix = "ASIA", .body = .upper, .min_body = 16 },
    .{ .prefix = "AIza", .body = .dashed, .min_body = 30 },
    .{ .prefix = "npm_", .body = .word, .min_body = 30 },
};

fn scanTokens(s: *Scanner) Allocator.Error!void {
    const t = s.text;
    var i: usize = 0;
    while (i < t.len) {
        if (!std.ascii.isAlphabetic(t[i]) or (i > 0 and std.ascii.isAlphanumeric(t[i - 1]))) {
            i += 1;
            continue;
        }
        if (matchApiKey(s, i)) |end| {
            try s.add(i, end, .api_key);
            i = end;
        } else if (matchJwt(s, i)) |end| {
            try s.add(i, end, .jwt);
            i = end;
        } else if (matchAuthScheme(t, i)) |tok| {
            try s.add(tok.start, tok.end, .bearer);
            i = tok.end;
        } else {
            i += 1;
        }
    }
}

fn matchApiKey(s: *Scanner, i: usize) ?usize {
    const t = s.text;
    for (key_prefixes) |p| {
        if (!std.mem.startsWith(u8, t[i..], p.prefix)) continue;
        const body_start = i + p.prefix.len;
        const end = switch (p.body) {
            inline else => |chars| s.bodyEnd(chars, body_start),
        };
        const body = t[body_start..end];
        if (body.len < p.min_body) continue;
        if (p.random_body and (end <= s.plain_body_end or !looksRandom(body))) {
            s.plain_body_end = end;
            continue;
        }
        return end;
    }
    return null;
}

fn looksRandom(body: []const u8) bool {
    var upper: usize = 0;
    var lower: usize = 0;
    for (body) |c| {
        if (std.ascii.isDigit(c)) return true;
        if (std.ascii.isUpper(c)) upper += 1;
        if (std.ascii.isLower(c)) lower += 1;
    }
    return upper >= 3 and lower >= 3;
}

fn matchJwt(s: *Scanner, i: usize) ?usize {
    const t = s.text;
    if (!std.mem.startsWith(u8, t[i..], "eyJ")) return null;
    const a = s.bodyEnd(.dashed, i);
    if (a - i < 10 or a >= t.len or t[a] != '.') return null;
    const b = s.bodyEnd(.dashed, a + 1);
    if (b - (a + 1) < 10) return null;
    if (b < t.len and t[b] == '.') return s.bodyEnd(.dashed, b + 1);
    return b;
}

const Range = struct { start: usize, end: usize };

fn matchAuthScheme(t: []const u8, i: usize) ?Range {
    const bearer = startsWithWordIgnoreCase(t[i..], "bearer");
    if (!bearer and !startsWithWordIgnoreCase(t[i..], "basic")) return null;
    const word_end = i + @as(usize, if (bearer) 6 else 5);
    const start = skipBlanks(t, word_end);
    if (start == word_end) return null;
    const end = if (bearer) runEnd(t, start, isBearerChar) else runEnd(t, start, isBase64Char);
    const tok = t[start..end];
    if (tok.len < 8) return null;
    if (tok.len >= 20 and bearer) return .{ .start = start, .end = end };
    var digit = false;
    var inner_upper = false;
    var symbol = false;
    for (tok, 0..) |c, k| {
        if (std.ascii.isDigit(c)) digit = true;
        if (k > 0 and std.ascii.isUpper(c)) inner_upper = true;
        if (c == '+' or c == '/' or c == '=' or (bearer and (c == '.' or c == '_' or c == '~'))) symbol = true;
    }
    if (!(digit or inner_upper or symbol)) return null;
    return .{ .start = start, .end = end };
}

fn startsWithWordIgnoreCase(t: []const u8, word: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(t, word)) return false;
    return t.len == word.len or !std.ascii.isAlphanumeric(t[word.len]);
}

fn scanUrlCredentials(s: *Scanner) Allocator.Error!void {
    const t = s.text;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, t, i, "://")) |p| {
        i = p + 3;
        if (p == 0 or !std.ascii.isAlphanumeric(t[p - 1])) continue;
        var end = i;
        var at: ?usize = null;
        while (end < t.len and !isAuthorityStop(t[end])) : (end += 1) {
            if (t[end] == '@') at = end;
        }
        const a = at orelse continue;
        const colon = std.mem.indexOfScalar(u8, t[i..a], ':') orelse continue;
        const start = i + colon + 1;
        if (!isPlaceholder(t[start..a])) try s.add(start, a, .url_credentials);
        i = end;
    }
}

fn isAuthorityStop(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '/', '?', '#', '"', '\'', '`', '<', '>', '\\' => true,
        else => false,
    };
}

const secret_words = [_][]const u8{
    "secret",     "token",     "password",   "passwd",      "pwd",
    "api_key",    "apikey",    "api-key",    "private_key", "privatekey",
    "access_key", "accesskey", "credential", "auth",        "passphrase",
};

const secret_segments = [_][]const u8{ "pass", "pw" };

const benign_segments = [_][]const u8{
    "type",   "types",      "count",    "counts",   "limit",   "limits",   "max",      "min",
    "len",    "length",     "size",     "usage",    "used",    "ttl",      "expiry",   "expires",
    "expire", "expiration", "name",     "names",    "url",     "uri",      "endpoint", "path",
    "file",   "dir",        "kind",     "format",   "mode",    "method",   "scheme",   "header",
    "prefix", "field",      "env",      "var",      "hint",    "label",    "id",       "ids",
    "policy", "provider",   "flow",     "grant",    "enabled", "strategy", "version",  "budget",
    "rate",   "num",        "total",    "estimate", "ratio",   "window",   "index",    "offset",
    "stream", "cost",       "required",
};

const type_words = [_][]const u8{
    "string", "str",   "bool",   "boolean", "int",       "integer",      "number", "float",
    "double", "bytes", "buffer", "any",     "unknown",   "object",       "option", "optional",
    "char",   "usize", "void",   "secret",  "secretstr", "secretstring",
};

const trivial_values = [_][]const u8{ "true", "false", "null", "none", "nil", "undefined", "yes", "no", "on", "off" };

const scheme_words = [_][]const u8{ "bearer", "basic", "token", "digest" };

fn scanAssignments(s: *Scanner) Allocator.Error!void {
    const t = s.text;
    var i: usize = 0;
    while (i < t.len) {
        if (!isKeyChar(t[i])) {
            i += 1;
            continue;
        }
        const key_start = i;
        const key_end = runEnd(t, i, isKeyChar);
        i = key_end;
        if (key_start >= 2 and t[key_start - 1] == '/' and t[key_start - 2] == '/') continue;
        if (!isSecretKey(t[key_start..key_end])) continue;
        if (try matchAssignment(s, key_start, key_end)) |resume_at| i = @max(i, resume_at);
    }
}

fn isSecretKey(raw: []const u8) bool {
    const key = std.mem.trimStart(u8, raw, "-");
    if (key.len == 0 or key.len > 96) return false;
    var buf: [96]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, key);
    if (std.mem.eql(u8, lower, "pwd") or std.mem.eql(u8, lower, "oldpwd")) return false;

    var secret = hasSecretWord(lower) or isEnvKeyName(key);
    var it: SegmentIterator = .{ .key = key };
    while (it.next()) |seg| {
        if (seg.len > 32) continue;
        var seg_buf: [32]u8 = undefined;
        const seg_lower = std.ascii.lowerString(&seg_buf, seg);
        if (inList(&benign_segments, seg_lower)) return false;
        if (inList(&secret_segments, seg_lower)) secret = true;
    }
    return secret;
}

fn hasSecretWord(lower: []const u8) bool {
    for (secret_words) |w| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, lower, from, w)) |at| {
            from = at + 1;
            const rest = lower[at + w.len ..];
            if (std.mem.eql(u8, w, "auth") and std.mem.startsWith(u8, rest, "or") and
                !std.mem.startsWith(u8, rest, "oriz") and !std.mem.startsWith(u8, rest, "oris")) continue;
            if (std.mem.eql(u8, w, "token") and (std.mem.startsWith(u8, rest, "iz") or std.mem.startsWith(u8, rest, "is"))) continue;
            return true;
        }
    }
    return false;
}

fn isEnvKeyName(key: []const u8) bool {
    if (key.len < 5 or !std.mem.endsWith(u8, key, "_KEY")) return false;
    for (key) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

const SegmentIterator = struct {
    key: []const u8,
    pos: usize = 0,

    fn next(it: *SegmentIterator) ?[]const u8 {
        const k = it.key;
        while (it.pos < k.len and !std.ascii.isAlphanumeric(k[it.pos])) it.pos += 1;
        if (it.pos >= k.len) return null;
        const start = it.pos;
        it.pos += 1;
        while (it.pos < k.len and std.ascii.isAlphanumeric(k[it.pos])) : (it.pos += 1) {
            if (std.ascii.isUpper(k[it.pos]) and std.ascii.isLower(k[it.pos - 1])) break;
        }
        return k[start..it.pos];
    }
};

const Mode = enum { tight, loose, flag };

fn matchAssignment(s: *Scanner, key_start: usize, key_end: usize) Allocator.Error!?usize {
    const t = s.text;
    var j = key_end;
    if (j < t.len and isQuote(t[j])) {
        j += 1;
    } else if (j + 1 < t.len and t[j] == '\\' and isQuote(t[j + 1])) {
        j += 2;
    }
    j = skipMarkdownBold(t, j);
    const sep = skipBlanks(t, j);
    const blank_before = sep != j;
    j = sep;
    if (j >= t.len) return null;

    var mode: Mode = .loose;
    var bare_colon = false;
    switch (t[j]) {
        '=' => {
            const next = if (j + 1 < t.len) t[j + 1] else 0;
            if (next == '=' or next == '~') return null;
            if (next == '>') {
                j += 2;
            } else {
                mode = if (blank_before) .loose else .tight;
                j += 1;
            }
        },
        ':' => {
            const next = if (j + 1 < t.len) t[j + 1] else 0;
            if (next == ':') return null;
            bare_colon = next != '=';
            j += if (next == '=') 2 else 1;
        },
        else => {
            if (t[key_start] != '-' or !blank_before) return null;
            mode = .flag;
        },
    }
    const value_at = skipMarkdownBold(t, skipBlanks(t, j));
    const glued = value_at == j;
    if (!glued and mode == .tight) mode = .loose;
    j = value_at;
    if (j >= t.len) return null;

    var vs: usize = undefined;
    var ve: usize = undefined;
    var quoted = true;
    if (isQuote(t[j])) {
        const q = t[j];
        vs = j + 1;
        ve = vs;
        while (ve < t.len and t[ve] != q and t[ve] != '\n') : (ve += 1) {
            if (t[ve] == '\\' and ve + 1 < t.len and t[ve + 1] != '\n') ve += 1;
        }
    } else if (t[j] == '\\' and j + 1 < t.len and isQuote(t[j + 1])) {
        const q = t[j + 1];
        vs = j + 2;
        ve = vs;
        while (ve < t.len and t[ve] != '\n' and !(t[ve] == '\\' and ve + 1 < t.len and t[ve + 1] == q)) ve += 1;
    } else {
        if (bare_colon and glued) return null;
        quoted = false;
        vs = j;
        ve = valueEnd(t, vs);
    }
    ve = @min(ve, t.len);
    const value = t[vs..ve];

    if (schemePrefixLen(value, quoted)) |n| {
        const tok_start = if (quoted) vs + n else skipBlanks(t, ve);
        if (!quoted and tok_start == ve) return ve;
        const tok_end = if (quoted) ve else valueEnd(t, tok_start);
        if (!isPlaceholder(t[tok_start..tok_end])) try s.add(tok_start, tok_end, .bearer);
        return tok_end;
    }

    if (isPlaceholder(value) or isTrivial(value)) return ve;
    if (value.len < 3) return ve;
    if (!quoted and mode != .tight) {
        if (mode == .flag and value[0] == '-') return ve;
        if (looksLikeCode(t, vs, ve)) return ve;
        if (!looksSecretish(value)) return ve;
    }
    try s.add(vs, ve, .assignment);
    return ve;
}

fn skipMarkdownBold(t: []const u8, from: usize) usize {
    var j = from;
    while (j < t.len and j - from < 2 and t[j] == '*') j += 1;
    return j;
}

fn valueEnd(t: []const u8, from: usize) usize {
    var e = from;
    while (e < t.len) : (e += 1) {
        switch (t[e]) {
            ' ', '\t', '\n', '\r', '"', '\'', '`', ',', ';', '&', '(', ')', '<', '>', '{', '}', '[', ']', '|' => return e,
            '\\' => if (e + 1 < t.len) switch (t[e + 1]) {
                'n', 'r', 't', '"', '\'', '\\' => return e,
                else => {},
            },
            else => {},
        }
    }
    return e;
}

fn schemePrefixLen(value: []const u8, quoted: bool) ?usize {
    for (scheme_words) |w| {
        if (!std.ascii.startsWithIgnoreCase(value, w)) continue;
        if (!quoted) return if (value.len == w.len) w.len else null;
        if (value.len > w.len and (value[w.len] == ' ' or value[w.len] == '\t')) return skipBlanks(value, w.len);
    }
    return null;
}

fn isPlaceholder(v: []const u8) bool {
    if (v.len == 0) return true;
    if (std.mem.startsWith(u8, v, marker_prefix)) return true;
    if (v[0] == '$') return true;
    if (std.mem.startsWith(u8, v, "{{")) return true;
    if (v.len >= 2 and v[0] == '<' and v[v.len - 1] == '>') return true;
    if (v.len >= 2 and v[0] == '%' and v[v.len - 1] == '%') return true;
    for (v) |c| switch (c) {
        '*', 'x', 'X', '.', '-', '#' => {},
        else => return false,
    };
    return true;
}

fn isTrivial(v: []const u8) bool {
    if (v.len <= 9) {
        var buf: [9]u8 = undefined;
        if (inList(&trivial_values, std.ascii.lowerString(&buf, v))) return true;
    }
    if (std.mem.indexOf(u8, v, "://") != null or std.mem.startsWith(u8, v, "//")) return true;
    var digit = false;
    for (v) |c| switch (c) {
        '0'...'9' => digit = true,
        '.', ',', '_', '+', '-' => {},
        else => return false,
    };
    return digit;
}

fn looksLikeCode(t: []const u8, vs: usize, ve: usize) bool {
    const v = t[vs..ve];
    switch (v[0]) {
        '&', '*', '?', '!' => return true,
        else => {},
    }
    if (ve < t.len and (t[ve] == '(' or t[ve] == '[' or t[ve] == '<')) return true;
    var dotted = false;
    for (v) |c| {
        if (c == '.') {
            dotted = true;
        } else if (!(std.ascii.isAlphabetic(c) or c == '_' or c == '$')) return false;
    }
    if (dotted) return true;
    if (v.len <= 96) {
        var name_buf: [96]u8 = undefined;
        if (hasSecretWord(std.ascii.lowerString(&name_buf, v))) return true;
    }
    if (v.len <= 12) {
        var buf: [12]u8 = undefined;
        if (inList(&type_words, std.ascii.lowerString(&buf, v))) return true;
    }
    const after = skipBlanks(t, ve);
    if (after < t.len) switch (t[after]) {
        ',', ';', ')', '=', '|', '{', '}' => return true,
        else => {},
    };
    return false;
}

fn looksSecretish(v: []const u8) bool {
    if (v.len >= 8) return true;
    if (v.len < 4) return false;
    var upper = false;
    var lower = false;
    for (v) |c| {
        if (std.ascii.isDigit(c)) return true;
        if (std.ascii.isUpper(c)) upper = true;
        if (std.ascii.isLower(c)) lower = true;
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return true;
    }
    return upper and lower;
}

fn scanHighEntropy(s: *Scanner) Allocator.Error!void {
    const t = s.text;
    var i: usize = 0;
    while (i < t.len) {
        if (!isEntropyChar(t[i])) {
            i += 1;
            continue;
        }
        var end = runEnd(t, i, isEntropyChar);
        var pad: usize = 0;
        while (end + pad < t.len and pad < 2 and t[end + pad] == '=') pad += 1;
        if (end + pad >= t.len or !isEntropyChar(t[end + pad])) end += pad;
        if (end - i >= 32) try checkRun(s, i, end);
        i = end;
    }
}

fn checkRun(s: *Scanner, start: usize, end: usize) Allocator.Error!void {
    const run = s.text[start..end];
    if (isPathLike(run)) return checkPieces(s, start, end, "/", true);
    if (isHighEntropy(run)) return s.add(start, end, .high_entropy);
    try checkPieces(s, start, end, "/-_+", false);
}

fn checkPieces(s: *Scanner, start: usize, end: usize, comptime seps: []const u8, deeper: bool) Allocator.Error!void {
    var seg = start;
    var k = start;
    while (k <= end) : (k += 1) {
        if (k < end and std.mem.indexOfScalar(u8, seps, s.text[k]) == null) continue;
        if (k - seg >= 32) {
            if (isHighEntropy(s.text[seg..k])) {
                try s.add(seg, k, .high_entropy);
            } else if (deeper) {
                try checkPieces(s, seg, k, "-_+", false);
            }
        }
        seg = k + 1;
    }
}

fn isPathLike(run: []const u8) bool {
    if (std.mem.indexOfScalar(u8, run, '/') == null) return false;
    var wordy: usize = 0;
    var segments: usize = 0;
    var it = std.mem.tokenizeScalar(u8, run, '/');
    while (it.next()) |seg| {
        segments += 1;
        if (seg.len >= 3 and isPlainWord(seg)) wordy += 1;
    }
    return wordy >= 2 and wordy * 2 >= segments;
}

fn isPlainWord(seg: []const u8) bool {
    var vowel = false;
    for (seg) |c| switch (c) {
        'a', 'e', 'i', 'o', 'u', 'y' => vowel = true,
        'b'...'d', 'f'...'h', 'j'...'n', 'p'...'t', 'v'...'x', 'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return vowel;
}

fn isHighEntropy(run: []const u8) bool {
    const v = std.mem.trimEnd(u8, run, "=");
    if (isUuid(v)) return false;
    const hex = if (std.mem.startsWith(u8, v, "0x")) v[2..] else v;
    var hex_digit = false;
    var hex_alpha = false;
    var all_hex = true;
    for (hex) |c| {
        if (std.ascii.isDigit(c)) {
            hex_digit = true;
        } else if ((c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
            hex_alpha = true;
        } else {
            all_hex = false;
            break;
        }
    }
    if (all_hex) return hex.len >= 32 and hex_digit and hex_alpha and entropy(hex) >= 2.5;

    if (v.len < 32) return false;
    var upper: usize = 0;
    var lower: usize = 0;
    var digit: usize = 0;
    var seps: usize = 0;
    var islands: usize = 0;
    for (v, 0..) |c, k| {
        if (std.ascii.isUpper(c)) upper += 1;
        if (std.ascii.isLower(c)) lower += 1;
        if (std.ascii.isDigit(c)) {
            digit += 1;
            if (k == 0 or !std.ascii.isDigit(v[k - 1])) islands += 1;
        }
        if (c == '-' or c == '_' or c == '/') seps += 1;
    }
    const classes = @as(u8, @intFromBool(upper > 0)) + @intFromBool(lower > 0) + @intFromBool(digit > 0);
    if (classes < 2) return false;
    const cap = std.math.log2(@as(f64, @floatFromInt(@min(v.len, 64))));
    if (entropy(v) < 0.72 * cap) return false;
    if (wordiness(v) * 10 < v.len * 4) return true;
    return islands >= 4 and seps <= 2;
}

fn isUuid(v: []const u8) bool {
    if (v.len != 36) return false;
    for (v, 0..) |c, k| {
        const dash = k == 8 or k == 13 or k == 18 or k == 23;
        if (dash != (c == '-')) return false;
        if (!dash and !std.ascii.isHex(c)) return false;
    }
    return true;
}

fn entropy(v: []const u8) f64 {
    var counts: [256]u32 = @splat(0);
    for (v) |c| counts[c] += 1;
    const n: f64 = @floatFromInt(v.len);
    var h: f64 = 0;
    for (counts) |count| {
        if (count == 0) continue;
        const p = @as(f64, @floatFromInt(count)) / n;
        h -= p * std.math.log2(p);
    }
    return h;
}

fn wordiness(v: []const u8) usize {
    var total: usize = 0;
    var k: usize = 0;
    while (k < v.len) {
        if (!std.ascii.isLower(v[k])) {
            k += 1;
            continue;
        }
        const start = k;
        var vowel = false;
        while (k < v.len and std.ascii.isLower(v[k])) : (k += 1) {
            switch (v[k]) {
                'a', 'e', 'i', 'o', 'u', 'y' => vowel = true,
                else => {},
            }
        }
        if (k - start >= 3 and vowel) {
            total += k - start;
            if (start > 0 and std.ascii.isUpper(v[start - 1])) total += 1;
        }
    }
    return total;
}

fn runEnd(t: []const u8, from: usize, comptime pred: fn (u8) bool) usize {
    var e = from;
    while (e < t.len and pred(t[e])) e += 1;
    return e;
}

fn skipBlanks(t: []const u8, from: usize) usize {
    var e = from;
    while (e < t.len and (t[e] == ' ' or t[e] == '\t')) e += 1;
    return e;
}

fn inList(list: []const []const u8, v: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, v)) return true;
    return false;
}

fn isQuote(c: u8) bool {
    return c == '"' or c == '\'' or c == '`';
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isB64UrlChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn isUpperAlnum(c: u8) bool {
    return std.ascii.isUpper(c) or std.ascii.isDigit(c);
}

fn isBase64Char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=';
}

fn isBearerChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '-', '.', '_', '~', '+', '/', '=' => true,
        else => false,
    };
}

fn isEntropyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '_' or c == '-';
}

pub fn redactBody(arena: Allocator, body: types.EntryBody) Allocator.Error!types.EntryBody {
    const turns = try arena.alloc(types.Turn, body.turns.len);
    for (body.turns, turns) |src, *dst| {
        const calls = try arena.alloc(types.ToolCall, src.tool_calls.len);
        for (src.tool_calls, calls) |call, *out| out.* = .{
            .name = try redact(arena, call.name),
            .args_preview = try redact(arena, call.args_preview),
            .result_preview = try redact(arena, call.result_preview),
        };
        dst.* = .{ .role = src.role, .text = try redact(arena, src.text), .tool_calls = calls, .ts = src.ts };
    }
    return .{ .turns = turns, .text = if (body.text) |text| try redact(arena, text) else null };
}

pub fn redactDraft(arena: Allocator, draft: types.EntryDraft) Allocator.Error!types.EntryDraft {
    var out = draft;
    out.body = try redactBody(arena, draft.body);
    return out;
}

test "redactDraft clears every string in the body and is stable on redacted input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const secret = try std.mem.concat(arena, u8, &.{ "gh" ++ "p_", "a1B2c3D4e5F6g7H8", "i9J0k1L2m3N4o5P6q7R8" });
    const note = try std.fmt.allocPrint(arena, "remember GITHUB_TOKEN={s}", .{secret});
    const turns = [_]types.Turn{.{
        .role = .assistant,
        .text = note,
        .tool_calls = &.{.{ .name = "Bash", .args_preview = secret, .result_preview = note }},
    }};
    const draft: types.EntryDraft = .{ .kind = .turns, .author = .agent, .body = .{ .turns = &turns, .text = note }, .reference_time = 0 };
    const once = try redactDraft(arena, draft);
    const json = try std.json.Stringify.valueAlloc(arena, once.body, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "a1B2c3D4e5F6g7H8") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[REDACTED:") != null);
    const twice = try redactDraft(arena, once);
    try std.testing.expectEqualStrings(json, try std.json.Stringify.valueAlloc(arena, twice.body, .{}));
}

test {
    _ = @import("redact_test.zig");
}
