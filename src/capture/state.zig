const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub fn dir(arena: Allocator, env: *const Environ.Map) Allocator.Error!?[]const u8 {
    _ = arena;
    _ = env;
    return null;
}

pub fn isPaused(io: std.Io, state_dir: []const u8) bool {
    _ = io;
    _ = state_dir;
    return false;
}

pub fn setPaused(io: std.Io, state_dir: []const u8, paused: bool) !void {
    _ = io;
    _ = state_dir;
    _ = paused;
    return core.NotImplemented;
}

pub fn captureSince(io: std.Io, state_dir: []const u8, now: core.Micros) !core.Micros {
    _ = io;
    _ = state_dir;
    return now;
}
