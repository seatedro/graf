const std = @import("std");
const Io = std.Io;
const transport = @import("transport.zig");
const limiter = @import("limiter.zig");
const testing = std.testing;

const deadline_ms = 5_000;

const Server = struct {
    listener: Io.net.Server,
    accepts: std.atomic.Value(u32) = .init(0),

    fn run(s: *Server, io: Io) Io.Cancelable!void {
        var group: Io.Group = .init;
        defer group.cancel(io);
        while (true) {
            const stream = s.listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            _ = s.accepts.fetchAdd(1, .monotonic);
            group.concurrent(io, serve, .{ io, stream }) catch {
                stream.close(io);
                return;
            };
        }
    }

    fn serve(io: Io, stream: Io.net.Stream) Io.Cancelable!void {
        defer stream.close(io);
        var in_buf: [8192]u8 = undefined;
        var out_buf: [8192]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        var writer = stream.writer(io, &out_buf);
        var http: std.http.Server = .init(&reader.interface, &writer.interface);
        while (true) {
            var req = http.receiveHead() catch return;
            const target = req.head.target;
            if (std.mem.eql(u8, target, "/ok")) {
                req.respond("{\"ok\":true}", .{ .extra_headers = &.{.{ .name = "x-example-cost-usd", .value = "0.5" }} }) catch return;
            } else if (std.mem.eql(u8, target, "/stall")) {
                writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n{") catch return;
                writer.interface.flush() catch return;
                try io.sleep(.fromSeconds(5), .awake);
                return;
            } else {
                try io.sleep(.fromSeconds(5), .awake);
                return;
            }
        }
    }
};

test "real HTTP: keep-alive reuse, header capture, first-byte and stall deadlines, cancel" {
    const io = testing.io;
    var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server: Server = .{ .listener = try addr.listen(io, .{ .reuse_address = true }) };
    defer server.listener.deinit(io);
    var server_task = try io.concurrent(Server.run, .{ &server, io });
    defer server_task.cancel(io) catch {};
    const port = server.listener.socket.address.getPort();

    var http = transport.Http.init(testing.allocator, io);
    defer http.deinit();
    const t = http.transport();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ok_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/ok", .{port});
    for (0..2) |_| {
        const res = try t.send(io, arena, &.{ .url = ok_url, .body = "{}", .total_ms = deadline_ms, .capture = &.{"x-example-cost-usd"} });
        try testing.expectEqual(@as(u16, 200), res.response.status);
        try testing.expectEqualStrings("{\"ok\":true}", res.response.body);
        try testing.expectEqualStrings("0.5", res.response.header("x-example-cost-usd").?);
    }
    try testing.expectEqual(@as(u32, 1), server.accepts.load(.monotonic));

    const slow_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/slow", .{port});
    var start = limiter.nowMs(io);
    const slow = try t.send(io, arena, &.{ .url = slow_url, .body = "{}", .total_ms = deadline_ms, .bounds = .{ .first_response_ms = 150 } });
    try testing.expect(slow.failure.timed_out);
    try testing.expect(slow.failure.sent);
    try testing.expect(limiter.nowMs(io) - start < 2000);

    const stall_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/stall", .{port});
    start = limiter.nowMs(io);
    const stalled = try t.send(io, arena, &.{ .url = stall_url, .body = "{}", .total_ms = deadline_ms, .bounds = .{ .stall_ms = 150 } });
    try testing.expect(stalled.failure.timed_out);
    try testing.expect(limiter.nowMs(io) - start < 2000);

    var cancel: std.atomic.Value(bool) = .init(true);
    const cancelled = try t.send(io, arena, &.{ .url = slow_url, .body = "{}", .total_ms = deadline_ms, .cancel = &cancel });
    try testing.expect(cancelled.failure.cancelled);

    const refused = try t.send(io, arena, &.{ .url = "http://127.0.0.1:1/ok", .body = "{}", .total_ms = deadline_ms });
    try testing.expect(!refused.failure.sent);
}
