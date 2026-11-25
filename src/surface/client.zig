const std = @import("std");
const api = @import("api.zig");

const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;

pub const max_response_len = 16 * 1024 * 1024;

pub const Target = union(enum) {
    unix: []const u8,
    tcp: []const u8,
};

pub const Client = struct {
    io: Io,
    target: Target,
    token: []const u8,

    pub fn init(io: Io, target: Target, token: []const u8) Client {
        return .{ .io = io, .target = target, .token = token };
    }

    pub fn request(c: *const Client, arena: Allocator, method: std.http.Method, path: []const u8, body: ?[]const u8) !api.Reply {
        const stream = try c.connect();
        defer stream.close(c.io);

        var send_buffer: [4096]u8 = undefined;
        var writer = stream.writer(c.io, &send_buffer);
        const out = &writer.interface;

        const host = switch (c.target) {
            .unix => "localhost",
            .tcp => |address| address,
        };

        sendRequest(out, method, path, host, c.token, body) catch |err| switch (err) {
            error.WriteFailed => return writer.err orelse err,
        };

        var recv_buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(c.io, &recv_buffer);
        var http_reader: std.http.Reader = .{
            .in = &reader.interface,
            .state = .ready,
            .interface = undefined,
            .max_head_len = recv_buffer.len,
            .side = .response,
        };

        const head_bytes = http_reader.receiveHead() catch |err| switch (err) {
            error.ReadFailed => return reader.err orelse err,
            else => |e| return e,
        };
        const head = try std.http.Client.Response.Head.parse(head_bytes);
        const status: u16 = @backingInt(head.status);

        const body_reader = http_reader.bodyReader(try arena.alloc(u8, 4096), head.transfer_encoding, head.content_length);
        const data = body_reader.allocRemaining(arena, .limited(max_response_len)) catch |err| switch (err) {
            error.ReadFailed => {
                if (http_reader.body_err) |e| return e;
                return reader.err orelse err;
            },
            else => |e| return e,
        };

        return .{ .status = status, .body = data };
    }

    pub fn health(c: *const Client) Io.Cancelable!bool {
        var buffer: [16 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const response = c.request(fba.allocator(), .GET, "/v1/health", null) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        return response.status == 200;
    }

    pub fn handler(c: *Client) api.Handler {
        return .{ .ptr = c, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, arena: Allocator, req: api.Request) anyerror!api.Reply {
        const c: *Client = @ptrCast(@alignCast(ptr));
        const call = try route(arena, req);
        return c.request(arena, call.method, call.path, call.body);
    }

    fn connect(c: *const Client) !net.Stream {
        return switch (c.target) {
            .unix => |path| (try net.UnixAddress.init(path)).connect(c.io),
            .tcp => |address| (try net.IpAddress.parseLiteral(address)).connect(c.io, .{ .mode = .stream }),
        };
    }
};

fn sendRequest(out: *Io.Writer, method: std.http.Method, path: []const u8, host: []const u8, token: []const u8, body: ?[]const u8) Io.Writer.Error!void {
    try out.print("{t} {s} HTTP/1.1\r\nhost: {s}\r\nconnection: close\r\naccept: application/json\r\n", .{ method, path, host });
    if (token.len > 0) try out.print("authorization: Bearer {s}\r\n", .{token});
    if (body) |b| try out.print("content-type: application/json\r\ncontent-length: {d}\r\n", .{b.len});
    try out.writeAll("\r\n");
    if (body) |b| try out.writeAll(b);
    try out.flush();
}

pub const Call = struct {
    method: std.http.Method,
    path: []const u8,
    body: ?[]const u8,
};

pub fn route(arena: Allocator, req: api.Request) !Call {
    return switch (req.op) {
        .graph_overview => .{ .method = .POST, .path = "/v1/graph/overview", .body = req.body },
        .graph_map => .{ .method = .POST, .path = "/v1/graph/map", .body = req.body },
        .graph_neighborhood => .{ .method = .POST, .path = "/v1/graph/neighborhood", .body = req.body },
        .graph_search => .{ .method = .POST, .path = "/v1/graph/search", .body = req.body },
        .graph_entity => .{ .method = .POST, .path = "/v1/graph/entity", .body = req.body },
        .entries => .{ .method = .POST, .path = "/v1/entries", .body = req.body },
        .search => .{ .method = .POST, .path = "/v1/search", .body = req.body },
        .entity => .{ .method = .POST, .path = "/v1/entity", .body = req.body },
        .remember => .{ .method = .POST, .path = "/v1/remember", .body = req.body },
        .forget => .{ .method = .POST, .path = "/v1/forget", .body = req.body },
        .flush => .{ .method = .POST, .path = "/v1/hooks/flush", .body = req.body },
        .brief => .{ .method = .GET, .path = try withQuery(arena, "/v1/brief", req.body, "project"), .body = null },
        .warm => .{ .method = .POST, .path = try sessionPath(arena, req.session_id, "warm"), .body = req.body },
        .recall => .{
            .method = .GET,
            .path = try withQuery(arena, try sessionPath(arena, req.session_id, "recall"), req.body, "prompt"),
            .body = null,
        },
    };
}

fn sessionPath(arena: Allocator, session_id: ?[]const u8, action: []const u8) ![]const u8 {
    const id = session_id orelse return error.MissingSessionId;

    var out: Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("/v1/sessions/");
    try std.Uri.Component.percentEncode(&out.writer, id, isUnreserved);
    try out.writer.print("/{s}", .{action});
    return out.written();
}

fn withQuery(arena: Allocator, path: []const u8, body: []const u8, name: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.InvalidRequestBody;
    if (parsed != .object) return error.InvalidRequestBody;
    const value = parsed.object.get(name) orelse return path;
    if (value != .string) return error.InvalidRequestBody;

    var out: Io.Writer.Allocating = .init(arena);
    try out.writer.print("{s}?{s}=", .{ path, name });
    try std.Uri.Component.percentEncode(&out.writer, value.string, isUnreserved);
    return out.written();
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

pub const Spawn = *const fn (io: Io, env: *const std.process.Environ.Map, argv: []const []const u8, log_path: ?[]const u8) anyerror!void;

pub const EnsureOptions = struct {
    timeout: Io.Duration = .fromSeconds(5),
    poll_interval: Io.Duration = .fromMilliseconds(50),
    args: []const []const u8 = &.{},
    spawn: Spawn = spawnDetached,
};

pub fn ensureDaemonWith(
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    client: *const Client,
    exe_path: []const u8,
    options: EnsureOptions,
) !void {
    if (try client.health()) return;

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, exe_path);
    try argv.appendSlice(arena, options.args);
    try argv.append(arena, "serve");

    try options.spawn(io, env, argv.items, try logPath(arena, env, client.target));

    const started = Io.Timestamp.now(io, .awake);
    while (started.untilNow(io, .awake).toNanoseconds() < options.timeout.toNanoseconds()) {
        try io.sleep(options.poll_interval, .awake);
        if (try client.health()) return;
    }
    return error.DaemonUnavailable;
}

pub fn logPath(arena: Allocator, env: *const std.process.Environ.Map, target: Target) !?[]const u8 {
    switch (target) {
        .unix => |socket| {
            const dir = std.fs.path.dirname(socket) orelse ".";
            return try std.fs.path.join(arena, &.{ dir, "graf.log" });
        },
        .tcp => {
            if (env.get("XDG_STATE_HOME")) |xdg| if (xdg.len > 0) return try std.fs.path.join(arena, &.{ xdg, "graf", "graf.log" });
            if (env.get("HOME")) |home| if (home.len > 0) return try std.fs.path.join(arena, &.{ home, ".local", "state", "graf", "graf.log" });
            return null;
        },
    }
}

pub fn spawnDetached(io: Io, env: *const std.process.Environ.Map, argv: []const []const u8, log_path: ?[]const u8) !void {
    var log: ?Io.File = null;
    defer if (log) |file| file.close(io);

    if (log_path) |path| {
        if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
        const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        log = file;
        var end = file.writerStreaming(io, &.{});
        try end.seekToUnbuffered(try file.length(io));
    }

    _ = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = if (log) |file| .{ .file = file } else .ignore,
        .pgid = 0,
    });
}

const testing = std.testing;
const http = @import("http.zig");

test "route maps every op to its endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const recall = try route(arena, .{ .op = .recall, .session_id = "a b/c", .body = "{\"prompt\":\"what & why?\"}" });
    try testing.expectEqual(std.http.Method.GET, recall.method);
    try testing.expectEqualStrings("/v1/sessions/a%20b%2Fc/recall?prompt=what%20%26%20why%3F", recall.path);
    try testing.expectEqual(null, recall.body);

    try testing.expectEqualStrings("/v1/brief", (try route(arena, .{ .op = .brief })).path);
    try testing.expectError(error.MissingSessionId, route(arena, .{ .op = .warm }));
}

test "client handler round-trips every request through the daemon" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const socket_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/graf.sock", .{tmp.sub_path});

    var fake: http.FakeHandler = .{ .io = io };
    defer fake.deinit();

    var server = http.Server.init(testing.allocator, io, fake.handler(), .{ .listen = "127.0.0.1:0", .socket_path = socket_path, .token = "t" });
    try server.start();
    defer server.deinit();

    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch {};
    }

    var clients = [_]Client{
        .init(io, .{ .unix = socket_path }, ""),
        .init(io, .{ .tcp = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{server.boundPort()}) }, "t"),
    };

    const requests = [_]api.Request{
        .{ .op = .search, .body = "{\"query\":\"q\",\"project\":\"*\"}" },
        .{ .op = .entity, .body = "{\"name_or_id\":\"brackwater\"}" },
        .{ .op = .remember, .body = "{\"text\":\"We deploy on Fridays.\"}" },
        .{ .op = .forget, .body = "{\"fact_id\":\"00000000-0000-0000-0000-000000000001\"}" },
        .{ .op = .entries, .body = "{\"harness\":\"cli\",\"text\":\"hi\"}" },
        .{ .op = .flush, .body = "{\"harness\":\"cli\",\"session_id\":\"s\",\"transcript_path\":\"/t\",\"cwd\":\"/w\"}" },
        .{ .op = .brief, .body = "{\"project\":\"brackwater web/caf\u{e9}\"}" },
        .{ .op = .brief },
        .{ .op = .warm, .session_id = "sess 1/2", .body = "{\"cwd\":\"/w\"}" },
        .{ .op = .warm, .session_id = "s" },
        .{ .op = .recall, .session_id = "s1", .body = "{\"prompt\":\"what & why?\"}" },
    };

    for (&clients) |*c| {
        const h = c.handler();

        for (requests) |req| {
            const reply = try h.handle(arena, req);
            try testing.expectEqual(200, reply.status);
            try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{{\"text\":\"ok {t}\"}}", .{req.op}), reply.body);
            try fake.expectLast(req.op, req.body, req.session_id);
        }

        const failed = try h.handle(arena, .{ .op = .entity, .body = "{\"name_or_id\":\"missing\"}" });
        try testing.expectEqual(404, failed.status);
        try testing.expectEqualStrings("{\"error\":\"no such entity\"}", failed.body);
    }
}

const SpawnProbe = struct {
    var calls: usize = 0;
    var argv_len: usize = 0;
    var log_path_buffer: [256]u8 = undefined;
    var log_path: []const u8 = "";

    fn record(io: Io, env: *const std.process.Environ.Map, argv: []const []const u8, path: ?[]const u8) anyerror!void {
        _ = io;
        _ = env;

        calls += 1;
        argv_len = argv.len;
        try testing.expectEqualStrings("serve", argv[argv.len - 1]);
        log_path = try std.fmt.bufPrint(&log_path_buffer, "{s}", .{path.?});
    }
};

test "ensureDaemon returns at once when the daemon is healthy" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/graf.sock", .{tmp.sub_path});

    var fake: http.FakeHandler = .{ .io = io };
    defer fake.deinit();

    var server = http.Server.init(testing.allocator, io, fake.handler(), .{ .listen = "", .socket_path = socket_path });
    try server.start();
    defer server.deinit();

    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch {};
    }

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const client: Client = .init(io, .{ .unix = socket_path }, "");

    SpawnProbe.calls = 0;
    try ensureDaemonWith(arena_state.allocator(), io, &env, &client, "/bin/graf", .{ .spawn = SpawnProbe.record });

    try testing.expectEqual(0, SpawnProbe.calls);
}

test "ensureDaemon gives up when the daemon never comes up" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/run/graf.sock", .{tmp.sub_path});

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const client: Client = .init(io, .{ .unix = socket_path }, "");
    SpawnProbe.calls = 0;
    const started = Io.Timestamp.now(io, .awake);
    try testing.expectError(error.DaemonUnavailable, ensureDaemonWith(arena_state.allocator(), io, &env, &client, "/bin/graf", .{
        .spawn = SpawnProbe.record,
        .timeout = .fromMilliseconds(200),
        .args = &.{ "--config", "/etc/graf.toml" },
    }));

    try testing.expect(started.untilNow(io, .awake).toMilliseconds() < 2000);
    try testing.expectEqual(1, SpawnProbe.calls);
    try testing.expectEqual(4, SpawnProbe.argv_len);
    try testing.expect(std.mem.endsWith(u8, SpawnProbe.log_path, "/run/graf.log"));
}

const LateDaemon = struct {
    var server: *http.Server = undefined;
    var future: ?Io.Future(@typeInfo(@TypeOf(http.Server.run)).@"fn".return_type.?) = null;

    fn spawn(io: Io, env: *const std.process.Environ.Map, argv: []const []const u8, path: ?[]const u8) anyerror!void {
        _ = env;
        _ = argv;
        _ = path;

        try server.start();
        future = try io.concurrent(http.Server.run, .{server});
    }
};

test "ensureDaemon waits for a daemon it started" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/graf.sock", .{tmp.sub_path});

    var fake: http.FakeHandler = .{ .io = io };
    defer fake.deinit();

    var server = http.Server.init(testing.allocator, io, fake.handler(), .{ .listen = "", .socket_path = socket_path });
    LateDaemon.server = &server;
    LateDaemon.future = null;
    defer if (LateDaemon.future) |*f| {
        server.stop();
        f.await(io) catch {};
        server.deinit();
    };

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const client: Client = .init(io, .{ .unix = socket_path }, "");

    try ensureDaemonWith(arena_state.allocator(), io, &env, &client, "/bin/graf", .{ .spawn = LateDaemon.spawn });

    try testing.expect(LateDaemon.future != null);
}
