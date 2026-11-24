const std = @import("std");
const Allocator = std.mem.Allocator;

pub const head_len_max: usize = 256;

pub const Cursor = struct {
    v: u8 = 1,
    offset: u64 = 0,
    seq: i32 = 0,
    inode: []const u8 = "",
    head: []const u8 = "",
    head_len: u64 = 0,

    pub fn encode(c: Cursor, arena: Allocator) Allocator.Error![]const u8 {
        return std.json.Stringify.valueAlloc(arena, c, .{});
    }

    pub fn decode(arena: Allocator, text: []const u8) ?Cursor {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10)) |offset| return .{ .offset = offset } else |_| {}
        return std.json.parseFromSliceLeaky(Cursor, arena, text, .{ .ignore_unknown_fields = true }) catch null;
    }
};

pub fn fingerprint(arena: Allocator, prefix: []const u8) Allocator.Error![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(prefix, &hash, .{});
    return std.fmt.allocPrint(arena, "{x}", .{hash[0..8]});
}

test "cursor round trip and legacy offsets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c: Cursor = .{ .offset = 4096, .seq = 7, .inode = "123", .head = try fingerprint(arena, "{\"type\":\"session\"}"), .head_len = 18 };
    const back = Cursor.decode(arena, try c.encode(arena)).?;

    try std.testing.expectEqual(@as(u64, 4096), back.offset);
    try std.testing.expectEqual(@as(i32, 7), back.seq);
    try std.testing.expectEqualStrings(c.head, back.head);
    try std.testing.expectEqual(@as(u64, 99), Cursor.decode(arena, "99").?.offset);
    try std.testing.expect(Cursor.decode(arena, "garbage") == null);
}
