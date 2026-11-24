const std = @import("std");
const Io = std.Io;
const deadlines = @import("request_deadlines.zig");
const limiter = @import("limiter.zig");

pub const Bounds = deadlines.Bounds;

pub const Request = struct {
    url: []const u8,
    headers: []const std.http.Header = &.{},
    body: []const u8,
    bounds: Bounds = .{},
    total_ms: u64 = deadlines.never,
    capture: []const []const u8 = &.{},
    cancel: ?*const std.atomic.Value(bool) = null,
};

pub const Response = struct {
    status: u16,
    headers: []const std.http.Header = &.{},
    body: []const u8,

    pub fn header(r: Response, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

pub const Failure = struct {
    err: anyerror,
    sent: bool,
    timed_out: bool = false,
    cancelled: bool = false,
};

pub const Result = union(enum) {
    response: Response,
    failure: Failure,
};

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, io: Io, arena: std.mem.Allocator, req: *const Request) std.mem.Allocator.Error!Result,
    };

    pub fn send(t: Transport, io: Io, arena: std.mem.Allocator, req: *const Request) std.mem.Allocator.Error!Result {
        return t.vtable.send(t.ptr, io, arena, req);
    }
};

pub const Http = struct {
    client: std.http.Client,
    last_done_ms: std.atomic.Value(u64) = .init(0),

    const max_body_bytes = 64 << 20;
    const idle_ttl_ms = 30_000;
    const pool_size = 32;
    const poll_ms = 5;

    pub fn init(gpa: std.mem.Allocator, io: Io) Http {
        return .{ .client = .{ .allocator = gpa, .io = io } };
    }

    pub fn deinit(h: *Http) void {
        h.client.deinit();
    }

    pub fn transport(h: *Http) Transport {
        return .{ .ptr = h, .vtable = &.{ .send = send } };
    }

    const Phase = enum(u8) { connecting, awaiting_head, streaming, done };

    const Progress = struct {
        phase: std.atomic.Value(Phase) = .init(.connecting),
        sent: std.atomic.Value(bool) = .init(false),
        phase_ms: std.atomic.Value(u64),
        last_bytes_ms: std.atomic.Value(u64),

        fn enter(p: *Progress, io: Io, phase: Phase) void {
            const now = limiter.nowMs(io);
            p.phase_ms.store(now, .release);
            p.last_bytes_ms.store(now, .release);
            p.phase.store(phase, .release);
        }
    };

    const Exchange = union(enum) { response: Response, err: anyerror };

    fn send(ptr: *anyopaque, io: Io, arena: std.mem.Allocator, req: *const Request) std.mem.Allocator.Error!Result {
        const h: *Http = @ptrCast(@alignCast(ptr));
        h.dropIdleConnections(io);
        const start = limiter.nowMs(io);
        var progress: Progress = .{ .phase_ms = .init(start), .last_bytes_ms = .init(start) };

        var future = io.concurrent(exchange, .{ h, io, arena, req, &progress }) catch {
            return finish(h, io, exchange(h, io, arena, req, &progress), &progress, false, false);
        };
        var timed_out = false;
        var cancelled = false;
        while (progress.phase.load(.acquire) != .done) {
            const now = limiter.nowMs(io);
            if (req.cancel) |flag| if (flag.load(.acquire)) {
                cancelled = true;
                break;
            };
            if (now -| start >= req.total_ms or expired(req.bounds, start, &progress, now)) {
                timed_out = true;
                break;
            }
            io.sleep(.fromMilliseconds(poll_ms), .awake) catch {
                cancelled = true;
                break;
            };
        }
        const outcome = if (timed_out or cancelled) future.cancel(io) else future.await(io);
        return finish(h, io, outcome, &progress, timed_out, cancelled);
    }

    fn expired(bounds: Bounds, start: u64, p: *Progress, now: u64) bool {
        var d = deadlines.Deadlines.init(bounds, start);
        switch (p.phase.load(.acquire)) {
            .connecting => {},
            .awaiting_head => d.connected(p.phase_ms.load(.acquire)),
            .streaming => {
                d.connected(p.phase_ms.load(.acquire));
                d.headArrived(p.phase_ms.load(.acquire));
                d.bytes(p.last_bytes_ms.load(.acquire));
            },
            .done => return false,
        }
        return d.expired(now) != null;
    }

    fn finish(h: *Http, io: Io, outcome: Exchange, p: *Progress, timed_out: bool, cancelled: bool) std.mem.Allocator.Error!Result {
        h.last_done_ms.store(limiter.nowMs(io), .release);
        switch (outcome) {
            .response => |r| return .{ .response = r },
            .err => |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .failure = .{
                    .err = err,
                    .sent = p.sent.load(.acquire),
                    .timed_out = timed_out,
                    .cancelled = cancelled,
                } };
            },
        }
    }

    fn dropIdleConnections(h: *Http, io: Io) void {
        const last = h.last_done_ms.load(.acquire);
        if (last == 0 or limiter.nowMs(io) -| last < idle_ttl_ms) return;
        h.client.connection_pool.resize(io, 0) catch return;
        h.client.connection_pool.resize(io, pool_size) catch return;
    }

    fn exchange(h: *Http, io: Io, arena: std.mem.Allocator, req: *const Request, p: *Progress) Exchange {
        defer p.phase.store(.done, .release);
        return .{ .response = h.exchangeInner(io, arena, req, p) catch |err| return .{ .err = err } };
    }

    fn exchangeInner(h: *Http, io: Io, arena: std.mem.Allocator, req: *const Request, p: *Progress) !Response {
        const uri = try std.Uri.parse(req.url);
        var r = try h.client.request(.POST, uri, .{
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = req.headers,
            .redirect_behavior = .unhandled,
        });
        defer r.deinit();
        p.enter(io, .awaiting_head);

        r.transfer_encoding = .{ .content_length = req.body.len };
        p.sent.store(true, .release);
        var body_writer = try r.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(req.body);
        try body_writer.end();
        try r.connection.?.flush();

        var response = try r.receiveHead(&.{});
        p.enter(io, .streaming);

        var captured: std.ArrayList(std.http.Header) = .empty;
        var it = response.head.iterateHeaders();
        while (it.next()) |hdr| for (req.capture) |name| {
            if (std.ascii.eqlIgnoreCase(hdr.name, name)) try captured.append(arena, .{
                .name = try arena.dupe(u8, hdr.name),
                .value = try arena.dupe(u8, hdr.value),
            });
        };
        const status: u16 = @backingInt(response.head.status);

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        var transfer: [16 * 1024]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer, &decompress, decompress_buffer);
        var out: Io.Writer.Allocating = .init(arena);
        while (true) {
            _ = reader.stream(&out.writer, .limited(64 * 1024)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
                error.WriteFailed => return error.OutOfMemory,
            };
            p.last_bytes_ms.store(limiter.nowMs(io), .release);
            if (out.written().len > max_body_bytes) return error.ResponseTooLarge;
        }
        return .{ .status = status, .headers = captured.items, .body = out.written() };
    }
};

pub const Replay = struct {
    gpa: std.mem.Allocator,
    steps: []const Step,
    next: usize = 0,
    sent: std.ArrayList(Sent) = .empty,

    pub const Step = union(enum) {
        capture: []const u8,
        failure: Failure,
    };

    pub const Sent = struct { url: []const u8, body: []const u8, headers: []const std.http.Header };

    pub fn init(gpa: std.mem.Allocator, steps: []const Step) Replay {
        return .{ .gpa = gpa, .steps = steps };
    }

    pub fn deinit(r: *Replay) void {
        for (r.sent.items) |s| {
            r.gpa.free(s.url);
            r.gpa.free(s.body);
            for (s.headers) |h| {
                r.gpa.free(h.name);
                r.gpa.free(h.value);
            }
            r.gpa.free(s.headers);
        }
        r.sent.deinit(r.gpa);
    }

    pub fn transport(r: *Replay) Transport {
        return .{ .ptr = r, .vtable = &.{ .send = send } };
    }

    pub fn remaining(r: *const Replay) usize {
        return r.steps.len - r.next;
    }

    fn send(ptr: *anyopaque, io: Io, arena: std.mem.Allocator, req: *const Request) std.mem.Allocator.Error!Result {
        _ = io;
        const r: *Replay = @ptrCast(@alignCast(ptr));
        const headers = try r.gpa.alloc(std.http.Header, req.headers.len);
        for (req.headers, headers) |src, *dst| dst.* = .{ .name = try r.gpa.dupe(u8, src.name), .value = try r.gpa.dupe(u8, src.value) };
        try r.sent.append(r.gpa, .{ .url = try r.gpa.dupe(u8, req.url), .body = try r.gpa.dupe(u8, req.body), .headers = headers });
        if (r.next >= r.steps.len) return .{ .failure = .{ .err = error.ReplayExhausted, .sent = false } };
        const step = r.steps[r.next];
        r.next += 1;
        return switch (step) {
            .failure => |f| .{ .failure = f },
            .capture => |text| .{ .response = parseCapture(arena, text, req.capture) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .failure = .{ .err = err, .sent = true } },
            } },
        };
    }
};

pub fn parseCapture(arena: std.mem.Allocator, text: []const u8, capture: []const []const u8) !Response {
    const split = std.mem.find(u8, text, "\r\n\r\n");
    const head_end, const body_start = if (split) |i| .{ i, i + 4 } else blk: {
        const j = std.mem.find(u8, text, "\n\n") orelse return error.BadCapture;
        break :blk .{ j, j + 2 };
    };
    var lines = std.mem.tokenizeAny(u8, text[0..head_end], "\r\n");
    const status_line = lines.next() orelse return error.BadCapture;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.BadCapture;
    const status = std.fmt.parseInt(u16, parts.next() orelse return error.BadCapture, 10) catch return error.BadCapture;
    var headers: std.ArrayList(std.http.Header) = .empty;
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.BadCapture;
        const name = std.mem.trim(u8, line[0..colon], " ");
        for (capture) |want| if (std.ascii.eqlIgnoreCase(want, name)) {
            try headers.append(arena, .{ .name = name, .value = std.mem.trim(u8, line[colon + 1 ..], " ") });
        };
    }
    return .{ .status = status, .headers = headers.items, .body = text[body_start..] };
}

test "capture parsing keeps requested headers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const r = try parseCapture(arena_state.allocator(), "HTTP/1.1 429 Too Many Requests\nRetry-After: 2\nx-other: y\n\n{\"error\":{}}\n", &.{"retry-after"});
    try std.testing.expectEqual(@as(u16, 429), r.status);
    try std.testing.expectEqualStrings("2", r.header("retry-after").?);
    try std.testing.expect(r.header("x-other") == null);
    try std.testing.expectEqualStrings("{\"error\":{}}\n", r.body);
}
