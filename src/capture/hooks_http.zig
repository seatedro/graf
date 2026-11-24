const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;

pub const max_response_bytes = 1 << 20;

pub const Endpoint = union(enum) {
    unix: []const u8,
    tcp: net.IpAddress,
};

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    token: []const u8 = "",
    body: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,

    pub fn ok(r: Response) bool {
        return r.status >= 200 and r.status < 300;
    }
};

pub const Error = error{
    Unreachable,
    WriteFailed,
    ReadFailed,
    BadResponse,
    ResponseTooLarge,
    OutOfMemory,
    Canceled,
};

pub fn connect(io: Io, endpoints: []const Endpoint) Error!net.Stream {
    for (endpoints) |endpoint| {
        const stream = switch (endpoint) {
            .unix => |path| blk: {
                const addr = net.UnixAddress.init(path) catch continue;
                break :blk addr.connect(io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => continue,
                };
            },
            .tcp => |addr| addr.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            },
        };
        return stream;
    }

    return error.Unreachable;
}

pub fn send(io: Io, stream: net.Stream, request: Request) Error!void {
    var buf: [2048]u8 = undefined;
    var writer = stream.writer(io, &buf);
    const w = &writer.interface;

    writeRequest(w, request) catch return if (writer.err) |e| switch (e) {
        error.Canceled => error.Canceled,
        else => error.WriteFailed,
    } else error.WriteFailed;
}

fn writeRequest(w: *Io.Writer, request: Request) Io.Writer.Error!void {
    try w.print("{s} {s} HTTP/1.1\r\nHost: localhost\r\nUser-Agent: graf-hook\r\nAccept: text/plain, text/markdown, application/json\r\nConnection: close\r\n", .{ request.method, request.target });
    if (request.token.len > 0) try w.print("Authorization: Bearer {s}\r\n", .{request.token});

    if (request.body) |body| {
        try w.print("Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len});
        try w.writeAll(body);
    } else {
        try w.writeAll("\r\n");
    }

    try w.flush();
}

pub fn receive(arena: Allocator, io: Io, stream: net.Stream) Error!Response {
    var raw: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;

    while (true) {
        var bufs = [_][]u8{&chunk};
        const n = stream.read(io, &bufs) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.ReadFailed,
        };
        if (n == 0) return try parse(arena, raw.items, true) orelse error.BadResponse;
        if (raw.items.len + n > max_response_bytes) return error.ResponseTooLarge;
        try raw.appendSlice(arena, chunk[0..n]);
        if (try parse(arena, raw.items, false)) |response| return response;
    }
}

pub fn parse(arena: Allocator, raw: []const u8, eof: bool) Error!?Response {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return if (eof) error.BadResponse else null;
    var lines = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
    const status_line = lines.next() orelse return error.BadResponse;
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.BadResponse;

    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next();
    const status = std.fmt.parseInt(u16, parts.next() orelse return error.BadResponse, 10) catch return error.BadResponse;

    var content_type: []const u8 = "";
    var content_length: ?usize = null;
    var chunked = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            content_type = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            chunked = containsIgnoreCase(value, "chunked");
        }
    }

    const rest = raw[head_end + 4 ..];
    if (status == 204 or status == 304 or (status >= 100 and status < 200)) {
        return .{ .status = status, .content_type = content_type, .body = "" };
    }

    if (chunked) {
        const body = try decodeChunked(arena, rest) orelse return if (eof) error.BadResponse else null;
        return .{ .status = status, .content_type = content_type, .body = body };
    }

    if (content_length) |len| {
        if (rest.len < len) return if (eof) error.BadResponse else null;
        return .{ .status = status, .content_type = content_type, .body = rest[0..len] };
    }

    if (!eof) return null;
    return .{ .status = status, .content_type = content_type, .body = rest };
}

fn decodeChunked(arena: Allocator, data: []const u8) Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;

    while (true) {
        const line_end = std.mem.indexOfPos(u8, data, pos, "\r\n") orelse return null;
        var size_text = data[pos..line_end];
        if (std.mem.indexOfScalar(u8, size_text, ';')) |semi| size_text = size_text[0..semi];
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_text, " \t"), 16) catch return error.BadResponse;
        pos = line_end + 2;

        if (size == 0) return out.items;
        if (data.len < pos + size + 2) return null;
        try out.appendSlice(arena, data[pos .. pos + size]);
        pos += size + 2;
    }
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

pub fn ReturnType(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

pub fn withinDeadline(
    io: Io,
    deadline: Io.Clock.Timestamp,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) ?ReturnType(function) {
    const U = union(enum) {
        done: ReturnType(function),
        expired: Io.Cancelable!void,
    };

    var buffer: [2]U = undefined;
    var select = Io.Select(U).init(io, &buffer);
    select.concurrent(.done, function, args) catch return null;
    select.concurrent(.expired, sleepUntil, .{ io, deadline }) catch {
        select.cancelDiscard();
        return null;
    };

    const first = select.await() catch {
        select.cancelDiscard();
        return null;
    };

    select.cancelDiscard();
    return switch (first) {
        .done => |result| result,
        .expired => null,
    };
}

fn sleepUntil(io: Io, deadline: Io.Clock.Timestamp) Io.Cancelable!void {
    return Io.Timeout.sleep(.{ .deadline = deadline }, io);
}

pub fn parseListen(text: []const u8) ?net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;

    var host = text[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    if (host.len == 0 or std.mem.eql(u8, host, "0.0.0.0") or std.ascii.eqlIgnoreCase(host, "localhost")) host = "127.0.0.1";
    if (std.mem.eql(u8, host, "::")) host = "::1";
    return net.IpAddress.parse(host, port) catch null;
}

pub fn percentEncode(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.items;
}

const testing = std.testing;

test "parse: content-length, chunked, close-delimited, incomplete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cl = (try parse(arena, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello", false)).?;
    try testing.expectEqual(@as(u16, 200), cl.status);
    try testing.expectEqualStrings("text/plain", cl.content_type);
    try testing.expectEqualStrings("hello", cl.body);

    try testing.expect((try parse(arena, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel", false)) == null);
    try testing.expect((try parse(arena, "HTTP/1.1 200 OK\r\nContent-Len", false)) == null);
    try testing.expectError(error.BadResponse, parse(arena, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel", true));

    const chunked = "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n4\r\nwiki\r\n6;x=y\r\npedia!\r\n0\r\n\r\n";
    try testing.expectEqualStrings("wikipedia!", (try parse(arena, chunked, false)).?.body);
    try testing.expect((try parse(arena, chunked[0 .. chunked.len - 7], false)) == null);

    try testing.expect((try parse(arena, "HTTP/1.0 200 OK\r\n\r\nuntil close", false)) == null);
    try testing.expectEqualStrings("until close", (try parse(arena, "HTTP/1.0 200 OK\r\n\r\nuntil close", true)).?.body);
    try testing.expectEqualStrings("", (try parse(arena, "HTTP/1.1 204 No Content\r\n\r\n", false)).?.body);
    try testing.expectError(error.BadResponse, parse(arena, "garbage\r\n\r\n", false));
}

test "parseListen and percentEncode" {
    try testing.expectEqual(@as(u16, 7420), parseListen("127.0.0.1:7420").?.getPort());
    try testing.expect(parseListen("0.0.0.0:7420") != null);
    try testing.expect(parseListen(":7420") != null);
    try testing.expect(parseListen("[::1]:7420") != null);
    try testing.expect(parseListen("localhost:7420") != null);
    try testing.expect(parseListen("db.example.test:7420") == null);
    try testing.expect(parseListen("127.0.0.1") == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("a%20b%2Fc%3F%26%3D%C3%A9-_.~", try percentEncode(arena_state.allocator(), "a b/c?&=\xc3\xa9-_.~"));
}
