const std = @import("std");
const core = @import("core");
const capy = @import("capy.zig");
const state = @import("state.zig");
const segment = @import("segment.zig");
const FakeSink = @import("tailer.zig").FakeSink;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const testing = std.testing;

const key = "capy_test-key-0001";

const MockMessage = struct {
    event: []const u8,
    json: []const u8,
};

const MockThread = struct {
    id: []const u8,
    project: []const u8,
    status: []const u8 = "idle",
    updated: []const u8 = "2026-11-24T10:00:00.000Z",
    messages: std.ArrayList(MockMessage) = .empty,
    paged: ?usize = null,
};

const Failure = struct {
    prefix: []const u8,
    status: u16,
    retry_after: ?u32 = null,
};

const Mock = struct {
    io: Io,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    server: net.Server,
    accept: ?Io.Future(void) = null,
    conns: Io.Group = .init,
    mutex: Io.Mutex = .init,
    projects: []const u8 = "{\"items\":[]}",
    threads: std.ArrayList(MockThread) = .empty,
    thread_page: usize = 1,
    message_page: usize = 2,
    failures: std.ArrayList(Failure) = .empty,
    cut_first_stream_after: ?usize = null,
    hold_streams: bool = false,
    streams_served: usize = 0,
    log: std.ArrayList([]const u8) = .empty,

    fn listen(m: *Mock, gpa: Allocator, io: Io) !void {
        m.* = .{ .io = io, .gpa = gpa, .arena = .init(gpa), .server = undefined };
        const addr = try net.IpAddress.parseLiteral("127.0.0.1:0");
        m.server = try addr.listen(io, .{});
        m.accept = try io.concurrent(loop, .{m});
    }

    fn stop(m: *Mock) void {
        if (m.accept) |*f| f.cancel(m.io);
        m.conns.cancel(m.io);
        m.server.deinit(m.io);
        m.arena.deinit();
    }

    fn baseUrl(m: *Mock, a: Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/api/v1", .{m.server.socket.address.getPort()});
    }

    fn alloc(m: *Mock) Allocator {
        return m.arena.allocator();
    }

    fn thread(m: *Mock, id: []const u8) *MockThread {
        for (m.threads.items) |*t| if (std.mem.eql(u8, t.id, id)) return t;
        unreachable;
    }

    fn addThread(m: *Mock, t: MockThread) !void {
        try m.threads.append(m.alloc(), t);
    }

    fn say(m: *Mock, thread_id: []const u8, source: []const u8, text: []const u8, created: []const u8) !void {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);

        const t = m.thread(thread_id);
        const n = t.messages.items.len + 1;
        const event = try std.fmt.allocPrint(m.alloc(), "01JTESTEVENT{s}{d:0>6}", .{ thread_id[thread_id.len - 8 ..], n });
        const msg_id = if (std.mem.eql(u8, source, "tool")) try std.fmt.allocPrint(m.alloc(), "toolu_{d}", .{n}) else event;
        const tool_field: []const u8 = if (std.mem.eql(u8, source, "tool")) ",\"tool\":\"bash\"" else "";

        const json = try std.json.Stringify.valueAlloc(m.alloc(), .{ .id = msg_id, .source = source, .text = text, .createdAt = created }, .{});
        const full = try std.fmt.allocPrint(m.alloc(), "{s}{s}}}", .{ json[0 .. json.len - 1], tool_field });
        try t.messages.append(m.alloc(), .{ .event = event, .json = full });
    }

    fn requests(m: *Mock, prefix: []const u8) usize {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);

        var n: usize = 0;
        for (m.log.items) |line| if (std.mem.startsWith(u8, line, prefix)) {
            n += 1;
        };
        return n;
    }

    fn exact(m: *Mock, line: []const u8) usize {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);

        var n: usize = 0;
        for (m.log.items) |l| if (std.mem.eql(u8, l, line)) {
            n += 1;
        };
        return n;
    }

    fn loop(m: *Mock) void {
        while (true) {
            const stream = m.server.accept(m.io) catch return;
            m.conns.concurrent(m.io, serve, .{ m, stream }) catch {
                stream.close(m.io);
                return;
            };
        }
    }

    fn serve(m: *Mock, stream: net.Stream) Io.Cancelable!void {
        defer stream.close(m.io);
        m.handle(stream) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }

    const Reply = union(enum) {
        json: struct { status: u16, body: []const u8, retry_after: ?u32 = null },
        stream: struct { frames: []const MockMessage, thread_id: []const u8, cut: ?usize },
    };

    fn handle(m: *Mock, stream: net.Stream) !void {
        var buf: [8192]u8 = undefined;
        var len: usize = 0;
        while (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") == null) {
            if (len == buf.len) return error.RequestTooLarge;
            var bufs = [_][]u8{buf[len..]};
            const n = try stream.read(m.io, &bufs);
            if (n == 0) return;
            len += n;
        }

        const head = buf[0..std.mem.indexOf(u8, buf[0..len], "\r\n\r\n").?];
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        var first = std.mem.tokenizeScalar(u8, lines.next().?, ' ');
        _ = first.next();
        const target = first.next() orelse return;

        var auth: []const u8 = "";
        var last_id: []const u8 = "";
        while (lines.next()) |line| {
            const name, const value = std.mem.cut(u8, line, ":") orelse continue;
            const v = std.mem.trim(u8, value, " ");
            if (std.ascii.eqlIgnoreCase(name, "authorization")) auth = v;
            if (std.ascii.eqlIgnoreCase(name, "last-event-id")) last_id = v;
        }

        var scratch: std.heap.ArenaAllocator = .init(m.gpa);
        defer scratch.deinit();
        const reply = try m.route(scratch.allocator(), target, auth, last_id);

        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(m.io, &wbuf);
        const w = &writer.interface;

        switch (reply) {
            .json => |j| {
                try w.print("HTTP/1.1 {d} X\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n", .{ j.status, j.body.len });
                if (j.retry_after) |ra| try w.print("Retry-After: {d}\r\n", .{ra});
                try w.print("\r\n{s}", .{j.body});
                try w.flush();
            },
            .stream => |st| {
                try w.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
                try chunk(w, try std.fmt.allocPrint(scratch.allocator(), "event: status\ndata: {{\"threadId\":\"{s}\",\"status\":\"working\"}}\n\nretry: 1\n\n", .{st.thread_id}));

                for (st.frames, 0..) |f, i| {
                    if (st.cut) |c| if (i == c) return;
                    try chunk(w, try std.fmt.allocPrint(scratch.allocator(), "event: heartbeat\ndata: {{}}\n\nid: {s}\nevent: transcript\ndata: {s}\n\n", .{ f.event, f.json }));
                }

                if (m.hold_streams) while (true) try m.io.sleep(.fromMilliseconds(5), .awake);
                try chunk(w, try std.fmt.allocPrint(scratch.allocator(), "event: run\ndata: {{\"phase\":\"end\"}}\n\nevent: status\ndata: {{\"threadId\":\"{s}\",\"status\":\"idle\"}}\n\n", .{st.thread_id}));
                try w.writeAll("0\r\n\r\n");
                try w.flush();
            },
        }
    }

    fn chunk(w: *Io.Writer, data: []const u8) !void {
        try w.print("{x}\r\n{s}\r\n", .{ data.len, data });
        try w.flush();
    }

    fn route(m: *Mock, arena: Allocator, target: []const u8, auth: []const u8, last_id: []const u8) !Reply {
        try m.mutex.lock(m.io);
        defer m.mutex.unlock(m.io);
        try m.log.append(m.alloc(), try std.fmt.allocPrint(m.alloc(), "{s}|{s}", .{ target, last_id }));

        const path_full = std.mem.cutPrefix(u8, target, "/api/v1") orelse return notFound();
        for (m.failures.items, 0..) |f, i| if (std.mem.startsWith(u8, path_full, f.prefix)) {
            _ = m.failures.orderedRemove(i);
            return .{ .json = .{ .status = f.status, .body = "{\"_tag\":\"capy/Failure\",\"retryAfterSeconds\":0}", .retry_after = f.retry_after } };
        };

        if (!std.mem.eql(u8, auth, "Bearer " ++ key)) return .{ .json = .{ .status = 401, .body = "{\"_tag\":\"capy/Unauthorized\"}" } };
        const path, const query = std.mem.cut(u8, path_full, "?") orelse .{ path_full, "" };
        if (std.mem.eql(u8, path, "/projects")) return .{ .json = .{ .status = 200, .body = m.projects } };
        if (std.mem.eql(u8, path, "/threads")) return m.threadPage(arena, query);

        const rest = std.mem.cutPrefix(u8, path, "/threads/") orelse return notFound();
        const id, const tail = std.mem.cut(u8, rest, "/") orelse return notFound();
        const t = for (m.threads.items) |*t| {
            if (std.mem.eql(u8, t.id, id)) break t;
        } else return notFound();

        if (std.mem.eql(u8, tail, "messages")) return m.messagePage(arena, t, query);
        if (std.mem.eql(u8, tail, "stream")) {
            const after = if (last_id.len > 0) last_id else param(arena, query, "after") orelse "";
            const start = indexAfter(t.messages.items, after) orelse return .{ .json = .{ .status = 400, .body = "{}" } };
            const cut = if (m.streams_served == 0) m.cut_first_stream_after else null;
            m.streams_served += 1;
            return .{ .stream = .{ .frames = try arena.dupe(MockMessage, t.messages.items[start..]), .thread_id = t.id, .cut = cut } };
        }

        return notFound();
    }

    fn notFound() Reply {
        return .{ .json = .{ .status = 404, .body = "{\"_tag\":\"capy/ThreadNotFound\"}" } };
    }

    fn threadPage(m: *Mock, arena: Allocator, query: []const u8) !Reply {
        const project_id = param(arena, query, "projectId") orelse return .{ .json = .{ .status = 400, .body = "{}" } };
        var matching: std.ArrayList(*MockThread) = .empty;
        for (m.threads.items) |*t| if (std.mem.eql(u8, t.project, project_id)) try matching.append(arena, t);

        const offset = if (param(arena, query, "cursor")) |c| try std.fmt.parseInt(usize, c[std.mem.indexOfScalar(u8, c, ':').? + 1 ..], 10) else 0;
        const end = @min(matching.items.len, offset + m.thread_page);

        var out: Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("{\"items\":[");
        for (matching.items[offset..end], 0..) |t, i| {
            try out.writer.print("{s}{{\"id\":\"{s}\",\"projectId\":\"{s}\",\"status\":\"{s}\",\"archived\":false,\"lastModelId\":\"model-x\",\"updatedAt\":\"{s}\",\"lastActivityAt\":\"{s}\",\"title\":null}}", .{ if (i == 0) "" else ",", t.id, t.project, t.status, t.updated, t.updated });
        }
        if (end < matching.items.len) try out.writer.print("],\"cursor\":\"1795000000000:{d}\"}}", .{end}) else try out.writer.writeAll("],\"cursor\":null}");

        return .{ .json = .{ .status = 200, .body = out.written() } };
    }

    fn messagePage(m: *Mock, arena: Allocator, t: *MockThread, query: []const u8) !Reply {
        const visible = t.messages.items[0..@min(t.messages.items.len, t.paged orelse t.messages.items.len)];
        const after = indexAfter(t.messages.items, param(arena, query, "after") orelse "") orelse return .{ .json = .{ .status = 400, .body = "{}" } };
        const start = @min(after, visible.len);
        const end = @min(visible.len, start + m.message_page);

        var out: Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("{\"items\":[");
        for (visible[start..end], 0..) |msg, i| try out.writer.print("{s}{s}", .{ if (i == 0) "" else ",", msg.json });
        if (end < visible.len) try out.writer.print("],\"cursor\":\"{s}\",\"beforeCursor\":null}}", .{visible[end - 1].event}) else try out.writer.writeAll("],\"cursor\":null,\"beforeCursor\":null}");

        return .{ .json = .{ .status = 200, .body = out.written() } };
    }

    fn indexAfter(items: []const MockMessage, after: []const u8) ?usize {
        if (after.len == 0) return 0;
        for (items, 0..) |msg, i| if (std.mem.eql(u8, msg.event, after)) return i + 1;
        return null;
    }

    fn param(arena: Allocator, query: []const u8, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            const k, const v = std.mem.cut(u8, pair, "=") orelse continue;
            if (!std.mem.eql(u8, k, name)) continue;

            const out = arena.alloc(u8, v.len) catch return null;
            var o: usize = 0;
            var i: usize = 0;
            while (i < v.len) : (i += 1) {
                if (v[i] == '%' and i + 2 < v.len) {
                    out[o] = std.fmt.parseInt(u8, v[i + 1 .. i + 3], 16) catch return null;
                    i += 2;
                } else out[o] = v[i];
                o += 1;
            }

            return out[0..o];
        }
        return null;
    }
};

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    mock: Mock,
    sink: FakeSink,
    env: std.process.Environ.Map,
    config: core.Config = .{},
    tmp: testing.TmpDir,

    fn init(f: *Fixture) !void {
        f.arena_state = .init(testing.allocator);
        f.tmp = testing.tmpDir(.{});
        try f.mock.listen(testing.allocator, testing.io);
        f.sink = .init(testing.allocator);
        f.env = .init(testing.allocator);

        const root = try f.tmp.dir.realPathFileAlloc(testing.io, ".", f.arena());
        try f.env.put("XDG_STATE_HOME", try std.fs.path.join(f.arena(), &.{ root, "state" }));

        f.config = .{};
        f.config.sources.capy = .{ .enabled = true, .api_key = key, .base_url = try f.mock.baseUrl(f.arena()) };
    }

    fn deinit(f: *Fixture) void {
        f.mock.stop();
        f.sink.deinit();
        f.env.deinit();
        f.tmp.cleanup();
        f.arena_state.deinit();
    }

    fn arena(f: *Fixture) Allocator {
        return f.arena_state.allocator();
    }

    fn source(f: *Fixture, options: capy.Options) !capy.Source {
        var opts = options;
        opts.backfill = true;
        opts.backoff = .{ .base_ms = 1, .max_ms = 4, .auth_ms = 50 };
        opts.tick_every = .fromMilliseconds(5);
        return capy.Source.init(testing.allocator, testing.io, &f.env, &f.config, f.sink.entrySink(), opts);
    }

    fn bodies(f: *Fixture) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (f.sink.entries.items) |e| try out.appendSlice(f.arena(), e.body);
        return out.items;
    }
};

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

const t_late: core.Micros = 1_795_996_800_000_000;

test "discovery pages through projects and threads, maps repos to projects and honors exclusions" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    f.mock.projects =
        \\{"items":[
        \\{"id":"proj_w","name":"Widgets","code":"WID","description":null,"visibility":"org","repos":[{"repoFullName":"brackwater/docs","baseBranch":"main","mode":"lazy"},{"repoFullName":"Brackwater/Widgets","baseBranch":"main","mode":"primary"}],"createdAt":"x","updatedAt":"x"},
        \\{"id":"proj_o","name":"Ops","code":"OPS","description":null,"visibility":"org","repos":[],"createdAt":"x","updatedAt":"x"},
        \\{"id":"proj_s","name":"Secret","code":"SEC","description":null,"visibility":"private","repos":[],"createdAt":"x","updatedAt":"x"}]}
    ;

    try f.mock.addThread(.{ .id = "jam_w000001", .project = "proj_w" });
    try f.mock.addThread(.{ .id = "jam_w000002", .project = "proj_w", .status = "working" });
    try f.mock.addThread(.{ .id = "jam_w000003", .project = "proj_w" });
    try f.mock.addThread(.{ .id = "jam_o000001", .project = "proj_o" });
    try f.mock.addThread(.{ .id = "jam_s000001", .project = "proj_s" });
    for ([_][]const u8{ "jam_w000001", "jam_w000002", "jam_w000003", "jam_o000001", "jam_s000001" }) |id| {
        try f.mock.say(id, "user", try std.fmt.allocPrint(f.arena(), "hello from {s}", .{id}), "2026-11-24T10:00:00.000Z");
    }

    f.config.sources.capy.exclude_projects = &.{"SE*"};
    f.config.sources.capy.exclude_threads = &.{"jam_w000003"};

    var s = try f.source(.{});
    defer s.deinit();
    try s.runOnce(t_late);

    const stats = s.snapshot();
    try testing.expectEqual(@as(usize, 3), stats.threads);
    try testing.expectEqual(@as(usize, 3), f.sink.entries.items.len);
    try testing.expectEqual(@as(usize, 3), f.mock.requests("/api/v1/threads?projectId=proj_w&limit=100"));
    try testing.expectEqual(@as(usize, 0), f.mock.requests("/api/v1/threads?projectId=proj_s"));
    try testing.expectEqual(@as(usize, 0), f.mock.requests("/api/v1/threads/jam_w000003/"));

    const body = try f.bodies();
    try testing.expect(std.mem.indexOf(u8, body, "jam_s000001") == null);
    try testing.expect(std.mem.indexOf(u8, body, "jam_w000003") == null);

    var widgets: usize = 0;
    var ops: usize = 0;
    for (f.sink.entries.items) |e| {
        if (std.mem.eql(u8, e.project.?, "github.com/Brackwater/Widgets")) widgets += 1;
        if (std.mem.eql(u8, e.project.?, "capy/OPS")) ops += 1;
    }
    try testing.expectEqual(@as(usize, 2), widgets);
    try testing.expectEqual(@as(usize, 1), ops);

    f.config.sources.capy.exclude_projects = &.{};
    f.config.sources.capy.exclude_threads = &.{};
    f.config.sources.capy.projects = &.{"OPS"};
    f.config.capture.exclude_projects = &.{"capy/*"};

    var only_ops = try f.source(.{});
    defer only_ops.deinit();
    try only_ops.runOnce(t_late);

    try testing.expectEqual(@as(usize, 1), only_ops.snapshot().excluded_threads);
    try testing.expectEqual(@as(usize, 3), f.sink.entries.items.len);
}

test "catch-up pages messages, redacts and segments them, and resumes from the durable cursor" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    f.mock.projects = "{\"items\":[{\"id\":\"proj_w\",\"name\":\"Widgets\",\"code\":\"WID\",\"repos\":[{\"repoFullName\":\"brackwater/widgets\",\"baseBranch\":\"main\",\"mode\":\"primary\"}]}]}";
    try f.mock.addThread(.{ .id = "jam_c000001", .project = "proj_w" });
    const secret = try std.mem.concat(f.arena(), u8, &.{ "gh" ++ "p_", "a1B2c3D4e5F6g7H8", "i9J0k1L2m3N4o5P6q7R8" });
    try f.mock.say("jam_c000001", "user", try std.fmt.allocPrint(f.arena(), "Deploy with GITHUB_TOKEN={s} to the staging cluster.", .{secret}), "2026-11-24T10:00:00.000Z");
    try f.mock.say("jam_c000001", "tool", "Running the deploy script", "2026-11-24T10:00:05.000Z");
    try f.mock.say("jam_c000001", "assistant", "Staging deploy finished; the berth service is on port 7443.", "2026-11-24T10:00:30.000Z");
    try f.mock.say("jam_c000001", "user", "   ", "2026-11-24T10:00:40.000Z");
    try f.mock.say("jam_c000001", "user", "Thanks, now pin the base image.", "2026-11-24T10:00:50.000Z");

    {
        var s = try f.source(.{});
        defer s.deinit();
        try s.runOnce(t_late);
        try testing.expectEqual(@as(u64, 5), s.snapshot().messages);
    }

    try testing.expectEqual(@as(usize, 1), f.sink.entries.items.len);
    const first = f.sink.entries.items[0];
    try testing.expectEqual(@as(usize, 4), first.turns);
    try testing.expectEqual(core.types.Author.mixed, first.author);
    try testing.expectEqualStrings("github.com/brackwater/widgets", first.project.?);
    try testing.expectEqual(@as(i32, 1), first.seq);
    try testing.expect(std.mem.indexOf(u8, first.body, secret) == null);
    try testing.expect(std.mem.indexOf(u8, first.body, "i9J0k1L2m3N4o5P6") == null);
    try testing.expect(std.mem.indexOf(u8, first.body, "[REDACTED:") != null);
    try testing.expect(std.mem.indexOf(u8, first.body, "\"name\":\"bash\",\"args_preview\":\"Running the deploy script\"") != null);
    try testing.expect(std.mem.indexOf(u8, first.body, "port 7443") != null);

    const c = capy.Cursor.decode(f.arena(), f.sink.cursors.get("jam_c000001").?).?;
    try testing.expectEqualStrings(f.mock.thread("jam_c000001").messages.items[3].event, c.after.?);
    try testing.expectEqual(@as(u32, 1), c.skip);
    try testing.expectEqual(@as(i32, 1), c.seq);

    try f.mock.say("jam_c000001", "user", "Also rotate the staging credentials.", "2026-11-24T11:00:00.000Z");
    try f.mock.say("jam_c000001", "assistant", "Rotated; the old ones are revoked.", "2026-11-24T11:00:20.000Z");

    {
        var s = try f.source(.{});
        defer s.deinit();
        try s.runOnce(1795518050000000);
        try testing.expectEqual(@as(u64, 2), s.snapshot().messages);
    }

    try testing.expectEqual(@as(usize, 1), f.sink.entries.items.len);

    {
        var s = try f.source(.{});
        defer s.deinit();
        try s.runOnce(t_late);
        const stats = s.snapshot();
        try testing.expectEqual(@as(u64, 2), stats.messages);
        try testing.expectEqual(@as(u64, 0), stats.duplicates);
    }

    try testing.expectEqual(@as(usize, 2), f.sink.entries.items.len);
    try testing.expectEqual(@as(i32, 2), f.sink.entries.items[1].seq);
    try testing.expectEqual(@as(usize, 2), f.sink.entries.items[1].turns);

    {
        var s = try f.source(.{});
        defer s.deinit();
        try s.runOnce(t_late);
        try testing.expectEqual(@as(u64, 0), s.snapshot().messages);
    }

    const body = try f.bodies();
    for ([_][]const u8{ "pin the base image", "rotate the staging credentials", "old ones are revoked", "berth service" }) |text| {
        try testing.expectEqual(@as(usize, 1), count(body, text));
    }
}

test "a paused source drops Capy turns instead of capturing them" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    f.mock.projects = "{\"items\":[{\"id\":\"proj_o\",\"code\":\"OPS\"}]}";
    try f.mock.addThread(.{ .id = "jam_p000001", .project = "proj_o" });
    try f.mock.say("jam_p000001", "user", "private while paused", "2026-11-24T10:00:00.000Z");
    const sd = try std.fs.path.join(f.arena(), &.{ f.env.get("XDG_STATE_HOME").?, "graf" });
    try state.setPaused(testing.io, sd, true);

    var s = try f.source(.{});
    defer s.deinit();
    try s.runOnce(t_late);

    try testing.expectEqual(@as(usize, 0), f.sink.entries.items.len);
    try testing.expectEqual(@as(u64, 1), s.snapshot().dropped_turns);
}

test "rate limits and server errors back off and retry; a rejected key fails without retrying" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    f.mock.projects = "{\"items\":[{\"id\":\"proj_o\",\"code\":\"OPS\"}]}";
    try f.mock.addThread(.{ .id = "jam_r000001", .project = "proj_o" });
    try f.mock.say("jam_r000001", "user", "retry me", "2026-11-24T10:00:00.000Z");

    try f.mock.failures.append(f.mock.alloc(), .{ .prefix = "/projects", .status = 429, .retry_after = 0 });
    try f.mock.failures.append(f.mock.alloc(), .{ .prefix = "/threads?", .status = 503 });
    try f.mock.failures.append(f.mock.alloc(), .{ .prefix = "/threads/jam_r000001/messages", .status = 502 });

    {
        var s = try f.source(.{});
        defer s.deinit();
        try s.runOnce(t_late);
        try testing.expectEqual(@as(u64, 3), s.snapshot().backoffs);
    }

    try testing.expectEqual(@as(usize, 1), f.sink.entries.items.len);

    try f.mock.failures.append(f.mock.alloc(), .{ .prefix = "/projects", .status = 401 });
    var s = try f.source(.{});
    defer s.deinit();

    try testing.expectError(error.Unauthorized, s.runOnce(t_late));
    try testing.expectEqual(@as(u64, 0), s.snapshot().backoffs);

    for (0..5) |_| try f.mock.failures.append(f.mock.alloc(), .{ .prefix = "/projects", .status = 503 });
    try testing.expectError(error.Unavailable, s.runOnce(t_late));
    try testing.expectEqual(@as(u64, 4), s.snapshot().backoffs);
}

fn waitUntil(s: *capy.Source, sink: *FakeSink, entries: usize) !void {
    var waited: usize = 0;
    while (true) : (waited += 1) {
        {
            s.mutex.lockUncancelable(testing.io);
            defer s.mutex.unlock(testing.io);
            if (sink.entries.items.len >= entries) return;
        }

        if (waited > 1000) return error.Timeout;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "a working thread streams transcript frames and a dropped stream resumes without gaps or duplicates" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    f.mock.projects = "{\"items\":[{\"id\":\"proj_o\",\"code\":\"OPS\"}]}";
    try f.mock.addThread(.{ .id = "jam_s000001", .project = "proj_o", .status = "working", .paged = 2 });
    const texts = [_][]const u8{ "first: plan the migration", "second: run the dry run", "third: dry run passed", "fourth: apply to staging", "fifth: staging is healthy", "sixth: ship it" };
    for (texts, 0..) |text, i| try f.mock.say("jam_s000001", if (i % 2 == 0) "user" else "assistant", text, try std.fmt.allocPrint(f.arena(), "2026-11-24T10:00:{d:0>2}.000Z", .{i}));
    f.mock.cut_first_stream_after = 4;

    var s = try f.source(.{ .segment = .{ .max_tokens = 1 } });
    defer s.deinit();
    var run = try testing.io.concurrent(capy.Source.run, .{&s});
    errdefer run.cancel(testing.io) catch {};
    try waitUntil(&s, &f.sink, texts.len);
    run.cancel(testing.io) catch {};

    try testing.expectEqual(texts.len, f.sink.entries.items.len);
    for (texts, f.sink.entries.items, 1..) |text, e, seq| {
        try testing.expect(std.mem.indexOf(u8, e.body, text) != null);
        try testing.expectEqual(@as(i32, @intCast(seq)), e.seq);
    }

    const body = try f.bodies();
    for (texts) |text| try testing.expectEqual(@as(usize, 1), count(body, text));

    const stats = s.snapshot();
    try testing.expectEqual(@as(u64, 1), stats.stream_drops);
    try testing.expectEqual(@as(u64, 2), stats.streams_opened);
    try testing.expectEqual(@as(u64, 0), stats.duplicates);

    const events = f.mock.thread("jam_s000001").messages.items;
    const resumed = try std.fmt.allocPrint(f.arena(), "/api/v1/threads/jam_s000001/stream|{s}", .{events[3].event});
    try testing.expectEqual(@as(usize, 1), f.mock.requests(resumed));
    try testing.expectEqual(@as(usize, 1), f.mock.exact("/api/v1/threads/jam_s000001/stream|"));

    const c = capy.Cursor.decode(f.arena(), f.sink.cursors.get("jam_s000001").?).?;
    try testing.expectEqualStrings(events[5].event, c.after.?);
    try testing.expectEqual(@as(u32, 0), c.skip);
}

test "cancel stops a source that holds a live stream" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    f.mock.projects = "{\"items\":[{\"id\":\"proj_o\",\"code\":\"OPS\"}]}";
    try f.mock.addThread(.{ .id = "jam_h000001", .project = "proj_o", .status = "working", .paged = 0 });
    try f.mock.say("jam_h000001", "user", "live only", "2026-11-24T10:00:00.000Z");
    f.mock.hold_streams = true;

    var s = try f.source(.{ .segment = .{ .max_tokens = 1 } });
    defer s.deinit();
    var run = try testing.io.concurrent(capy.Source.run, .{&s});
    errdefer run.cancel(testing.io) catch {};
    try waitUntil(&s, &f.sink, 1);
    run.cancel(testing.io) catch {};

    try testing.expectEqual(@as(u32, 0), s.active_streams);
    try testing.expectEqual(@as(u64, 1), s.snapshot().streams_opened);
}
