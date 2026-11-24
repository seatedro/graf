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

test "norm folds case and punctuation" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("pg zig", normInto(&buf, "pg.zig"));
    try std.testing.expectEqualStrings("pg zig", normInto(&buf, "  PG-Zig "));
    try std.testing.expectEqualStrings("brackwater s gateway v2", normInto(&buf, "Brackwater's gateway (v2)"));
    try std.testing.expectEqualStrings("", normInto(&buf, "--"));
    try std.testing.expectEqualStrings("caf\xc3\xa9", normInto(&buf, "Caf\xc3\xa9"));
}
