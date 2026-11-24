const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;

pub fn derive(arena: Allocator, io: std.Io, cwd: []const u8) Allocator.Error![]const u8 {
    _ = arena;
    _ = io;
    return cwd;
}

pub const Exclusion = struct {
    cwd: ?[]const u8 = null,
    project: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

pub fn isExcluded(arena: Allocator, io: std.Io, config: *const core.Config, what: Exclusion) Allocator.Error!bool {
    _ = arena;
    _ = io;
    _ = config;
    _ = what;
    return false;
}
