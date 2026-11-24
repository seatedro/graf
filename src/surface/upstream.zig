const std = @import("std");
const api = @import("api.zig");
const client = @import("client.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Upstream = struct {
    gpa: Allocator,
    io: Io,
    http: std.http.Client,
    base: []const u8,
    authorization: []const u8,
    timeout: Io.Duration,

    pub fn init(gpa: Allocator, io: Io, url: []const u8, token: []const u8, timeout_ms: u32) !Upstream {
        const base = std.mem.trimEnd(u8, std.mem.trim(u8, url, " \t\r\n"), "/");
        const uri = std.Uri.parse(base) catch return error.InvalidUpstreamUrl;
        if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidUpstreamUrl;
        if (uri.host == null) return error.InvalidUpstreamUrl;

        const owned_base = try gpa.dupe(u8, base);
        errdefer gpa.free(owned_base);
        const authorization = if (token.len > 0) try std.fmt.allocPrint(gpa, "Bearer {s}", .{token}) else "";

        return .{
            .gpa = gpa,
            .io = io,
            .http = .{ .allocator = gpa, .io = io },
            .base = owned_base,
            .authorization = authorization,
            .timeout = .fromMilliseconds(timeout_ms),
        };
    }

    pub fn deinit(u: *Upstream) void {
        u.http.deinit();
        u.gpa.free(u.base);
        if (u.authorization.len > 0) u.gpa.free(u.authorization);
        u.* = undefined;
    }

    pub fn request(u: *Upstream, arena: Allocator, method: std.http.Method, path: []const u8, body: ?[]const u8) !api.Reply {
        const Outcome = union(enum) {
            done: anyerror!api.Reply,
            expired: Io.Cancelable!void,
        };

        var buffer: [2]Outcome = undefined;
        var select = Io.Select(Outcome).init(u.io, &buffer);
        select.concurrent(.done, exchange, .{ u, arena, method, path, body }) catch return exchange(u, arena, method, path, body);
        select.concurrent(.expired, Io.sleep, .{ u.io, u.timeout, .awake }) catch {
            select.cancelDiscard();
            return exchange(u, arena, method, path, body);
        };

        const first = select.await() catch |err| {
            select.cancelDiscard();
            return err;
        };

        select.cancelDiscard();
        return switch (first) {
            .done => |result| result,
            .expired => error.Timeout,
        };
    }

    fn exchange(u: *Upstream, arena: Allocator, method: std.http.Method, path: []const u8, body: ?[]const u8) anyerror!api.Reply {
        const url = try std.mem.concat(arena, u8, &.{ u.base, path });
        var out: Io.Writer.Allocating = .init(arena);

        const result = try u.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .response_writer = &out.writer,
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = if (body != null) .{ .override = "application/json" } else .default,
                .authorization = if (u.authorization.len > 0) .{ .override = u.authorization } else .default,
                .user_agent = .{ .override = "graf-edge" },
            },
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
        });

        return .{ .status = @backingInt(result.status), .body = out.written() };
    }

    pub fn health(u: *Upstream) Io.Cancelable!bool {
        var arena_state = std.heap.ArenaAllocator.init(u.gpa);
        defer arena_state.deinit();

        const reply = u.request(arena_state.allocator(), .GET, "/v1/health", null) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        return reply.status == 200;
    }

    pub fn handler(u: *Upstream) api.Handler {
        return .{ .ptr = u, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, arena: Allocator, req: api.Request) anyerror!api.Reply {
        const u: *Upstream = @ptrCast(@alignCast(ptr));
        const call = try client.route(arena, req);
        return u.request(arena, call.method, call.path, call.body) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| e,
            error.Timeout => api.errorReply(arena, 504, "the graf hub did not answer in time"),
            else => api.errorReply(arena, 502, try std.fmt.allocPrint(arena, "the graf hub is unreachable ({s})", .{@errorName(err)})),
        };
    }
};

const testing = std.testing;
const http = @import("http.zig");

test "upstream rejects urls it cannot reach" {
    const io = testing.io;
    try testing.expectError(error.InvalidUpstreamUrl, Upstream.init(testing.allocator, io, "hub.example.ts.net", "", 1000));
    try testing.expectError(error.InvalidUpstreamUrl, Upstream.init(testing.allocator, io, "ftp://hub.example.ts.net", "", 1000));

    var u = try Upstream.init(testing.allocator, io, " https://hub.example.ts.net/graf/ ", "t", 1000);
    defer u.deinit();

    try testing.expectEqualStrings("https://hub.example.ts.net/graf", u.base);
    try testing.expectEqualStrings("Bearer t", u.authorization);
}

test "upstream forwards every op with the bearer token and maps outages to 502" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake: http.FakeHandler = .{ .io = io };
    defer fake.deinit();
    var hub = http.Server.init(testing.allocator, io, fake.handler(), .{ .listen = "127.0.0.1:0", .token = "hub-token" });
    try hub.start();
    var running = try io.concurrent(http.Server.run, .{&hub});
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{hub.boundPort()});

    var u = try Upstream.init(testing.allocator, io, url, "hub-token", 2000);
    defer u.deinit();
    try testing.expect(try u.health());

    const h = u.handler();
    const requests = [_]api.Request{
        .{ .op = .search, .body = "{\"query\":\"q\"}" },
        .{ .op = .entity, .body = "{\"name_or_id\":\"brackwater\"}" },
        .{ .op = .remember, .body = "{\"text\":\"We deploy on Fridays.\"}" },
        .{ .op = .forget, .body = "{\"query\":\"old\"}" },
        .{ .op = .entries, .body = "{\"kind\":\"note\"}" },
        .{ .op = .brief, .body = "{\"project\":\"brackwater web\"}" },
        .{ .op = .warm, .session_id = "s 1", .body = "{\"prompt\":\"p\"}" },
        .{ .op = .recall, .session_id = "s1", .body = "{\"prompt\":\"what & why?\"}" },
    };

    for (requests) |req| {
        const reply = try h.handle(arena, req);
        try testing.expectEqual(200, reply.status);
        try fake.expectLast(req.op, req.body, req.session_id);
    }

    const missing = try h.handle(arena, .{ .op = .entity, .body = "{\"name_or_id\":\"missing\"}" });
    try testing.expectEqual(404, missing.status);

    var anonymous = try Upstream.init(testing.allocator, io, url, "", 2000);
    defer anonymous.deinit();
    try testing.expectEqual(401, (try anonymous.handler().handle(arena, requests[0])).status);

    hub.stop();
    running.await(io) catch {};
    hub.deinit();

    try testing.expect(!try u.health());
    const offline = try h.handle(arena, requests[0]);
    try testing.expectEqual(502, offline.status);
    try testing.expect(std.mem.find(u8, offline.body, "unreachable") != null);
}
