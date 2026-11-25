const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");
const ingest = @import("mod.zig");
const workers = @import("workers.zig");
const fakes = @import("testing.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const testing = std.testing;

const Provider = struct {
    io: Io,
    gpa: Allocator,
    server: net.Server,
    accept: ?Io.Future(void) = null,
    conns: Io.Group = .init,

    fn listen(p: *Provider, gpa: Allocator, io: Io) !void {
        p.* = .{ .io = io, .gpa = gpa, .server = undefined };
        const addr = try net.IpAddress.parseLiteral("127.0.0.1:0");
        p.server = try addr.listen(io, .{});
        p.accept = try io.concurrent(loop, .{p});
    }

    fn stop(p: *Provider) void {
        if (p.accept) |*f| f.cancel(p.io);
        p.conns.cancel(p.io);
        p.server.deinit(p.io);
    }

    fn baseUrl(p: *Provider, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/v1", .{p.server.socket.address.getPort()});
    }

    fn loop(p: *Provider) void {
        while (true) {
            const stream = p.server.accept(p.io) catch return;
            p.conns.concurrent(p.io, serve, .{ p, stream }) catch {
                stream.close(p.io);
                return;
            };
        }
    }

    fn serve(p: *Provider, stream: net.Stream) Io.Cancelable!void {
        defer stream.close(p.io);
        p.handle(stream) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }

    fn handle(p: *Provider, stream: net.Stream) !void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var head_buf: [16 * 1024]u8 = undefined;
        var len: usize = 0;
        const head_end = while (true) {
            if (std.mem.indexOf(u8, head_buf[0..len], "\r\n\r\n")) |i| break i + 4;
            if (len == head_buf.len) return error.RequestTooLarge;
            var bufs = [_][]u8{head_buf[len..]};
            const n = try stream.read(p.io, &bufs);
            if (n == 0) return;
            len += n;
        };

        var lines = std.mem.splitSequence(u8, head_buf[0 .. head_end - 4], "\r\n");
        var first = std.mem.tokenizeScalar(u8, lines.next().?, ' ');
        _ = first.next();
        const target = first.next() orelse return;
        var content_length: usize = 0;
        while (lines.next()) |line| {
            const name, const value = std.mem.cut(u8, line, ":") orelse continue;
            if (std.ascii.eqlIgnoreCase(name, "content-length")) content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, value, " "), 10);
        }

        const body = try arena.alloc(u8, content_length);
        const early = len - head_end;
        @memcpy(body[0..early], head_buf[head_end..len]);
        var got = early;
        while (got < body.len) {
            var bufs = [_][]u8{body[got..]};
            const n = try stream.read(p.io, &bufs);
            if (n == 0) return;
            got += n;
        }

        try p.io.sleep(.fromMilliseconds(20), .awake);
        const reply = if (std.mem.endsWith(u8, target, "/embeddings"))
            try embeddings(arena, body)
        else if (std.mem.indexOf(u8, body, "resolve_result") != null)
            try response(arena, "{\"entity_links\":[],\"fact_verdicts\":[]}")
        else
            try response(arena, fakes.relay_hollis);

        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(p.io, &wbuf);
        const w = &writer.interface;
        try w.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ reply.len, reply });
        try w.flush();
    }

    fn response(arena: Allocator, text: []const u8) ![]const u8 {
        return std.json.Stringify.valueAlloc(arena, .{
            .id = "resp_1",
            .object = "response",
            .status = "completed",
            .model = "example-model",
            .output = .{.{ .type = "message", .role = "assistant", .content = .{.{ .type = "output_text", .text = text }} }},
            .usage = .{ .input_tokens = 100, .output_tokens = 50 },
        }, .{});
    }

    fn embeddings(arena: Allocator, body: []const u8) ![]const u8 {
        const req = try std.json.parseFromSliceLeaky(struct { input: []const []const u8 }, arena, body, .{ .ignore_unknown_fields = true });
        const Row = struct { object: []const u8 = "embedding", index: usize, embedding: []const f32 };

        const rows = try arena.alloc(Row, req.input.len);
        for (rows, req.input, 0..) |*row, text, i| {
            const vec = try arena.alloc(f32, store.embedding_dims);
            @memset(vec, 0);
            vec[std.hash.Wyhash.hash(0, text) % vec.len] = 1;
            row.* = .{ .index = i, .embedding = vec };
        }

        return std.json.Stringify.valueAlloc(arena, .{ .object = "list", .data = rows, .model = "example-embedding-model", .usage = .{ .prompt_tokens = 10, .total_tokens = 10 } }, .{});
    }
};

test "a worker arena gives a large entry's memory back before the next claim and keeps a small one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    _ = try arena_state.allocator().alloc(u8, 64 << 20);
    workers.recycle(&arena_state);
    try testing.expect(arena_state.queryCapacity() <= workers.arena_retain_bytes);

    _ = try arena_state.allocator().alloc(u8, 256 << 10);
    workers.recycle(&arena_state);
    try testing.expect(arena_state.queryCapacity() >= 256 << 10);
}

fn drain(p: *ingest.Pipeline, stop: *std.atomic.Value(bool)) void {
    workers.lead(p, stop) catch |err| std.debug.print("workers stopped: {t}\n", .{err});
}

fn count(s: *store.Store, sql: []const u8, g: core.Id) !i64 {
    var row = (try s.pool.row(sql, .{@as([]const u8, &g.bytes)})).?;
    defer row.deinit() catch {};
    return row.get(i64, 0);
}

test "workers drain a backlog over HTTP through concurrent commits and rebases without leaking" {
    var s = try store.testing.openWith(.{ .pool_size = 16 });
    defer s.close();
    const g = try store.testing.freshGraph(&s);

    var provider: Provider = undefined;
    try provider.listen(testing.allocator, testing.io);
    defer provider.stop();
    var url_buf: [64]u8 = undefined;
    const url = try provider.baseUrl(&url_buf);

    const cfg: core.Config = .{
        .llm = .{ .base_url = url, .api_key = "test-key", .model = "example-model" },
        .embed = .{ .base_url = url, .api_key = "test-key", .model = "example-embedding-model", .dimensions = store.embedding_dims },
        .limits = .{ .daily_usd = 1e9, .monthly_usd = 1e9, .backfill_daily_usd = 1e9, .max_inflight = 16 },
        .ingest = .{ .workers = 6 },
    };

    var client = llm.Client.init(testing.allocator, testing.io, &cfg, s.ledger());
    defer client.deinit();
    client.graph_id = g;

    const n = 30;
    for (0..n) |i| {
        var text_buf: [128]u8 = undefined;
        var source_buf: [32]u8 = undefined;
        const draft: core.EntryDraft = .{
            .source = .{ .harness = .cli, .external_id = try std.fmt.bufPrint(&source_buf, "session-{d}", .{i}), .project = "brackwater/monorepo" },
            .kind = .note,
            .project = "brackwater/monorepo",
            .author = .user,
            .body = .{ .text = try std.fmt.bufPrint(&text_buf, "Relay lives under infra/relay. Hollis is currently on call for Relay. ({d})", .{i}) },
            .reference_time = fakes.at("2026-11-19T22:00:00Z") + @as(i64, @intCast(i)),
            .backfill = i % 2 == 0,
        };
        _ = try s.enqueue(g, &draft);
    }

    var p: ingest.Pipeline = .{ .store = &s, .client = &client, .config = &cfg, .graph_id = g };
    var stop: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, drain, .{ &p, &stop });

    var committed: i64 = 0;
    for (0..1200) |_| {
        committed = try count(&s, "SELECT count(*) FROM entry WHERE graph_id = $1 AND status = 'committed'", g);
        if (committed == n) break;
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    }

    stop.store(true, .release);
    thread.join();

    try testing.expectEqual(@as(i64, n), committed);
    try testing.expect(try count(&s, "SELECT count(*) FROM entry WHERE graph_id = $1 AND commit_seq > base_seq + 1", g) > 0);
    try testing.expectEqual(@as(i64, 1), try count(&s, "SELECT count(*) FROM entity WHERE graph_id = $1 AND merged_into IS NULL AND name = 'Relay'", g));
}
