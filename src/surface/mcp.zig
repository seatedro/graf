const std = @import("std");
const core = @import("core");

pub const tools = [_][]const u8{ "memory_search", "memory_entity", "memory_remember", "memory_forget" };

pub fn serveStdio(arena: std.mem.Allocator, io: std.Io, config: *const core.Config) !void {
    _ = arena;
    _ = io;
    _ = config;
    return core.NotImplemented;
}
