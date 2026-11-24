const std = @import("std");
const core = @import("core");
const store = @import("store");
const capture = @import("capture");
const Upstream = @import("upstream.zig").Upstream;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const Writer = Io.Writer;

const log = std.log.scoped(.backfill);

pub const local_harnesses = [_]core.Harness{ .@"claude-code", .codex, .pi, .fx };

pub const Plan = struct {
    harnesses: std.EnumSet(core.Harness) = .empty,
    since: ?core.Micros = null,
    dry_run: bool = false,
    max_entries: ?u64 = null,
    cap_usd: ?f64 = null,
};

pub const Defaults = struct {
    edge: bool,
    capy: bool,
    capy_key: bool,
};

pub const ParseError = error{
    UnknownFlag,
    MissingFlagValue,
    UnknownHarness,
    InvalidSince,
    InvalidNumber,
    CapyNotConfigured,
    UnexpectedArgument,
};

pub fn parse(rest: []const []const u8, now: core.Micros, defaults: Defaults) ParseError!Plan {
    var plan: Plan = .{};
    var all = false;
    var i: usize = 0;

    while (i < rest.len) : (i += 1) {
        const flag = rest[i];
        if (std.mem.eql(u8, flag, "--dry-run")) {
            plan.dry_run = true;
            continue;
        }

        if (!std.mem.startsWith(u8, flag, "--")) return error.UnexpectedArgument;
        if (!isValueFlag(flag)) return error.UnknownFlag;
        if (i + 1 >= rest.len) return error.MissingFlagValue;
        const value = rest[i + 1];
        i += 1;

        if (std.mem.eql(u8, flag, "--harness")) {
            var it = std.mem.tokenizeAny(u8, value, ", ");
            while (it.next()) |name| {
                if (std.mem.eql(u8, name, "all")) {
                    all = true;
                    continue;
                }

                const h = std.meta.stringToEnum(core.Harness, name) orelse return error.UnknownHarness;
                if (h != .capy and std.mem.indexOfScalar(core.Harness, &local_harnesses, h) == null) return error.UnknownHarness;
                plan.harnesses.insert(h);
            }
        } else if (std.mem.eql(u8, flag, "--since")) {
            plan.since = try parseSince(value, now);
        } else if (std.mem.eql(u8, flag, "--max-entries")) {
            plan.max_entries = std.fmt.parseInt(u64, value, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, flag, "--cap-usd")) {
            const usd = std.fmt.parseFloat(f64, std.mem.trimStart(u8, value, "$")) catch return error.InvalidNumber;
            if (!(usd >= 0) or !std.math.isFinite(usd)) return error.InvalidNumber;
            plan.cap_usd = usd;
        }
    }

    if (all or plan.harnesses.count() == 0) {
        for (local_harnesses) |h| plan.harnesses.insert(h);
        if (defaults.capy_key and (all or (defaults.capy and !defaults.edge))) plan.harnesses.insert(.capy);
    }

    if (plan.harnesses.contains(.capy) and !defaults.capy_key) return error.CapyNotConfigured;
    return plan;
}

fn isValueFlag(flag: []const u8) bool {
    for ([_][]const u8{ "--harness", "--since", "--max-entries", "--cap-usd", "--upstream" }) |f| if (std.mem.eql(u8, f, flag)) return true;
    return false;
}

pub fn parseSince(text: []const u8, now: core.Micros) ParseError!core.Micros {
    if (text.len >= 2) {
        const unit: ?core.Micros = switch (text[text.len - 1]) {
            'h' => std.time.us_per_hour,
            'd' => std.time.us_per_day,
            'w' => std.time.us_per_week,
            else => null,
        };
        if (unit) |u| if (std.fmt.parseInt(u32, text[0 .. text.len - 1], 10)) |n| return now - @as(core.Micros, n) * u else |_| {};
    }

    return core.time.parseIso(text) catch error.InvalidSince;
}

pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownFlag => "unknown flag",
        error.MissingFlagValue => "a flag is missing its value",
        error.UnknownHarness => "--harness takes claude-code, codex, pi, fx, capy or all",
        error.InvalidSince => "--since takes a date like 2026-01-31, a timestamp, or an age like 12h, 30d, 8w",
        error.InvalidNumber => "--max-entries takes a whole number and --cap-usd a dollar amount",
        error.CapyNotConfigured => "the capy harness needs sources.capy.api_key or GRAF_CAPY_API_KEY",
        error.UnexpectedArgument => "backfill takes no positional arguments",
        else => @errorName(err),
    };
}

pub const Hub = struct {
    store: *store.Store,
    graph_id: ?core.Id,
};

pub const Target = union(enum) {
    hub: Hub,
    edge: *Upstream,
    offline,
};

pub const Report = struct {
    stats: capture.backfill.Stats,
    plan: Plan,
    mode: enum { hub, edge },
    until: core.Micros,
    entry_usd: f64,
    measured_cost: bool,
    dedup_checked: bool,
};

pub fn run(gpa: Allocator, io: Io, env: *const Environ.Map, config: *const core.Config, plan: Plan, target: Target) !Report {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const now = core.time.now(io);
    const until = if (try capture.state.dir(arena, env)) |sd|
        if (plan.dry_run) try capture.state.loadCaptureSince(io, sd) orelse now else try capture.state.captureSince(io, sd, now)
    else
        now;

    var roots: std.ArrayList(capture.service.Root) = .empty;
    for (try capture.service.discoverRoots(arena, io, env)) |r| if (plan.harnesses.contains(r.harness)) try roots.append(arena, r);

    const measured: ?f64 = switch (target) {
        .hub => |h| if (h.graph_id) |g| try h.store.meanEntryCost(g) else null,
        else => null,
    };
    const entry_usd = measured orelse capture.backfill.default_entry_usd;

    var dry: DryRun = .{ .gpa = gpa, .hub = if (target == .hub) target.hub else null };
    defer dry.deinit();
    var push: Push = .{ .gpa = gpa, .io = io, .up = if (target == .edge) target.edge else undefined };

    const sink: core.EntrySink = if (plan.dry_run) dry.sink() else switch (target) {
        .hub => |h| h.store.sink(h.graph_id orelse return error.GraphNotFound),
        .edge => push.sink(),
        .offline => return error.DatabaseNotConfigured,
    };

    const stats = try capture.backfill.run(gpa, io, env, config, sink, .{
        .roots = roots.items,
        .capy = plan.harnesses.contains(.capy),
        .since = plan.since,
        .until = until,
        .now = now,
        .home = env.get("HOME"),
        .max_entries = plan.max_entries,
        .cap_usd = plan.cap_usd,
        .entry_usd = entry_usd,
    });

    return .{
        .stats = stats,
        .plan = plan,
        .mode = if (target == .edge) .edge else .hub,
        .until = until,
        .entry_usd = entry_usd,
        .measured_cost = measured != null,
        .dedup_checked = target == .hub,
    };
}

const DryRun = struct {
    gpa: Allocator,
    hub: ?Hub,
    seen: std.AutoHashMapUnmanaged([32]u8, void) = .empty,

    fn deinit(d: *DryRun) void {
        d.seen.deinit(d.gpa);
    }

    fn sink(d: *DryRun) core.EntrySink {
        return .{ .ptr = d, .vtable = &.{ .enqueue = enqueue, .loadCursor = noCursor } };
    }

    fn enqueue(ptr: *anyopaque, draft: *const core.EntryDraft) anyerror!core.EntrySink.Outcome {
        const d: *DryRun = @ptrCast(@alignCast(ptr));
        var arena_state: std.heap.ArenaAllocator = .init(d.gpa);
        defer arena_state.deinit();

        const redacted = try core.redactDraft(arena_state.allocator(), draft.*);
        const hash = try store.contentHash(arena_state.allocator(), &redacted);
        if ((try d.seen.getOrPut(d.gpa, hash)).found_existing) return .duplicate;

        if (d.hub) |h| if (h.graph_id) |g| if (try h.store.hasEntry(g, hash)) return .duplicate;
        return .{ .queued = core.Id.nil };
    }
};

fn noCursor(_: *anyopaque, _: Allocator, _: *const core.SourceKey) anyerror!?[]const u8 {
    return null;
}

const Push = struct {
    gpa: Allocator,
    io: Io,
    up: *Upstream,
    attempts: u32 = 4,
    backoff_ms: u64 = 500,

    fn sink(p: *Push) core.EntrySink {
        return .{ .ptr = p, .vtable = &.{ .enqueue = enqueue, .loadCursor = noCursor } };
    }

    fn enqueue(ptr: *anyopaque, draft: *const core.EntryDraft) anyerror!core.EntrySink.Outcome {
        const p: *Push = @ptrCast(@alignCast(ptr));
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var redacted = try core.redactDraft(arena, draft.*);
        redacted.cursor = null;
        const body = try std.json.Stringify.valueAlloc(arena, redacted, .{ .emit_null_optional_fields = false });

        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            if (attempt > 0) {
                if (attempt >= p.attempts) return error.UpstreamUnavailable;
                try p.io.sleep(.fromMilliseconds(@intCast(p.backoff_ms << @intCast(attempt - 1))), .awake);
            }

            const reply = p.up.request(arena, .POST, "/v1/entries", body) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory => |e| return e,
                else => {
                    log.info("pushing to the hub failed ({s}); retrying", .{@errorName(err)});
                    continue;
                },
            };

            if (reply.status == 429 or reply.status >= 500) continue;
            if (reply.status < 200 or reply.status >= 300) {
                log.err("the hub rejected a backfill entry with {d}: {s}", .{ reply.status, reply.body });
                return error.HubRejectedEntry;
            }

            const Ack = struct { duplicate: bool = false };
            const ack = std.json.parseFromSliceLeaky(Ack, arena, reply.body, .{ .ignore_unknown_fields = true }) catch Ack{};
            return if (ack.duplicate) .duplicate else .{ .queued = core.Id.nil };
        }
    }
};

pub fn print(r: Report, out: *Writer) !void {
    const s = r.stats;
    const verb: []const u8 = switch (r.mode) {
        .hub => if (r.plan.dry_run) "to enqueue" else "enqueued",
        .edge => if (r.plan.dry_run) "to push" else "pushed",
    };

    try out.print("graf backfill ({t}{s})\n", .{ r.mode, if (r.plan.dry_run) ", dry run: nothing written" else "" });

    try out.writeAll("  window   ");
    if (r.plan.since) |since| {
        try out.print("{f} to {f}", .{ Stamp{ .at = since }, Stamp{ .at = r.until } });
    } else try out.print("everything before {f}", .{Stamp{ .at = r.until }});
    try out.writeAll(" (live capture owns the rest)\n");

    try out.writeAll("  sources  ");
    var it = r.plan.harnesses.iterator();
    var first = true;
    while (it.next()) |h| : (first = false) try out.print("{s}{t}", .{ if (first) "" else ", ", h });
    try out.writeByte('\n');

    try out.print("  scanned  {d} files ({d} excluded)", .{ s.files, s.excluded_files });
    if (r.plan.harnesses.contains(.capy)) try out.print(", {d} capy threads ({d} excluded)", .{ s.threads, s.excluded_threads });
    try out.print(", {d} turns kept, {d} outside the window\n", .{ s.turns, s.dropped_turns });

    try out.print("  entries  {d} found: {d} {s}, ", .{ s.entries, s.queued, verb });
    if (r.mode == .edge and r.plan.dry_run) {
        try out.writeAll("the hub skips any it already has\n");
    } else if (!r.dedup_checked) {
        try out.writeAll("already-ingested entries not checked (database unreachable)\n");
    } else try out.print("{d} already ingested\n", .{s.duplicates});

    try out.print("  cost     ~${d:.2} at ${d:.4}/entry ({s})\n", .{ s.estimatedUsd(r.entry_usd), r.entry_usd, if (r.measured_cost) "this graph's recent average" else "default estimate" });

    if (s.limited) {
        const by_count = if (r.plan.max_entries) |max| s.queued >= max else false;
        try out.print("  limit    stopped at {s}; {d} entries wait for the next run\n", .{ if (by_count) "--max-entries" else "--cap-usd", s.deferred() });
    }
}

const Stamp = struct {
    at: core.Micros,

    pub fn format(st: Stamp, w: *Writer) Writer.Error!void {
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, @divFloor(st.at, std.time.us_per_s))) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
    }
};

test {
    _ = @import("backfill_test.zig");
}
