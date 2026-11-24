const std = @import("std");
const core = @import("core");
const store = @import("store");
const retrieve = @import("retrieve");
const capture = @import("capture");
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
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: http.FakeHandler = .{ .io = testing.io };
    defer fake.deinit();

    var d: service.DefaultProject = .{ .inner = fake.handler(), .project = "github.com/brackwater/app" };
    const h = d.handler();

    _ = try h.handle(arena, .{ .op = .search, .body = "{\"query\":\"q\"}" });
    try fake.expectLast(.search, "{\"query\":\"q\",\"project\":\"github.com/brackwater/app\"}", null);

    _ = try h.handle(arena, .{ .op = .search, .body = "{\"query\":\"q\",\"project\":\"*\"}" });
    try fake.expectLast(.search, "{\"query\":\"q\",\"project\":\"*\"}", null);

    _ = try h.handle(arena, .{ .op = .remember, .body = "{\"text\":\"t\",\"scope\":\"global\"}" });
    try fake.expectLast(.remember, "{\"text\":\"t\",\"scope\":\"global\"}", null);

    _ = try h.handle(arena, .{ .op = .forget, .body = "{\"query\":\"q\"}" });
    try fake.expectLast(.forget, "{\"query\":\"q\"}", null);
}

fn rawExchange(arena: std.mem.Allocator, port: u16, bytes: []const u8) ![]const u8 {
    const io = testing.io;
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var send_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();

    var recv_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    return reader.interface.allocRemaining(arena, .limited(1 << 20));
}

test "streamable HTTP /mcp serves the four tools from the graph behind the bearer token" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket = try std.fs.path.join(arena, &.{ try tmp.dir.realPathFileAlloc(io, ".", arena), "graf.sock" });

    var server: http.Server = .init(testing.allocator, io, f.svc.handler(), .{ .listen = "127.0.0.1:0", .socket_path = socket, .token = "hub-token", .version = "test" });
    try server.start();
    defer server.deinit();
    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch {};
    }

    const port = server.boundPort();
    const tcp_target = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{port});
    const c = client.Client.init(io, .{ .tcp = tcp_target }, "hub-token");

    var r = try c.request(arena, .POST, "/mcp", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"remote\",\"version\":\"1\"}}}");
    try testing.expectEqual(@as(u16, 200), r.status);
    const init_reply = try std.json.parseFromSliceLeaky(std.json.Value, arena, r.body, .{});
    const init_result = init_reply.object.get("result").?.object;
    try testing.expectEqualStrings("2025-06-18", init_result.get("protocolVersion").?.string);
    try testing.expectEqualStrings(mcp.instructions, init_result.get("instructions").?.string);

    r = try c.request(arena, .POST, "/mcp", "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try testing.expectEqual(@as(u16, 202), r.status);
    try testing.expectEqualStrings("", r.body);

    r = try c.request(arena, .POST, "/mcp", "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    const listed = try std.json.parseFromSliceLeaky(std.json.Value, arena, r.body, .{});
    const tools = listed.object.get("result").?.object.get("tools").?.array.items;
    try testing.expectEqual(mcp.tool_names.len, tools.len);
    for (tools, mcp.tool_names) |tool, name| try testing.expectEqualStrings(name, tool.object.get("name").?.string);

    const reads = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_search\",\"arguments\":{\"query\":\"pg.zig COPY support\",\"project\":\"graf\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_entity\",\"arguments\":{\"name_or_id\":\"pg-zig\",\"include_history\":true}}}",
    };
    for (reads) |call| {
        r = try c.request(arena, .POST, "/mcp", call);
        try testing.expectEqual(@as(u16, 200), r.status);
        try testing.expectEqualStrings((try mcp.handleMessage(arena, f.svc.handler(), "test", call)).?, r.body);
    }

    try testing.expect(std.mem.indexOf(u8, (try toolText(arena, r.body)).text, "## pg.zig (software)") != null);

    r = try c.request(arena, .POST, "/mcp", "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_remember\",\"arguments\":{\"text\":\"alice prefers dark mode\",\"scope\":\"global\",\"wait\":false}}}");
    const remember = try toolText(arena, r.body);
    try testing.expect(!remember.is_error);
    try testing.expect(std.mem.startsWith(u8, remember.text, "Queued as entry "));
    try testing.expectEqual(@as(usize, 1), f.sink.drafts.items.len);

    r = try c.request(arena, .POST, "/mcp", "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_forget\",\"arguments\":{\"query\":\"tabs over spaces\"}}}");
    const forgot = try toolText(arena, r.body);
    try testing.expect(!forgot.is_error);
    try testing.expect(std.mem.indexOf(u8, forgot.text, "alice prefers tabs over spaces") != null);

    r = try c.request(arena, .POST, "/mcp", "[{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"},{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"},{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/list\"}]");
    const batch = try std.json.parseFromSliceLeaky(std.json.Value, arena, r.body, .{});
    try testing.expectEqual(@as(usize, 2), batch.array.items.len);
    try testing.expectEqual(@as(i64, 8), batch.array.items[1].object.get("id").?.integer);

    const anonymous = client.Client.init(io, .{ .tcp = tcp_target }, "");
    const wrong = client.Client.init(io, .{ .tcp = tcp_target }, "not-the-token");

    const drafts = f.sink.drafts.items.len;
    try testing.expectEqual(@as(u16, 401), (try anonymous.request(arena, .POST, "/mcp", reads[0])).status);
    try testing.expectEqual(@as(u16, 401), (try wrong.request(arena, .POST, "/mcp", reads[0])).status);
    try testing.expectEqual(@as(u16, 401), (try anonymous.request(arena, .POST, "/v1/remember", "{\"text\":\"x\",\"wait\":false}")).status);
    try testing.expectEqual(drafts, f.sink.drafts.items.len);

    try testing.expectEqual(@as(u16, 200), (try anonymous.request(arena, .GET, "/v1/health", null)).status);

    const local = client.Client.init(io, .{ .unix = socket }, "");
    try testing.expectEqual(@as(u16, 200), (try local.request(arena, .POST, "/mcp", reads[0])).status);

    const challenge = try rawExchange(arena, port, "POST /mcp HTTP/1.1\r\nhost: x\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}");
    try testing.expect(std.mem.startsWith(u8, challenge, "HTTP/1.1 401 "));
    try testing.expect(std.mem.indexOf(u8, challenge, "www-authenticate: Bearer") != null);

    for ([_][]const u8{ "GET", "DELETE" }) |method| {
        const reply = try rawExchange(arena, port, try std.fmt.allocPrint(arena, "{s} /mcp HTTP/1.1\r\nhost: x\r\naccept: text/event-stream\r\nauthorization: Bearer hub-token\r\nconnection: close\r\n\r\n", .{method}));
        try testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 405 "));
        try testing.expect(std.mem.indexOf(u8, reply, "allow: POST") != null);
    }

    const stale = try rawExchange(arena, port, "POST /mcp HTTP/1.1\r\nhost: x\r\nauthorization: Bearer hub-token\r\nmcp-protocol-version: 1999-01-01\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}");
    try testing.expect(std.mem.startsWith(u8, stale, "HTTP/1.1 400 "));

    const same_host = try rawExchange(arena, port, "POST /mcp HTTP/1.1\r\nhost: hub.example.ts.net\r\norigin: https://hub.example.ts.net\r\nauthorization: Bearer hub-token\r\nmcp-protocol-version: 2025-06-18\r\ncontent-length: 40\r\nconnection: close\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}");
    try testing.expect(std.mem.startsWith(u8, same_host, "HTTP/1.1 200 "));
}
