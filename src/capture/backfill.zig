const std = @import("std");
const core = @import("core");
const tailer = @import("tailer.zig");
const service = @import("service.zig");
const capy = @import("capy.zig");
const normalize = @import("normalize.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

pub const default_entry_usd: f64 = 0.01;

pub const Options = struct {
    roots: []const service.Root = &.{},
    capy: bool = false,
    capy_options: capy.Options = .{},
    since: ?core.Micros = null,
    until: ?core.Micros = null,
    now: core.Micros,
    home: ?[]const u8 = null,
    max_entries: ?u64 = null,
    cap_usd: ?f64 = null,
    entry_usd: f64 = default_entry_usd,
};

pub const Stats = struct {
    files: usize = 0,
    excluded_files: usize = 0,
    threads: usize = 0,
    excluded_threads: usize = 0,
    lines: u64 = 0,
    malformed_lines: u64 = 0,
    dropped_turns: u64 = 0,
    entries: u64 = 0,
    turns: u64 = 0,
    queued: u64 = 0,
    duplicates: u64 = 0,
    limited: bool = false,

    pub fn estimatedUsd(s: Stats, entry_usd: f64) f64 {
        return @as(f64, @floatFromInt(s.queued)) * entry_usd;
    }

    pub fn deferred(s: Stats) u64 {
        return s.entries - s.queued - s.duplicates;
    }
};

const File = struct {
    harness: core.Harness,
    root: []const u8,
    path: []const u8,
};

const Pending = struct {
    first: core.Micros,
    file: ?File,
};

const Batch = struct {
    arena: std.heap.ArenaAllocator,
    drafts: std.ArrayList(core.EntryDraft) = .empty,
    next: usize = 0,

    fn create(gpa: Allocator) !*Batch {
        const b = try gpa.create(Batch);
        b.* = .{ .arena = .init(gpa) };
        return b;
    }

    fn destroy(b: *Batch, gpa: Allocator) void {
        b.arena.deinit();
        gpa.destroy(b);
    }

    fn head(b: *const Batch) core.Micros {
        return b.drafts.items[b.next].reference_time;
    }

    fn first(b: *const Batch) ?core.Micros {
        var min: ?core.Micros = null;
        for (b.drafts.items) |d| min = if (min) |m| @min(m, d.reference_time) else d.reference_time;
        return min;
    }

    fn tally(b: *const Batch, stats: *Stats) void {
        stats.entries += b.drafts.items.len;
        for (b.drafts.items) |d| stats.turns += d.body.turns.len;
    }

    fn sink(b: *Batch) core.EntrySink {
        return .{ .ptr = b, .vtable = &.{ .enqueue = enqueue, .loadCursor = loadCursor } };
    }

    fn enqueue(ptr: *anyopaque, draft: *const core.EntryDraft) anyerror!core.EntrySink.Outcome {
        const b: *Batch = @ptrCast(@alignCast(ptr));
        const a = b.arena.allocator();

        var kept = draft.*;
        if (draft.source) |s| kept.source = .{
            .harness = s.harness,
            .external_id = try a.dupe(u8, s.external_id),
            .project = try dupeOptional(a, s.project),
            .agent = try dupeOptional(a, s.agent),
            .model = try dupeOptional(a, s.model),
        };

        const turns = try a.alloc(core.Turn, draft.body.turns.len);
        for (draft.body.turns, turns) |t, *dst| dst.* = try normalize.dupeTurn(a, t);

        kept.project = try dupeOptional(a, draft.project);
        kept.body = .{ .turns = turns, .text = try dupeOptional(a, draft.body.text) };
        kept.seq_in_source = 0;
        kept.cursor = null;
        kept.backfill = true;

        try b.drafts.append(a, kept);
        return .{ .queued = core.Id.nil };
    }

    fn loadCursor(_: *anyopaque, _: Allocator, _: *const core.SourceKey) anyerror!?[]const u8 {
        return null;
    }
};

fn dupeOptional(a: Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try a.dupe(u8, v) else null;
}

const Merge = struct {
    gpa: Allocator,
    sink: core.EntrySink,
    options: *const Options,
    stats: *Stats,
    active: std.ArrayList(*Batch) = .empty,

    fn deinit(m: *Merge) void {
        for (m.active.items) |b| b.destroy(m.gpa);
        m.active.deinit(m.gpa);
    }

    fn add(m: *Merge, b: *Batch) !void {
        if (b.drafts.items.len == 0) return b.destroy(m.gpa);
        m.active.append(m.gpa, b) catch |err| {
            b.destroy(m.gpa);
            return err;
        };
    }

    fn drainThrough(m: *Merge, until: core.Micros) !bool {
        while (m.active.items.len > 0) {
            var min: usize = 0;
            for (m.active.items, 0..) |b, i| {
                if (b.head() < m.active.items[min].head()) min = i;
            }

            const b = m.active.items[min];
            if (b.head() > until) return true;
            if (!try m.emit(&b.drafts.items[b.next])) return false;

            b.next += 1;
            if (b.next == b.drafts.items.len) {
                _ = m.active.orderedRemove(min);
                b.destroy(m.gpa);
            }
        }
        return true;
    }

    fn emit(m: *Merge, draft: *const core.EntryDraft) !bool {
        const s = m.stats;
        const over_count = if (m.options.max_entries) |max| s.queued >= max else false;
        const over_cost = if (m.options.cap_usd) |cap| @as(f64, @floatFromInt(s.queued + 1)) * m.options.entry_usd > cap else false;
        if (over_count or over_cost) {
            s.limited = true;
            return false;
        }

        switch (try m.sink.enqueue(draft)) {
            .queued => s.queued += 1,
            .duplicate => s.duplicates += 1,
        }
        return true;
    }
};

pub fn run(gpa: Allocator, io: Io, env: *const Environ.Map, config: *const core.Config, sink: core.EntrySink, options: Options) !Stats {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stats: Stats = .{};
    const files = try discover(arena, io, options);
    stats.files = files.len;

    var pending: std.ArrayList(Pending) = .empty;
    for (files) |f| {
        const b = try collectFile(gpa, io, config, f, &options, &stats);
        defer b.destroy(gpa);
        b.tally(&stats);
        if (b.first()) |first| try pending.append(arena, .{ .first = first, .file = f });
    }

    var capy_batch: ?*Batch = null;
    defer if (capy_batch) |b| b.destroy(gpa);
    if (options.capy) {
        const b = try collectCapy(gpa, io, env, config, &options, &stats);
        capy_batch = b;
        b.tally(&stats);
        if (b.first()) |first| try pending.append(arena, .{ .first = first, .file = null });
    }

    std.sort.block(Pending, pending.items, {}, struct {
        fn lessThan(_: void, a: Pending, b: Pending) bool {
            return a.first < b.first;
        }
    }.lessThan);

    var merge: Merge = .{ .gpa = gpa, .sink = sink, .options = &options, .stats = &stats };
    defer merge.deinit();

    for (pending.items) |p| {
        if (!try merge.drainThrough(p.first)) return stats;

        if (p.file) |f| {
            try merge.add(try collectFile(gpa, io, config, f, &options, null));
        } else {
            const b = capy_batch.?;
            capy_batch = null;
            try merge.add(b);
        }
    }

    _ = try merge.drainThrough(std.math.maxInt(core.Micros));
    return stats;
}

fn discover(arena: Allocator, io: Io, options: Options) ![]const File {
    var files: std.ArrayList(File) = .empty;

    for (options.roots) |root| {
        var dir = Io.Dir.cwd().openDir(io, root.path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => |e| return e,
        };
        defer dir.close(io);

        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !tailer.matches(root.harness, entry.basename)) continue;
            const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            if (options.since) |since| if (@divTrunc(st.mtime.nanoseconds, std.time.ns_per_us) < since) continue;
            try files.append(arena, .{ .harness = root.harness, .root = root.path, .path = try std.fs.path.join(arena, &.{ root.path, entry.path }) });
        }
    }

    std.sort.block(File, files.items, {}, struct {
        fn lessThan(_: void, a: File, b: File) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);
    return files.items;
}

fn collectFile(gpa: Allocator, io: Io, config: *const core.Config, file: File, options: *const Options, stats: ?*Stats) !*Batch {
    const b = try Batch.create(gpa);
    errdefer b.destroy(gpa);

    var t: tailer.Tailer = .init(gpa, io, file.harness, file.root, b.sink(), config, .{ .since = options.since, .until = options.until, .home = options.home });
    defer t.deinit();
    try t.pollPath(file.path, options.now);
    try t.finish(options.now);

    if (stats) |s| {
        s.excluded_files += t.stats.excluded_files;
        s.lines += t.stats.lines;
        s.malformed_lines += t.stats.malformed_lines;
        s.dropped_turns += t.stats.dropped_turns;
    }
    return b;
}

fn collectCapy(gpa: Allocator, io: Io, env: *const Environ.Map, config: *const core.Config, options: *const Options, stats: *Stats) !*Batch {
    const b = try Batch.create(gpa);
    errdefer b.destroy(gpa);

    var opts = options.capy_options;
    opts.backfill = true;
    opts.since = options.since;
    opts.until = options.until;

    var src = try capy.Source.init(gpa, io, env, config, b.sink(), opts);
    defer src.deinit();
    try src.runOnce(options.now);
    try src.finish(options.now);

    const s = src.snapshot();
    stats.threads += s.threads;
    stats.excluded_threads += s.excluded_threads;
    stats.dropped_turns += s.dropped_turns;

    std.sort.block(core.EntryDraft, b.drafts.items, {}, struct {
        fn lessThan(_: void, x: core.EntryDraft, y: core.EntryDraft) bool {
            return x.reference_time < y.reference_time;
        }
    }.lessThan);
    return b;
}

const testing = std.testing;

const Recorder = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Seen) = .empty,

    const Seen = struct { text: []const u8, seq: i32, backfill: bool, cursor: bool };

    fn sink(r: *Recorder) core.EntrySink {
        return .{ .ptr = r, .vtable = &.{ .enqueue = enqueue, .loadCursor = Batch.loadCursor } };
    }

    fn enqueue(ptr: *anyopaque, draft: *const core.EntryDraft) anyerror!core.EntrySink.Outcome {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        const a = r.arena.allocator();
        for (r.entries.items) |e| if (std.mem.eql(u8, e.text, draft.body.turns[0].text)) return .duplicate;

        try r.entries.append(a, .{
            .text = try a.dupe(u8, draft.body.turns[0].text),
            .seq = draft.seq_in_source,
            .backfill = draft.backfill,
            .cursor = draft.cursor != null,
        });
        return .{ .queued = core.Id.nil };
    }
};

pub const testdata = struct {
    pub const day = std.time.us_per_day;
    pub const t0: core.Micros = 1_795_194_000_000_000;

    pub const Exchange = struct { core.Micros, []const u8 };

    pub fn session(gpa: Allocator, exchanges: []const Exchange) ![]const u8 {
        const Line = struct {
            type: []const u8,
            cwd: []const u8 = "/home/dev/brackwater/widget",
            timestamp: []const u8,
            message: struct { role: []const u8, content: []const u8 },
        };

        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();

        for (exchanges) |e| {
            var buf: [2][32]u8 = undefined;
            const lines = [_]Line{
                .{ .type = "user", .timestamp = try stamp(&buf[0], e[0]), .message = .{ .role = "user", .content = e[1] } },
                .{ .type = "assistant", .timestamp = try stamp(&buf[1], e[0] + 5 * std.time.us_per_s), .message = .{ .role = "assistant", .content = "Done." } },
            };

            for (lines) |line| {
                try std.json.Stringify.value(line, .{}, &out.writer);
                try out.writer.writeByte('\n');
            }
        }

        return out.toOwnedSlice();
    }

    pub fn write(io: Io, dir: Io.Dir, sub: []const u8, exchanges: []const Exchange) !void {
        const data = try session(testing.allocator, exchanges);
        defer testing.allocator.free(data);
        try dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }

    fn stamp(buf: *[32]u8, at: core.Micros) ![]const u8 {
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(at, std.time.us_per_s)) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
    }
};

const day = testdata.day;
const t0 = testdata.t0;

test "backfill feeds entries oldest first across files and keeps to the window" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "claude/p");
    try testdata.write(io, tmp.dir, "claude/p/a.jsonl", &.{ .{ t0 + day, "first on day one" }, .{ t0 + 3 * day, "later on day three" } });
    try testdata.write(io, tmp.dir, "claude/p/b.jsonl", &.{.{ t0 + 2 * day, "middle on day two" }});
    try testdata.write(io, tmp.dir, "claude/p/c.jsonl", &.{ .{ t0, "before the window" }, .{ t0 + 5 * day, "after the live epoch" } });

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const roots = [_]service.Root{.{ .harness = .@"claude-code", .path = try std.fs.path.join(arena, &.{ base, "claude" }) }};

    var rec: Recorder = .{ .arena = .init(testing.allocator) };
    defer rec.arena.deinit();
    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();
    const config: core.Config = .{};

    const options: Options = .{ .roots = &roots, .since = t0 + day / 2, .until = t0 + 4 * day, .now = t0 + 6 * day };
    const stats = try run(testing.allocator, io, &env, &config, rec.sink(), options);

    try testing.expectEqual(@as(usize, 3), stats.files);
    try testing.expectEqual(@as(u64, 3), stats.entries);
    try testing.expectEqual(@as(u64, 6), stats.turns);
    try testing.expectEqual(@as(u64, 4), stats.dropped_turns);
    try testing.expectEqual(@as(u64, 3), stats.queued);

    const want = [_][]const u8{ "first on day one", "middle on day two", "later on day three" };
    try testing.expectEqual(want.len, rec.entries.items.len);
    for (want, rec.entries.items) |text, e| {
        try testing.expectEqualStrings(text, e.text);
        try testing.expect(e.backfill and !e.cursor);
        try testing.expectEqual(@as(i32, 0), e.seq);
    }

    const again = try run(testing.allocator, io, &env, &config, rec.sink(), options);
    try testing.expectEqual(@as(u64, 0), again.queued);
    try testing.expectEqual(@as(u64, 3), again.duplicates);
}

test "backfill stops at the entry and spend limits and resumes on the next run" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "claude/p");
    try testdata.write(io, tmp.dir, "claude/p/a.jsonl", &.{ .{ t0, "one" }, .{ t0 + day, "two" }, .{ t0 + 2 * day, "three" } });

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const roots = [_]service.Root{.{ .harness = .@"claude-code", .path = try std.fs.path.join(arena, &.{ base, "claude" }) }};

    var rec: Recorder = .{ .arena = .init(testing.allocator) };
    defer rec.arena.deinit();
    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();
    const config: core.Config = .{};

    const capped = try run(testing.allocator, io, &env, &config, rec.sink(), .{ .roots = &roots, .now = t0 + 3 * day, .max_entries = 2 });
    try testing.expect(capped.limited);
    try testing.expectEqual(@as(u64, 2), capped.queued);
    try testing.expectEqual(@as(u64, 1), capped.deferred());

    const budgeted = try run(testing.allocator, io, &env, &config, rec.sink(), .{ .roots = &roots, .now = t0 + 3 * day, .cap_usd = 0.015 });
    try testing.expect(!budgeted.limited);
    try testing.expectEqual(@as(u64, 1), budgeted.queued);
    try testing.expectEqual(@as(u64, 2), budgeted.duplicates);
    try testing.expectEqualStrings("three", rec.entries.items[2].text);
}
