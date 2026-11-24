const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

pub const max_body_bytes = 16 << 20;
pub const max_line_bytes = 16 << 20;

pub const Error = error{ RateLimited, Unavailable, Unauthorized, Forbidden, NotFound, BadRequest, BadResponse };

pub const Diag = struct {
    status: u16 = 0,
    retry_after_s: ?u32 = null,
};

pub const Repo = struct {
    repoFullName: []const u8,
    mode: []const u8 = "",
};

pub const Project = struct {
    id: []const u8,
    name: []const u8 = "",
    code: []const u8 = "",
    repos: []const Repo = &.{},
};

pub const ProjectList = struct {
    items: []const Project = &.{},
};

pub const Thread = struct {
    id: []const u8,
    projectId: ?[]const u8 = null,
    status: []const u8 = "",
    archived: bool = false,
    lastModelId: ?[]const u8 = null,
    updatedAt: []const u8 = "",
    lastActivityAt: ?[]const u8 = null,
};

pub const ThreadPage = struct {
    items: []const Thread = &.{},
    cursor: ?[]const u8 = null,
};

pub const Message = struct {
    id: []const u8,
    source: []const u8,
    tool: ?[]const u8 = null,
    text: []const u8 = "",
    model: ?[]const u8 = null,
    createdAt: []const u8 = "",
};

pub const MessagePage = struct {
    items: []const Message = &.{},
    cursor: ?[]const u8 = null,
};

pub const StatusFrame = struct {
    status: []const u8 = "",
};

pub const ErrorFrame = struct {
    code: []const u8 = "",
};

pub const Backoff = struct {
    base_ms: u64 = 1000,
    max_ms: u64 = 60_000,
    auth_ms: u64 = 300_000,

    pub fn delay(b: Backoff, err: anyerror, retry_after_s: ?u32, attempt: u32) u64 {
        return switch (err) {
            error.Unauthorized, error.Forbidden => b.auth_ms,
            error.RateLimited => if (retry_after_s) |s| @max(@as(u64, s) * std.time.ms_per_s, b.base_ms) else b.exponential(attempt),
            else => b.exponential(attempt),
        };
    }

    fn exponential(b: Backoff, attempt: u32) u64 {
        return @min(b.max_ms, b.base_ms << @intCast(@min(attempt, 20)));
    }
};

pub fn decode(comptime T: type, arena: Allocator, body: []const u8) (Error || Allocator.Error)!T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadResponse,
    };
}

pub fn classify(status: u16) Error!void {
    return switch (status) {
        200...299 => {},
        400 => error.BadRequest,
        401 => error.Unauthorized,
        403 => error.Forbidden,
        404 => error.NotFound,
        429 => error.RateLimited,
        else => if (status >= 500) error.Unavailable else error.BadResponse,
    };
}

fn retryAfter(arena: Allocator, header: ?u32, body: []const u8) ?u32 {
    if (header) |h| return h;
    const parsed = std.json.parseFromSliceLeaky(struct { retryAfterSeconds: ?u32 = null }, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
    return parsed.retryAfterSeconds;
}

pub fn writeEscaped(w: *Io.Writer, value: []const u8) Io.Writer.Error!void {
    for (value) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

pub fn threadsTarget(arena: Allocator, project_id: []const u8, cursor: ?[]const u8, limit: u32) Allocator.Error![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    w.writeAll("/threads?projectId=") catch return error.OutOfMemory;
    writeEscaped(w, project_id) catch return error.OutOfMemory;
    w.print("&limit={d}", .{limit}) catch return error.OutOfMemory;
    if (cursor) |c| {
        w.writeAll("&cursor=") catch return error.OutOfMemory;
        writeEscaped(w, c) catch return error.OutOfMemory;
    }

    return out.written();
}

pub fn messagesTarget(arena: Allocator, thread_id: []const u8, after: ?[]const u8, limit: u32) Allocator.Error![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    w.writeAll("/threads/") catch return error.OutOfMemory;
    writeEscaped(w, thread_id) catch return error.OutOfMemory;
    w.print("/messages?limit={d}", .{limit}) catch return error.OutOfMemory;
    if (after) |a| {
        w.writeAll("&after=") catch return error.OutOfMemory;
        writeEscaped(w, a) catch return error.OutOfMemory;
    }

    return out.written();
}

pub fn streamTarget(arena: Allocator, thread_id: []const u8) Allocator.Error![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    w.writeAll("/threads/") catch return error.OutOfMemory;
    writeEscaped(w, thread_id) catch return error.OutOfMemory;
    w.writeAll("/stream") catch return error.OutOfMemory;
    return out.written();
}

fn settle(req: *const http.Client.Request, err: anytype) (@TypeOf(err) || Io.Cancelable) {
    const c = req.connection orelse return err;
    if (c.stream_reader.err) |e| if (e == error.Canceled) return error.Canceled;
    if (c.stream_writer.err) |e| if (e == error.Canceled) return error.Canceled;
    return err;
}

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    http: http.Client,
    base_url: []const u8,
    authorization: []const u8,

    pub fn init(gpa: Allocator, io: Io, base_url: []const u8, api_key: []const u8) Allocator.Error!Client {
        return .{
            .gpa = gpa,
            .io = io,
            .http = .{ .allocator = gpa, .io = io },
            .base_url = try gpa.dupe(u8, std.mem.trimEnd(u8, base_url, "/")),
            .authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key}),
        };
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
        c.gpa.free(c.base_url);
        c.gpa.free(c.authorization);
        c.* = undefined;
    }

    fn headers(c: *const Client) http.Client.Request.Headers {
        return .{
            .authorization = .{ .override = c.authorization },
            .accept_encoding = .{ .override = "identity" },
            .user_agent = .{ .override = "graf" },
        };
    }

    pub fn getJson(c: *Client, comptime T: type, arena: Allocator, target: []const u8, diag: *Diag) !T {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ c.base_url, target });
        var req = try c.http.request(.GET, try std.Uri.parse(url), .{
            .headers = c.headers(),
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();

        return receiveJson(T, &req, arena, diag) catch |err| return settle(&req, err);
    }

    fn receiveJson(comptime T: type, req: *http.Client.Request, arena: Allocator, diag: *Diag) !T {
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        diag.status = @backingInt(response.head.status);

        var header_retry: ?u32 = null;
        var it = response.head.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            header_retry = std.fmt.parseInt(u32, std.mem.trim(u8, h.value, " "), 10) catch null;
        };

        if (response.head.content_encoding != .identity) return error.BadResponse;
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const body = reader.allocRemaining(arena, .limited(max_body_bytes)) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => |e| return e,
        };

        classify(diag.status) catch |err| {
            diag.retry_after_s = retryAfter(arena, header_retry, body);
            return err;
        };
        return decode(T, arena, body);
    }
};

pub const Stream = struct {
    req: http.Client.Request,
    response: http.Client.Response,
    reader: *Io.Reader,
    transfer: [16 * 1024]u8,
    line: Io.Writer.Allocating,
    id_buf: [128]u8,
    extra: [2]http.Header,

    pub fn open(s: *Stream, c: *Client, arena: Allocator, thread_id: []const u8, last_event_id: ?[]const u8, diag: *Diag) !void {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ c.base_url, try streamTarget(arena, thread_id) });

        s.extra[0] = .{ .name = "accept", .value = "text/event-stream" };
        var extra_len: usize = 1;
        if (last_event_id) |id| {
            if (id.len > s.id_buf.len) return error.BadRequest;
            @memcpy(s.id_buf[0..id.len], id);
            s.extra[1] = .{ .name = "last-event-id", .value = s.id_buf[0..id.len] };
            extra_len = 2;
        }

        s.req = try c.http.request(.GET, try std.Uri.parse(url), .{
            .headers = c.headers(),
            .extra_headers = s.extra[0..extra_len],
            .redirect_behavior = .unhandled,
            .keep_alive = false,
        });
        errdefer s.req.deinit();

        s.receiveHead(arena, diag) catch |err| return settle(&s.req, err);
        s.line = .init(c.gpa);
    }

    fn receiveHead(s: *Stream, arena: Allocator, diag: *Diag) !void {
        try s.req.sendBodiless();
        s.response = try s.req.receiveHead(&.{});
        diag.status = @backingInt(s.response.head.status);

        var header_retry: ?u32 = null;
        var it = s.response.head.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            header_retry = std.fmt.parseInt(u32, std.mem.trim(u8, h.value, " "), 10) catch null;
        };

        if (s.response.head.content_encoding != .identity) return error.BadResponse;
        s.reader = s.response.reader(&s.transfer);
        classify(diag.status) catch |err| {
            const body = s.reader.allocRemaining(arena, .limited(64 << 10)) catch "";
            diag.retry_after_s = retryAfter(arena, header_retry, body);
            return err;
        };
    }

    pub fn close(s: *Stream) void {
        s.line.deinit();
        s.req.deinit();
    }

    pub fn nextLine(s: *Stream) !?[]const u8 {
        s.line.clearRetainingCapacity();
        _ = s.reader.streamDelimiterLimit(&s.line.writer, '\n', .limited(max_line_bytes)) catch |err| switch (err) {
            error.ReadFailed => return s.readError(),
            error.WriteFailed => return error.OutOfMemory,
            error.StreamTooLong => return error.StreamTooLong,
        };

        _ = s.reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            error.ReadFailed => return s.readError(),
        };

        return s.line.written();
    }

    fn readError(s: *Stream) anyerror {
        if (s.response.bodyErr()) |err| return err;
        if (s.req.connection) |c| return c.getReadError() orelse error.ReadFailed;
        return error.ReadFailed;
    }
};

const testing = std.testing;

test "backoff honors retry-after, grows exponentially to a cap, and waits long on auth failures" {
    const b: Backoff = .{ .base_ms = 1000, .max_ms = 60_000, .auth_ms = 300_000 };

    try testing.expectEqual(@as(u64, 7000), b.delay(error.RateLimited, 7, 0));
    try testing.expectEqual(@as(u64, 1000), b.delay(error.RateLimited, 0, 4));
    try testing.expectEqual(@as(u64, 4000), b.delay(error.RateLimited, null, 2));
    try testing.expectEqual(@as(u64, 1000), b.delay(error.Unavailable, null, 0));
    try testing.expectEqual(@as(u64, 8000), b.delay(error.Unavailable, null, 3));
    try testing.expectEqual(@as(u64, 60_000), b.delay(error.ConnectionRefused, null, 30));
    try testing.expectEqual(@as(u64, 300_000), b.delay(error.Unauthorized, null, 0));
    try testing.expectEqual(@as(u64, 300_000), b.delay(error.Forbidden, 3, 0));
}

test "status codes map to the API's error tags" {
    try classify(200);
    try testing.expectError(error.BadRequest, classify(400));
    try testing.expectError(error.Unauthorized, classify(401));
    try testing.expectError(error.Forbidden, classify(403));
    try testing.expectError(error.NotFound, classify(404));
    try testing.expectError(error.RateLimited, classify(429));
    try testing.expectError(error.Unavailable, classify(503));
    try testing.expectError(error.BadResponse, classify(302));
}

test "targets escape their parameters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("/threads?projectId=proj_1&limit=100&cursor=1700%3Ajam_9", try threadsTarget(a, "proj_1", "1700:jam_9", 100));
    try testing.expectEqualStrings("/threads?projectId=p%20q&limit=5", try threadsTarget(a, "p q", null, 5));
    try testing.expectEqualStrings("/threads/jam_1/messages?limit=50&after=01JZ", try messagesTarget(a, "jam_1", "01JZ", 50));
    try testing.expectEqualStrings("/threads/jam_1/stream", try streamTarget(a, "jam_1"));
    try testing.expectEqual(@as(?u32, 9), retryAfter(a, null, "{\"_tag\":\"capy/RateLimited\",\"retryAfterSeconds\":9}"));
    try testing.expectEqual(@as(?u32, 3), retryAfter(a, 3, "{}"));
}
