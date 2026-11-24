const std = @import("std");
const core = @import("core");
const capture = @import("capture");
const api = @import("api.zig");
const http = @import("http.zig");
const mcp = @import("mcp.zig");
const client = @import("client.zig");
const service = @import("service.zig");
const edge = @import("edge.zig");
const Upstream = @import("upstream.zig").Upstream;

const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Hub = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    entries: std.ArrayList([]const u8) = .empty,
    ops: std.ArrayList(api.Op) = .empty,
    entry_calls: usize = 0,
    fail_call: ?usize = null,

    fn handler(h: *Hub) api.Handler {
        return .{ .ptr = h, .vtable = &.{ .handle = handle } };
    }

    fn deinit(h: *Hub) void {
        for (h.entries.items) |e| testing.allocator.free(e);
        h.entries.deinit(testing.allocator);
        h.ops.deinit(testing.allocator);
    }

    fn handle(ptr: *anyopaque, arena: Allocator, req: api.Request) anyerror!api.Reply {
        const h: *Hub = @ptrCast(@alignCast(ptr));
        try h.mutex.lock(h.io);
        defer h.mutex.unlock(h.io);
        try h.ops.append(testing.allocator, req.op);
        if (req.op != .entries) return .{ .body = try std.fmt.allocPrint(arena, "{{\"text\":\"hub {t}\"}}", .{req.op}) };
        h.entry_calls += 1;
        if (h.fail_call == h.entry_calls) return api.errorReply(arena, 503, "busy");
        for (h.entries.items) |e| if (std.mem.eql(u8, e, req.body)) return .{ .body = "{\"duplicate\":true}" };
        try h.entries.append(testing.allocator, try testing.allocator.dupe(u8, req.body));
        return .{ .body = "{\"id\":\"00000000-0000-7000-8000-000000000000\"}" };
    }

    fn served(h: *Hub, op: api.Op) bool {
        for (h.ops.items) |o| if (o == op) return true;
        return false;
    }
};

const CountingFlusher = struct {
    calls: usize = 0,

    fn flusher(f: *CountingFlusher) service.Flusher {
        return .{ .ptr = f, .flushFn = flush };
    }

    fn flush(ptr: *anyopaque, req: service.FlushRequest) anyerror!bool {
        const f: *CountingFlusher = @ptrCast(@alignCast(ptr));
        f.calls += 1;
        return req.transcript_path != null;
    }
};

fn session(arena: Allocator, id: []const u8, cwd: []const u8, user_text: []const u8) ![]const u8 {
    const Line = struct {
        type: []const u8,
        sessionId: []const u8,
        cwd: []const u8,
        uuid: []const u8,
        timestamp: []const u8,
        message: struct { role: []const u8, content: []const u8 },
    };
    var out: Io.Writer.Allocating = .init(arena);
    const lines = [_]Line{
        .{ .type = "user", .sessionId = id, .cwd = cwd, .uuid = "u1", .timestamp = "2026-11-20T17:00:00.000Z", .message = .{ .role = "user", .content = user_text } },
        .{ .type = "assistant", .sessionId = id, .cwd = cwd, .uuid = "a1", .timestamp = "2026-11-20T17:00:05.000Z", .message = .{ .role = "assistant", .content = "Done. The widget service now runs on Postgres 17." } },
    };
    for (lines) |line| {
        try std.json.Stringify.value(line, .{}, &out.writer);
        try out.writer.writeByte('\n');
    }
    return out.written();
}

fn reservePort(io: Io, h: *Hub) !u16 {
    var probe = http.Server.init(testing.allocator, io, h.handler(), .{ .listen = "127.0.0.1:0" });
    try probe.start();
    defer probe.deinit();
    return probe.boundPort();
}

test "edge spools captured entries while the hub is offline and drains each exactly once" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "claude/proj");
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const roots = [_]capture.service.Root{.{ .harness = .@"claude-code", .path = try std.fs.path.join(arena, &.{ base, "claude" }) }};
    const spool_dir = try edge.spoolDir(arena, try std.fs.path.join(arena, &.{ base, "state", "graf" }));
    const secret = try std.mem.concat(arena, u8, &.{ "gh" ++ "p_", "a1B2c3D4e5F6g7H8", "i9J0k1L2m3N4o5P6q7R8" });

    var hub: Hub = .{ .io = io };
    defer hub.deinit();
    const port = try reservePort(io, &hub);
    const listen = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{port});
    var up = try Upstream.init(gpa, io, try std.fmt.allocPrint(arena, "http://{s}", .{listen}), "hub-token", 2000);
    defer up.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const config: core.Config = .{};
    const t0: core.Micros = 1_795_194_000_000_000;
    const minute = std.time.us_per_min;

    {
        var spool = try edge.Spool.open(gpa, io, spool_dir, .{});
        defer spool.close();
        var cap = try capture.Capture.init(gpa, io, &env, &config, spool.sink(), .{ .roots = &roots, .backfill = true });
        defer cap.deinit();
        try cap.step(t0);
        try tmp.dir.writeFile(io, .{ .sub_path = "claude/proj/one.jsonl", .data = try session(arena, "s-one", "/home/dev/brackwater/widget", try std.fmt.allocPrint(arena, "Deploy with GITHUB_TOKEN={s} and move widget to Postgres 17.", .{secret})) });
        try tmp.dir.writeFile(io, .{ .sub_path = "claude/proj/two.jsonl", .data = try session(arena, "s-two", "/home/dev/brackwater/widget", "Switch the widget service to Postgres 17.") });
        try cap.step(t0 + minute);
        try cap.step(t0 + 2 * minute);
        try cap.step(t0 + 26 * 60 * minute);
        try testing.expectEqual(4, try spool.pending());

        if (spool.drain(&up)) |_| return error.TestUnexpectedResult else |_| {}
        try testing.expectEqual(4, try spool.pending());
    }

    var server = http.Server.init(gpa, io, hub.handler(), .{ .listen = listen, .token = "hub-token" });
    try server.start();
    defer server.deinit();
    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch {};
    }

    {
        var spool = try edge.Spool.open(gpa, io, spool_dir, .{});
        defer spool.close();
        hub.fail_call = 2;
        try testing.expectError(error.UpstreamUnavailable, spool.drain(&up));
        try testing.expectEqual(1, hub.entries.items.len);
        try testing.expectEqual(3, try spool.pending());
    }
    {
        var spool = try edge.Spool.open(gpa, io, spool_dir, .{});
        defer spool.close();
        const drained = try spool.drain(&up);
        try testing.expectEqual(3, drained.delivered);
        try testing.expectEqual(0, try spool.pending());
        try testing.expectEqual(0, (try spool.drain(&up)).delivered);

        var cap = try capture.Capture.init(gpa, io, &env, &config, spool.sink(), .{ .roots = &roots, .backfill = true });
        defer cap.deinit();
        try cap.step(t0 + 27 * 60 * minute);
        try cap.step(t0 + 28 * 60 * minute);
        try testing.expectEqual(0, try spool.pending());
    }

    try testing.expectEqual(4, hub.entries.items.len);
    try testing.expectEqual(5, hub.entry_calls);
    var redacted = false;
    for (hub.entries.items, 0..) |body, i| {
        for (hub.entries.items[i + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, body, other));
        try testing.expect(std.mem.find(u8, body, secret) == null);
        try testing.expect(std.mem.find(u8, body, "\"cursor\"") == null);
        const draft = try std.json.parseFromSliceLeaky(core.EntryDraft, arena, body, .{ .ignore_unknown_fields = true });
        try testing.expectEqual(core.Harness.@"claude-code", draft.source.?.harness);
        if (std.mem.find(u8, body, "[REDACTED") != null) redacted = true;
    }
    try testing.expect(redacted);
}

test "spool drops a torn last line and keeps rejected entries aside" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try tmp.dir.writeFile(io, .{ .sub_path = edge.spool_file, .data = "{\"kind\":\"note\",\"author\":\"user\",\"body\":{\"text\":\"a\"},\"reference_time\":1}\nnot json\n{\"kind\":\"no" });

    var hub: Hub = .{ .io = io };
    defer hub.deinit();
    var fake = Rejecting{ .inner = hub.handler() };
    var server = http.Server.init(gpa, io, fake.handler(), .{ .listen = "127.0.0.1:0" });
    try server.start();
    defer server.deinit();
    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch {};
    }
    var up = try Upstream.init(gpa, io, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{server.boundPort()}), "", 2000);
    defer up.deinit();

    var spool = try edge.Spool.open(gpa, io, dir, .{});
    defer spool.close();
    try testing.expectEqual(2, try spool.pending());
    const drained = try spool.drain(&up);
    try testing.expectEqual(1, drained.delivered);
    try testing.expectEqual(1, drained.rejected);
    try testing.expectEqual(0, try spool.pending());
    const rejected = try tmp.dir.readFileAlloc(io, edge.rejected_file, arena, .limited(1024));
    try testing.expectEqualStrings("not json\n", rejected);
}

const Rejecting = struct {
    inner: api.Handler,

    fn handler(r: *Rejecting) api.Handler {
        return .{ .ptr = r, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, arena: Allocator, req: api.Request) anyerror!api.Reply {
        const r: *Rejecting = @ptrCast(@alignCast(ptr));
        if (std.mem.startsWith(u8, req.body, "not")) return api.errorReply(arena, 400, "bad entry");
        return r.inner.handle(arena, req);
    }
};

test "edge proxies MCP, reads and hooks to the hub and fails open while it is offline" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "work");
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const socket = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/state/graf/graf.sock", .{tmp.sub_path});

    var hub: Hub = .{ .io = io };
    defer hub.deinit();
    var hub_server = http.Server.init(gpa, io, hub.handler(), .{ .listen = "127.0.0.1:0", .token = "hub-token" });
    try hub_server.start();
    var hub_running = try io.concurrent(http.Server.run, .{&hub_server});
    var hub_up = true;
    defer if (hub_up) {
        hub_server.stop();
        hub_running.await(io) catch {};
        hub_server.deinit();
    };

    var up = try Upstream.init(gpa, io, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{hub_server.boundPort()}), "hub-token", 1000);
    defer up.deinit();
    var spool = try edge.Spool.open(gpa, io, try std.fs.path.join(arena, &.{ base, "spool" }), .{});
    defer spool.close();
    var flusher: CountingFlusher = .{};
    var proxy: edge.Edge = .{ .upstream = &up, .spool = &spool, .flusher = flusher.flusher() };
    var local = http.Server.init(gpa, io, proxy.handler(), .{ .listen = "", .socket_path = socket });
    try local.start();
    defer local.deinit();
    var local_running = try io.concurrent(http.Server.run, .{&local});
    defer {
        local.stop();
        local_running.await(io) catch {};
    }

    const search_call = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_search\",\"arguments\":{\"query\":\"db\"}}}";
    const direct = (try mcp.handleMessage(arena, up.handler(), "t", search_call)).?;
    try testing.expect(std.mem.find(u8, direct, "\"text\":\"hub search\"") != null);
    try testing.expect(std.mem.find(u8, direct, "\"isError\":false") != null);

    const c = client.Client.init(io, .{ .unix = socket }, "");
    var r = try c.request(arena, .POST, "/v1/entity", "{\"name_or_id\":\"widget\"}");
    try testing.expectEqual(200, r.status);
    try testing.expectEqualStrings("{\"text\":\"hub entity\"}", r.body);
    r = try c.request(arena, .POST, "/v1/entries", "{\"kind\":\"note\",\"author\":\"user\",\"body\":{\"text\":\"use Postgres 17\"},\"reference_time\":1}");
    try testing.expectEqual(200, r.status);
    try testing.expectEqual(1, try spool.pending());
    try testing.expectEqual(400, (try c.request(arena, .POST, "/v1/entries", "{\"kind\":\"nope\"}")).status);
    r = try c.request(arena, .POST, "/v1/hooks/flush", "{\"harness\":\"claude-code\",\"transcript_path\":\"/t.jsonl\"}");
    try testing.expectEqual(202, r.status);
    try testing.expectEqual(1, flusher.calls);
    try testing.expect(!hub.served(.flush) and !hub.served(.entries));

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", base);
    try env.put("XDG_STATE_HOME", try std.fs.path.join(arena, &.{ base, "state" }));
    var config: core.Config = .{};
    config.serve.listen = "";
    config.serve.socket = socket;
    const payload = try std.json.Stringify.valueAlloc(arena, .{ .session_id = "s1", .cwd = try std.fs.path.join(arena, &.{ base, "work" }), .transcript_path = "/t.jsonl" }, .{});
    var out: Io.Writer.Allocating = .init(arena);
    try capture.hooks.run(arena, io, &env, &config, .@"claude-code", .@"session-start", payload, &out.writer);
    try testing.expect(std.mem.find(u8, out.written(), "hub brief") != null);

    hub_server.stop();
    hub_running.await(io) catch {};
    hub_server.deinit();
    hub_up = false;

    const offline = (try mcp.handleMessage(arena, up.handler(), "t", search_call)).?;
    try testing.expect(std.mem.find(u8, offline, "\"isError\":true") != null);
    try testing.expect(std.mem.find(u8, offline, "unreachable") != null);
    r = try c.request(arena, .POST, "/v1/search", "{\"query\":\"db\"}");
    try testing.expectEqual(502, r.status);

    var quiet: Io.Writer.Allocating = .init(arena);
    const started = Io.Timestamp.now(io, .awake);
    try capture.hooks.run(arena, io, &env, &config, .@"claude-code", .@"session-start", payload, &quiet.writer);
    try capture.hooks.run(arena, io, &env, &config, .@"claude-code", .stop, payload, &quiet.writer);
    try testing.expect(started.untilNow(io, .awake).toMilliseconds() < 1500);
    try testing.expectEqualStrings("", quiet.written());
    try testing.expectEqual(2, flusher.calls);
}
