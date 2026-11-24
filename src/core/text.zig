const std = @import("std");

pub fn normInto(out: []u8, s: []const u8) []u8 {
    var n: usize = 0;
    var pending_space = false;

    for (s) |c| {
        const keep = c >= 0x80 or std.ascii.isAlphanumeric(c);
        if (!keep) {
            pending_space = n > 0;
            continue;
        }

        if (pending_space) {
            out[n] = ' ';
            n += 1;
            pending_space = false;
        }
        out[n] = std.ascii.toLower(c);
        n += 1;
    }

    return out[0..n];
}

pub fn norm(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    const buf = try allocator.alloc(u8, s.len);
    const used = normInto(buf, s);
    if (allocator.resize(buf, used.len)) return buf[0..used.len];
    return used;
}

pub fn sanitize(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, 0) == null and std.unicode.utf8ValidateSlice(s)) return s;

    var out: std.ArrayList(u8) = try .initCapacity(allocator, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0) {
            i += 1;
            continue;
        }

        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..n])) {
            try out.appendSlice(allocator, s[i..][0..n]);
            i += n;
        } else {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
        }
    }

    return out.items;
}

test "norm folds case and punctuation" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("pg zig", normInto(&buf, "pg.zig"));
    try std.testing.expectEqualStrings("pg zig", normInto(&buf, "  PG-Zig "));
    try std.testing.expectEqualStrings("brackwater s gateway v2", normInto(&buf, "Brackwater's gateway (v2)"));
    try std.testing.expectEqualStrings("", normInto(&buf, "--"));
    try std.testing.expectEqualStrings("caf\xc3\xa9", normInto(&buf, "Caf\xc3\xa9"));
}

test "sanitize drops NUL bytes and replaces invalid UTF-8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const clean = "caf\xc3\xa9 \xf0\x9f\xa6\x92\ttab";
    try std.testing.expectEqual(clean.ptr, (try sanitize(arena, clean)).ptr);

    try std.testing.expectEqualStrings("ab", try sanitize(arena, "a\x00b\x00"));
    try std.testing.expectEqualStrings("caf\xc3\xa9", try sanitize(arena, "\x00caf\x00\xc3\xa9"));
    try std.testing.expectEqualStrings("x\u{FFFD}y", try sanitize(arena, "x\xffy"));
    try std.testing.expectEqualStrings("end\u{FFFD}", try sanitize(arena, "end\xc3"));
    try std.testing.expectEqualStrings("\u{FFFD}\u{FFFD}", try sanitize(arena, "\xc0\xaf"));
    try std.testing.expectEqualStrings("\u{FFFD}\u{FFFD}\u{FFFD}", try sanitize(arena, "\xed\xa0\x80"));
}
