const std = @import("std");
const core = @import("core");

pub const Op = enum { search, entity, remember, forget, episodes, brief, flush, warm, recall };

pub const Request = struct {
    op: Op,
    body: []const u8 = "{}",
    session_id: ?[]const u8 = null,
};

pub const Reply = struct {
    status: u16 = 200,
    /// JSON object. A successful search, entity, remember, forget, brief or recall reply
    /// carries the rendered result in a "text" field; an error reply carries "error".
    body: []const u8,
};

pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, req: Request) anyerror!Reply,
    };

    pub fn handle(h: Handler, arena: std.mem.Allocator, req: Request) !Reply {
        return h.vtable.handle(h.ptr, arena, req);
    }
};

pub fn errorReply(arena: std.mem.Allocator, status: u16, message: []const u8) !Reply {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(arena, .{ .@"error" = message }, .{}) };
}

pub fn socketPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map, config: *const core.Config) !?[]const u8 {
    if (config.serve.socket.len > 0) return config.serve.socket;
    if (env.get("XDG_STATE_HOME")) |xdg| if (xdg.len > 0) return try std.fs.path.join(arena, &.{ xdg, "graf", "graf.sock" });
    if (env.get("HOME")) |home| if (home.len > 0) return try std.fs.path.join(arena, &.{ home, ".local", "state", "graf", "graf.sock" });
    return null;
}

test "socket path precedence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/u");
    var cfg: core.Config = .{};
    try std.testing.expectEqualStrings("/home/u/.local/state/graf/graf.sock", (try socketPath(arena, &env, &cfg)).?);
    try env.put("XDG_STATE_HOME", "/state");
    try std.testing.expectEqualStrings("/state/graf/graf.sock", (try socketPath(arena, &env, &cfg)).?);
    cfg.serve.socket = "/run/graf.sock";
    try std.testing.expectEqualStrings("/run/graf.sock", (try socketPath(arena, &env, &cfg)).?);
}
