const std = @import("std");
const core = @import("core");
const store = @import("store");
const capture = @import("capture");
const api = @import("api.zig");
const http = @import("http.zig");
const backfill = @import("backfill.zig");
const Upstream = @import("upstream.zig").Upstream;

const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testdata = capture.backfill.testdata;

const day = testdata.day;
const t0 = testdata.t0;

const Home = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    base: []const u8,
    secret: []const u8,

    fn init() !Home {
        const io = testing.io;
        var h: Home = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .env = .init(testing.allocator), .base = "", .secret = "" };
        errdefer h.deinit();
        const a = h.arena.allocator();

        h.base = try h.tmp.dir.realPathFileAlloc(io, ".", a);
        h.secret = try std.mem.concat(a, u8, &.{ "gh" ++ "p_", "a1B2c3D4e5F6g7H8", "i9J0k1L2m3N4o5P6q7R8" });
        try h.env.put("HOME", try std.fs.path.join(a, &.{ h.base, "home" }));
        try h.env.put("XDG_STATE_HOME", try std.fs.path.join(a, &.{ h.base, "state" }));

        try h.tmp.dir.createDirPath(io, "home/.claude/projects/p");
        try h.tmp.dir.createDirPath(io, "state/graf");
        try h.tmp.dir.writeFile(io, .{ .sub_path = "state/graf/capture-since", .data = try std.fmt.allocPrint(a, "{d}\n", .{t0 + 10 * day}) });

        try testdata.write(io, h.tmp.dir, "home/.claude/projects/p/a.jsonl", &.{ .{ t0 + day, "Move the widget service to Postgres 17." }, .{ t0 + 3 * day, try std.fmt.allocPrint(a, "Deploy with GITHUB_TOKEN={s} today.", .{h.secret}) } });
        try testdata.write(io, h.tmp.dir, "home/.claude/projects/p/b.jsonl", &.{.{ t0 + 2 * day, "Pin the widget service to port 5433." }});
        try testdata.write(io, h.tmp.dir, "home/.claude/projects/p/live.jsonl", &.{.{ t0 + 11 * day, "Already tailed live after the capture epoch." }});
        return h;
    }

    fn deinit(h: *Home) void {
        h.env.deinit();
        h.arena.deinit();
        h.tmp.cleanup();
    }

    fn plan(dry_run: bool) backfill.Plan {
        var p: backfill.Plan = .{ .dry_run = dry_run };
        p.harnesses.insert(.@"claude-code");
        return p;
    }
};

fn count(s: *store.Store, g: core.Id, sql: []const u8) !i64 {
    var row = (try s.pool.row(sql, .{@as([]const u8, &g.bytes)})).?;
    defer row.deinit() catch {};
    return row.get(i64, 0);
}

test "hub backfill dry run writes nothing, then enqueues history once in its own lane" {
    var s = try store.testing.open();
    defer s.close();
    const g = try store.testing.freshGraph(&s);

    var h = try Home.init();
    defer h.deinit();
    const config: core.Config = .{};
    const io = testing.io;
    const target: backfill.Target = .{ .hub = .{ .store = &s, .graph_id = g } };

    const dry = try backfill.run(testing.allocator, io, &h.env, &config, Home.plan(true), target);
    try testing.expectEqual(@as(usize, 3), dry.stats.files);
    try testing.expectEqual(@as(u64, 3), dry.stats.entries);
    try testing.expectEqual(@as(u64, 6), dry.stats.turns);
    try testing.expectEqual(@as(u64, 2), dry.stats.dropped_turns);
    try testing.expectEqual(@as(u64, 3), dry.stats.queued);
    try testing.expectEqual(@as(u64, 0), dry.stats.duplicates);
    try testing.expectEqual(t0 + 10 * day, dry.until);
    try testing.expectEqual(@as(i64, 0), try count(&s, g, "SELECT count(*) FROM entry WHERE graph_id = $1"));
    try testing.expectEqual(@as(i64, 0), try count(&s, g, "SELECT count(*) FROM source WHERE graph_id = $1"));

    const real = try backfill.run(testing.allocator, io, &h.env, &config, Home.plan(false), target);
    try testing.expectEqual(@as(u64, 3), real.stats.queued);
    try testing.expectEqual(@as(i64, 3), try count(&s, g, "SELECT count(*) FROM entry WHERE graph_id = $1 AND backfill"));
    try testing.expectEqual(@as(i64, 0), try count(&s, g, "SELECT count(*) FROM source WHERE graph_id = $1 AND cursor IS NOT NULL"));
    try testing.expectEqual(@as(i64, 0), try count(&s, g, "SELECT count(*) FROM entry WHERE graph_id = $1 AND position('a1B2c3D4e5F6g7H8' IN body::text) > 0"));

    var row = (try s.pool.row(
        "SELECT min(extract(epoch FROM reference_time))::bigint, max(extract(epoch FROM reference_time))::bigint FROM entry WHERE graph_id = $1",
        .{@as([]const u8, &g.bytes)},
    )).?;
    try testing.expectEqual(@divFloor(t0 + day, std.time.us_per_s), try row.get(i64, 0));
    try testing.expectEqual(@divFloor(t0 + 3 * day, std.time.us_per_s), try row.get(i64, 1));
    try row.deinit();

    const again = try backfill.run(testing.allocator, io, &h.env, &config, Home.plan(false), target);
    try testing.expectEqual(@as(u64, 0), again.stats.queued);
    try testing.expectEqual(@as(u64, 3), again.stats.duplicates);
    try testing.expectEqual(@as(i64, 3), try count(&s, g, "SELECT count(*) FROM entry WHERE graph_id = $1"));

    const rehearsed = try backfill.run(testing.allocator, io, &h.env, &config, Home.plan(true), target);
    try testing.expectEqual(@as(u64, 0), rehearsed.stats.queued);
    try testing.expectEqual(@as(u64, 3), rehearsed.stats.duplicates);
}

test "since drops older transcripts and keeps newer ones" {
    var h = try Home.init();
    defer h.deinit();
    const config: core.Config = .{};

    var plan = Home.plan(true);
    plan.since = try backfill.parseSince("2026-11-22T12:00:00Z", 0);
    try testing.expectEqual(t0 + 2 * day - 5 * std.time.us_per_hour, plan.since.?);

    const report = try backfill.run(testing.allocator, testing.io, &h.env, &config, plan, .offline);
    try testing.expectEqual(@as(u64, 2), report.stats.queued);
    try testing.expectEqual(@as(u64, 4), report.stats.dropped_turns);
    try testing.expect(!report.dedup_checked);
}

const MockHub = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    bodies: std.ArrayList([]const u8) = .empty,
    requests: usize = 0,

    fn handler(m: *MockHub) api.Handler {
        return .{ .ptr = m, .vtable = &.{ .handle = handle } };
    }

    fn deinit(m: *MockHub) void {
        for (m.bodies.items) |b| testing.allocator.free(b);
        m.bodies.deinit(testing.allocator);
    }

    fn handle(ptr: *anyopaque, _: Allocator, req: api.Request) anyerror!api.Reply {
        const m: *MockHub = @ptrCast(@alignCast(ptr));
        try m.mutex.lock(m.io);
        defer m.mutex.unlock(m.io);

        m.requests += 1;
        if (req.op != .entries) return .{ .body = "{}" };
        for (m.bodies.items) |b| if (std.mem.eql(u8, b, req.body)) return .{ .body = "{\"duplicate\":true}" };
        try m.bodies.append(testing.allocator, try testing.allocator.dupe(u8, req.body));
        return .{ .body = "{\"id\":\"00000000-0000-7000-8000-000000000000\"}" };
    }
};

test "edge backfill pushes redacted history to the hub oldest first and dry-runs without a request" {
    const io = testing.io;
    var h = try Home.init();
    defer h.deinit();
    const config: core.Config = .{};
    const a = h.arena.allocator();

    var mock: MockHub = .{ .io = io };
    defer mock.deinit();
    var hub = http.Server.init(testing.allocator, io, mock.handler(), .{ .listen = "127.0.0.1:0", .token = "hub-token" });
    try hub.start();
    var running = try io.concurrent(http.Server.run, .{&hub});
    defer {
        hub.stop();
        running.await(io) catch {};
        hub.deinit();
    }

    var up = try Upstream.init(testing.allocator, io, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{hub.boundPort()}), "hub-token", 2000);
    defer up.deinit();

    const dry = try backfill.run(testing.allocator, io, &h.env, &config, Home.plan(true), .{ .edge = &up });
    try testing.expectEqual(@as(u64, 3), dry.stats.queued);
    try testing.expectEqual(@as(usize, 0), mock.requests);

    const pushed = try backfill.run(testing.allocator, io, &h.env, &config, Home.plan(false), .{ .edge = &up });
    try testing.expectEqual(@as(u64, 3), pushed.stats.queued);
    try testing.expectEqual(@as(usize, 3), mock.bodies.items.len);

    const want = [_]core.Micros{ t0 + day, t0 + 2 * day, t0 + 3 * day };
    for (want, mock.bodies.items) |at, body| {
        const draft = try std.json.parseFromSliceLeaky(core.EntryDraft, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        try testing.expectEqual(at, draft.reference_time);
        try testing.expect(draft.backfill);
        try testing.expect(draft.cursor == null);
        try testing.expect(std.mem.indexOf(u8, body, "a1B2c3D4e5F6g7H8") == null);
    }
    try testing.expect(std.mem.indexOf(u8, mock.bodies.items[2], "[REDACTED:") != null);

    const again = try backfill.run(testing.allocator, io, &h.env, &config, Home.plan(false), .{ .edge = &up });
    try testing.expectEqual(@as(u64, 3), again.stats.duplicates);
    try testing.expectEqual(@as(usize, 3), mock.bodies.items.len);

    const spool = try std.fs.path.join(a, &.{ h.base, "state", "graf", "edge", "spool.jsonl" });
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, spool, .{}));
}

test "plans parse harness lists, ages and limits" {
    const now = t0;
    const edge = try backfill.parse(&.{ "--harness", "codex,pi", "--harness", "fx", "--since", "30d", "--max-entries", "500", "--cap-usd", "$12.50", "--dry-run" }, now, .{ .edge = true, .capy = true, .capy_key = true });
    try testing.expect(edge.dry_run);
    try testing.expectEqual(@as(usize, 3), edge.harnesses.count());
    try testing.expect(!edge.harnesses.contains(.@"claude-code"));
    try testing.expectEqual(now - 30 * day, edge.since.?);
    try testing.expectEqual(@as(u64, 500), edge.max_entries.?);
    try testing.expectEqual(@as(f64, 12.5), edge.cap_usd.?);

    const hub = try backfill.parse(&.{}, now, .{ .edge = false, .capy = true, .capy_key = true });
    try testing.expectEqual(@as(usize, 5), hub.harnesses.count());
    const local = try backfill.parse(&.{ "--upstream", "https://hub.example.ts.net" }, now, .{ .edge = true, .capy = true, .capy_key = true });
    try testing.expect(!local.harnesses.contains(.capy));

    try testing.expectEqual(@as(usize, 4), (try backfill.parse(&.{ "--harness", "all" }, now, .{ .edge = false, .capy = false, .capy_key = false })).harnesses.count());
    try testing.expectError(error.CapyNotConfigured, backfill.parse(&.{ "--harness", "capy" }, now, .{ .edge = false, .capy = false, .capy_key = false }));
    try testing.expectError(error.UnknownHarness, backfill.parse(&.{ "--harness", "mcp" }, now, .{ .edge = false, .capy = false, .capy_key = false }));
    try testing.expectError(error.InvalidSince, backfill.parse(&.{ "--since", "last tuesday" }, now, .{ .edge = false, .capy = false, .capy_key = false }));
    try testing.expectError(error.UnknownFlag, backfill.parse(&.{"--force"}, now, .{ .edge = false, .capy = false, .capy_key = false }));
}
