const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");
const ingest = @import("ingest");
const retrieve = @import("retrieve");
const mod = @import("mod.zig");
const fixtures = @import("fixtures.zig");
const score = @import("score.zig");
const pgload = @import("pgload.zig");
const time = @import("time.zig");

const Allocator = std.mem.Allocator;

pub const RunOptions = struct {
    suite_dir: []const u8 = "evals",
    graph: ?[]const u8 = null,
    serve_bin: ?[]const u8 = null,
    environ: ?*const std.process.Environ.Map = null,
    crash_entry: []const u8 = "e06",
    entry_timeout_ms: u32 = 300_000,
    poll_ms: u32 = 50,
    worker: []const u8 = "graf-eval",
};

pub fn toDraft(ep: mod.EvalEntry) !core.EntryDraft {
    return .{
        .source = .{
            .harness = ep.harness,
            .external_id = ep.source_id,
            .project = ep.project,
            .agent = ep.agent,
            .model = ep.model,
        },
        .seq_in_source = @intCast(ep.seq),
        .kind = ep.kind,
        .project = ep.project,
        .author = ep.author,
        .body = .{ .turns = ep.turns },
        .reference_time = try time.parseRfc3339(ep.reference_time),
    };
}

fn isTerminal(s: core.types.EntryStatus) bool {
    return switch (s) {
        .committed, .skipped, .dead, .split => true,
        else => false,
    };
}

fn nowMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn sleepMs(io: std.Io, ms: u32) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

const Notes = struct {
    arena: Allocator,
    list: std.ArrayList([]const u8) = .empty,

    fn add(n: *Notes, comptime fmt: []const u8, args: anytype) !void {
        try n.list.append(n.arena, try std.fmt.allocPrint(n.arena, fmt, args));
    }
};

const Drive = enum { finished, unavailable, timed_out };

fn drive(io: std.Io, s: *store.Store, pipeline: *ingest.Pipeline, graph_id: core.Id, id: core.Id, opts: RunOptions, notes: *Notes, eval_id: []const u8) !Drive {
    const deadline = nowMs(io) + opts.entry_timeout_ms;
    while (true) {
        const status = (try pgload.entryStatus(s.pool, id)) orelse return error.EntryMissing;
        if (isTerminal(status)) return .finished;
        if (nowMs(io) > deadline) {
            try notes.add("ingest: {s} still {s} after {d} ms", .{ eval_id, @tagName(status), opts.entry_timeout_ms });
            return .timed_out;
        }
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const claimed = s.claim(scratch.allocator(), graph_id, opts.worker) catch |err| {
            if (err == error.NotImplemented) return .unavailable;
            return err;
        };
        const lease = claimed orelse {
            sleepMs(io, opts.poll_ms);
            continue;
        };
        _ = pipeline.process(scratch.allocator(), lease) catch |err| {
            if (err == error.NotImplemented) return .unavailable;
            try notes.add("ingest: an attempt during {s} failed: {s}", .{ eval_id, @errorName(err) });
        };
    }
}

pub fn run(arena: Allocator, io: std.Io, config: *const core.Config, opts: RunOptions) !score.Report {
    const suite = try fixtures.loadSuite(arena, io, opts.suite_dir);
    if ((try fixtures.validate(arena, &suite)).len > 0) return error.InvalidSuite;
    if (config.database.url.len == 0) return error.NoDatabase;

    var notes: Notes = .{ .arena = arena };
    const graph = opts.graph orelse try std.fmt.allocPrint(arena, "eval-{d}", .{@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms)});

    var s = try store.Store.open(io, arena, config.database.url, .{});
    defer s.close();
    _ = try s.migrate();

    const graph_id = s.ensureGraph(graph) catch |err| {
        if (err != error.NotImplemented) return err;
        try notes.add("store: creating graphs is not implemented yet; nothing was replayed", .{});
        return finish(arena, &suite, &.{}, graph, &notes);
    };

    var client = llm.Client.init(arena, io, config, s.ledger());
    client.graph_id = graph_id;
    defer client.deinit();
    var pipeline: ingest.Pipeline = .{ .store = &s, .client = &client, .config = config, .graph_id = graph_id };

    var links: std.ArrayList(pgload.EntryLink) = .empty;
    var ingesting = true;
    var enqueued = true;
    for (suite.entries) |ep| {
        const draft = try toDraft(ep);
        const outcome = s.enqueue(graph_id, &draft) catch |err| {
            if (err != error.NotImplemented) return err;
            try notes.add("store: enqueue is not implemented yet; nothing was replayed", .{});
            enqueued = false;
            break;
        };
        const id = switch (outcome) {
            .queued => |id| id,
            .duplicate => {
                try notes.add("replay: {s} was a duplicate of an earlier entry", .{ep.id});
                continue;
            },
        };
        try links.append(arena, .{ .eval_id = ep.id, .id = id });
        if (!ingesting) continue;
        switch (try drive(io, &s, &pipeline, graph_id, id, opts, &notes, ep.id)) {
            .finished, .timed_out => {},
            .unavailable => {
                ingesting = false;
                try notes.add("ingest: the pipeline is not implemented yet; entries stay queued", .{});
            },
        }
    }

    var state: score.GraphState = if (enqueued)
        try pgload.loadGraphState(arena, s.pool, graph_id, links.items)
    else
        .{};

    if (ingesting and enqueued) {
        var engine: retrieve.Engine = .{ .store = &s, .client = &client, .config = config, .graph_id = graph_id };
        state.retrieval = try runQueries(arena, &engine, &suite, &notes);
    } else try notes.add("retrieval: skipped because ingestion did not run", .{});

    state.crash_resume = try crashResume(arena, io, &s, config, opts, &suite, graph, &notes);
    return finish(arena, &suite, &state, graph, &notes);
}

fn finish(arena: Allocator, suite: *const fixtures.Suite, state: *const score.GraphState, graph: []const u8, notes: *Notes) !score.Report {
    var report = try score.scoreState(arena, suite, state);
    report.graph = graph;
    report.findings = try std.mem.concat(arena, []const u8, &.{ notes.list.items, report.findings });
    return report;
}

fn runQueries(arena: Allocator, engine: *retrieve.Engine, suite: *const fixtures.Suite, notes: *Notes) !?[]const score.QueryResult {
    var results: std.ArrayList(score.QueryResult) = .empty;
    for (suite.expected.retrieval_queries) |q| {
        const params: retrieve.SearchParams = .{
            .query = q.query,
            .project = q.project,
            .as_of = if (q.as_of) |v| try time.parseRfc3339(v) else null,
            .max_tokens = 1500,
        };
        const found = engine.search(arena, params) catch |err| {
            if (err == error.NotImplemented) {
                try notes.add("retrieval: search is not implemented yet", .{});
                return null;
            }
            try notes.add("retrieval: {s} failed: {s}", .{ q.id, @errorName(err) });
            try results.append(arena, .{ .query = q.id });
            continue;
        };
        const hits = try arena.alloc(score.Hit, found.hits.len);
        for (found.hits, hits) |h, *out| {
            var buf: [36]u8 = undefined;
            out.* = .{ .fact = try arena.dupe(u8, h.fact.id.toString(&buf)), .text = h.fact.text };
        }
        try results.append(arena, .{ .query = q.id, .hits = hits });
    }
    return results.items;
}

fn serveEnv(arena: Allocator, config: *const core.Config, opts: RunOptions, graph: []const u8) !std.process.Environ.Map {
    var env = if (opts.environ) |e| try e.clone(arena) else std.process.Environ.Map.init(arena);
    try env.put("GRAF_GRAPH", graph);
    try env.put("GRAF_DATABASE_URL", config.database.url);
    return env;
}

fn spawnServe(io: std.Io, bin: []const u8, env: *const std.process.Environ.Map) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ bin, "serve" },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn stop(io: std.Io, child: *std.process.Child, hard: bool) void {
    if (hard) {
        if (child.id) |pid| std.posix.kill(pid, .KILL) catch {};
        _ = child.wait(io) catch {};
    } else child.kill(io);
}

fn crashResume(arena: Allocator, io: std.Io, s: *store.Store, config: *const core.Config, opts: RunOptions, suite: *const fixtures.Suite, base_graph: []const u8, notes: *Notes) !?score.CrashResume {
    const bin = opts.serve_bin orelse {
        try notes.add("crash-resume: no serve binary given (--serve-bin); unmeasured", .{});
        return null;
    };
    const index = suite.entryIndex(opts.crash_entry) orelse {
        try notes.add("crash-resume: unknown entry {s}", .{opts.crash_entry});
        return null;
    };
    const ep = suite.entries[index];
    const graph = try std.fmt.allocPrint(arena, "{s}-crash", .{base_graph});
    const graph_id = s.ensureGraph(graph) catch |err| {
        if (err != error.NotImplemented) return err;
        try notes.add("crash-resume: creating graphs is not implemented yet; unmeasured", .{});
        return null;
    };
    const draft = try toDraft(ep);
    const outcome = s.enqueue(graph_id, &draft) catch |err| {
        if (err != error.NotImplemented) return err;
        try notes.add("crash-resume: enqueue is not implemented yet; unmeasured", .{});
        return null;
    };
    const id = switch (outcome) {
        .queued => |id| id,
        .duplicate => {
            try notes.add("crash-resume: {s} was already in {s}; unmeasured", .{ ep.id, graph });
            return null;
        },
    };

    var env = try serveEnv(arena, config, opts, graph);
    var first = try spawnServe(io, bin, &env);
    const deadline = nowMs(io) + opts.entry_timeout_ms;
    while (true) {
        const status = (try pgload.entryStatus(s.pool, id)) orelse return error.EntryMissing;
        if (status == .extracted) break;
        if (isTerminal(status) or nowMs(io) > deadline) {
            stop(io, &first, false);
            try notes.add("crash-resume: {s} reached {s} without being observed at extracted; unmeasured", .{ ep.id, @tagName(status) });
            return null;
        }
        sleepMs(io, 10);
    }
    const before = try pgload.countCalls(s.pool, id, .extract);
    stop(io, &first, true);

    var second = try spawnServe(io, bin, &env);
    defer stop(io, &second, false);
    const restart_deadline = nowMs(io) + 2 * @as(i64, opts.entry_timeout_ms);
    var final: core.types.EntryStatus = .extracted;
    while (nowMs(io) <= restart_deadline) {
        final = (try pgload.entryStatus(s.pool, id)) orelse return error.EntryMissing;
        if (isTerminal(final)) break;
        sleepMs(io, opts.poll_ms);
    }
    const after = try pgload.countCalls(s.pool, id, .extract);
    const passed = (final == .committed or final == .skipped) and after == before;
    if (!passed) try notes.add("crash-resume: {s} ended {s} with {d} extraction calls after restart", .{ ep.id, @tagName(final), after - before });
    return .{ .trials = 1, .passed = if (passed) 1 else 0 };
}

test "entries convert to drafts with their source key and reference time" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const suite = try fixtures.loadShippedSuite(arena_state.allocator(), std.testing.io);
    const draft = try toDraft(suite.entries[1]);
    try std.testing.expectEqual(core.Harness.capy, draft.source.?.harness);
    try std.testing.expectEqualStrings("capy-thread-0012", draft.source.?.external_id);
    try std.testing.expectEqualStrings("github.com/tidewright/brinelog", draft.project.?);
    try std.testing.expectEqual(@as(i32, 1), draft.seq_in_source);
    try std.testing.expectEqual(try time.parseRfc3339("2026-11-19T20:15:00Z"), draft.reference_time);
    try std.testing.expectEqual(@as(usize, 2), draft.body.turns.len);
}

test "a run against unbuilt pipeline pieces reports unmeasured gates instead of failing" {
    const url = store.testing.databaseUrl() orelse return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const config: core.Config = .{ .database = .{ .url = url } };
    var name_buf: [36]u8 = undefined;
    const graph = try std.fmt.allocPrint(arena, "eval-run-{s}", .{core.Id.v7(std.testing.io).toString(&name_buf)});
    const report = try run(arena, std.testing.io, &config, .{ .graph = graph, .suite_dir = try fixtures.shippedSuiteDir(arena, std.testing.io) });
    try std.testing.expect(!report.metrics.passes());
    try std.testing.expect(report.metrics.crash_resume_pass_rate == null);
    try std.testing.expect(report.findings.len > 0);
}
