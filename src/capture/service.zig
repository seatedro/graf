const std = @import("std");
const core = @import("core");
const tailer_mod = @import("tailer.zig");
const watch = @import("watch.zig");
const state = @import("state.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

pub const Root = struct {
    harness: core.Harness,
    path: []const u8,
};

pub const default_roots = [_]struct { core.Harness, []const u8 }{
    .{ .@"claude-code", ".claude/projects" },
    .{ .codex, ".codex/sessions" },
    .{ .pi, ".pi/agent/sessions" },
    .{ .fx, ".fx/sessions" },
};

pub const Options = struct {
    roots: ?[]const Root = null,
    since: ?core.Micros = null,
    backfill: bool = false,
    scan_every: core.Micros = 30 * std.time.us_per_s,
    tick_every: Io.Duration = .fromSeconds(1),
    tailer: tailer_mod.Options = .{},
};

pub const Capture = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    state_dir: ?[]const u8,
    tailers: []tailer_mod.Tailer,
    watcher: watch.Watcher,
    mutex: Io.Mutex = .init,
    last_scan: ?core.Micros = null,
    options: Options,

    pub fn init(gpa: Allocator, io: Io, env: *const Environ.Map, config: *const core.Config, sink: core.EpisodeSink, options: Options) !Capture {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const home = env.get("HOME");
        const state_dir = try state.dir(a, env);
        const roots = options.roots orelse blk: {
            const h = home orelse break :blk &.{};
            const list = try a.alloc(Root, default_roots.len);
            for (default_roots, list) |d, *r| r.* = .{ .harness = d[0], .path = try std.fs.path.join(a, &.{ h, d[1] }) };
            break :blk list;
        };
        const now = Io.Timestamp.now(io, .real).toMicroseconds();
        var tailer_options = options.tailer;
        if (tailer_options.home == null) tailer_options.home = if (home) |h| try a.dupe(u8, h) else null;
        if (!options.backfill and tailer_options.since == null) {
            tailer_options.since = options.since orelse if (state_dir) |sd| try state.captureSince(io, sd, now) else now;
        }
        const tailers = try gpa.alloc(tailer_mod.Tailer, roots.len);
        for (roots, tailers) |r, *t| t.* = .init(gpa, io, r.harness, try a.dupe(u8, r.path), sink, config, tailer_options);
        var watcher: watch.Watcher = .init(gpa);
        for (tailers) |*t| watcher.watchTree(io, t.root) catch {};
        return .{
            .gpa = gpa,
            .io = io,
            .arena = arena,
            .state_dir = state_dir,
            .tailers = tailers,
            .watcher = watcher,
            .options = options,
        };
    }

    pub fn deinit(c: *Capture) void {
        for (c.tailers) |*t| t.deinit();
        c.gpa.free(c.tailers);
        c.watcher.deinit();
        c.arena.deinit();
        c.* = undefined;
    }

    pub fn run(c: *Capture) Io.Cancelable!void {
        while (true) {
            c.step(Io.Timestamp.now(c.io, .real).toMicroseconds()) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                std.log.scoped(.capture).warn("capture step failed: {t}", .{err});
            };
            try c.io.sleep(c.options.tick_every, .awake);
        }
    }

    pub fn step(c: *Capture, now: core.Micros) !void {
        try c.mutex.lock(c.io);
        defer c.mutex.unlock(c.io);
        const paused = if (c.state_dir) |sd| state.isPaused(c.io, sd) else false;
        for (c.tailers) |*t| t.paused = paused;

        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        var changes: watch.Changes = .{};
        try c.watcher.poll(c.io, scratch.allocator(), &changes);

        const due = if (c.last_scan) |last| now - last >= c.options.scan_every else true;
        if (due or changes.rescan or !c.watcher.active()) {
            for (c.tailers) |*t| {
                c.watcher.watchTree(c.io, t.root) catch {};
                try t.scan(now);
            }
            c.last_scan = now;
        } else {
            for (changes.paths.items) |path| {
                for (c.tailers) |*t| {
                    if (!std.mem.startsWith(u8, path, t.root) or !tailer_mod.matches(t.harness, std.fs.path.basename(path))) continue;
                    try t.pollPath(path, now);
                    break;
                }
            }
            for (c.tailers) |*t| try t.tick(now);
        }
        for (c.tailers) |*t| {
            for (t.recent.items) |path| c.watcher.watchFile(path) catch {};
            t.recent.clearRetainingCapacity();
        }
    }

    pub fn flush(c: *Capture, harness: core.Harness, transcript_path: []const u8) !bool {
        try c.mutex.lock(c.io);
        defer c.mutex.unlock(c.io);
        const now = Io.Timestamp.now(c.io, .real).toMicroseconds();
        for (c.tailers) |*t| {
            if (t.harness != harness) continue;
            if (try t.flush(transcript_path, now)) return true;
        }
        return false;
    }

    pub fn stats(c: *Capture) tailer_mod.Stats {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        var total: tailer_mod.Stats = .{};
        for (c.tailers) |*t| inline for (@typeInfo(tailer_mod.Stats).@"struct".field_names) |name| {
            @field(total, name) += @field(t.stats, name);
        };
        return total;
    }
};

const testing = std.testing;

test "capture tails every configured root and answers hook flushes" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "claude/proj");
    try tmp.dir.createDirPath(io, "codex/2026/11/21");
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const roots = [_]Root{
        .{ .harness = .@"claude-code", .path = try std.fs.path.join(arena, &.{ base, "claude" }) },
        .{ .harness = .codex, .path = try std.fs.path.join(arena, &.{ base, "codex" }) },
    };

    var sink: tailer_mod.FakeSink = .init(testing.allocator);
    defer sink.deinit();
    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();
    const config: core.Config = .{};
    var c: Capture = try .init(testing.allocator, io, &env, &config, sink.episodeSink(), .{ .roots = &roots, .backfill = true });
    defer c.deinit();

    const t0: core.Micros = 1_795_194_000_000_000;
    const minute = std.time.us_per_min;
    try c.step(t0);
    try tmp.dir.writeFile(io, .{ .sub_path = "claude/proj/s.jsonl", .data = @embedFile("testdata/claude-code/session.jsonl") });
    try tmp.dir.writeFile(io, .{ .sub_path = "codex/2026/11/21/rollout-2026-11-21T09-00-00-x.jsonl", .data = @embedFile("testdata/codex/rollout.jsonl") });
    try tmp.dir.writeFile(io, .{ .sub_path = "codex/2026/11/21/notes.jsonl", .data = "{}\n" });
    try c.step(t0 + minute);
    try c.step(t0 + 2 * minute);
    try c.step(t0 + 26 * 60 * minute);
    const s = c.stats();
    try testing.expectEqual(@as(usize, 2), s.files);
    try testing.expectEqual(@as(usize, 2), sink.episodes.items.len);

    const transcript = try std.fs.path.join(arena, &.{ base, "claude", "proj", "s.jsonl" });
    try tmp.dir.writeFile(io, .{ .sub_path = "claude/proj/s.jsonl", .data = "" });
    try testing.expect(try c.flush(.@"claude-code", transcript));
    try testing.expect(!try c.flush(.codex, transcript));
}
