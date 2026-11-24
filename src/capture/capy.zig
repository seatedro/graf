const std = @import("std");
const core = @import("core");
const api = @import("capy_api.zig");
const sse = @import("sse.zig");
const dialect = @import("dialect.zig");
const normalize = @import("normalize.zig");
const segment = @import("segment.zig");
const project = @import("project.zig");
const state = @import("state.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

const log = std.log.scoped(.capy);

pub const Options = struct {
    since: ?core.Micros = null,
    until: ?core.Micros = null,
    backfill: bool = false,
    page_limit: u32 = 100,
    segment: segment.Options = .{},
    tick_every: Io.Duration = .fromSeconds(1),
    backoff: api.Backoff = .{},
    max_attempts: u32 = 5,
    max_reconnects: u32 = 5,
    stream_retry_ms: u64 = 2000,
};

pub const Stats = struct {
    threads: usize = 0,
    excluded_threads: usize = 0,
    messages: u64 = 0,
    dropped_turns: u64 = 0,
    entries: u64 = 0,
    duplicates: u64 = 0,
    enqueue_errors: u64 = 0,
    backoffs: u64 = 0,
    last_backoff_ms: u64 = 0,
    streams_opened: u64 = 0,
    stream_drops: u64 = 0,
};

pub const Cursor = struct {
    v: u8 = 1,
    after: ?[]const u8 = null,
    skip: u32 = 0,
    seq: i32 = 0,

    pub fn encode(c: Cursor, arena: Allocator) Allocator.Error![]const u8 {
        return std.json.Stringify.valueAlloc(arena, c, .{});
    }

    pub fn decode(arena: Allocator, text: []const u8) ?Cursor {
        const c = std.json.parseFromSliceLeaky(Cursor, arena, text, .{ .ignore_unknown_fields = true }) catch return null;
        if (c.after) |a| if (a.len == 0 or a.len > Mark.max) return null;
        return c;
    }
};

const Mark = struct {
    buf: [max]u8 = undefined,
    len: u8 = 0,
    skip: u32 = 0,

    const max = 64;

    fn at(cursor: ?[]const u8, skip: u32) error{BadResponse}!Mark {
        var m: Mark = .{ .skip = skip };
        const c = cursor orelse return m;
        if (c.len == 0) return m;
        if (c.len > max) return error.BadResponse;

        @memcpy(m.buf[0..c.len], c);
        m.len = @intCast(c.len);
        return m;
    }

    fn after(m: *const Mark) ?[]const u8 {
        return if (m.len == 0) null else m.buf[0..m.len];
    }
};

const Thread = struct {
    id: []const u8,
    keep: std.heap.ArenaAllocator,
    window: std.heap.ArenaAllocator,
    project: []const u8,
    model: ?[]const u8 = null,
    seen: u64 = 0,
    working: bool = false,
    excluded: bool = false,
    loaded: bool = false,
    busy: bool = false,
    dirty: bool = true,
    retry_at: core.Micros = 0,
    mark: Mark = .{},
    seq: i32 = 0,
    segmenter: segment.Segmenter,
    marks: std.ArrayList(Mark) = .empty,
    base: u64 = 0,
    next: u64 = 0,
    outbox: std.ArrayList(core.EntryDraft) = .empty,

    fn sourceKey(t: *const Thread) core.SourceKey {
        return .{ .harness = .capy, .external_id = t.id, .project = t.project, .agent = "capy", .model = t.model };
    }

    fn setModel(t: *Thread, model: []const u8) Allocator.Error!void {
        if (model.len == 0) return;
        if (t.model) |m| if (std.mem.eql(u8, m, model)) return;
        t.model = try t.keep.allocator().dupe(u8, model);
    }
};

pub fn turnOf(arena: Allocator, scratch: Allocator, m: api.Message) Allocator.Error!?core.Turn {
    const ts = normalize.jsonTimestamp(.{ .string = m.createdAt });

    if (std.mem.eql(u8, m.source, "tool")) {
        const calls = try arena.alloc(core.ToolCall, 1);
        calls[0] = .{
            .name = try arena.dupe(u8, m.tool orelse "tool"),
            .args_preview = try normalize.cleanBounded(arena, scratch, m.text, normalize.args_budget),
        };
        return .{ .role = .tool, .text = "", .tool_calls = calls, .ts = ts };
    }

    const role: core.types.Role = if (std.mem.eql(u8, m.source, "user"))
        .user
    else if (std.mem.eql(u8, m.source, "assistant"))
        .assistant
    else
        return null;

    const text = std.mem.trim(u8, m.text, " \t\r\n");
    if (text.len == 0) return null;
    return .{ .role = role, .text = try normalize.cleanBounded(arena, scratch, text, dialect.text_budget), .ts = ts };
}

pub fn projectOf(arena: Allocator, p: api.Project) Allocator.Error![]const u8 {
    var chosen: ?api.Repo = null;
    for (p.repos) |r| {
        if (chosen == null or (std.mem.eql(u8, r.mode, "primary") and !std.mem.eql(u8, chosen.?.mode, "primary"))) chosen = r;
    }

    if (chosen) |r| {
        const url = try std.fmt.allocPrint(arena, "https://github.com/{s}", .{r.repoFullName});
        if (try project.normalizeRemote(arena, url)) |name| return name;
    }

    return std.fmt.allocPrint(arena, "capy/{s}", .{if (p.code.len > 0) p.code else p.id});
}

fn listed(list: []const []const u8, value: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

fn globbed(patterns: []const []const u8, p: api.Project) bool {
    for (patterns) |pattern| {
        if (project.globMatch(pattern, p.id) or project.globMatch(pattern, p.code) or project.globMatch(pattern, p.name)) return true;
    }
    return false;
}

const End = union(enum) {
    settled,
    fatal,
    dropped: u64,
};

pub const Source = struct {
    gpa: Allocator,
    io: Io,
    config: *const core.Config,
    sink: core.EntrySink,
    options: Options,
    client: api.Client,
    arena: std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,
    state_dir: ?[]const u8,
    mutex: Io.Mutex = .init,
    threads: std.StringArrayHashMapUnmanaged(*Thread) = .empty,
    streams: Io.Group = .init,
    active_streams: u32 = 0,
    paused: bool = false,
    blocked_until: core.Micros = 0,
    last_discovery: ?core.Micros = null,
    stats: Stats = .{},

    pub fn init(gpa: Allocator, io: Io, env: *const Environ.Map, config: *const core.Config, sink: core.EntrySink, options: Options) !Source {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const state_dir = try state.dir(arena.allocator(), env);

        var opts = options;
        if (!opts.backfill and opts.since == null) {
            const now = Io.Timestamp.now(io, .real).toMicroseconds();
            opts.since = if (state_dir) |sd| try state.captureSince(io, sd, now) else now;
        }

        const cfg = &config.sources.capy;
        var client: api.Client = try .init(gpa, io, cfg.base_url, cfg.api_key);
        errdefer client.deinit();

        return .{
            .gpa = gpa,
            .io = io,
            .config = config,
            .sink = sink,
            .options = opts,
            .client = client,
            .arena = arena,
            .scratch = .init(gpa),
            .state_dir = state_dir,
        };
    }

    pub fn deinit(s: *Source) void {
        s.streams.cancel(s.io);

        for (s.threads.values()) |t| {
            t.marks.deinit(s.gpa);
            t.window.deinit();
            t.keep.deinit();
            s.gpa.destroy(t);
        }

        s.threads.deinit(s.gpa);
        s.client.deinit();
        s.scratch.deinit();
        s.arena.deinit();
        s.* = undefined;
    }

    pub fn run(s: *Source) Io.Cancelable!void {
        defer s.streams.cancel(s.io);
        while (true) {
            s.step(Io.Timestamp.now(s.io, .real).toMicroseconds()) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                log.warn("capy source step failed: {t}", .{err});
            };
            try s.io.sleep(s.options.tick_every, .awake);
        }
    }

    pub fn runOnce(s: *Source, now: core.Micros) !void {
        try s.refreshPaused();
        try s.discover();

        for (s.threads.values()) |t| {
            if (t.excluded) continue;
            _ = try s.catchUp(t, now);
            t.dirty = false;
        }

        try s.tickAll(now);
    }

    pub fn snapshot(s: *Source) Stats {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.stats;
    }

    fn step(s: *Source, now: core.Micros) !void {
        try s.refreshPaused();
        if (s.isBlocked(now)) return s.tickAll(now);

        const every = @as(core.Micros, s.config.sources.capy.discover_every_s) * std.time.us_per_s;
        if (s.last_discovery == null or now - s.last_discovery.? >= every) {
            s.last_discovery = now;
            s.discover() catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Unauthorized, error.Forbidden => return s.block(now, err),
                else => log.warn("capy thread discovery failed: {t}", .{err}),
            };
        }

        var i: usize = 0;
        while (s.nextDue(&i, now)) |t| {
            const settled = s.catchUp(t, now) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Unauthorized, error.Forbidden => return s.block(now, err),
                error.NotFound => {
                    t.excluded = true;
                    continue;
                },
                else => {
                    log.warn("capy catch-up for {s} failed: {t}", .{ t.id, err });
                    t.retry_at = now + @as(core.Micros, @intCast(s.options.backoff.max_ms)) * std.time.us_per_ms;
                    continue;
                },
            };

            try s.mutex.lock(s.io);
            defer s.mutex.unlock(s.io);
            t.dirty = !settled;

            if (t.working and s.active_streams < s.config.sources.capy.max_streams) {
                t.busy = true;
                s.active_streams += 1;
                s.streams.concurrent(s.io, follow, .{ s, t }) catch {
                    t.busy = false;
                    s.active_streams -= 1;
                };
            }
        }

        try s.tickAll(now);
    }

    fn nextDue(s: *Source, i: *usize, now: core.Micros) ?*Thread {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);

        const all = s.threads.values();
        while (i.* < all.len) {
            const t = all[i.*];
            i.* += 1;
            if (!t.busy and !t.excluded and t.dirty and now >= t.retry_at) return t;
        }
        return null;
    }

    fn block(s: *Source, now: core.Micros, err: anyerror) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        log.err("capy api rejected the key ({t}); retrying in {d}s", .{ err, s.options.backoff.auth_ms / std.time.ms_per_s });
        s.blocked_until = now + @as(core.Micros, @intCast(s.options.backoff.auth_ms)) * std.time.us_per_ms;
    }

    fn isBlocked(s: *Source, now: core.Micros) bool {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return now < s.blocked_until;
    }

    fn refreshPaused(s: *Source) Io.Cancelable!void {
        const paused = if (s.state_dir) |sd| try state.isPaused(s.io, sd) else false;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.paused = paused;
    }

    fn fetch(s: *Source, comptime T: type, arena: Allocator, target: []const u8) !T {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            var diag: api.Diag = .{};
            if (s.client.getJson(T, arena, target, &diag)) |value| return value else |err| {
                switch (err) {
                    error.Canceled, error.OutOfMemory, error.Unauthorized, error.Forbidden, error.NotFound, error.BadRequest => return err,
                    else => {},
                }

                if (attempt + 1 >= s.options.max_attempts) return err;
                const wait = s.options.backoff.delay(err, diag.retry_after_s, attempt);
                s.noteBackoff(wait);
                log.info("capy GET {s} failed ({t}, status {d}); retrying in {d} ms", .{ target, err, diag.status, wait });
                try s.io.sleep(.fromMilliseconds(@intCast(wait)), .awake);
            }
        }
    }

    fn noteBackoff(s: *Source, wait: u64) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.stats.backoffs += 1;
        s.stats.last_backoff_ms = wait;
    }

    fn discover(s: *Source) !void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const cfg = &s.config.sources.capy;
        const projects = try s.fetch(api.ProjectList, arena, "/projects");

        for (projects.items) |p| {
            if (cfg.projects.len > 0 and !(listed(cfg.projects, p.id) or listed(cfg.projects, p.code) or listed(cfg.projects, p.name))) continue;
            if (globbed(cfg.exclude_projects, p)) continue;

            const name = try projectOf(arena, p);
            var cursor: ?[]const u8 = null;
            while (true) {
                const page = try s.fetch(api.ThreadPage, arena, try api.threadsTarget(arena, p.id, cursor, s.options.page_limit));

                {
                    try s.mutex.lock(s.io);
                    defer s.mutex.unlock(s.io);
                    for (page.items) |th| try s.observe(name, th);
                }

                const next = page.cursor orelse break;
                if (page.items.len == 0 or (cursor != null and std.mem.eql(u8, next, cursor.?))) break;
                cursor = next;
            }
        }
    }

    fn observe(s: *Source, name: []const u8, th: api.Thread) !void {
        const cfg = &s.config.sources.capy;
        if (listed(cfg.exclude_threads, th.id)) return;
        if (cfg.statuses.len > 0 and !listed(cfg.statuses, th.status)) return;

        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(th.status);
        hasher.update(&.{0});
        hasher.update(th.updatedAt);
        hasher.update(&.{0});
        hasher.update(th.lastActivityAt orelse "");
        const seen = hasher.final();

        const t = s.threads.get(th.id) orelse blk: {
            if (s.options.since) |since| {
                const activity = normalize.jsonTimestamp(.{ .string = th.lastActivityAt orelse th.updatedAt });
                if (activity) |ts| if (ts < since) return;
            }

            const t = try s.gpa.create(Thread);
            errdefer s.gpa.destroy(t);
            t.* = .{ .id = undefined, .project = undefined, .keep = .init(s.gpa), .window = .init(s.gpa), .segmenter = .{ .options = s.options.segment } };

            const keep = t.keep.allocator();
            t.id = try keep.dupe(u8, th.id);
            t.project = try keep.dupe(u8, name);
            t.excluded = try project.isExcluded(s.scratch.allocator(), s.io, s.config, .{ .project = t.project });
            _ = s.scratch.reset(.retain_capacity);
            try s.threads.put(s.gpa, t.id, t);
            s.stats.threads += 1;
            if (t.excluded) s.stats.excluded_threads += 1;
            break :blk t;
        };

        t.working = std.mem.eql(u8, th.status, "working");
        if (th.lastModelId) |m| try t.setModel(m);
        if (t.seen != seen) {
            t.seen = seen;
            t.dirty = true;
        }
    }

    fn load(s: *Source, t: *Thread) !void {
        if (t.loaded) return;

        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        defer _ = s.scratch.reset(.retain_capacity);

        const key = t.sourceKey();
        if (try s.sink.loadCursor(s.scratch.allocator(), &key)) |text| if (Cursor.decode(s.scratch.allocator(), text)) |c| {
            t.mark = try Mark.at(c.after, c.skip);
            t.seq = c.seq;
        };
        t.loaded = true;
    }

    fn catchUp(s: *Source, t: *Thread, now: core.Micros) !bool {
        try s.load(t);

        while (true) {
            var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const from = t.mark;
            const page = try s.fetch(api.MessagePage, arena, try api.messagesTarget(arena, t.id, from.after(), s.options.page_limit));

            try s.mutex.lock(s.io);
            defer s.mutex.unlock(s.io);
            var skip = from.skip;
            for (page.items) |m| {
                if (skip > 0) {
                    skip -= 1;
                    continue;
                }
                try s.consume(t, m, null, now);
            }

            const next = page.cursor orelse return true;
            if (from.after()) |prev| if (std.mem.eql(u8, prev, next)) return false;
            t.mark = try Mark.at(next, 0);
        }
    }

    fn consume(s: *Source, t: *Thread, m: api.Message, event_id: ?[]const u8, now: core.Micros) !void {
        s.stats.messages += 1;
        const before = t.mark;
        if (event_id) |id| t.mark = try Mark.at(id, 0) else t.mark.skip += 1;

        defer _ = s.scratch.reset(.retain_capacity);
        const turn = try turnOf(t.window.allocator(), s.scratch.allocator(), m) orelse return;
        const at = turn.ts orelse now;
        const too_old = if (s.options.since) |since| at < since else false;
        const too_new = if (s.options.until) |until| at >= until else false;
        if (s.paused or too_old or too_new) {
            s.stats.dropped_turns += 1;
            return;
        }

        if (m.model) |model| try t.setModel(model);
        try t.marks.append(s.gpa, before);

        var sealed: std.ArrayList(segment.Window) = .empty;
        try t.segmenter.push(t.window.allocator(), .{ .turn = turn, .start = t.next }, &sealed);
        t.next += 1;
        try s.seal(t, sealed.items, now);
    }

    fn seal(s: *Source, t: *Thread, windows: []const segment.Window, now: core.Micros) !void {
        if (windows.len > 0) {
            const arena = t.window.allocator();
            const open: Mark = if (t.segmenter.firstStart()) |first| t.marks.items[first - t.base] else t.mark;

            for (windows, 0..) |w, i| {
                const resume_at = if (i + 1 < windows.len) t.marks.items[windows[i + 1].items[0].start - t.base] else open;
                t.seq += 1;
                const turns = try segment.turnsOf(arena, w);
                const cursor: Cursor = .{ .after = resume_at.after(), .skip = resume_at.skip, .seq = t.seq };

                try t.outbox.append(arena, .{
                    .source = t.sourceKey(),
                    .seq_in_source = t.seq,
                    .kind = .turns,
                    .project = t.project,
                    .author = segment.authorOf(turns),
                    .body = .{ .turns = turns },
                    .reference_time = turns[0].ts orelse now,
                    .cursor = try cursor.encode(arena),
                });
            }

            const keep_from = t.segmenter.firstStart() orelse t.next;
            t.marks.replaceRangeAssumeCapacity(0, @intCast(keep_from - t.base), &.{});
            t.base = keep_from;
        }

        s.drain(t);
        s.compact(t);
    }

    fn drain(s: *Source, t: *Thread) void {
        var sent: usize = 0;
        defer if (sent > 0) t.outbox.replaceRangeAssumeCapacity(0, sent, &.{});

        for (t.outbox.items) |*draft| {
            const outcome = s.sink.enqueue(draft) catch |err| {
                s.stats.enqueue_errors += 1;
                log.warn("enqueue for capy thread {s} failed: {t}", .{ t.id, err });
                return;
            };

            switch (outcome) {
                .queued => s.stats.entries += 1,
                .duplicate => s.stats.duplicates += 1,
            }
            sent += 1;
        }
    }

    fn compact(s: *Source, t: *Thread) void {
        _ = s;
        if (t.outbox.items.len > 0) return;

        if (t.segmenter.isEmpty()) {
            t.segmenter.clear();
            t.outbox = .empty;
            _ = t.window.reset(.retain_capacity);
            return;
        }

        if (t.window.queryCapacity() < t.segmenter.options.max_tokens * 64 + (4 << 20)) return;
        var fresh: std.heap.ArenaAllocator = .init(t.window.child_allocator);
        t.segmenter.rehome(fresh.allocator()) catch {
            fresh.deinit();
            return;
        };

        t.outbox = .empty;
        t.window.deinit();
        t.window = fresh;
    }

    pub fn finish(s: *Source, now: core.Micros) !void {
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);

        for (s.threads.values()) |t| {
            if (t.excluded) continue;
            var sealed: std.ArrayList(segment.Window) = .empty;
            try t.segmenter.flush(t.window.allocator(), &sealed);
            try s.seal(t, sealed.items, now);
        }
    }

    fn tickAll(s: *Source, now: core.Micros) !void {
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);

        for (s.threads.values()) |t| {
            if (t.excluded) continue;
            var sealed: std.ArrayList(segment.Window) = .empty;
            try t.segmenter.tick(t.window.allocator(), now, &sealed);
            try s.seal(t, sealed.items, now);
        }
    }

    fn follow(s: *Source, t: *Thread) Io.Cancelable!void {
        defer {
            s.mutex.lockUncancelable(s.io);
            t.busy = false;
            t.dirty = true;
            s.active_streams -= 1;
            s.mutex.unlock(s.io);
        }

        var retry_ms = s.options.stream_retry_ms;
        var drops: u32 = 0;

        while (true) {
            const end = s.followOnce(t, &retry_ms, drops) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => blk: {
                    log.info("capy stream for {s} dropped: {t}", .{ t.id, err });
                    break :blk End{ .dropped = retry_ms };
                },
            };

            const wait = switch (end) {
                .settled, .fatal => return,
                .dropped => |ms| ms,
            };

            drops += 1;
            {
                s.mutex.lockUncancelable(s.io);
                defer s.mutex.unlock(s.io);
                s.stats.stream_drops += 1;
            }

            if (drops > s.options.max_reconnects) return;
            try s.io.sleep(.fromMilliseconds(@intCast(wait)), .awake);
            _ = s.catchUp(t, Io.Timestamp.now(s.io, .real).toMicroseconds()) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    log.warn("capy catch-up for {s} after a stream drop failed: {t}", .{ t.id, err });
                    return;
                },
            };
        }
    }

    fn followOnce(s: *Source, t: *Thread, retry_ms: *u64, attempt: u32) !End {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();

        const from = t.mark;
        var diag: api.Diag = .{};
        var stream: api.Stream = undefined;
        stream.open(&s.client, arena_state.allocator(), t.id, from.after(), &diag) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Unauthorized, error.Forbidden => {
                s.block(Io.Timestamp.now(s.io, .real).toMicroseconds(), err);
                return .fatal;
            },
            error.NotFound, error.BadRequest => {
                log.warn("capy stream for {s} refused: {t}", .{ t.id, err });
                return .fatal;
            },
            else => {
                const wait = s.options.backoff.delay(err, diag.retry_after_s, attempt);
                s.noteBackoff(wait);
                return .{ .dropped = wait };
            },
        };
        defer stream.close();

        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            s.stats.streams_opened += 1;
        }

        var parser: sse.Parser = .init(s.gpa);
        defer parser.deinit();
        var frame: std.heap.ArenaAllocator = .init(s.gpa);
        defer frame.deinit();
        var skip = from.skip;

        while (try stream.nextLine()) |line| {
            const ev = try parser.feedLine(line) orelse continue;
            if (parser.retry_ms) |ms| retry_ms.* = ms;
            defer _ = frame.reset(.retain_capacity);
            const a = frame.allocator();

            if (std.mem.eql(u8, ev.name, "transcript")) {
                if (skip > 0) {
                    skip -= 1;
                    continue;
                }

                const m = try api.decode(api.Message, a, ev.data);
                try s.mutex.lock(s.io);
                defer s.mutex.unlock(s.io);
                try s.consume(t, m, ev.id, Io.Timestamp.now(s.io, .real).toMicroseconds());
            } else if (std.mem.eql(u8, ev.name, "status")) {
                const status = try api.decode(api.StatusFrame, a, ev.data);
                if (!std.mem.eql(u8, status.status, "working")) {
                    try s.mutex.lock(s.io);
                    defer s.mutex.unlock(s.io);
                    t.working = false;
                    return .settled;
                }
            } else if (std.mem.eql(u8, ev.name, "done")) {
                return .settled;
            } else if (std.mem.eql(u8, ev.name, "error")) {
                const frame_err = try api.decode(api.ErrorFrame, a, ev.data);
                if (std.mem.eql(u8, frame_err.code, "unauthorized") or std.mem.eql(u8, frame_err.code, "forbidden")) {
                    s.block(Io.Timestamp.now(s.io, .real).toMicroseconds(), error.Unauthorized);
                    return .fatal;
                }
                return .{ .dropped = retry_ms.* };
            }
        }

        return .{ .dropped = retry_ms.* };
    }
};

test {
    _ = @import("capy_test.zig");
}
