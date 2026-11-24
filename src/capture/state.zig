const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Dir = std.Io.Dir;

pub const paused_file = "paused";
pub const capture_since_file = "capture-since";
pub const spool_file = "spool.jsonl";
pub const socket_file = "graf.sock";

pub fn dir(arena: Allocator, env: *const Environ.Map) Allocator.Error!?[]const u8 {
    if (env.get("XDG_STATE_HOME")) |xdg| if (xdg.len > 0) return try std.fs.path.join(arena, &.{ xdg, "graf" });
    if (env.get("HOME")) |home| if (home.len > 0) return try std.fs.path.join(arena, &.{ home, ".local", "state", "graf" });
    return null;
}

pub fn isPaused(io: std.Io, state_dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ state_dir, paused_file }) catch return false;
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn setPaused(io: std.Io, state_dir: []const u8, paused: bool) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ state_dir, paused_file });

    if (paused) {
        try Dir.cwd().createDirPath(io, state_dir);
        const file = try Dir.cwd().createFile(io, path, .{ .truncate = false });
        file.close(io);
    } else {
        Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }
}

pub fn captureSince(io: std.Io, state_dir: []const u8, now: core.Micros) !core.Micros {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ state_dir, capture_since_file });
    if (try readMicros(io, path)) |since| return since;

    try Dir.cwd().createDirPath(io, state_dir);
    var atomic = try Dir.cwd().createFileAtomic(io, path, .{});
    defer atomic.deinit(io);

    var num: [32]u8 = undefined;
    try atomic.file.writeStreamingAll(io, try std.fmt.bufPrint(&num, "{d}\n", .{now}));
    atomic.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => return (try readMicros(io, path)) orelse now,
        else => |e| return e,
    };

    return now;
}

fn readMicros(io: std.Io, path: []const u8) !?core.Micros {
    var buf: [64]u8 = undefined;
    const text = Dir.cwd().readFile(io, path, &buf) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    return std.fmt.parseInt(core.Micros, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

pub fn spoolPath(arena: Allocator, state_dir: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ state_dir, spool_file });
}

pub fn socketPath(arena: Allocator, config: *const core.Config, env: *const Environ.Map) Allocator.Error!?[]const u8 {
    const configured = config.serve.socket;
    if (configured.len > 0) {
        if (std.mem.eql(u8, configured, "~") or std.mem.startsWith(u8, configured, "~/")) {
            const home = env.get("HOME") orelse return configured;
            return try std.mem.concat(arena, u8, &.{ home, configured[1..] });
        }
        return configured;
    }

    const state_dir = try dir(arena, env) orelse return null;
    return try std.fs.path.join(arena, &.{ state_dir, socket_file });
}

fn testEnv(pairs: []const [2][]const u8) !Environ.Map {
    var env = Environ.Map.init(std.testing.allocator);
    errdefer env.deinit();
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "state dir prefers XDG_STATE_HOME, then HOME" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var both = try testEnv(&.{ .{ "XDG_STATE_HOME", "/x/state" }, .{ "HOME", "/home/brackwater" } });
    defer both.deinit();
    try std.testing.expectEqualStrings("/x/state/graf", (try dir(arena, &both)).?);

    var home_only = try testEnv(&.{ .{ "XDG_STATE_HOME", "" }, .{ "HOME", "/home/brackwater" } });
    defer home_only.deinit();
    try std.testing.expectEqualStrings("/home/brackwater/.local/state/graf", (try dir(arena, &home_only)).?);

    var none = try testEnv(&.{});
    defer none.deinit();
    try std.testing.expect((try dir(arena, &none)) == null);
}

test "socket path: configured, tilde, default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = try testEnv(&.{.{ "HOME", "/home/brackwater" }});
    defer env.deinit();

    var cfg: core.Config = .{};
    try std.testing.expectEqualStrings("/home/brackwater/.local/state/graf/graf.sock", (try socketPath(arena, &cfg, &env)).?);
    cfg.serve.socket = "/run/graf.sock";
    try std.testing.expectEqualStrings("/run/graf.sock", (try socketPath(arena, &cfg, &env)).?);
    cfg.serve.socket = "~/g.sock";
    try std.testing.expectEqualStrings("/home/brackwater/g.sock", (try socketPath(arena, &cfg, &env)).?);
    try std.testing.expectEqualStrings("/s/spool.jsonl", try spoolPath(arena, "/s"));
}

test "pause flag round trip and capture epoch persists" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const state_dir = try std.fs.path.join(arena, &.{ root, "nested", "graf" });

    try std.testing.expect(!isPaused(io, state_dir));
    try setPaused(io, state_dir, true);
    try std.testing.expect(isPaused(io, state_dir));
    try setPaused(io, state_dir, true);
    try setPaused(io, state_dir, false);
    try std.testing.expect(!isPaused(io, state_dir));
    try setPaused(io, state_dir, false);

    const other = try std.fs.path.join(arena, &.{ root, "fresh", "graf" });
    try std.testing.expectEqual(@as(core.Micros, 1_700_000_000_000_000), try captureSince(io, other, 1_700_000_000_000_000));
    try std.testing.expectEqual(@as(core.Micros, 1_700_000_000_000_000), try captureSince(io, other, 1_800_000_000_000_000));
    const text = try Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ other, capture_since_file }), arena, .limited(64));
    try std.testing.expectEqualStrings("1700000000000000\n", text);
}
