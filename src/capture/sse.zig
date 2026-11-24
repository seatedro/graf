const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Event = struct {
    name: []const u8,
    data: []const u8,
    id: ?[]const u8,
};

pub const Parser = struct {
    gpa: Allocator,
    name: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    id: std.ArrayList(u8) = .empty,
    has_data: bool = false,
    has_id: bool = false,
    dispatched: bool = false,
    retry_ms: ?u64 = null,

    pub fn init(gpa: Allocator) Parser {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Parser) void {
        p.name.deinit(p.gpa);
        p.data.deinit(p.gpa);
        p.id.deinit(p.gpa);
    }

    pub fn feedLine(p: *Parser, raw: []const u8) Allocator.Error!?Event {
        if (p.dispatched) p.reset();
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (!p.has_data) {
                p.reset();
                return null;
            }
            p.dispatched = true;
            return .{
                .name = if (p.name.items.len > 0) p.name.items else "message",
                .data = p.data.items,
                .id = if (p.has_id) p.id.items else null,
            };
        }
        if (line[0] == ':') return null;
        const field, var value = std.mem.cut(u8, line, ":") orelse .{ line, "" };
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, field, "event")) {
            p.name.clearRetainingCapacity();
            try p.name.appendSlice(p.gpa, value);
        } else if (std.mem.eql(u8, field, "data")) {
            if (p.has_data) try p.data.append(p.gpa, '\n');
            try p.data.appendSlice(p.gpa, value);
            p.has_data = true;
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.indexOfScalar(u8, value, 0) != null) return null;
            p.id.clearRetainingCapacity();
            try p.id.appendSlice(p.gpa, value);
            p.has_id = true;
        } else if (std.mem.eql(u8, field, "retry")) {
            p.retry_ms = std.fmt.parseInt(u64, value, 10) catch p.retry_ms;
        }
        return null;
    }

    fn reset(p: *Parser) void {
        p.name.clearRetainingCapacity();
        p.data.clearRetainingCapacity();
        p.id.clearRetainingCapacity();
        p.has_data = false;
        p.has_id = false;
        p.dispatched = false;
    }
};

const testing = std.testing;

fn feedAll(p: *Parser, text: []const u8, out: *std.ArrayList(Event), arena: Allocator) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (try p.feedLine(line)) |ev| {
        try out.append(arena, .{ .name = try arena.dupe(u8, ev.name), .data = try arena.dupe(u8, ev.data), .id = if (ev.id) |id| try arena.dupe(u8, id) else null });
    };
}

test "frames carry their event name, joined data and per-frame id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    var events: std.ArrayList(Event) = .empty;
    try feedAll(&p,
        \\event: status
        \\data: {"status":"working"}
        \\
        \\retry: 2000
        \\
        \\: keepalive comment
        \\id: 01JAAAAAAAAAAAAAAAAAAAAAAA
        \\event: transcript
        \\data: {"a":1,
        \\data:"b":2}
        \\
        \\event: heartbeat
        \\data: {}
        \\
        \\event: ignored-without-data
        \\
        \\data: plain
        \\
    , &events, arena);
    try testing.expectEqual(@as(usize, 4), events.items.len);
    try testing.expectEqualStrings("status", events.items[0].name);
    try testing.expect(events.items[0].id == null);
    try testing.expectEqual(@as(?u64, 2000), p.retry_ms);
    try testing.expectEqualStrings("transcript", events.items[1].name);
    try testing.expectEqualStrings("{\"a\":1,\n\"b\":2}", events.items[1].data);
    try testing.expectEqualStrings("01JAAAAAAAAAAAAAAAAAAAAAAA", events.items[1].id.?);
    try testing.expectEqualStrings("heartbeat", events.items[2].name);
    try testing.expect(events.items[2].id == null);
    try testing.expectEqualStrings("message", events.items[3].name);
    try testing.expectEqualStrings("plain", events.items[3].data);
}

test "carriage returns and a missing space after the colon are tolerated" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    try testing.expect(try p.feedLine("event:transcript\r") == null);
    try testing.expect(try p.feedLine("id:X\r") == null);
    try testing.expect(try p.feedLine("data:{}\r") == null);
    const ev = (try p.feedLine("\r")).?;
    try testing.expectEqualStrings("transcript", ev.name);
    try testing.expectEqualStrings("X", ev.id.?);
    try testing.expectEqualStrings("{}", ev.data);
}
