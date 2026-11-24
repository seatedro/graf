const std = @import("std");
const api = @import("api.zig");
const mcp = @import("mcp.zig");

const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;

pub const max_body_len = 4 * 1024 * 1024;

pub const Options = struct {
    listen: []const u8 = "127.0.0.1:7420",
    socket_path: ?[]const u8 = null,
    token: []const u8 = "",
    version: []const u8 = "",
};

const Transport = enum { tcp, unix };

const Endpoint = union(enum) {
    health,
    mcp,
    op: struct { op: api.Op, session_id: ?[]const u8 = null },
};

const Route = struct { method: std.http.Method, endpoint: Endpoint };

const fixed_routes = [_]struct { path: []const u8, route: Route }{
    .{ .path = "/v1/health", .route = .{ .method = .GET, .endpoint = .health } },
    .{ .path = "/mcp", .route = .{ .method = .POST, .endpoint = .mcp } },
    .{ .path = "/v1/entries", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .entries } } } },
    .{ .path = "/v1/search", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .search } } } },
    .{ .path = "/v1/entity", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .entity } } } },
    .{ .path = "/v1/remember", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .remember } } } },
    .{ .path = "/v1/forget", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .forget } } } },
    .{ .path = "/v1/brief", .route = .{ .method = .GET, .endpoint = .{ .op = .{ .op = .brief } } } },
    .{ .path = "/v1/hooks/flush", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .flush } } } },
};

const Response = struct {
    status: std.http.Status,
    body: []const u8 = "",
    close: bool = false,
};

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    handler: api.Handler,
    options: Options,
    tcp: ?net.Server = null,
    unix: ?net.Server = null,
    listeners: Io.Group = .init,
    connections: Io.Group = .init,
    stopping: Io.Event = .unset,

    pub fn init(gpa: Allocator, io: Io, handler: api.Handler, options: Options) Server {
        return .{ .gpa = gpa, .io = io, .handler = handler, .options = options };
    }

    pub fn start(s: *Server) !void {
        if (s.options.listen.len > 0) {
            const address = try net.IpAddress.parseLiteral(s.options.listen);
            s.tcp = try address.listen(s.io, .{ .reuse_address = true });
        }
        errdefer if (s.tcp) |*l| {
            l.deinit(s.io);
            s.tcp = null;
        };
        if (s.options.socket_path) |path| s.unix = try listenUnix(s.io, path);
    }

    pub fn run(s: *Server) !void {
        defer {
            s.listeners.cancel(s.io);
            s.connections.cancel(s.io);
        }
        if (s.tcp) |*l| try s.listeners.concurrent(s.io, acceptLoop, .{ s, l, .tcp });
        if (s.unix) |*l| try s.listeners.concurrent(s.io, acceptLoop, .{ s, l, .unix });
        try s.stopping.wait(s.io);
    }

    pub fn stop(s: *Server) void {
        s.stopping.set(s.io);
    }

    pub fn boundPort(s: *const Server) u16 {
        return s.tcp.?.socket.address.getPort();
    }

    pub fn deinit(s: *Server) void {
        if (s.tcp) |*l| l.deinit(s.io);
        if (s.unix) |*l| {
            l.deinit(s.io);
            Io.Dir.cwd().deleteFile(s.io, s.options.socket_path.?) catch {};
        }
        s.* = undefined;
    }

    fn acceptLoop(s: *Server, listener: *net.Server, transport: Transport) Io.Cancelable!void {
        while (true) {
            const stream = listener.accept(s.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.ConnectionAborted => continue,
                else => {
                    std.log.scoped(.http).warn("accept failed: {s}", .{@errorName(err)});
                    try s.io.sleep(.fromMilliseconds(100), .awake);
                    continue;
                },
            };
            s.connections.concurrent(s.io, serveConnection, .{ s, stream, transport }) catch stream.close(s.io);
        }
    }

    fn serveConnection(s: *Server, stream: net.Stream, transport: Transport) void {
        defer stream.close(s.io);
        var recv_buffer: [16 * 1024]u8 = undefined;
        var send_buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(s.io, &recv_buffer);
        var writer = stream.writer(s.io, &send_buffer);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        while (true) {
            _ = arena_state.reset(.retain_capacity);
            var request = http_server.receiveHead() catch return;
            const keep_alive = request.head.keep_alive;
            const response = s.respondTo(arena_state.allocator(), &request, transport) catch return;
            const json = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
            request.respond(response.body, .{
                .status = response.status,
                .keep_alive = !response.close,
                .extra_headers = if (response.body.len > 0) &json else &.{},
            }) catch return;
            if (response.close or !keep_alive) return;
        }
    }

    fn respondTo(s: *Server, arena: Allocator, request: *std.http.Server.Request, transport: Transport) !Response {
        const target = try arena.dupe(u8, request.head.target);
        const path, const query = std.mem.cut(u8, target, "?") orelse .{ target, "" };
        if (!originAllowed(request)) return errorResponse(arena, .forbidden, "origin not allowed");
        const route = try resolve(arena, path);
        const authorized = transport == .unix or s.options.token.len == 0 or bearerMatches(request, s.options.token);
        if (!authorized and !(route != null and route.?.endpoint == .health))
            return errorResponse(arena, .unauthorized, "unauthorized");
        const found = route orelse return errorResponse(arena, .not_found, "not found");
        if (request.head.method != found.method) return errorResponse(arena, .method_not_allowed, "method not allowed");

        switch (found.endpoint) {
            .health => return .{
                .status = .ok,
                .body = try std.json.Stringify.valueAlloc(arena, .{ .ok = true, .version = s.options.version }, .{}),
            },
            .mcp => {
                const body = readBody(arena, request) catch |err| return bodyError(arena, err);
                const reply = try mcp.handleMessage(arena, s.handler, s.options.version, body) orelse
                    return .{ .status = .accepted };
                return .{ .status = .ok, .body = reply };
            },
            .op => |op| {
                const body = switch (op.op) {
                    .brief => try queryBody(arena, query, "project"),
                    .recall => try queryBody(arena, query, "prompt"),
                    else => body: {
                        const raw = readBody(arena, request) catch |err| return bodyError(arena, err);
                        if (op.op == .warm and std.mem.trim(u8, raw, " \t\r\n").len == 0) break :body "{}";
                        if (!isJsonObject(arena, raw)) return errorResponse(arena, .bad_request, "request body must be a JSON object");
                        break :body raw;
                    },
                };
                const reply = s.handler.handle(arena, .{ .op = op.op, .body = body, .session_id = op.session_id }) catch |err|
                    return errorResponse(arena, .internal_server_error, @errorName(err));
                const status: std.http.Status = if (reply.status >= 100 and reply.status <= 599) @fromBackingInt(@intCast(reply.status)) else .internal_server_error;
                return .{ .status = status, .body = reply.body };
            },
        }
    }
};

fn listenUnix(io: Io, path: []const u8) !net.Server {
    const address = try net.UnixAddress.init(path);
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    if (address.connect(io)) |stream| {
        stream.close(io);
        return error.AddressInUse;
    } else |_| {}
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var server = try address.listen(io, .{});
    errdefer server.deinit(io);
    try Io.Dir.cwd().setFilePermissions(io, path, @fromBackingInt(0o600), .{});
    return server;
}

fn resolve(arena: Allocator, path: []const u8) !?Route {
    for (fixed_routes) |r| if (std.mem.eql(u8, r.path, path)) return r.route;
    const rest = std.mem.cutPrefix(u8, path, "/v1/sessions/") orelse return null;
    const raw_id, const action = std.mem.cut(u8, rest, "/") orelse return null;
    if (raw_id.len == 0) return null;
    const op: api.Op, const method: std.http.Method = if (std.mem.eql(u8, action, "warm"))
        .{ .warm, .POST }
    else if (std.mem.eql(u8, action, "recall"))
        .{ .recall, .GET }
    else
        return null;
    return .{ .method = method, .endpoint = .{ .op = .{ .op = op, .session_id = try percentDecode(arena, raw_id, false) } } };
}

fn readBody(arena: Allocator, request: *std.http.Server.Request) ![]u8 {
    if (request.head.content_length) |len| if (len > max_body_len) return error.BodyTooLarge;
    const body_reader = try request.readerExpectContinue(try arena.alloc(u8, 4096));
    return body_reader.allocRemaining(arena, .limited(max_body_len)) catch |err| switch (err) {
        error.StreamTooLong => error.BodyTooLarge,
        else => |e| e,
    };
}

fn bodyError(arena: Allocator, err: anyerror) !Response {
    if (err == error.BodyTooLarge) {
        var response = try errorResponse(arena, .payload_too_large, "request body too large");
        response.close = true;
        return response;
    }
    return err;
}

fn errorResponse(arena: Allocator, status: std.http.Status, message: []const u8) !Response {
    return .{ .status = status, .body = (try api.errorReply(arena, @backingInt(status), message)).body };
}

fn isJsonObject(arena: Allocator, body: []const u8) bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return false;
    return value == .object;
}

fn queryBody(arena: Allocator, query: []const u8, name: []const u8) ![]const u8 {
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        const raw_key, const raw_value = std.mem.cut(u8, param, "=") orelse .{ param, "" };
        if (!std.mem.eql(u8, try percentDecode(arena, raw_key, true), name)) continue;
        const value = try percentDecode(arena, raw_value, true);
        return std.fmt.allocPrint(arena, "{{{f}:{f}}}", .{ std.json.fmt(name, .{}), std.json.fmt(value, .{}) });
    }
    return "{}";
}

fn percentDecode(arena: Allocator, raw: []const u8, plus_is_space: bool) ![]const u8 {
    const buffer = try arena.dupe(u8, raw);
    if (plus_is_space) std.mem.replaceScalar(u8, buffer, '+', ' ');
    return std.Uri.percentDecodeInPlace(buffer);
}

fn header(request: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn bearerMatches(request: *const std.http.Server.Request, token: []const u8) bool {
    const value = header(request, "authorization") orelse return false;
    const scheme, const credentials = std.mem.cut(u8, value, " ") orelse return false;
    if (!std.ascii.eqlIgnoreCase(scheme, "bearer")) return false;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var presented: [Sha256.digest_length]u8 = undefined;
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(std.mem.trim(u8, credentials, " "), &presented, .{});
    Sha256.hash(token, &expected, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, presented, expected);
}

fn originAllowed(request: *const std.http.Server.Request) bool {
    const origin = header(request, "origin") orelse return true;
    const rest = std.mem.cutPrefix(u8, origin, "http://") orelse std.mem.cutPrefix(u8, origin, "https://") orelse return false;
    const host = if (std.mem.startsWith(u8, rest, "["))
        rest[0 .. (std.mem.findScalar(u8, rest, ']') orelse return false) + 1]
    else
        rest[0 .. std.mem.findScalar(u8, rest, ':') orelse rest.len];
    for ([_][]const u8{ "localhost", "127.0.0.1", "[::1]" }) |allowed| {
        if (std.ascii.eqlIgnoreCase(host, allowed)) return true;
    }
    return false;
}

const testing = std.testing;
const Client = @import("client.zig").Client;

pub const FakeHandler = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    count: usize = 0,
    last_op: ?api.Op = null,
    last_body: std.ArrayList(u8) = .empty,
    last_session: std.ArrayList(u8) = .empty,
    last_had_session: bool = false,

    pub fn handler(f: *FakeHandler) api.Handler {
        return .{ .ptr = f, .vtable = &.{ .handle = handle } };
    }

    pub fn deinit(f: *FakeHandler) void {
        f.last_body.deinit(testing.allocator);
        f.last_session.deinit(testing.allocator);
    }

    pub fn expectLast(f: *FakeHandler, op: api.Op, body: []const u8, session_id: ?[]const u8) !void {
        try testing.expectEqual(op, f.last_op.?);
        try testing.expectEqualStrings(body, f.last_body.items);
        try testing.expectEqual(session_id != null, f.last_had_session);
        if (session_id) |id| try testing.expectEqualStrings(id, f.last_session.items);
    }

    fn handle(ptr: *anyopaque, arena: Allocator, req: api.Request) anyerror!api.Reply {
        const f: *FakeHandler = @ptrCast(@alignCast(ptr));
        try f.mutex.lock(f.io);
        defer f.mutex.unlock(f.io);
        f.count += 1;
        f.last_op = req.op;
        f.last_body.clearRetainingCapacity();
        try f.last_body.appendSlice(testing.allocator, req.body);
        f.last_session.clearRetainingCapacity();
        f.last_had_session = req.session_id != null;
        if (req.session_id) |id| try f.last_session.appendSlice(testing.allocator, id);
        if (std.mem.find(u8, req.body, "explode") != null) return error.Boom;
        if (std.mem.find(u8, req.body, "missing") != null) return api.errorReply(arena, 404, "no such entity");
        return .{ .body = try std.fmt.allocPrint(arena, "{{\"text\":\"ok {t}\"}}", .{req.op}) };
    }
};

fn rawExchange(io: Io, port: u16, bytes: []const u8) ![]u8 {
    var address: net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var send_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    var recv_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    return reader.interface.allocRemaining(testing.allocator, .limited(1 << 20));
}

test "http routes over tcp and unix socket" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/state/graf.sock", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/graf.sock", .data = "stale" });

    var fake: FakeHandler = .{ .io = io };
    defer fake.deinit();
    var server = Server.init(gpa, io, fake.handler(), .{ .listen = "127.0.0.1:0", .socket_path = socket_path, .token = "s3cret", .version = "9.9.9" });
    try server.start();
    defer server.deinit();
    var running = try io.concurrent(Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch {};
    }

    const tcp_target = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{server.boundPort()});
    var clients = [_]Client{
        .init(io, .{ .tcp = tcp_target }, "s3cret"),
        .init(io, .{ .unix = socket_path }, ""),
    };

    const posts = [_]struct { path: []const u8, op: api.Op }{
        .{ .path = "/v1/entries", .op = .entries },
        .{ .path = "/v1/search", .op = .search },
        .{ .path = "/v1/entity", .op = .entity },
        .{ .path = "/v1/remember", .op = .remember },
        .{ .path = "/v1/forget", .op = .forget },
        .{ .path = "/v1/hooks/flush", .op = .flush },
    };

    for (&clients) |*c| {
        for (posts) |p| {
            const r = try c.request(arena, .POST, p.path, "{\"query\":\"x\"}");
            try testing.expectEqual(200, r.status);
            try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{{\"text\":\"ok {t}\"}}", .{p.op}), r.body);
            try fake.expectLast(p.op, "{\"query\":\"x\"}", null);
        }

        var r = try c.request(arena, .GET, "/v1/brief?project=brackwater%20web&x=1", null);
        try testing.expectEqual(200, r.status);
        try fake.expectLast(.brief, "{\"project\":\"brackwater web\"}", null);
        r = try c.request(arena, .GET, "/v1/brief", null);
        try fake.expectLast(.brief, "{}", null);

        r = try c.request(arena, .POST, "/v1/sessions/s%2F1/warm", null);
        try testing.expectEqual(200, r.status);
        try fake.expectLast(.warm, "{}", "s/1");
        r = try c.request(arena, .POST, "/v1/sessions/abc/warm", "{\"cwd\":\"/x\"}");
        try fake.expectLast(.warm, "{\"cwd\":\"/x\"}", "abc");

        r = try c.request(arena, .GET, "/v1/sessions/abc/recall?prompt=what+about%20the%20db%3F", null);
        try testing.expectEqual(200, r.status);
        try testing.expectEqualStrings("{\"text\":\"ok recall\"}", r.body);
        try fake.expectLast(.recall, "{\"prompt\":\"what about the db?\"}", "abc");

        r = try c.request(arena, .GET, "/v1/health", null);
        try testing.expectEqual(200, r.status);
        try testing.expectEqualStrings("{\"ok\":true,\"version\":\"9.9.9\"}", r.body);

        const count = fake.count;
        try testing.expectEqual(404, (try c.request(arena, .GET, "/v1/nope", null)).status);
        try testing.expectEqual(404, (try c.request(arena, .POST, "/v1/sessions/abc/sleep", "{}")).status);
        try testing.expectEqual(405, (try c.request(arena, .GET, "/v1/search", null)).status);
        try testing.expectEqual(405, (try c.request(arena, .POST, "/v1/brief", "{}")).status);
        r = try c.request(arena, .POST, "/v1/search", "not json");
        try testing.expectEqual(400, r.status);
        try testing.expectEqualStrings("{\"error\":\"request body must be a JSON object\"}", r.body);
        try testing.expectEqual(400, (try c.request(arena, .POST, "/v1/search", "[1]")).status);
        try testing.expectEqual(400, (try c.request(arena, .POST, "/v1/remember", null)).status);
        try testing.expectEqual(count, fake.count);

        r = try c.request(arena, .POST, "/v1/search", "{\"query\":\"explode\"}");
        try testing.expectEqual(500, r.status);
        try testing.expectEqualStrings("{\"error\":\"Boom\"}", r.body);
        r = try c.request(arena, .POST, "/v1/entity", "{\"name_or_id\":\"missing\"}");
        try testing.expectEqual(404, r.status);
        try testing.expectEqualStrings("{\"error\":\"no such entity\"}", r.body);

        r = try c.request(arena, .POST, "/mcp", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}");
        try testing.expectEqual(200, r.status);
        const listed = try std.json.parseFromSliceLeaky(std.json.Value, arena, r.body, .{});
        try testing.expectEqual(1, listed.object.get("id").?.integer);
        try testing.expectEqual(4, listed.object.get("result").?.object.get("tools").?.array.items.len);
        r = try c.request(arena, .POST, "/mcp", "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
        try testing.expectEqual(202, r.status);
        try testing.expectEqualStrings("", r.body);
        r = try c.request(arena, .POST, "/mcp", "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_search\",\"arguments\":{\"query\":\"q\"}}}");
        try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok search\"}],\"isError\":false}}", r.body);
        try testing.expectEqual(405, (try c.request(arena, .GET, "/mcp", null)).status);
    }

    var anonymous: Client = .init(io, .{ .tcp = tcp_target }, "");
    var wrong: Client = .init(io, .{ .tcp = tcp_target }, "nope");
    const count = fake.count;
    try testing.expectEqual(401, (try anonymous.request(arena, .POST, "/v1/search", "{\"query\":\"x\"}")).status);
    try testing.expectEqual(401, (try anonymous.request(arena, .GET, "/v1/nope", null)).status);
    try testing.expectEqual(401, (try anonymous.request(arena, .POST, "/mcp", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}")).status);
    try testing.expectEqual(401, (try wrong.request(arena, .POST, "/v1/search", "{\"query\":\"x\"}")).status);
    try testing.expectEqual(200, (try anonymous.request(arena, .GET, "/v1/health", null)).status);
    try testing.expect(try anonymous.health());
    try testing.expectEqual(count, fake.count);

    const port = server.boundPort();
    const pipelined = try rawExchange(io, port, "GET /v1/health HTTP/1.1\r\nhost: x\r\n\r\n" ++
        "POST /v1/search HTTP/1.1\r\nhost: x\r\nauthorization: Bearer s3cret\r\ncontent-length: 13\r\n\r\n{\"query\":\"k\"}" ++
        "GET /v1/health HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n");
    defer gpa.free(pipelined);
    try testing.expectEqual(3, std.mem.count(u8, pipelined, "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.find(u8, pipelined, "{\"text\":\"ok search\"}") != null);
    try testing.expect(std.mem.find(u8, pipelined, "content-type: application/json") != null);

    const too_large = try rawExchange(io, port, "POST /v1/search HTTP/1.1\r\nhost: x\r\nauthorization: Bearer s3cret\r\ncontent-length: 5000000\r\n\r\n{");
    defer gpa.free(too_large);
    try testing.expect(std.mem.startsWith(u8, too_large, "HTTP/1.1 413 "));

    const foreign = try rawExchange(io, port, "GET /v1/health HTTP/1.1\r\nhost: x\r\norigin: http://evil.test\r\nconnection: close\r\n\r\n");
    defer gpa.free(foreign);
    try testing.expect(std.mem.startsWith(u8, foreign, "HTTP/1.1 403 "));

    const local = try rawExchange(io, port, "GET /v1/health HTTP/1.1\r\nhost: x\r\norigin: http://localhost:3000\r\nconnection: close\r\n\r\n");
    defer gpa.free(local);
    try testing.expect(std.mem.startsWith(u8, local, "HTTP/1.1 200 "));
}

test "unix socket refuses to replace a live daemon" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/graf.sock", .{tmp.sub_path});
    var fake: FakeHandler = .{ .io = io };
    defer fake.deinit();
    var first = Server.init(testing.allocator, io, fake.handler(), .{ .listen = "", .socket_path = socket_path });
    try first.start();
    defer first.deinit();
    var second = Server.init(testing.allocator, io, fake.handler(), .{ .listen = "", .socket_path = socket_path });
    try testing.expectError(error.AddressInUse, second.start());
}
