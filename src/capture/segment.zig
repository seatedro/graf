const std = @import("std");
const core = @import("core");
const dialect = @import("dialect.zig");
const normalize = @import("normalize.zig");
const Allocator = std.mem.Allocator;
const Item = dialect.Item;

pub const Trigger = enum { tokens, idle, hook, gap };

pub const Options = struct {
    max_tokens: usize = 3000,
    idle: core.Micros = 120 * std.time.us_per_s,
    gap: core.Micros = 5 * std.time.us_per_min,
};

pub const Window = struct {
    items: []const Item,
    trigger: Trigger,
};

pub const Segmenter = struct {
    options: Options = .{},
    items: std.ArrayList(Item) = .empty,
    tokens: usize = 0,
    last_ts: ?core.Micros = null,

    pub fn push(s: *Segmenter, arena: Allocator, item: Item, sealed: *std.ArrayList(Window)) Allocator.Error!void {
        if (s.items.items.len > 0) if (item.turn.ts) |ts| if (s.last_ts) |last| {
            const gap = ts - last;
            if (item.turn.role == .user and gap >= s.options.gap) {
                try s.seal(arena, .gap, sealed);
            } else if (gap >= s.options.idle) {
                try s.seal(arena, .idle, sealed);
            }
        };

        try s.items.append(arena, item);
        s.tokens += normalize.estimateTokens(item.turn);
        if (item.turn.ts) |ts| s.last_ts = if (s.last_ts) |last| @max(last, ts) else ts;
        if (s.tokens >= s.options.max_tokens) try s.seal(arena, .tokens, sealed);
    }

    pub fn tick(s: *Segmenter, arena: Allocator, now: core.Micros, sealed: *std.ArrayList(Window)) Allocator.Error!void {
        if (s.items.items.len == 0) return;
        const last = s.last_ts orelse return;
        if (now - last >= s.options.idle) try s.seal(arena, .idle, sealed);
    }

    pub fn hook(s: *Segmenter, arena: Allocator, sealed: *std.ArrayList(Window)) Allocator.Error!void {
        var user = false;
        var agent = false;
        for (s.items.items) |item| switch (item.turn.role) {
            .user => user = true,
            .assistant, .tool => agent = true,
            .system => {},
        };

        if (user and agent) try s.seal(arena, .hook, sealed);
    }

    pub fn firstStart(s: *const Segmenter) ?u64 {
        return if (s.items.items.len > 0) s.items.items[0].start else null;
    }

    pub fn isEmpty(s: *const Segmenter) bool {
        return s.items.items.len == 0;
    }

    pub fn rehome(s: *Segmenter, arena: Allocator) Allocator.Error!void {
        var fresh: std.ArrayList(Item) = .empty;
        try fresh.ensureTotalCapacity(arena, s.items.items.len);
        for (s.items.items) |item| fresh.appendAssumeCapacity(.{ .turn = try normalize.dupeTurn(arena, item.turn), .start = item.start });
        s.items = fresh;
    }

    pub fn clear(s: *Segmenter) void {
        s.items = .empty;
        s.tokens = 0;
        s.last_ts = null;
    }

    fn seal(s: *Segmenter, arena: Allocator, trigger: Trigger, sealed: *std.ArrayList(Window)) Allocator.Error!void {
        if (s.items.items.len == 0) return;
        try sealed.append(arena, .{ .items = try arena.dupe(Item, s.items.items), .trigger = trigger });
        s.items = .empty;
        s.tokens = 0;
    }
};

pub fn authorOf(turns: []const core.Turn) core.types.Author {
    var user = false;
    var agent = false;
    var tool = false;
    for (turns) |t| switch (t.role) {
        .user => user = true,
        .assistant => agent = true,
        .tool => tool = true,
        .system => {},
    };

    if (user and (agent or tool)) return .mixed;
    if (user) return .user;
    if (agent) return .agent;
    return .tool;
}

pub fn turnsOf(arena: Allocator, window: Window) Allocator.Error![]const core.Turn {
    const turns = try arena.alloc(core.Turn, window.items.len);
    for (window.items, turns) |item, *t| t.* = item.turn;
    return turns;
}

pub fn canonicalBody(arena: Allocator, body: core.EntryBody) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, body, .{});
}

pub fn contentHash(arena: Allocator, body: core.EntryBody) Allocator.Error![32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try canonicalBody(arena, body), &out, .{});
    return out;
}

const testing = std.testing;

fn mk(role: core.types.Role, text: []const u8, ts: core.Micros, start: u64) Item {
    return .{ .turn = .{ .role = role, .text = text, .ts = ts }, .start = start };
}

test "token trigger seals the window that crosses the budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s: Segmenter = .{ .options = .{ .max_tokens = 10 } };
    var sealed: std.ArrayList(Window) = .empty;

    try s.push(arena, mk(.user, "short", 0, 0), &sealed);
    try testing.expectEqual(@as(usize, 0), sealed.items.len);

    try s.push(arena, mk(.assistant, "a reply long enough to cross the budget", 1, 10), &sealed);
    try testing.expectEqual(@as(usize, 1), sealed.items.len);
    try testing.expectEqual(Trigger.tokens, sealed.items[0].trigger);
    try testing.expectEqual(@as(usize, 2), sealed.items[0].items.len);
    try testing.expect(s.isEmpty());
}

test "idle and gap triggers come from turn timestamps" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sec = std.time.us_per_s;
    var s: Segmenter = .{};
    var sealed: std.ArrayList(Window) = .empty;

    try s.push(arena, mk(.user, "q1", 0, 0), &sealed);
    try s.push(arena, mk(.assistant, "a1", 10 * sec, 10), &sealed);
    try s.push(arena, mk(.assistant, "a2", 140 * sec, 20), &sealed);
    try testing.expectEqual(Trigger.idle, sealed.items[0].trigger);
    try testing.expectEqual(@as(?u64, 20), s.firstStart());

    try s.push(arena, mk(.user, "q2", 140 * sec + 6 * 60 * sec, 30), &sealed);
    try testing.expectEqual(Trigger.gap, sealed.items[1].trigger);

    try s.tick(arena, 140 * sec + 6 * 60 * sec + 119 * sec, &sealed);
    try testing.expectEqual(@as(usize, 2), sealed.items.len);
    try s.tick(arena, 140 * sec + 6 * 60 * sec + 120 * sec, &sealed);
    try testing.expectEqual(@as(usize, 3), sealed.items.len);
    try testing.expectEqual(Trigger.idle, sealed.items[2].trigger);
}

test "hook trigger needs a complete exchange" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s: Segmenter = .{};
    var sealed: std.ArrayList(Window) = .empty;

    try s.push(arena, mk(.user, "q", 0, 0), &sealed);
    try s.hook(arena, &sealed);
    try testing.expectEqual(@as(usize, 0), sealed.items.len);

    try s.push(arena, mk(.assistant, "a", 1, 5), &sealed);
    try s.hook(arena, &sealed);
    try testing.expectEqual(Trigger.hook, sealed.items[0].trigger);
}

test "canonical body is stable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const turns = [_]core.Turn{ .{ .role = .user, .text = "q", .ts = 1 }, .{ .role = .assistant, .text = "a", .tool_calls = &.{.{ .name = "Bash", .args_preview = "ls" }}, .ts = 2 } };

    const a = try contentHash(arena, .{ .turns = &turns });
    const b = try contentHash(arena, .{ .turns = try arena.dupe(core.Turn, &turns) });

    try testing.expectEqualSlices(u8, &a, &b);
    try testing.expectEqual(core.types.Author.mixed, authorOf(&turns));
    try testing.expectEqual(core.types.Author.agent, authorOf(turns[1..]));
}
