const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Event = enum { @"session-start", @"prompt-submit", stop, @"session-end" };

pub fn run(arena: Allocator, io: std.Io, env: *const Environ.Map, config: *const core.Config, harness: core.Harness, event: Event, stdin_json: []const u8, out: *std.Io.Writer) !void {
    _ = arena;
    _ = io;
    _ = env;
    _ = config;
    _ = harness;
    _ = event;
    _ = stdin_json;
    _ = out;
    return core.NotImplemented;
}
