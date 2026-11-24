const std = @import("std");

// Mirrors the alias normalizer ingestion stores entity_alias.norm with; swap to core's copy once it lands.
pub fn norm(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, s.len);
    var gap = false;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c >= 0x80) {
            if (gap and out.items.len > 0) out.appendAssumeCapacity(' ');
            gap = false;
            out.appendAssumeCapacity(std.ascii.toLower(c));
        } else gap = true;
    }
    return out.items;
}

test "norm folds case, punctuation and whitespace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("pg zig", try norm(a, "pg.zig"));
    try std.testing.expectEqualStrings("pg zig copy support", try norm(a, "  PG-Zig   COPY support?! "));
    try std.testing.expectEqualStrings("", try norm(a, " .,; "));
}
