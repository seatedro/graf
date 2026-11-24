const std = @import("std");
const core = @import("core");
const state = @import("state.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const posix = std.posix;

pub const draining_file = "spool.draining.jsonl";

pub const Entry = struct {
    ts: core.Micros = 0,
    harness: []const u8 = "",
    event: []const u8 = "",
    session_id: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

pub fn append(arena: Allocator, io: Io, state_dir: []const u8, entry: Entry) !void {
    var line: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(entry, .{}, &line.writer);
    try line.writer.writeByte('\n');

    try Dir.cwd().createDirPath(io, state_dir);
    const path = try state.spoolPath(arena, state_dir);

    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);
        const file: File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer file.close(io);
        try file.lock(io, .exclusive);

        const opened = try file.stat(io);
        const current = Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        if (opened.inode != current.inode) continue;

        try file.writeStreamingAll(io, line.written());
        return;
    }

    return error.SpoolContended;
}

pub fn drain(
    arena: Allocator,
    io: Io,
    state_dir: []const u8,
    ctx: anytype,
    comptime handler: fn (@TypeOf(ctx), Entry) anyerror!void,
) !usize {
    const spool = try state.spoolPath(arena, state_dir);
    const draining = try std.fs.path.join(arena, &.{ state_dir, draining_file });

    var delivered: usize = 0;
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        const leftover = if (Dir.cwd().access(io, draining, .{})) |_| true else |_| false;
        if (!leftover and !try claim(io, spool, draining)) break;

        const text = try Dir.cwd().readFileAlloc(io, draining, arena, .unlimited);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            const entry = std.json.parseFromSliceLeaky(Entry, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
            try handler(ctx, entry);
            delivered += 1;
        }

        try Dir.cwd().deleteFile(io, draining);
    }

    return delivered;
}

fn claim(io: Io, spool: []const u8, draining: []const u8) !bool {
    const file = Dir.cwd().openFile(io, spool, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer file.close(io);
    try file.lock(io, .exclusive);

    Dir.cwd().rename(spool, Dir.cwd(), draining, io) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}
