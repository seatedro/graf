const std = @import("std");

pub const Op = enum {
    search,
    entity,
    remember,
    forget,
    entries,
    brief,
    flush,
    warm,
    recall,
    graph_overview,
    graph_neighborhood,
    graph_search,
    graph_entity,
};

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
