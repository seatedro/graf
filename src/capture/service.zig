const std = @import("std");
const core = @import("core");
const tailer_mod = @import("tailer.zig");
const watch = @import("watch.zig");
const state = @import("state.zig");
const spool = @import("hooks_spool.zig");
const profiles = @import("profiles.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

pub const Root = struct {
    harness: core.Harness,
    path: []const u8,
};

pub const profile_roots = [_]struct { core.Harness, profiles.Kind, []const u8 }{
    .{ .@"claude-code", profiles.claude, "projects" },
    .{ .codex, profiles.codex, "sessions" },
};

pub const fixed_roots = [_]struct { core.Harness, []const u8 }{
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

const Discovery = struct {
    home: []const u8,
    overrides: [profile_roots.len]?[]const u8,

    fn roots(d: Discovery, arena: Allocator, io: Io) ![]const Root {
        var list: std.ArrayList(Root) = .empty;
        for (profile_roots, d.overrides) |p, override| {
            for (try profiles.discover(arena, io, d.home, override, p[1])) |profile| {
                try list.append(arena, .{ .harness = p[0], .path = try std.fs.path.join(arena, &.{ profile.dir, p[2] }) });
            }
        }

        for (fixed_roots) |f| try list.append(arena, .{ .harness = f[0], .path = try std.fs.path.join(arena, &.{ d.home, f[1] }) });
        return list.items;
    }
};

pub const Capture = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    state_dir: ?[]const u8,
    sink: core.EntrySink,
    config: *const core.Config,
    tailer_options: tailer_mod.Options,
    discovery: ?Discovery,
    tailers: std.ArrayList(tailer_mod.Tailer) = .empty,
    watcher: watch.Watcher,
    mutex: Io.Mutex = .init,
    last_scan: ?core.Micros = null,
    paused: bool = false,
    options: Options,

    pub fn init(gpa: Allocator, io: Io, env: *const Environ.Map, config: *const core.Config, sink: core.EntrySink, options: Options) !Capture {
        var c: Capture = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .state_dir = null,
            .sink = sink,
            .config = config,
            .tailer_options = options.tailer,
            .discovery = null,
            .watcher = .init(gpa),
            .options = options,
        };
        errdefer c.deinit();
        const a = c.arena.allocator();

        const home = if (env.get("HOME")) |h| try a.dupe(u8, h) else null;
        c.state_dir = try state.dir(a, env);

        if (options.roots == null) if (home) |h| {
            var d: Discovery = .{ .home = h, .overrides = undefined };
            for (profile_roots, &d.overrides) |p, *o| o.* = if (env.get(p[1].env)) |v| try a.dupe(u8, v) else null;
            c.discovery = d;
        };

        const now = Io.Timestamp.now(io, .real).toMicroseconds();
        if (c.tailer_options.home == null) c.tailer_options.home = home;
        if (!options.backfill and c.tailer_options.since == null) {
            c.tailer_options.since = options.since orelse if (c.state_dir) |sd| try state.captureSince(io, sd, now) else now;
        }

        if (options.roots) |roots| {
            for (roots) |r| try c.addTailer(r);
        } else _ = try c.discoverRoots();

        return c;
    }

    pub fn deinit(c: *Capture) void {
        for (c.tailers.items) |*t| t.deinit();
        c.tailers.deinit(c.gpa);
        c.watcher.deinit();
        c.arena.deinit();
        c.* = undefined;
    }

    fn addTailer(c: *Capture, root: Root) !void {
        const path = try c.arena.allocator().dupe(u8, root.path);
        var t: tailer_mod.Tailer = .init(c.gpa, c.io, root.harness, path, c.sink, c.config, c.tailer_options);
        t.paused = c.paused;
        try c.tailers.append(c.gpa, t);
        c.watcher.watchTree(c.io, path) catch {};
    }

    fn discoverRoots(c: *Capture) !usize {
        const d = c.discovery orelse return 0;
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();

        var added: usize = 0;
        next: for (try d.roots(scratch.allocator(), c.io)) |r| {
            for (c.tailers.items) |*t| if (t.harness == r.harness and std.mem.eql(u8, t.root, r.path)) continue :next;
            try c.addTailer(r);
            added += 1;
        }
        return added;
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
        c.paused = if (c.state_dir) |sd| try state.isPaused(c.io, sd) else false;
        for (c.tailers.items) |*t| t.paused = c.paused;

        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        var changes: watch.Changes = .{};
        try c.watcher.poll(c.io, scratch.allocator(), &changes);

        const due = if (c.last_scan) |last| now - last >= c.options.scan_every else true;
        if (due or changes.rescan or !c.watcher.active()) {
            if (due) _ = try c.discoverRoots();
            for (c.tailers.items) |*t| {
                c.watcher.watchTree(c.io, t.root) catch {};
                try t.scan(now);
            }
            c.last_scan = now;
        } else {
            for (changes.paths.items) |path| {
                for (c.tailers.items) |*t| {
                    if (!t.owns(path) or !tailer_mod.matches(t.harness, std.fs.path.basename(path))) continue;
                    try t.pollPath(path, now);
                    break;
                }
            }
            for (c.tailers.items) |*t| try t.tick(now);
        }

        for (c.tailers.items) |*t| {
            for (t.recent.items) |path| c.watcher.watchFile(path) catch {};
            t.recent.clearRetainingCapacity();
        }
    }

    pub fn flush(c: *Capture, harness: core.Harness, transcript_path: []const u8) !bool {
        try c.mutex.lock(c.io);
        defer c.mutex.unlock(c.io);

        const now = Io.Timestamp.now(c.io, .real).toMicroseconds();
        if (try c.flushKnown(harness, transcript_path, now)) return true;
        if (try c.discoverRoots() == 0) return false;
        return c.flushKnown(harness, transcript_path, now);
    }

    fn flushKnown(c: *Capture, harness: core.Harness, transcript_path: []const u8, now: core.Micros) !bool {
        for (c.tailers.items) |*t| {
            if (t.harness != harness) continue;
            if (try t.flush(transcript_path, now)) return true;
        }
        return false;
    }

    pub fn replaySpool(c: *Capture) !usize {
        const sd = c.state_dir orelse return 0;
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        return spool.drain(arena.allocator(), c.io, sd, c, replayOne);
    }

    fn replayOne(c: *Capture, entry: spool.Entry) anyerror!void {
        const harness = std.meta.stringToEnum(core.Harness, entry.harness) orelse return;
        const path = entry.transcript_path orelse return;
        _ = try c.flush(harness, path);
    }

    pub fn stats(c: *Capture) tailer_mod.Stats {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);

        var total: tailer_mod.Stats = .{};
        for (c.tailers.items) |*t| inline for (@typeInfo(tailer_mod.Stats).@"struct".field_names) |name| {
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
    var c: Capture = try .init(testing.allocator, io, &env, &config, sink.entrySink(), .{ .roots = &roots, .backfill = true });
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
    try testing.expectEqual(@as(usize, 2), sink.entries.items.len);

    const transcript = try std.fs.path.join(arena, &.{ base, "claude", "proj", "s.jsonl" });
    try tmp.dir.writeFile(io, .{ .sub_path = "claude/proj/s.jsonl", .data = "" });
    try testing.expect(try c.flush(.@"claude-code", transcript));
    try testing.expect(!try c.flush(.codex, transcript));
}

test "capture discovers every claude and codex profile under home" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const transcripts = [_][]const u8{
        ".claude/projects/p/s.jsonl",
        ".claude-work/projects/p/s.jsonl",
        ".codex/sessions/2026/11/21/rollout-2026-11-21T09-00-00-x.jsonl",
        ".codex-alt/sessions/2026/11/21/rollout-2026-11-21T09-00-00-x.jsonl",
    };
    for (transcripts) |sub| try tmp.dir.createDirPath(io, std.fs.path.dirname(sub).?);
    try tmp.dir.createDirPath(io, ".claude.bak/projects/p");
    try tmp.dir.createDirPath(io, ".claude-router");
    const home = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var sink: tailer_mod.FakeSink = .init(testing.allocator);
    defer sink.deinit();
    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", home);
    const config: core.Config = .{};
    var c: Capture = try .init(testing.allocator, io, &env, &config, sink.entrySink(), .{ .backfill = true });
    defer c.deinit();

    var roots: usize = 0;
    for (c.tailers.items) |t| {
        if (t.harness == .@"claude-code" or t.harness == .codex) roots += 1;
    }
    try testing.expectEqual(@as(usize, 4), roots);

    const t0: core.Micros = 1_795_194_000_000_000;
    const minute = std.time.us_per_min;

    try c.step(t0);
    for (transcripts) |sub| {
        const data = if (std.mem.startsWith(u8, sub, ".claude")) @embedFile("testdata/claude-code/session.jsonl") else @embedFile("testdata/codex/rollout.jsonl");
        try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude.bak/projects/p/s.jsonl", .data = @embedFile("testdata/claude-code/session.jsonl") });
    try c.step(t0 + minute);
    try c.step(t0 + 2 * minute);
    try c.step(t0 + 26 * 60 * minute);

    try testing.expectEqual(@as(usize, 4), c.stats().files);
    try testing.expectEqual(@as(u32, 4), sink.cursors.count());
    for (transcripts) |sub| {
        const path = try std.fs.path.join(arena, &.{ home, sub });
        try testing.expect(sink.cursors.contains(path));
        const harness: core.Harness = if (std.mem.startsWith(u8, sub, ".claude")) .@"claude-code" else .codex;
        try testing.expect(try c.flush(harness, path));
    }

    try testing.expect(!try c.flush(.@"claude-code", try std.fs.path.join(arena, &.{ home, ".claude", "projects-old", "p", "s.jsonl" })));
    try testing.expect(!try c.flush(.codex, try std.fs.path.join(arena, &.{ home, transcripts[0] })));

    try tmp.dir.createDirPath(io, ".claude-late/projects/p");
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude-late/projects/p/s.jsonl", .data = @embedFile("testdata/claude-code/session.jsonl") });
    const late = try std.fs.path.join(arena, &.{ home, ".claude-late", "projects", "p", "s.jsonl" });
    try testing.expect(try c.flush(.@"claude-code", late));
    try testing.expect(sink.cursors.contains(late));

    try tmp.dir.createDirPath(io, ".codex-next/sessions/2026/11/22");
    try tmp.dir.writeFile(io, .{ .sub_path = ".codex-next/sessions/2026/11/22/rollout-2026-11-22T09-00-00-y.jsonl", .data = @embedFile("testdata/codex/rollout.jsonl") });
    try c.step(t0 + 27 * 60 * minute);
    try c.step(t0 + 52 * 60 * minute);
    try testing.expect(sink.cursors.contains(try std.fs.path.join(arena, &.{ home, ".codex-next", "sessions", "2026", "11", "22", "rollout-2026-11-22T09-00-00-y.jsonl" })));
}

test "spooled flushes replay into the matching tailer" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "claude/proj");
    try tmp.dir.createDirPath(io, "state/graf");
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const roots = [_]Root{.{ .harness = .@"claude-code", .path = try std.fs.path.join(arena, &.{ base, "claude" }) }};
    const transcript = try std.fs.path.join(arena, &.{ base, "claude", "proj", "s.jsonl" });
    try tmp.dir.writeFile(io, .{ .sub_path = "claude/proj/s.jsonl", .data = @embedFile("testdata/claude-code/session.jsonl") });
    const line = try std.fmt.allocPrint(arena, "{{\"ts\":1,\"harness\":\"claude-code\",\"event\":\"stop\",\"session_id\":\"s\",\"transcript_path\":\"{s}\",\"cwd\":null}}\n", .{transcript});
    try tmp.dir.writeFile(io, .{ .sub_path = "state/graf/spool.jsonl", .data = line, .flags = .{} });

    var sink: tailer_mod.FakeSink = .init(testing.allocator);
    defer sink.deinit();
    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", try std.fs.path.join(arena, &.{ base, "state" }));
    const config: core.Config = .{};
    var c: Capture = try .init(testing.allocator, io, &env, &config, sink.entrySink(), .{ .roots = &roots, .backfill = true });
    defer c.deinit();

    try testing.expectEqual(@as(usize, 1), try c.replaySpool());
    try testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    try testing.expectEqual(@as(usize, 0), try c.replaySpool());
}
