const std = @import("std");
const core = @import("core");
const dialect = @import("dialect.zig");
const segment = @import("segment.zig");
const cursor_mod = @import("cursor.zig");
const project = @import("project.zig");
const Allocator = std.mem.Allocator;
const Cursor = cursor_mod.Cursor;
const Io = std.Io;

pub const Options = struct {
    since: ?core.Micros = null,
    segment: segment.Options = .{},
    home: ?[]const u8 = null,
    read_chunk: usize = 1 << 20,
    max_line: usize = 64 << 20,
    meta_prime_bytes: usize = 64 << 10,
    abandon_step_after: core.Micros = 20 * std.time.us_per_min,
    compact_bytes: usize = 4 << 20,
};

pub const Stats = struct {
    files: usize = 0,
    excluded_files: usize = 0,
    lines: u64 = 0,
    malformed_lines: u64 = 0,
    entries: u64 = 0,
    duplicates: u64 = 0,
    dropped_turns: u64 = 0,
    enqueue_errors: u64 = 0,
    resets: u64 = 0,
};

pub fn matches(harness: core.Harness, basename: []const u8) bool {
    if (!std.mem.endsWith(u8, basename, ".jsonl")) return false;
    return switch (harness) {
        .codex => std.mem.startsWith(u8, basename, "rollout-"),
        .fx => std.mem.eql(u8, basename, "events.jsonl"),
        else => true,
    };
}

const TailFile = struct {
    path: []const u8,
    keep: std.heap.ArenaAllocator,
    window: std.heap.ArenaAllocator,
    parser: dialect.Parser,
    segmenter: segment.Segmenter,
    outbox: std.ArrayList(core.EntryDraft) = .empty,
    loaded: bool = false,
    excluded: ?bool = null,
    project: ?[]const u8 = null,
    seq: i32 = 0,
    read_off: u64 = 0,
    skip_to_newline: bool = false,
    inode: []const u8 = "",
    head: []const u8 = "",
    head_len: u64 = 0,
    seen_size: u64 = 0,
    seen_mtime: i96 = 0,

    fn sink(f: *TailFile, scratch: Allocator, out: *std.ArrayList(dialect.Item)) dialect.Sink {
        return .{ .arena = f.window.allocator(), .scratch = scratch, .out = out };
    }
};

pub const Tailer = struct {
    gpa: Allocator,
    io: Io,
    harness: core.Harness,
    root: []const u8,
    sink: core.EntrySink,
    config: *const core.Config,
    options: Options,
    paused: bool = false,
    stats: Stats = .{},
    files: std.StringHashMapUnmanaged(*TailFile) = .empty,
    scratch: std.heap.ArenaAllocator,
    buf: []u8 = &.{},
    recent: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator, io: Io, harness: core.Harness, root: []const u8, sink: core.EntrySink, config: *const core.Config, options: Options) Tailer {
        return .{
            .gpa = gpa,
            .io = io,
            .harness = harness,
            .root = root,
            .sink = sink,
            .config = config,
            .options = options,
            .scratch = .init(gpa),
        };
    }

    pub fn deinit(t: *Tailer) void {
        var it = t.files.valueIterator();
        while (it.next()) |f| t.destroyFile(f.*);
        t.files.deinit(t.gpa);
        t.recent.deinit(t.gpa);
        t.scratch.deinit();
        t.gpa.free(t.buf);
        t.* = undefined;
    }

    pub fn scan(t: *Tailer, now: core.Micros) !void {
        var dir = Io.Dir.cwd().openDir(t.io, t.root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => |e| return e,
        };
        defer dir.close(t.io);
        var walker = try dir.walk(t.gpa);
        defer walker.deinit();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(t.gpa);
        var paths: std.heap.ArenaAllocator = .init(t.gpa);
        defer paths.deinit();
        while (try walker.next(t.io)) |entry| {
            if (entry.kind != .file or !matches(t.harness, entry.basename)) continue;
            const full = try std.fs.path.join(paths.allocator(), &.{ t.root, entry.path });
            try seen.put(t.gpa, full, {});
            const st = entry.dir.statFile(t.io, entry.basename, .{}) catch continue;
            if (t.files.get(full)) |f| {
                if (f.loaded and st.size == f.seen_size and st.mtime.nanoseconds == f.seen_mtime) continue;
            }
            try t.pollPath(full, now);
        }
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(t.gpa);
        var it = t.files.iterator();
        while (it.next()) |e| if (!seen.contains(e.key_ptr.*) and e.value_ptr.*.outbox.items.len == 0) try stale.append(t.gpa, e.key_ptr.*);
        for (stale.items) |path| t.forget(path);
        try t.tick(now);
    }

    pub fn pollPath(t: *Tailer, path: []const u8, now: core.Micros) !void {
        const f = try t.fileFor(path);
        try t.drainOutbox(f);
        if (f.excluded == true) return;
        const file = Io.Dir.cwd().openFile(t.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (f.outbox.items.len == 0) t.forget(path);
                return;
            },
            else => |e| return e,
        };
        defer file.close(t.io);
        const st = try file.stat(t.io);
        const inode = try std.fmt.allocPrint(t.scratch.allocator(), "{d}", .{st.inode});
        if (!f.loaded) {
            try t.load(f, file, st, inode);
        } else if (!std.mem.eql(u8, inode, f.inode) or st.size < f.read_off) {
            try t.restart(f, inode);
        }
        f.seen_size = st.size;
        f.seen_mtime = st.mtime.nanoseconds;
        if (f.read_off < st.size) try t.recent.append(t.gpa, f.path);
        try t.readNew(f, file, st.size, now);
        t.compact(f);
    }

    pub fn tick(t: *Tailer, now: core.Micros) !void {
        var it = t.files.valueIterator();
        while (it.next()) |fp| {
            const f = fp.*;
            try t.drainOutbox(f);
            if (f.excluded == true or !f.loaded) continue;
            var items: std.ArrayList(dialect.Item) = .empty;
            const s = f.sink(t.scratch.allocator(), &items);
            if (f.parser.pendingTs()) |ts| {
                if (now - ts >= t.options.abandon_step_after) {
                    try f.parser.flushAll(s);
                } else if (now - ts >= t.options.segment.idle) {
                    try f.parser.flushResolved(s);
                }
            }
            try t.absorb(f, items.items, f.read_off, now);
            var sealed: std.ArrayList(segment.Window) = .empty;
            try f.segmenter.tick(f.window.allocator(), now, &sealed);
            try t.sealAll(f, sealed.items, f.read_off, now);
            _ = t.scratch.reset(.retain_capacity);
            t.compact(f);
        }
    }

    pub fn flush(t: *Tailer, path: []const u8, now: core.Micros) !bool {
        if (!std.mem.startsWith(u8, path, t.root)) return false;
        const base = std.fs.path.basename(path);
        if (!matches(t.harness, base)) return false;
        try t.pollPath(path, now);
        const f = t.files.get(path) orelse return true;
        if (f.excluded == true or !f.loaded) return true;
        var items: std.ArrayList(dialect.Item) = .empty;
        try f.parser.flushResolved(f.sink(t.scratch.allocator(), &items));
        try t.absorb(f, items.items, f.read_off, now);
        var sealed: std.ArrayList(segment.Window) = .empty;
        try f.segmenter.hook(f.window.allocator(), &sealed);
        try t.sealAll(f, sealed.items, f.read_off, now);
        _ = t.scratch.reset(.retain_capacity);
        t.compact(f);
        return true;
    }

    pub fn sourceKey(t: *const Tailer, f: *const TailFile) core.SourceKey {
        return .{
            .harness = t.harness,
            .external_id = f.path,
            .project = f.project,
            .agent = @tagName(t.harness),
            .model = f.parser.meta.model,
        };
    }

    fn fileFor(t: *Tailer, path: []const u8) !*TailFile {
        if (t.files.get(path)) |f| return f;
        const f = try t.gpa.create(TailFile);
        errdefer t.gpa.destroy(f);
        f.* = .{
            .path = undefined,
            .keep = .init(t.gpa),
            .window = .init(t.gpa),
            .parser = undefined,
            .segmenter = .{ .options = t.options.segment },
        };
        f.path = try f.keep.allocator().dupe(u8, path);
        f.parser = .init(t.harness, f.keep.allocator());
        try t.files.put(t.gpa, f.path, f);
        t.stats.files += 1;
        return f;
    }

    fn forget(t: *Tailer, path: []const u8) void {
        const kv = t.files.fetchRemove(path) orelse return;
        var i: usize = 0;
        while (i < t.recent.items.len) {
            if (t.recent.items[i].ptr == kv.value.path.ptr) _ = t.recent.swapRemove(i) else i += 1;
        }
        if (kv.value.excluded == true) t.stats.excluded_files -= 1;
        t.stats.files -= 1;
        t.destroyFile(kv.value);
    }

    fn destroyFile(t: *Tailer, f: *TailFile) void {
        f.window.deinit();
        f.keep.deinit();
        t.gpa.destroy(f);
    }

    fn load(t: *Tailer, f: *TailFile, file: Io.File, st: Io.File.Stat, inode: []const u8) !void {
        const keep = f.keep.allocator();
        f.inode = try keep.dupe(u8, inode);
        const key = t.sourceKey(f);
        const stored = try t.sink.loadCursor(t.scratch.allocator(), &key);
        if (stored) |text| if (Cursor.decode(t.scratch.allocator(), text)) |c| {
            f.seq = c.seq;
            if (try t.cursorStillValid(file, st, inode, c)) {
                f.read_off = c.offset;
                f.head = try keep.dupe(u8, c.head);
                f.head_len = c.head_len;
            } else {
                t.stats.resets += 1;
            }
        };
        if (stored == null) if (t.options.since) |since| {
            if (@divTrunc(st.mtime.nanoseconds, std.time.ns_per_us) < since) f.read_off = st.size;
        };
        if (f.read_off > 0) try t.primeMeta(f, file);
        if (t.harness == .fx and f.parser.meta.cwd == null) try t.fxSessionMeta(f);
        f.loaded = true;
        _ = t.scratch.reset(.retain_capacity);
    }

    fn cursorStillValid(t: *Tailer, file: Io.File, st: Io.File.Stat, inode: []const u8, c: Cursor) !bool {
        if (c.inode.len > 0 and !std.mem.eql(u8, c.inode, inode)) return false;
        if (st.size < c.offset) return false;
        if (c.head_len > 0) {
            if (st.size < c.head_len) return false;
            const prefix = try t.scratch.allocator().alloc(u8, @intCast(c.head_len));
            const n = try file.readPositionalAll(t.io, prefix, 0);
            const fp = try cursor_mod.fingerprint(t.scratch.allocator(), prefix[0..n]);
            if (!std.mem.eql(u8, fp, c.head)) return false;
        }
        return true;
    }

    fn restart(t: *Tailer, f: *TailFile, inode: []const u8) !void {
        t.stats.resets += 1;
        f.inode = try f.keep.allocator().dupe(u8, inode);
        f.read_off = 0;
        f.head = "";
        f.head_len = 0;
        f.skip_to_newline = false;
        f.parser.pending = null;
        f.segmenter.clear();
        if (f.outbox.items.len == 0) _ = f.window.reset(.retain_capacity);
    }

    fn primeMeta(t: *Tailer, f: *TailFile, file: Io.File) !void {
        const len: usize = @intCast(@min(f.read_off, t.options.meta_prime_bytes));
        const scratch = t.scratch.allocator();
        const data = try scratch.alloc(u8, len);
        const n = try file.readPositionalAll(t.io, data, 0);
        var throwaway: std.heap.ArenaAllocator = .init(t.gpa);
        defer throwaway.deinit();
        var items: std.ArrayList(dialect.Item) = .empty;
        const s: dialect.Sink = .{ .arena = throwaway.allocator(), .scratch = throwaway.allocator(), .out = &items };
        var lines = std.mem.splitScalar(u8, data[0..n], '\n');
        while (lines.next()) |line| {
            if (lines.index == null) break;
            try f.parser.feed(s, line, 0);
        }
        f.parser.pending = null;
        f.parser.lines = 0;
        f.parser.malformed = 0;
    }

    fn fxSessionMeta(t: *Tailer, f: *TailFile) !void {
        const dir = std.fs.path.dirname(f.path) orelse return;
        const scratch = t.scratch.allocator();
        const path = try std.fs.path.join(scratch, &.{ dir, "session.json" });
        const bytes = Io.Dir.cwd().readFileAlloc(t.io, path, scratch, .limited(1 << 20)) catch return;
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch, bytes, .{}) catch return;
        if (v != .object) return;
        if (v.object.get("workspace_root")) |root| if (root == .string) {
            f.parser.meta.cwd = try f.keep.allocator().dupe(u8, root.string);
        };
        if (v.object.get("id")) |id| if (id == .string and f.parser.meta.session_id == null) {
            f.parser.meta.session_id = try f.keep.allocator().dupe(u8, id.string);
        };
    }

    fn readNew(t: *Tailer, f: *TailFile, file: Io.File, size: u64, now: core.Micros) !void {
        if (t.buf.len < t.options.read_chunk) {
            t.gpa.free(t.buf);
            t.buf = try t.gpa.alloc(u8, t.options.read_chunk);
        }
        while (f.read_off < size and f.excluded != true) {
            const want: usize = @intCast(@min(t.buf.len, size - f.read_off));
            const n = try file.readPositionalAll(t.io, t.buf[0..want], f.read_off);
            if (n == 0) return;
            const data = t.buf[0..n];
            const last_nl = std.mem.lastIndexOfScalar(u8, data, '\n') orelse {
                if (n < t.buf.len) return;
                if (t.buf.len < t.options.max_line) {
                    const bigger = try t.gpa.alloc(u8, @min(t.buf.len * 2, t.options.max_line));
                    t.gpa.free(t.buf);
                    t.buf = bigger;
                    continue;
                }
                f.read_off += n;
                f.skip_to_newline = true;
                continue;
            };
            var pos: usize = 0;
            while (pos <= last_nl) {
                const nl = std.mem.indexOfScalarPos(u8, data, pos, '\n').?;
                const start = f.read_off + pos;
                const line = data[pos..nl];
                pos = nl + 1;
                if (f.skip_to_newline) {
                    f.skip_to_newline = false;
                    continue;
                }
                try t.feedLine(f, line, start, f.read_off + pos, now);
            }
            f.read_off += last_nl + 1;
        }
    }

    fn feedLine(t: *Tailer, f: *TailFile, line: []const u8, start: u64, end: u64, now: core.Micros) !void {
        var items: std.ArrayList(dialect.Item) = .empty;
        const before_lines = f.parser.lines;
        const before_bad = f.parser.malformed;
        try f.parser.feed(f.sink(t.scratch.allocator(), &items), line, start);
        t.stats.lines += f.parser.lines - before_lines;
        t.stats.malformed_lines += f.parser.malformed - before_bad;
        try t.absorb(f, items.items, end, now);
        _ = t.scratch.reset(.retain_capacity);
    }

    fn absorb(t: *Tailer, f: *TailFile, items: []const dialect.Item, consumed: u64, now: core.Micros) !void {
        if (items.len == 0) return;
        if (f.excluded == null) try t.decideExclusion(f);
        if (f.excluded == true) return;
        var sealed: std.ArrayList(segment.Window) = .empty;
        for (items, 0..) |item, i| {
            if (t.paused or (t.options.since != null and item.turn.ts != null and item.turn.ts.? < t.options.since.?)) {
                t.stats.dropped_turns += 1;
                continue;
            }
            sealed.clearRetainingCapacity();
            try f.segmenter.push(f.window.allocator(), item, &sealed);
            const rest = if (i + 1 < items.len) items[i + 1].start else consumed;
            try t.sealAll(f, sealed.items, rest, now);
        }
    }

    fn decideExclusion(t: *Tailer, f: *TailFile) !void {
        const keep = f.keep.allocator();
        const cwd = f.parser.meta.cwd;
        if (cwd) |dir| f.project = try project.derive(keep, t.io, dir);
        const excluded = try project.isExcluded(t.scratch.allocator(), t.io, t.config, .{
            .cwd = cwd,
            .project = f.project,
            .transcript_path = f.path,
            .home = t.options.home,
        });
        f.excluded = excluded;
        if (excluded) {
            t.stats.excluded_files += 1;
            f.parser.pending = null;
            f.segmenter.clear();
        }
    }

    fn sealAll(t: *Tailer, f: *TailFile, windows: []const segment.Window, rest: u64, now: core.Micros) !void {
        if (windows.len == 0) return;
        const arena = f.window.allocator();
        var offset = rest;
        if (f.segmenter.firstStart()) |s| offset = @min(offset, s);
        if (f.parser.pendingStart()) |s| offset = @min(offset, s);
        for (windows) |w| {
            f.seq += 1;
            if (f.head_len == 0) try t.fingerprintHead(f);
            const turns = try segment.turnsOf(arena, w);
            const c: Cursor = .{ .offset = offset, .seq = f.seq, .inode = f.inode, .head = f.head, .head_len = f.head_len };
            try f.outbox.append(arena, .{
                .source = t.sourceKey(f),
                .seq_in_source = f.seq,
                .kind = .turns,
                .project = f.project,
                .author = segment.authorOf(turns),
                .body = .{ .turns = turns },
                .reference_time = turns[0].ts orelse now,
                .cursor = try c.encode(arena),
            });
        }
        try t.drainOutbox(f);
    }

    fn fingerprintHead(t: *Tailer, f: *TailFile) !void {
        const file = Io.Dir.cwd().openFile(t.io, f.path, .{}) catch return;
        defer file.close(t.io);
        var prefix: [cursor_mod.head_len_max]u8 = undefined;
        const n = try file.readPositionalAll(t.io, &prefix, 0);
        if (n == 0) return;
        f.head = try cursor_mod.fingerprint(f.keep.allocator(), prefix[0..n]);
        f.head_len = n;
    }

    fn drainOutbox(t: *Tailer, f: *TailFile) !void {
        var sent: usize = 0;
        defer if (sent > 0) f.outbox.replaceRangeAssumeCapacity(0, sent, &.{});
        for (f.outbox.items) |*draft| {
            const outcome = t.sink.enqueue(draft) catch {
                t.stats.enqueue_errors += 1;
                return;
            };
            switch (outcome) {
                .queued => t.stats.entries += 1,
                .duplicate => t.stats.duplicates += 1,
            }
            sent += 1;
        }
    }

    fn compact(t: *Tailer, f: *TailFile) void {
        _ = t;
        if (f.outbox.items.len > 0) return;
        if (f.segmenter.isEmpty() and f.parser.pending == null) {
            f.segmenter.clear();
            f.outbox = .empty;
            _ = f.window.reset(.retain_capacity);
            return;
        }
        if (f.window.queryCapacity() < f.segmenter.options.max_tokens * 64 + (4 << 20)) return;
        var fresh: std.heap.ArenaAllocator = .init(f.window.child_allocator);
        f.segmenter.rehome(fresh.allocator()) catch {
            fresh.deinit();
            return;
        };
        f.parser.rehome(fresh.allocator()) catch {
            fresh.deinit();
            return;
        };
        f.outbox = .empty;
        f.window.deinit();
        f.window = fresh;
    }
};

const testing = std.testing;

pub const FakeSink = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Recorded) = .empty,
    cursors: std.StringHashMapUnmanaged([]const u8) = .empty,
    hashes: std.AutoHashMapUnmanaged([32]u8, void) = .empty,
    failing: bool = false,

    pub const Recorded = struct {
        body: []const u8,
        seq: i32,
        project: ?[]const u8,
        author: core.types.Author,
        reference_time: core.Micros,
        cursor: []const u8,
        turns: usize,
    };

    pub fn init(gpa: Allocator) FakeSink {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(s: *FakeSink) void {
        s.arena.deinit();
    }

    pub fn entrySink(s: *FakeSink) core.EntrySink {
        return .{ .ptr = s, .vtable = &.{ .enqueue = enqueue, .loadCursor = loadCursor } };
    }

    fn enqueue(ptr: *anyopaque, draft: *const core.EntryDraft) anyerror!core.EntrySink.Outcome {
        const s: *FakeSink = @ptrCast(@alignCast(ptr));
        if (s.failing) return error.SinkUnavailable;
        const a = s.arena.allocator();
        const source = draft.source.?;
        try s.cursors.put(a, try a.dupe(u8, source.external_id), try a.dupe(u8, draft.cursor.?));
        const hash = try segment.contentHash(a, draft.body);
        const seen = try s.hashes.getOrPut(a, hash);
        if (seen.found_existing) return .duplicate;
        try s.entries.append(a, .{
            .body = try segment.canonicalBody(a, draft.body),
            .seq = draft.seq_in_source,
            .project = if (draft.project) |p| try a.dupe(u8, p) else null,
            .author = draft.author,
            .reference_time = draft.reference_time,
            .cursor = try a.dupe(u8, draft.cursor.?),
            .turns = draft.body.turns.len,
        });
        return .{ .queued = core.Id.nil };
    }

    fn loadCursor(ptr: *anyopaque, arena: Allocator, source: *const core.SourceKey) anyerror!?[]const u8 {
        const s: *FakeSink = @ptrCast(@alignCast(ptr));
        const c = s.cursors.get(source.external_id) orelse return null;
        return try arena.dupe(u8, c);
    }
};

const t0: core.Micros = 1_795_194_000_000_000;
const sec = std.time.us_per_s;
const claude_fixture = @embedFile("testdata/claude-code/session.jsonl");

fn fixtureLines(from: usize, to: usize) []const u8 {
    var start: usize = 0;
    var line: usize = 0;
    var i: usize = 0;
    while (i < claude_fixture.len) : (i += 1) {
        if (line == from and (i == 0 or claude_fixture[i - 1] == '\n')) start = i;
        if (claude_fixture[i] == '\n') {
            line += 1;
            if (line == to) return claude_fixture[start .. i + 1];
        }
    }
    return claude_fixture[start..];
}

const Harness = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    path: []const u8,
    arena: std.heap.ArenaAllocator,
    config: core.Config = .{},

    fn init() !Harness {
        var h: Harness = .{ .tmp = std.testing.tmpDir(.{}), .root = "", .path = "", .arena = .init(testing.allocator) };
        const a = h.arena.allocator();
        try h.tmp.dir.createDirPath(testing.io, "proj");
        h.root = try h.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        h.path = try std.fs.path.join(a, &.{ h.root, "proj", "session.jsonl" });
        return h;
    }

    fn deinit(h: *Harness) void {
        h.arena.deinit();
        h.tmp.cleanup();
    }

    fn write(h: *Harness, data: []const u8) !void {
        try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/session.jsonl", .data = data });
    }

    fn append(h: *Harness, data: []const u8) !void {
        const file = try h.tmp.dir.openFile(testing.io, "proj/session.jsonl", .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, data, try file.length(testing.io));
    }

    fn tailer(h: *Harness, sink: *FakeSink, options: Options) Tailer {
        return .init(testing.allocator, testing.io, .@"claude-code", h.root, sink.entrySink(), &h.config, options);
    }
};

test "tails a transcript, seals on idle, and resumes from the stored cursor" {
    var h: Harness = try .init();
    defer h.deinit();
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();

    try h.write(fixtureLines(0, 8));
    var t = h.tailer(&sink, .{});
    try t.scan(t0 + 30 * sec);
    try testing.expectEqual(@as(usize, 0), sink.entries.items.len);
    try t.tick(t0 + 3 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    try testing.expectEqual(@as(usize, 3), sink.entries.items[0].turns);
    try testing.expectEqual(core.types.Author.mixed, sink.entries.items[0].author);
    try testing.expectEqual(t0, sink.entries.items[0].reference_time);
    try testing.expectEqual(@as(i32, 1), sink.entries.items[0].seq);
    try testing.expect(std.mem.indexOf(u8, sink.entries.items[0].body, "HIDDEN-THOUGHT") == null);

    try h.append(fixtureLines(8, 100));
    try t.scan(t0 + 150 * sec);
    try t.tick(t0 + 10 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 2), sink.entries.items.len);
    try testing.expectEqual(@as(usize, 2), sink.entries.items[1].turns);
    try testing.expectEqual(@as(i32, 2), sink.entries.items[1].seq);
    try testing.expectEqual(@as(u64, 1), t.stats.malformed_lines);
    t.deinit();

    var restarted = h.tailer(&sink, .{});
    defer restarted.deinit();
    try restarted.scan(t0 + 11 * std.time.us_per_min);
    try restarted.tick(t0 + 20 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 2), sink.entries.items.len);
    try testing.expectEqual(@as(u64, 0), restarted.stats.lines);

    try h.append("{\"type\":\"user\",\"cwd\":\"/home/dev/acme/widget\",\"message\":{\"role\":\"user\",\"content\":\"One more thing: the staging database is on port 5433.\"},\"timestamp\":\"2026-11-20T17:30:00.000Z\"}\n");
    try restarted.scan(t0 + 30 * std.time.us_per_min);
    try restarted.tick(t0 + 40 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 3), sink.entries.items.len);
    try testing.expectEqual(@as(i32, 3), sink.entries.items[2].seq);
    try testing.expectEqual(core.types.Author.user, sink.entries.items[2].author);
}

test "a crash before sealing re-reads the open window and yields the same entries" {
    var h: Harness = try .init();
    defer h.deinit();
    try h.write(claude_fixture);

    var straight: FakeSink = .init(testing.allocator);
    defer straight.deinit();
    {
        var t = h.tailer(&straight, .{});
        defer t.deinit();
        try t.scan(t0 + 3 * std.time.us_per_min);
        try t.tick(t0 + 10 * std.time.us_per_min);
    }

    var crashy: FakeSink = .init(testing.allocator);
    defer crashy.deinit();
    {
        var t = h.tailer(&crashy, .{});
        defer t.deinit();
        try t.scan(t0 + 3 * std.time.us_per_min);
        try testing.expectEqual(@as(usize, 0), crashy.entries.items.len);
    }
    {
        var t = h.tailer(&crashy, .{});
        defer t.deinit();
        try t.scan(t0 + 3 * std.time.us_per_min);
        try t.tick(t0 + 10 * std.time.us_per_min);
    }
    try testing.expectEqual(straight.entries.items.len, crashy.entries.items.len);
    for (straight.entries.items, crashy.entries.items) |a, b| try testing.expectEqualStrings(a.body, b.body);
}

test "losing every cursor makes a full re-tail a no-op" {
    var h: Harness = try .init();
    defer h.deinit();
    try h.write(claude_fixture);
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();
    {
        var t = h.tailer(&sink, .{});
        defer t.deinit();
        try t.scan(t0 + 3 * std.time.us_per_min);
        try t.tick(t0 + 10 * std.time.us_per_min);
    }
    const before = sink.entries.items.len;
    try testing.expect(before > 0);
    sink.cursors = .empty;
    var t = h.tailer(&sink, .{});
    defer t.deinit();
    try t.scan(t0 + 3 * std.time.us_per_min);
    try t.tick(t0 + 10 * std.time.us_per_min);
    try testing.expectEqual(before, sink.entries.items.len);
    try testing.expectEqual(@as(u64, before), t.stats.duplicates);
}

test "partial lines wait for their newline" {
    var h: Harness = try .init();
    defer h.deinit();
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();
    const line = fixtureLines(1, 2);
    try h.write(line[0 .. line.len / 2]);
    var t = h.tailer(&sink, .{});
    defer t.deinit();
    try t.scan(t0);
    try testing.expectEqual(@as(u64, 0), t.stats.lines);
    try h.append(line[line.len / 2 ..]);
    try t.scan(t0);
    try testing.expectEqual(@as(u64, 1), t.stats.lines);
    try testing.expectEqual(@as(u64, 0), t.stats.malformed_lines);
}

test "truncation and rotation restart the file from the top" {
    var h: Harness = try .init();
    defer h.deinit();
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();
    try h.write(claude_fixture);
    var t = h.tailer(&sink, .{});
    defer t.deinit();
    try t.scan(t0 + 3 * std.time.us_per_min);
    try t.tick(t0 + 10 * std.time.us_per_min);
    const first = sink.entries.items.len;

    const fresh = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Truncated and started over.\"},\"timestamp\":\"2026-11-20T18:00:00.000Z\"}\n";
    try h.write(fresh);
    try t.scan(t0 + 61 * std.time.us_per_min);
    try t.tick(t0 + 70 * std.time.us_per_min);
    try testing.expectEqual(first + 1, sink.entries.items.len);
    try testing.expectEqual(@as(u64, 1), t.stats.resets);
    try testing.expect(std.mem.indexOf(u8, sink.entries.items[first].body, "Truncated and started over.") != null);

    try h.tmp.dir.rename("proj/session.jsonl", h.tmp.dir, "proj/session.jsonl.1", testing.io);
    try h.write("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"A rotated file with a much longer first line than before.\"},\"timestamp\":\"2026-11-20T19:00:00.000Z\"}\n");
    try t.scan(t0 + 121 * std.time.us_per_min);
    try t.tick(t0 + 130 * std.time.us_per_min);
    try testing.expectEqual(first + 2, sink.entries.items.len);
    try testing.expectEqual(@as(u64, 2), t.stats.resets);
    try testing.expectEqual(@as(i32, @intCast(first + 2)), sink.entries.items[first + 1].seq);
}

test "a cursor from a replaced file is not trusted" {
    var h: Harness = try .init();
    defer h.deinit();
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();
    try h.write(claude_fixture);
    {
        var t = h.tailer(&sink, .{});
        defer t.deinit();
        try t.scan(t0 + 3 * std.time.us_per_min);
        try t.tick(t0 + 10 * std.time.us_per_min);
    }
    try h.tmp.dir.deleteFile(testing.io, "proj/session.jsonl");
    var replacement: std.ArrayList(u8) = .empty;
    defer replacement.deinit(testing.allocator);
    for (0..40) |i| try replacement.print(testing.allocator, "{{\"type\":\"user\",\"message\":{{\"role\":\"user\",\"content\":\"replacement line {d}\"}},\"timestamp\":\"2026-11-21T08:00:{d:0>2}.000Z\"}}\n", .{ i, i });
    try h.write(replacement.items);
    var t = h.tailer(&sink, .{});
    defer t.deinit();
    try t.scan(t0 + 16 * std.time.us_per_hour);
    try t.tick(t0 + 17 * std.time.us_per_hour);
    try testing.expectEqual(@as(u64, 1), t.stats.resets);
    try testing.expect(std.mem.indexOf(u8, sink.entries.items[sink.entries.items.len - 1].body, "replacement line 39") != null);
    try testing.expect(std.mem.indexOf(u8, sink.entries.items[sink.entries.items.len - 1].body, "replacement line 0\"") != null or
        std.mem.indexOf(u8, sink.entries.items[sink.entries.items.len - 2].body, "replacement line 0\"") != null);
}

test "turns before the capture epoch and while paused are dropped" {
    var h: Harness = try .init();
    defer h.deinit();
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();
    try h.write(claude_fixture);
    var t = h.tailer(&sink, .{ .since = t0 + 30 * sec });
    defer t.deinit();
    try t.scan(t0 + 3 * std.time.us_per_min);
    try t.tick(t0 + 10 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    try testing.expectEqual(@as(usize, 1), sink.entries.items[0].turns);
    try testing.expectEqual(@as(u64, 4), t.stats.dropped_turns);

    t.paused = true;
    try h.append("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"private while paused\"},\"timestamp\":\"2026-11-20T17:20:00.000Z\"}\n");
    try t.scan(t0 + 21 * std.time.us_per_min);
    try t.tick(t0 + 30 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    try testing.expectEqual(@as(u64, 5), t.stats.dropped_turns);
}

test "a failing sink keeps sealed entries until it recovers" {
    var h: Harness = try .init();
    defer h.deinit();
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();
    try h.write(claude_fixture);
    sink.failing = true;
    var t = h.tailer(&sink, .{});
    defer t.deinit();
    try t.scan(t0 + 3 * std.time.us_per_min);
    try t.tick(t0 + 10 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 0), sink.entries.items.len);
    try testing.expect(t.stats.enqueue_errors > 0);
    sink.failing = false;
    try t.tick(t0 + 11 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 1), sink.entries.items.len);
}

test "a hook flush seals a complete exchange without waiting for idle" {
    var h: Harness = try .init();
    defer h.deinit();
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();
    try h.write(fixtureLines(0, 9));
    var t = h.tailer(&sink, .{});
    defer t.deinit();
    try testing.expect(try t.flush(h.path, t0 + 26 * sec));
    try testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    try testing.expectEqual(@as(usize, 4), sink.entries.items[0].turns);
    try testing.expect(!try t.flush("/elsewhere/x.jsonl", t0));
}

test "files untouched since the capture epoch are skipped until they grow" {
    var h: Harness = try .init();
    defer h.deinit();
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();
    try h.write(claude_fixture);
    {
        const file = try h.tmp.dir.openFile(testing.io, "proj/session.jsonl", .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, t0) * std.time.ns_per_us) } });
    }
    const since = t0 + std.time.us_per_day;
    var t = h.tailer(&sink, .{ .since = since });
    defer t.deinit();
    try t.scan(since);
    try testing.expectEqual(@as(u64, 0), t.stats.lines);
    try h.append("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Resumed a day later.\"},\"timestamp\":\"2026-11-21T18:00:00.000Z\"}\n");
    try t.scan(since + std.time.us_per_hour);
    try t.tick(since + 2 * std.time.us_per_hour);
    try testing.expectEqual(@as(u64, 1), t.stats.lines);
    try testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    try testing.expect(std.mem.indexOf(u8, sink.entries.items[0].body, "Resumed a day later.") != null);
}

test "excluded projects and paths are never read into entries" {
    var h: Harness = try .init();
    defer h.deinit();
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();
    try h.write(claude_fixture);
    h.config.capture.exclude_paths = &.{"/home/dev/acme"};
    var t = h.tailer(&sink, .{});
    defer t.deinit();
    try t.scan(t0 + 3 * std.time.us_per_min);
    try t.tick(t0 + 10 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 0), sink.entries.items.len);
    try testing.expectEqual(@as(usize, 1), t.stats.excluded_files);

    h.config.capture.exclude_paths = &.{};
    h.config.capture.exclude_projects = &.{"/home/dev/acme/*"};
    var again = h.tailer(&sink, .{});
    defer again.deinit();
    try again.scan(t0 + 3 * std.time.us_per_min);
    try again.tick(t0 + 10 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 0), sink.entries.items.len);
}

test "secrets never reach an entry from any part of a turn" {
    var h: Harness = try .init();
    defer h.deinit();
    var sink: FakeSink = .init(testing.allocator);
    defer sink.deinit();
    const a = h.arena.allocator();
    const gateway_key = try std.mem.concat(a, u8, &.{ "ak_live_", "Q7xV2mK9pL4rT8wZ", "3nB6cD1fH5jN0sY2" });
    const model_key = try std.mem.concat(a, u8, &.{ "sk-" ++ "ant-api03-", "Zr4Tq9LmXw2Vb7Nc", "K1pS8dF3gH6jY0uE", "5aWq-RtYu_Io9Pz" });
    const token = try std.mem.concat(a, u8, &.{ "gh" ++ "p_", "a1B2c3D4e5F6g7H8", "i9J0k1L2m3N4o5P6q7R8" });
    const transcript = try std.fmt.allocPrint(a,
        \\{{"type":"user","cwd":"/home/dev/acme/widget","message":{{"role":"user","content":"Try hitting the gateway with ACME_GATEWAY_API_KEY={s} and verify https://gateway.example.test/v1 responds."}},"timestamp":"2026-11-20T17:00:00.000Z"}}
        \\{{"type":"assistant","message":{{"content":[{{"type":"tool_use","id":"t1","name":"Bash","input":{{"command":"curl -H 'Authorization: Bearer {s}' https://gateway.example.test/v1/models"}}}}]}},"timestamp":"2026-11-20T17:00:02.000Z"}}
        \\{{"type":"user","message":{{"content":[{{"type":"tool_result","tool_use_id":"t1","content":"GITHUB_TOKEN={s}\nok"}}]}},"timestamp":"2026-11-20T17:00:03.000Z"}}
        \\{{"type":"assistant","message":{{"content":[{{"type":"text","text":"The gateway answered 200 OK."}}]}},"timestamp":"2026-11-20T17:00:04.000Z"}}
        \\
    , .{ gateway_key, model_key, token });
    try h.write(transcript);
    var t = h.tailer(&sink, .{});
    defer t.deinit();
    try t.scan(t0 + std.time.us_per_min);
    try t.tick(t0 + 10 * std.time.us_per_min);
    try testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    const body = sink.entries.items[0].body;
    for ([_][]const u8{ gateway_key, model_key, token, "Q7xV2mK9pL4rT8wZ", "K1pS8dF3gH6jY0uE", "i9J0k1L2m3N4o5P6" }) |secret| {
        try testing.expect(std.mem.indexOf(u8, body, secret) == null);
    }
    try testing.expect(std.mem.indexOf(u8, body, "https://gateway.example.test/v1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "[REDACTED:") != null);
}
