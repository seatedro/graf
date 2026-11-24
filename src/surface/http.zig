const std = @import("std");
const core = @import("core");

pub fn serve(arena: std.mem.Allocator, io: std.Io, config: *const core.Config) !void {
    _ = arena;
    _ = io;
    _ = config;
    return core.NotImplemented;
}
