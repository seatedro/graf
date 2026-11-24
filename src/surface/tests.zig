const std = @import("std");
const core = @import("core");
const store = @import("store");
const retrieve = @import("retrieve");
const capture = @import("capture");
const api = @import("api.zig");
const http = @import("http.zig");
const mcp = @import("mcp.zig");
const client = @import("client.zig");
const service = @import("service.zig");
const testing = std.testing;
const Io = std.Io;

const FakeSink = struct {
    io: Io,
    drafts: std.ArrayList([]const u8) = .empty,
    last_id: core.Id = .nil,

    fn sink(f: *FakeSink) core.EntrySink {
        return .{ .ptr = f, .vtable = &.{ .enqueue = enqueue, .loadCursor = loadCursor } };
    }

    fn enqueue(ptr: *anyopaque, draft: *const core.EntryDraft) anyerror!core.EntrySink.Outcome {
        const f: *FakeSink = @ptrCast(@alignCast(ptr));
        try f.drafts.append(testing.allocator, try std.json.Stringify.valueAlloc(testing.allocator, draft.*, .{}));
        f.last_id = core.Id.v7(f.io);
        return .{ .queued = f.last_id };
    }

    fn loadCursor(_: *anyopaque, _: std.mem.Allocator, _: *const core.SourceKey) anyerror!?[]const u8 {
        return null;
    }

    fn deinit(f: *FakeSink) void {
        for (f.drafts.items) |d| testing.allocator.free(d);
        f.drafts.deinit(testing.allocator);
    }
};

const FakeFlusher = struct {
    calls: u32 = 0,
    harness: ?core.Harness = null,

    fn flusher(f: *FakeFlusher) service.Flusher {
        return .{ .ptr = f, .flushFn = flush };
    }

    fn flush(ptr: *anyopaque, req: service.FlushRequest) anyerror!bool {
        const f: *FakeFlusher = @ptrCast(@alignCast(ptr));
        f.calls += 1;
        f.harness = req.harness;
        return true;
    }
};

const Fixture = struct {
    s: store.Store,
    seed: retrieve.testing.Seed,
    embedder: retrieve.testing.HashEmbedder = .{},
    config: core.Config = .{},
    engine: retrieve.Engine = undefined,
    sink: FakeSink = .{ .io = testing.io },
    flusher: FakeFlusher = .{},
    svc: service.Service = undefined,

    fn init(f: *Fixture) !void {
        f.* = .{ .s = try store.testing.open(), .seed = undefined };
        errdefer f.s.close();
        f.seed = try retrieve.testing.seed(&f.s, testing.io);
        f.engine = .init(testing.allocator, testing.io, &f.s, &f.config, f.seed.graph, .{ .embedder = f.embedder.embedder() });
        f.svc = .{ .gpa = testing.allocator, .io = testing.io, .engine = &f.engine, .sink = f.sink.sink(), .flusher = f.flusher.flusher() };
    }

    fn deinit(f: *Fixture) void {
        f.svc.deinit();
        f.engine.deinit();
        f.sink.deinit();
        retrieve.testing.cleanup(&f.s, f.seed.graph);
        f.s.close();
    }
};

fn toolText(arena: std.mem.Allocator, line: []const u8) !struct { text: []const u8, is_error: bool } {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    const result = v.object.get("result").?.object;
    return .{ .text = result.get("content").?.array.items[0].object.get("text").?.string, .is_error = result.get("isError").?.bool };
}

test "the four MCP tools answer from the graph over stdio" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"pg.zig COPY support","project":"graf"}}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"memory_entity","arguments":{"name_or_id":"pg-zig","include_history":true}}}
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"memory_remember","arguments":{"text":"alice prefers dark mode","scope":"global","wait":false}}}
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"memory_forget","arguments":{"query":"Postgres"}}}
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"memory_forget","arguments":{"query":"tabs over spaces","reason":"changed my mind"}}}
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"memory_entity","arguments":{"name_or_id":"no such thing"}}}
        \\
    ;
    var in: Io.Reader = .fixed(input);
    var out: Io.Writer.Allocating = .init(arena);
    try mcp.serveStdio(testing.allocator, f.svc.handler(), "test", &in, &out.writer);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    const init_line = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, init_line, "\"instructions\"") != null);
    const list = try std.json.parseFromSliceLeaky(std.json.Value, arena, lines.next().?, .{});
    try testing.expectEqual(@as(usize, 4), list.object.get("result").?.object.get("tools").?.array.items.len);

    const search = try toolText(arena, lines.next().?);
    try testing.expect(!search.is_error);
    try testing.expect(std.mem.indexOf(u8, search.text, "## Memory for \"pg.zig COPY support\" (project: graf") != null);
    try testing.expect(std.mem.indexOf(u8, search.text, "pg.zig supports COPY") != null);
    try testing.expect(std.mem.indexOf(u8, search.text, "pg.zig lacks COPY") == null);

    const entity = try toolText(arena, lines.next().?);
    try testing.expect(!entity.is_error);
    try testing.expect(std.mem.startsWith(u8, entity.text, "## pg.zig (software)"));
    try testing.expect(std.mem.indexOf(u8, entity.text, "(changed) | conf 0.80 | codex] pg.zig lacks COPY support.") != null);

    const remember = try toolText(arena, lines.next().?);
    try testing.expect(!remember.is_error);
    try testing.expect(std.mem.startsWith(u8, remember.text, "Queued as entry "));
    try testing.expectEqual(@as(usize, 1), f.sink.drafts.items.len);
    const draft = try std.json.parseFromSliceLeaky(core.EntryDraft, arena, f.sink.drafts.items[0], .{});
    try testing.expectEqual(core.types.EntryKind.note, draft.kind);
    try testing.expectEqual(core.types.Author.user, draft.author);
    try testing.expect(draft.project == null);
    try testing.expectEqualStrings("alice prefers dark mode", draft.body.text.?);

    const ambiguous = try toolText(arena, lines.next().?);
    try testing.expect(std.mem.startsWith(u8, ambiguous.text, "Several facts match; nothing was forgotten."));
    const forgot = try toolText(arena, lines.next().?);
    try testing.expect(std.mem.indexOf(u8, forgot.text, "alice prefers tabs over spaces") != null);
    const missing = try toolText(arena, lines.next().?);
    try testing.expect(missing.is_error);
    try testing.expect(lines.next() == null);
}

test "serve and hook round trip over the Unix socket" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const socket = try std.fs.path.join(arena, &.{ dir, "graf.sock" });

    var server: http.Server = .init(testing.allocator, io, f.svc.handler(), .{ .listen = "127.0.0.1:0", .socket_path = socket, .token = "secret", .version = "test" });
    try server.start();
    defer server.deinit();
    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch {};
    }

    var c = client.Client.init(io, .{ .unix = socket }, "");
    try testing.expect(try c.health());

    const brief = try c.request(arena, .GET, "/v1/brief?project=graf", null);
    try testing.expectEqual(@as(u16, 200), brief.status);
    try testing.expect(std.mem.indexOf(u8, brief.body, "graf memory brief (project: graf") != null);

    var samples: [100]i96 = undefined;
    for (&samples) |*sample| {
        var a = std.heap.ArenaAllocator.init(testing.allocator);
        defer a.deinit();
        const t0 = Io.Timestamp.now(io, .awake);
        const r = try c.request(a.allocator(), .GET, "/v1/brief?project=graf", null);
        sample.* = t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        try testing.expectEqual(@as(u16, 200), r.status);
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    try testing.expect(samples[98] < 150 * std.time.ns_per_ms);

    const warm = try c.request(arena, .POST, "/v1/sessions/s-1/warm", "{\"prompt\":\"storage engine for graf\",\"project\":\"graf\"}");
    try testing.expectEqual(@as(u16, 202), warm.status);
    const recall = try c.request(arena, .GET, "/v1/sessions/s-1/recall?prompt=is%20pg-zig%20able%20to%20do%20COPY", null);
    try testing.expectEqual(@as(u16, 200), recall.status);
    try testing.expect(std.mem.indexOf(u8, recall.body, "pg.zig supports COPY") != null);
    const again = try c.request(arena, .GET, "/v1/sessions/s-1/recall?prompt=is%20pg-zig%20able%20to%20do%20COPY", null);
    try testing.expect(std.mem.indexOf(u8, again.body, "pg.zig supports COPY") == null);

    const flush = try c.request(arena, .POST, "/v1/hooks/flush", "{\"harness\":\"codex\",\"session_id\":\"s-1\",\"transcript_path\":\"/tmp/x.jsonl\",\"cwd\":\"/tmp\"}");
    try testing.expectEqual(@as(u16, 202), flush.status);
    try testing.expectEqual(@as(u32, 1), f.flusher.calls);
    try testing.expectEqual(core.Harness.codex, f.flusher.harness.?);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", dir);
    var hook_config = f.config;
    hook_config.serve.socket = socket;
    var hook_out: std.Io.Writer.Allocating = .init(arena);
    try capture.hooks.run(arena, io, &env, &hook_config, .@"claude-code", .stop, "{\"session_id\":\"s-1\",\"transcript_path\":\"/tmp/y.jsonl\"}", &hook_out.writer);
    try testing.expectEqual(@as(u32, 2), f.flusher.calls);
    try testing.expectEqual(core.Harness.@"claude-code", f.flusher.harness.?);

    const entry = try c.request(arena, .POST, "/v1/entries", "{\"kind\":\"turns\",\"author\":\"mixed\",\"body\":{\"turns\":[{\"role\":\"user\",\"text\":\"hi\"}]},\"reference_time\":1795910400000000,\"project\":\"graf\"}");
    try testing.expectEqual(@as(u16, 200), entry.status);
    var id_buf: [36]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, entry.body, f.sink.last_id.toString(&id_buf)) != null);

    const bad_time = try c.request(arena, .POST, "/v1/search", "{\"query\":\"x\",\"as_of\":\"yesterday\"}");
    try testing.expectEqual(@as(u16, 400), bad_time.status);

    var tcp_buf: [32]u8 = undefined;
    var tcp = client.Client.init(io, .{ .tcp = try std.fmt.bufPrint(&tcp_buf, "127.0.0.1:{d}", .{server.boundPort()}) }, "secret");
    const over_tcp = try tcp.request(arena, .POST, "/v1/search", "{\"query\":\"alice prefers tabs\"}");
    try testing.expectEqual(@as(u16, 200), over_tcp.status);
    try testing.expect(std.mem.indexOf(u8, over_tcp.body, "alice prefers tabs over spaces") != null);
}

test "default project fills requests that omit one" {
    const Recorder = struct {
        body: []const u8 = "",
        fn handler(r: *@This()) api.Handler {
            return .{ .ptr = r, .vtable = &.{ .handle = handle } };
        }
        fn handle(ptr: *anyopaque, arena: std.mem.Allocator, req: api.Request) anyerror!api.Reply {
            const r: *@This() = @ptrCast(@alignCast(ptr));
            r.body = try arena.dupe(u8, req.body);
            return .{ .body = "{}" };
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rec: Recorder = .{};
    var d: service.DefaultProject = .{ .inner = rec.handler(), .project = "github.com/brackwater/app" };
    const h = d.handler();
    _ = try h.handle(arena, .{ .op = .search, .body = "{\"query\":\"q\"}" });
    try testing.expectEqualStrings("{\"query\":\"q\",\"project\":\"github.com/brackwater/app\"}", rec.body);
    _ = try h.handle(arena, .{ .op = .search, .body = "{\"query\":\"q\",\"project\":\"*\"}" });
    try testing.expectEqualStrings("{\"query\":\"q\",\"project\":\"*\"}", rec.body);
    _ = try h.handle(arena, .{ .op = .remember, .body = "{\"text\":\"t\",\"scope\":\"global\"}" });
    try testing.expectEqualStrings("{\"text\":\"t\",\"scope\":\"global\"}", rec.body);
    _ = try h.handle(arena, .{ .op = .forget, .body = "{\"query\":\"q\"}" });
    try testing.expectEqualStrings("{\"query\":\"q\"}", rec.body);
}
