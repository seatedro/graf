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
    tailscale_origin: []const u8 = "",
    tailscale_logins: []const []const u8 = &.{},
    version: []const u8 = "",

    pub fn validate(o: Options) !void {
        const address = if (o.listen.len > 0) try net.IpAddress.parseLiteral(o.listen) else null;
        if (o.tailscale_origin.len > 0) {
            const authority = std.mem.cutPrefix(u8, o.tailscale_origin, "https://") orelse return error.InvalidTailscaleOrigin;
            const host, const port = std.mem.cut(u8, authority, ":") orelse .{ authority, "443" };
            net.HostName.validate(host) catch return error.InvalidTailscaleOrigin;
            if (!std.mem.endsWith(u8, host, ".ts.net")) return error.InvalidTailscaleOrigin;
            for (port) |c| if (!std.ascii.isDigit(c)) return error.InvalidTailscaleOrigin;
            if ((std.fmt.parseInt(u16, port, 10) catch return error.InvalidTailscaleOrigin) == 0) return error.InvalidTailscaleOrigin;
            if (address == null or !isLoopback(address.?)) return error.TailscaleRequiresLoopback;
        } else if (o.tailscale_logins.len != 0) return error.MissingTailscaleOrigin;

        if (address != null and !isLoopback(address.?) and o.token.len == 0) return error.TokenRequired;
    }
};

const Transport = enum { tcp, unix };

const Endpoint = union(enum) {
    health,
    asset: Asset,
    session,
    mcp,
    op: struct { op: api.Op, session_id: ?[]const u8 = null },
};

const Asset = enum {
    index,
    js,
    world,
    css,
    favicon,

    fn response(asset: Asset) Response {
        return switch (asset) {
            .index => .{ .status = .ok, .content_type = "text/html; charset=utf-8", .body = @embedFile("viewer/index.html") },
            .js => .{ .status = .ok, .content_type = "text/javascript; charset=utf-8", .body = @embedFile("viewer/viewer.js") },
            .world => .{ .status = .ok, .content_type = "text/javascript; charset=utf-8", .body = @embedFile("viewer/world.js") },
            .css => .{ .status = .ok, .content_type = "text/css; charset=utf-8", .body = @embedFile("viewer/viewer.css") },
            .favicon => .{ .status = .no_content },
        };
    }
};

const Route = struct { method: std.http.Method, endpoint: Endpoint };

const fixed_routes = [_]struct { path: []const u8, route: Route }{
    .{ .path = "/", .route = .{ .method = .GET, .endpoint = .{ .asset = .index } } },
    .{ .path = "/viewer.js", .route = .{ .method = .GET, .endpoint = .{ .asset = .js } } },
    .{ .path = "/world.js", .route = .{ .method = .GET, .endpoint = .{ .asset = .world } } },
    .{ .path = "/viewer.css", .route = .{ .method = .GET, .endpoint = .{ .asset = .css } } },
    .{ .path = "/favicon.ico", .route = .{ .method = .GET, .endpoint = .{ .asset = .favicon } } },
    .{ .path = "/v1/graph/session", .route = .{ .method = .GET, .endpoint = .session } },
    .{ .path = "/v1/graph/overview", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .graph_overview } } } },
    .{ .path = "/v1/graph/map", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .graph_map } } } },
    .{ .path = "/v1/graph/neighborhood", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .graph_neighborhood } } } },
    .{ .path = "/v1/graph/search", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .graph_search } } } },
    .{ .path = "/v1/graph/entity", .route = .{ .method = .POST, .endpoint = .{ .op = .{ .op = .graph_entity } } } },
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
    content_type: []const u8 = "application/json",
    close: bool = false,
    allow: ?[]const u8 = null,
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
        try s.options.validate();
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
            const loopback = transport == .tcp and isLoopback(s.tcp.?.socket.address) and isLoopback(stream.socket.address);
            const response = s.respondTo(arena_state.allocator(), &request, transport, loopback) catch return;

            var headers = [_]std.http.Header{
                .{ .name = "content-security-policy", .value = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "referrer-policy", .value = "no-referrer" },
                .{ .name = "cross-origin-resource-policy", .value = "same-origin" },
                undefined,
                undefined,
                undefined,
            };
            var count: usize = headers.len - 3;

            if (response.body.len > 0) {
                headers[count] = .{ .name = "content-type", .value = response.content_type };
                count += 1;
            }
            if (response.allow) |allow| {
                headers[count] = .{ .name = "allow", .value = allow };
                count += 1;
            }
            if (response.status == .unauthorized) {
                headers[count] = .{ .name = "www-authenticate", .value = "Bearer realm=\"graf\"" };
                count += 1;
            }

            request.respond(response.body, .{
                .status = response.status,
                .keep_alive = !response.close,
                .extra_headers = headers[0..count],
            }) catch return;

            if (response.close or !keep_alive) return;
        }
    }

    fn respondTo(s: *Server, arena: Allocator, request: *std.http.Server.Request, transport: Transport, loopback: bool) !Response {
        const target = try arena.dupe(u8, request.head.target);
        const path, const query = std.mem.cut(u8, target, "?") orelse .{ target, "" };
        const headers = RequestHeaders.parse(request) orelse return errorResponse(arena, .forbidden, "invalid request headers");
        const route = try resolve(arena, path);
        const port = if (transport == .tcp) s.boundPort() else 80;
        const identity = headers.identity(s.options, transport, loopback, port) orelse return errorResponse(arena, .forbidden, "origin not allowed");
        if (headers.cross_site and !(route != null and route.?.endpoint == .asset))
            return errorResponse(arena, .forbidden, "cross-origin request");
        if (!identity.permits(route))
            return errorResponse(arena, .unauthorized, "unauthorized");

        const found = route orelse return errorResponse(arena, .not_found, "not found");
        if (request.head.method != found.method) {
            var response = try errorResponse(arena, .method_not_allowed, "method not allowed");
            response.allow = @tagName(found.method);
            return response;
        }

        switch (found.endpoint) {
            .asset => |asset| return asset.response(),
            .session => return .{ .status = .ok, .body = try std.json.Stringify.valueAlloc(arena, identity, .{ .emit_null_optional_fields = false }) },
            .health => return .{
                .status = .ok,
                .body = try std.json.Stringify.valueAlloc(arena, .{ .ok = true, .version = s.options.version }, .{}),
            },
            .mcp => {
                if (header(request, "mcp-protocol-version")) |version| {
                    if (!mcp.supportsVersion(version)) return errorResponse(arena, .bad_request, "unsupported MCP-Protocol-Version");
                }

                const body = readBody(arena, request) catch |err| return bodyError(arena, err);
                const reply = try mcp.handlePost(arena, s.handler, s.options.version, body) orelse
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

fn bearerMatches(value: []const u8, token: []const u8) bool {
    if (token.len == 0) return false;
    const scheme, const credentials = std.mem.cut(u8, value, " ") orelse return false;
    if (!std.ascii.eqlIgnoreCase(scheme, "bearer")) return false;

    const Sha256 = std.crypto.hash.sha2.Sha256;
    var presented: [Sha256.digest_length]u8 = undefined;
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(std.mem.trim(u8, credentials, " "), &presented, .{});
    Sha256.hash(token, &expected, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, presented, expected);
}

fn isLoopback(address: net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &net.Ip6Address.loopback(0).bytes),
    };
}

fn localAuthority(host: []const u8, port: u16) bool {
    const name, const explicit = std.mem.cut(u8, host, ":") orelse .{ host, "" };
    if (std.ascii.eqlIgnoreCase(name, "localhost")) {
        if (std.mem.eql(u8, name, host)) return port == 80;
        return (std.fmt.parseInt(u16, explicit, 10) catch return false) == port;
    }

    const address = net.IpAddress.parseLiteral(host) catch return false;
    const actual = address.getPort();
    return isLoopback(address) and (if (actual == 0) port == 80 else actual == port);
}

const Identity = struct {
    mode: enum { anonymous, local, bearer, tailscale } = .anonymous,
    login: ?[]const u8 = null,

    fn permits(id: Identity, route: ?Route) bool {
        if (id.mode == .local or id.mode == .bearer) return true;
        return switch ((route orelse return false).endpoint) {
            .session, .health, .asset => true,
            .mcp => false,
            .op => |op| switch (op.op) {
                .graph_overview, .graph_map, .graph_neighborhood, .graph_search, .graph_entity => id.mode == .tailscale,
                else => false,
            },
        };
    }
};

const RequestHeaders = struct {
    host: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    login: ?[]const u8 = null,
    forwarded_host: ?[]const u8 = null,
    forwarded_proto: ?[]const u8 = null,
    forwarded: bool = false,
    funnel: bool = false,
    cross_site: bool = false,

    fn parse(request: *const std.http.Server.Request) ?RequestHeaders {
        var fields: RequestHeaders = .{};
        var it = request.iterateHeaders();
        while (it.next()) |h| {
            inline for (.{
                .{ "host", "host" },                  .{ "origin", "origin" },                   .{ "authorization", "authorization" },
                .{ "tailscale-user-login", "login" }, .{ "x-forwarded-host", "forwarded_host" }, .{ "x-forwarded-proto", "forwarded_proto" },
            }) |f| {
                if (std.ascii.eqlIgnoreCase(h.name, f[0])) {
                    if (@field(fields, f[1]) != null) return null;
                    @field(fields, f[1]) = h.value;
                }
            }
            if (std.ascii.startsWithIgnoreCase(h.name, "x-forwarded-") or std.ascii.startsWithIgnoreCase(h.name, "tailscale-") or
                std.ascii.eqlIgnoreCase(h.name, "forwarded") or std.ascii.eqlIgnoreCase(h.name, "x-real-ip")) fields.forwarded = true;
            if (std.ascii.eqlIgnoreCase(h.name, "tailscale-funnel-request")) fields.funnel = true;
            if (std.ascii.eqlIgnoreCase(h.name, "sec-fetch-site") and
                !std.mem.eql(u8, h.value, "same-origin") and !std.mem.eql(u8, h.value, "none")) fields.cross_site = true;
        }
        return fields;
    }

    fn identity(h: RequestHeaders, options: Options, transport: Transport, loopback: bool, port: u16) ?Identity {
        const host = h.host orelse return null;
        if (host.len == 0) return null;
        const local_host = localAuthority(host, port);
        const expected_host = std.mem.cutPrefix(u8, options.tailscale_origin, "https://");
        const proxy_host = expected_host != null and std.ascii.eqlIgnoreCase(expected_host.?, host);
        if (options.token.len == 0 and !local_host and !proxy_host) return null;

        if (h.origin) |origin| {
            const scheme, const authority = std.mem.cut(u8, origin, "://") orelse return null;
            if (!std.ascii.eqlIgnoreCase(authority, host)) return null;
            const expected_scheme: []const u8 = if (local_host and !h.forwarded) "http" else "https";
            if (!std.mem.eql(u8, scheme, expected_scheme)) return null;
            if (h.forwarded_proto) |proto| if (!std.mem.eql(u8, scheme, proto)) return null;
        }

        if (transport == .unix and local_host and !h.forwarded) return .{ .mode = .local };
        if (h.authorization) |auth| return if (bearerMatches(auth, options.token)) .{ .mode = .bearer } else .{};
        if (!loopback) return .{};
        if (options.token.len == 0 and expected_host == null and local_host and !h.forwarded) return .{ .mode = .local };

        if (!proxy_host or h.funnel or !std.ascii.eqlIgnoreCase(h.forwarded_host orelse "", host) or
            !std.mem.eql(u8, h.forwarded_proto orelse "", "https")) return .{};
        const login = h.login orelse return .{};
        if (login.len == 0) return .{};
        for (login) |c| if (c <= ' ' or c >= 127 or c == ',') return .{};
        for (options.tailscale_logins) |allowed| {
            if (std.mem.eql(u8, allowed, login)) return .{ .mode = .tailscale, .login = login };
        }
        return if (options.tailscale_logins.len == 0) .{ .mode = .tailscale, .login = login } else .{};
    }
};

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
        .{ .path = "/v1/graph/overview", .op = .graph_overview },
        .{ .path = "/v1/graph/neighborhood", .op = .graph_neighborhood },
        .{ .path = "/v1/graph/search", .op = .graph_search },
        .{ .path = "/v1/graph/entity", .op = .graph_entity },
        .{ .path = "/v1/graph/map", .op = .graph_map },
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

        r = try c.request(arena, .GET, "/v1/graph/session", null);
        try testing.expectEqualStrings(if (c.target == .unix) "{\"mode\":\"local\"}" else "{\"mode\":\"bearer\"}", r.body);

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

    const other_loopback_origin = try rawExchange(io, port, "GET /v1/health HTTP/1.1\r\nhost: x\r\norigin: http://localhost:3000\r\nconnection: close\r\n\r\n");
    defer gpa.free(other_loopback_origin);
    try testing.expect(std.mem.startsWith(u8, other_loopback_origin, "HTTP/1.1 403 "));

    const local = try rawExchange(io, port, try std.fmt.allocPrint(arena, "GET /v1/graph/session HTTP/1.1\r\nhost: localhost:{d}\r\norigin: http://localhost:{d}\r\nconnection: close\r\n\r\n", .{ port, port }));
    defer gpa.free(local);
    try testing.expect(std.mem.startsWith(u8, local, "HTTP/1.1 200 "));
    try testing.expect(std.mem.endsWith(u8, local, "{\"mode\":\"anonymous\"}"));

    const remote = try rawExchange(io, port, "POST /v1/graph/overview HTTP/1.1\r\nhost: hub.example.ts.net:7443\r\norigin: https://hub.example.ts.net:7443\r\nx-forwarded-proto: https\r\nauthorization: Bearer s3cret\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}");
    defer gpa.free(remote);
    try testing.expect(std.mem.startsWith(u8, remote, "HTTP/1.1 200 "));
    try testing.expect(std.mem.endsWith(u8, remote, "{\"text\":\"ok graph_overview\"}"));
}

test "viewer validates the identity proxy configuration before listening" {
    const https = "https://hub.example.ts.net:7443";
    try (Options{ .tailscale_origin = https }).validate();
    try (Options{ .listen = "[::1]:7420", .tailscale_origin = https }).validate();
    try testing.expectError(error.TailscaleRequiresLoopback, (Options{ .listen = "0.0.0.0:7420", .token = "test-token", .tailscale_origin = https }).validate());
    try testing.expectError(error.MissingTailscaleOrigin, (Options{ .tailscale_logins = &.{"user@example.org"} }).validate());
    for ([_][]const u8{ "http://hub.example.ts.net", https ++ "/", "https://*.example.ts.net", "https://user@hub.example.ts.net", "https://hub.example.ts.net:99999", "https://hub.example.ts.net.invalid" }) |bad|
        try testing.expectError(error.InvalidTailscaleOrigin, (Options{ .tailscale_origin = bad }).validate());
}

test "viewer accepts only the configured proxy on a loopback connection" {
    const options: Options = .{ .token = "test-token", .tailscale_origin = "https://hub.example.ts.net:7443", .tailscale_logins = &.{"user@example.org"} };
    const headers: RequestHeaders = .{ .host = "hub.example.ts.net:7443", .forwarded_host = "hub.example.ts.net:7443", .forwarded_proto = "https", .login = "user@example.org", .forwarded = true };

    try testing.expectEqual(.tailscale, headers.identity(options, .tcp, true, 7420).?.mode);
    try testing.expectEqual(.anonymous, headers.identity(options, .tcp, false, 7420).?.mode);
    try testing.expectEqual(.anonymous, headers.identity(.{ .token = "test-token" }, .tcp, true, 7420).?.mode);
    var altered = headers;
    altered.funnel = true;
    try testing.expectEqual(.anonymous, altered.identity(options, .tcp, true, 7420).?.mode);
    altered = headers;
    altered.login = "other@example.org";
    try testing.expectEqual(.anonymous, altered.identity(options, .tcp, true, 7420).?.mode);
    altered = headers;
    altered.origin = "http://hub.example.ts.net:7443";
    try testing.expect(altered.identity(options, .tcp, true, 7420) == null);
    altered = headers;
    altered.forwarded_proto = "http";
    try testing.expectEqual(.anonymous, altered.identity(options, .tcp, true, 7420).?.mode);
    altered = headers;
    altered.forwarded_host = "hub.example.ts.net";
    try testing.expectEqual(.anonymous, altered.identity(options, .tcp, true, 7420).?.mode);
    altered = headers;
    altered.authorization = "Bearer test-token";
    altered.origin = "https://hub.example.ts.net:7443";
    try testing.expectEqual(.bearer, altered.identity(.{ .token = "test-token" }, .tcp, true, 7420).?.mode);

    for ([_][]const u8{ "localhost:7420", "127.0.0.1:7420", "[::1]:7420" }) |host| {
        const local: RequestHeaders = .{ .host = host };
        try testing.expectEqual(.local, local.identity(.{}, .tcp, true, 7420).?.mode);
        try testing.expectEqual(.anonymous, local.identity(.{ .tailscale_origin = options.tailscale_origin }, .tcp, true, 7420).?.mode);
        var proxied = local;
        proxied.forwarded = true;
        try testing.expectEqual(.anonymous, proxied.identity(.{}, .tcp, true, 7420).?.mode);
    }
    for ([_][]const u8{ "hub.example.ts.net:7443", "localhost.invalid:7420", "127.0.0.1:8000", "127.0.0.1:7420@other.invalid" }) |host| {
        const rebinding: RequestHeaders = .{ .host = host };
        try testing.expect(rebinding.identity(.{}, .tcp, true, 7420) == null);
    }
}

test "viewer shell and session bootstrap never grant anonymous data access" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake: FakeHandler = .{ .io = io };
    defer fake.deinit();
    var server = Server.init(gpa, io, fake.handler(), .{ .listen = "127.0.0.1:0", .tailscale_origin = "https://hub.example.ts.net:7443" });
    try server.start();
    defer server.deinit();
    var running = try io.concurrent(Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch {};
    }

    const proxy = "host: hub.example.ts.net:7443\r\nx-forwarded-host: hub.example.ts.net:7443\r\nx-forwarded-proto: https\r\n";
    const user = proxy ++ "tailscale-user-login: user@example.org\r\n";
    const origin = "origin: https://hub.example.ts.net:7443\r\n";
    const Case = struct { method: []const u8, path: []const u8, headers: []const u8, status: []const u8, contains: []const u8 = "" };
    for ([_]Case{
        .{ .method = "GET", .path = "/", .headers = proxy, .status = "200", .contains = "content-type: text/html" },
        .{ .method = "GET", .path = "/viewer.css", .headers = proxy, .status = "200", .contains = "content-type: text/css" },
        .{ .method = "GET", .path = "/viewer.js", .headers = proxy, .status = "200", .contains = "content-type: text/javascript" },
        .{ .method = "GET", .path = "/favicon.ico", .headers = proxy, .status = "204" },
        .{ .method = "GET", .path = "/v1/graph/session", .headers = proxy, .status = "200", .contains = "{\"mode\":\"anonymous\"}" },
        .{ .method = "GET", .path = "/v1/graph/session", .headers = user, .status = "200", .contains = "{\"mode\":\"tailscale\",\"login\":\"user@example.org\"}" },
        .{ .method = "POST", .path = "/v1/graph/neighborhood", .headers = proxy ++ origin, .status = "401" },
        .{ .method = "POST", .path = "/v1/graph/overview", .headers = proxy ++ "tailscale-user-login:  \r\n", .status = "401" },
        .{ .method = "POST", .path = "/v1/graph/overview", .headers = user ++ origin, .status = "200", .contains = "ok graph_overview" },
        .{ .method = "POST", .path = "/v1/graph/entity", .headers = user ++ "origin: https://other.example.ts.net:7443\r\n", .status = "403" },
        .{ .method = "POST", .path = "/v1/graph/entity", .headers = user ++ "tailscale-user-login: another@example.org\r\n", .status = "403" },
        .{ .method = "POST", .path = "/v1/graph/search", .headers = user ++ "host: other.invalid\r\n", .status = "403" },
        .{ .method = "POST", .path = "/v1/remember", .headers = user ++ origin, .status = "401" },
        .{ .method = "POST", .path = "/mcp", .headers = user, .status = "401" },
        .{ .method = "GET", .path = "/v1/brief", .headers = user, .status = "401" },
        .{ .method = "POST", .path = "/v1/graph/entity", .headers = "host: other.invalid\r\n", .status = "403" },
        .{ .method = "POST", .path = "/v1/graph/entity", .headers = user ++ "sec-fetch-site: cross-site\r\n", .status = "403" },
    }) |case| {
        const bytes = try std.fmt.allocPrint(arena, "{s} {s} HTTP/1.1\r\n{s}connection: close\r\n{s}", .{
            case.method, case.path, case.headers, if (std.mem.eql(u8, case.method, "POST")) "content-length: 2\r\n\r\n{}" else "\r\n",
        });
        const response = try rawExchange(io, server.boundPort(), bytes);
        defer gpa.free(response);
        try testing.expect(std.mem.startsWith(u8, response, try std.fmt.allocPrint(arena, "HTTP/1.1 {s} ", .{case.status})));
        if (case.contains.len > 0) try testing.expect(std.mem.find(u8, response, case.contains) != null);
        try testing.expect(std.mem.find(u8, response, "script-src 'self'; style-src 'self'") != null);
        try testing.expect(std.mem.find(u8, response, "cache-control: no-store") != null);
    }
    try testing.expectEqual(1, fake.count);
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
