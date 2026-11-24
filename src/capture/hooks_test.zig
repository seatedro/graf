const std = @import("std");
const core = @import("core");
const hooks = @import("hooks.zig");
const spool = @import("hooks_spool.zig");
const state = @import("state.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const testing = std.testing;

const Stub = struct {
    io: Io,
    server: net.Server,
    hang: bool = false,
    status: u16 = 200,
    content_type: []const u8 = "text/plain",
    body: []const u8 = "",
    count: std.atomic.Value(usize) = .init(0),
    log: [8][8192]u8 = undefined,
    lens: [8]usize = @splat(0),
    held: [8]?net.Stream = @splat(null),
    future: ?Io.Future(void) = null,

    fn start(stub: *Stub) !void {
        stub.future = try stub.io.concurrent(loop, .{stub});
    }

    fn stop(stub: *Stub) void {
        if (stub.future) |*f| f.cancel(stub.io);
        for (&stub.held) |*h| if (h.*) |s| {
            s.close(stub.io);
            h.* = null;
        };

        stub.server.deinit(stub.io);
    }

    fn loop(stub: *Stub) void {
        while (true) {
            const stream = stub.server.accept(stub.io) catch return;
            stub.handle(stream) catch |err| switch (err) {
                error.Canceled => {
                    stream.close(stub.io);
                    return;
                },
                else => stream.close(stub.io),
            };
        }
    }

    fn handle(stub: *Stub, stream: net.Stream) !void {
        const slot = stub.count.load(.acquire);
        if (slot >= stub.log.len) return error.TooManyRequests;

        const buf = &stub.log[slot];
        var len: usize = 0;
        while (true) {
            var bufs = [_][]u8{buf[len..]};
            const n = try stream.read(stub.io, &bufs);
            if (n == 0) break;
            len += n;
            if (requestComplete(buf[0..len])) break;
            if (len == buf.len) break;
        }

        stub.lens[slot] = len;
        stub.count.store(slot + 1, .release);

        if (stub.hang) {
            stub.held[slot] = stream;
            return;
        }

        var wbuf: [1024]u8 = undefined;
        var writer = stream.writer(stub.io, &wbuf);
        try writer.interface.print("HTTP/1.1 {d} X\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ stub.status, stub.content_type, stub.body.len, stub.body });
        try writer.interface.flush();
        stream.close(stub.io);
    }

    fn requestComplete(raw: []const u8) bool {
        const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return false;
        const head = raw[0..head_end];
        const marker = "Content-Length: ";
        const at = std.mem.indexOf(u8, head, marker) orelse return true;
        const line_end = std.mem.indexOfPos(u8, head, at, "\r\n") orelse head.len;
        const len = std.fmt.parseInt(usize, head[at + marker.len .. line_end], 10) catch return true;
        return raw.len >= head_end + 4 + len;
    }

    fn request(stub: *Stub, i: usize) []const u8 {
        return stub.log[i][0..stub.lens[i]];
    }

    fn waitFor(stub: *Stub, n: usize) !void {
        var waited: usize = 0;
        while (stub.count.load(.acquire) < n) : (waited += 1) {
            if (waited > 200) return error.Timeout;
            try stub.io.sleep(.fromMilliseconds(5), .awake);
        }
    }

    fn find(stub: *Stub, prefix: []const u8) ?[]const u8 {
        for (0..stub.count.load(.acquire)) |i| {
            if (std.mem.startsWith(u8, stub.request(i), prefix)) return stub.request(i);
        }
        return null;
    }
};

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,
    env: std.process.Environ.Map,
    config: core.Config = .{},
    out: Io.Writer.Allocating,

    fn init(h: *Harness) !void {
        h.arena_state = .init(testing.allocator);
        h.tmp = testing.tmpDir(.{});
        h.root = try h.tmp.dir.realPathFileAlloc(testing.io, ".", h.arena());

        h.env = .init(testing.allocator);
        try h.env.put("HOME", try h.path("home"));
        try h.env.put("XDG_STATE_HOME", try h.path("state"));

        h.config = .{};
        h.config.serve.socket = try h.path("missing.sock");
        try h.listenOn(try closedPort());
        h.out = .init(h.arena());

        try h.tmp.dir.createDirPath(testing.io, "repo/.git");
        try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.git/config", .data = "[remote \"origin\"]\n\turl = git@git.example.test:brackwater/widgets.git\n" });
    }

    fn deinit(h: *Harness) void {
        h.env.deinit();
        h.tmp.cleanup();
        h.arena_state.deinit();
    }

    fn arena(h: *Harness) Allocator {
        return h.arena_state.allocator();
    }

    fn path(h: *Harness, sub: []const u8) ![]const u8 {
        return std.fs.path.join(h.arena(), &.{ h.root, sub });
    }

    fn listenOn(h: *Harness, port: u16) !void {
        h.config.serve.listen = try std.fmt.allocPrint(h.arena(), "127.0.0.1:{d}", .{port});
    }

    fn serveTcp(h: *Harness, stub: *Stub) !void {
        const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
        stub.server = try addr.listen(stub.io, .{});
        try h.listenOn(stub.server.socket.address.getPort());
        try stub.start();
    }

    fn serveUnix(h: *Harness, stub: *Stub) !void {
        h.config.serve.socket = try h.path("graf.sock");
        const addr = try net.UnixAddress.init(h.config.serve.socket);
        stub.server = try addr.listen(stub.io, .{});
        try stub.start();
    }

    fn expectOutput(h: *Harness, hook_event_name: []const u8, context: []const u8) !void {
        const parsed = try std.json.parseFromSliceLeaky(ParsedOutput, h.arena(), h.out.written(), .{});
        try testing.expectEqualStrings(hook_event_name, parsed.hookSpecificOutput.hookEventName);
        try testing.expectEqualStrings(context, parsed.hookSpecificOutput.additionalContext);
    }

    fn payload(h: *Harness, extra: []const u8) ![]const u8 {
        return std.fmt.allocPrint(h.arena(), "{{\"session_id\":\"sess-1\",\"transcript_path\":\"{s}\",\"cwd\":\"{s}\"{s}}}", .{ try h.path("home/t/sess-1.jsonl"), try h.path("repo"), extra });
    }

    fn run(h: *Harness, harness: core.Harness, event: hooks.Event, stdin: []const u8) !i64 {
        h.out.clearRetainingCapacity();
        const start = Io.Clock.Timestamp.now(testing.io, .awake);
        try hooks.run(h.arena(), testing.io, &h.env, &h.config, harness, event, stdin, &h.out.writer);
        return start.untilNow(testing.io).raw.toMilliseconds();
    }

    fn spoolText(h: *Harness) ![]const u8 {
        const p = try h.path("state/graf/spool.jsonl");
        return Io.Dir.cwd().readFileAlloc(testing.io, p, h.arena(), .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => |e| return e,
        };
    }
};

fn closedPort() !u16 {
    const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(testing.io, .{});
    const port = server.socket.address.getPort();
    server.deinit(testing.io);
    return port;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

const ParsedOutput = struct {
    hookSpecificOutput: struct { hookEventName: []const u8, additionalContext: []const u8 },
};

test "session-start over the unix socket prints the brief for claude-code with the bearer token" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.config.serve.token = "tok-example";

    var stub: Stub = .{ .io = testing.io, .server = undefined, .body = "## Brief\nbrackwater/widgets uses zig\n", .content_type = "text/markdown" };
    try h.serveUnix(&stub);
    defer stub.stop();

    _ = try h.run(.@"claude-code", .@"session-start", try h.payload(",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\""));
    const req = stub.request(0);
    try expectContains(req, "GET /v1/brief?project=git.example.test%2Fbrackwater%2Fwidgets HTTP/1.1\r\n");
    try expectContains(req, "Authorization: Bearer tok-example\r\n");

    try h.expectOutput("SessionStart", "## Brief\nbrackwater/widgets uses zig");
}

test "session-start over tcp accepts a JSON body for codex and sends no token when unset" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var stub: Stub = .{ .io = testing.io, .server = undefined, .body = "{\"brief\":\"from json\"}", .content_type = "application/json" };
    try h.serveTcp(&stub);
    defer stub.stop();

    _ = try h.run(.codex, .@"session-start", try h.payload(""));
    try testing.expect(std.mem.indexOf(u8, stub.request(0), "Authorization") == null);
    try h.expectOutput("SessionStart", "from json");
}

test "prompt-submit fires warm, prints recall, and stays under 80 ms" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var stub: Stub = .{ .io = testing.io, .server = undefined, .body = "{\"text\":\"recalled: use the arena\"}", .content_type = "application/json" };
    try h.serveTcp(&stub);
    defer stub.stop();

    const ms = try h.run(.@"claude-code", .@"prompt-submit", try h.payload(",\"prompt\":\"fix the \\\"flaky\\\" test & ship\""));
    try testing.expect(ms < 80);

    try stub.waitFor(2);
    const warm = stub.find("POST /v1/sessions/sess-1/warm HTTP/1.1") orelse return error.MissingWarm;
    try expectContains(warm, "Content-Type: application/json\r\n");
    try expectContains(warm, "\r\n\r\n{\"prompt\":\"fix the \\\"flaky\\\" test & ship\"}");
    _ = stub.find("GET /v1/sessions/sess-1/recall?prompt=fix%20the%20%22flaky%22%20test%20%26%20ship HTTP/1.1") orelse return error.MissingRecall;

    try h.expectOutput("UserPromptSubmit", "recalled: use the arena");
}

test "stop posts flush to a fast daemon under 50 ms and spools nothing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var stub: Stub = .{ .io = testing.io, .server = undefined, .status = 202 };
    try h.serveUnix(&stub);
    defer stub.stop();

    const ms = try h.run(.@"claude-code", .stop, try h.payload(",\"hook_event_name\":\"Stop\""));
    try testing.expect(ms < 50);

    const req = stub.request(0);
    try expectContains(req, "POST /v1/hooks/flush HTTP/1.1\r\n");
    const body = req[std.mem.indexOf(u8, req, "\r\n\r\n").? + 4 ..];
    const Flush = struct { harness: []const u8, session_id: []const u8, transcript_path: []const u8, cwd: []const u8 };
    const flush = try std.json.parseFromSliceLeaky(Flush, h.arena(), body, .{});

    try testing.expectEqualStrings("claude-code", flush.harness);
    try testing.expectEqualStrings("sess-1", flush.session_id);
    try testing.expectEqualStrings(try h.path("repo"), flush.cwd);
    try testing.expectEqualStrings("", h.out.written());
    try testing.expectEqualStrings("", try h.spoolText());
}

test "session-end spools when nothing listens, under 50 ms" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const ms = try h.run(.@"claude-code", .@"session-end", try h.payload(""));
    try testing.expect(ms < 50);

    const text = try h.spoolText();
    try testing.expect(std.mem.endsWith(u8, text, "\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));

    const entry = try std.json.parseFromSliceLeaky(spool.Entry, h.arena(), std.mem.trimEnd(u8, text, "\n"), .{});
    try testing.expectEqualStrings("claude-code", entry.harness);
    try testing.expectEqualStrings("session-end", entry.event);
    try testing.expectEqualStrings("sess-1", entry.session_id.?);
    try testing.expectEqualStrings(try h.path("home/t/sess-1.jsonl"), entry.transcript_path.?);
    try testing.expect(entry.ts > 1_600_000_000_000_000);
}

test "stop and session-end spool when the daemon accepts but never answers, under 50 ms" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var stub: Stub = .{ .io = testing.io, .server = undefined, .hang = true };
    try h.serveTcp(&stub);
    defer stub.stop();

    const stop_ms = try h.run(.codex, .stop, try h.payload(""));
    try testing.expect(stop_ms < 50);
    try testing.expectEqualStrings("{}\n", h.out.written());

    const end_ms = try h.run(.@"claude-code", .@"session-end", try h.payload(""));
    try testing.expect(end_ms < 50);
    try stub.waitFor(2);

    const text = try h.spoolText();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\n"));
    try expectContains(text, "\"harness\":\"codex\",\"event\":\"stop\"");
    try expectContains(text, "\"harness\":\"claude-code\",\"event\":\"session-end\"");
}

test "a daemon error status spools the flush" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var stub: Stub = .{ .io = testing.io, .server = undefined, .status = 503 };
    try h.serveTcp(&stub);
    defer stub.stop();

    _ = try h.run(.@"claude-code", .stop, try h.payload(""));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, try h.spoolText(), "\n"));
}

test "prompt-submit and session-start print nothing within budget when the daemon hangs" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var stub: Stub = .{ .io = testing.io, .server = undefined, .hang = true };
    try h.serveUnix(&stub);
    defer stub.stop();

    const prompt_ms = try h.run(.@"claude-code", .@"prompt-submit", try h.payload(",\"prompt\":\"hello\""));
    try testing.expect(prompt_ms < 80);
    try testing.expectEqualStrings("", h.out.written());

    const start_ms = try h.run(.codex, .@"session-start", try h.payload(""));
    try testing.expect(start_ms < 250);
    try testing.expectEqualStrings("", h.out.written());
}

test "prompt-submit with nothing listening prints nothing, fast" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const ms = try h.run(.@"claude-code", .@"prompt-submit", try h.payload(",\"prompt\":\"hello\""));
    try testing.expect(ms < 80);
    try testing.expectEqualStrings("", h.out.written());
}

test "pi and fx are no-ops; paused, excluded, error bodies and bad stdin print nothing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var stub: Stub = .{ .io = testing.io, .server = undefined, .body = "brief" };
    try h.serveTcp(&stub);
    defer stub.stop();

    _ = try h.run(.pi, .@"session-start", try h.payload(""));
    _ = try h.run(.fx, .stop, try h.payload(""));
    _ = try h.run(.@"claude-code", .@"session-start", "not json");
    try testing.expectEqualStrings("", h.out.written());

    const state_dir = try h.path("state/graf");
    try state.setPaused(testing.io, state_dir, true);
    _ = try h.run(.@"claude-code", .@"session-start", try h.payload(""));
    _ = try h.run(.@"claude-code", .stop, try h.payload(""));
    try state.setPaused(testing.io, state_dir, false);

    h.config.capture.exclude_projects = &.{"git.example.test/brackwater/*"};
    _ = try h.run(.@"claude-code", .@"session-start", try h.payload(""));
    h.config.capture.exclude_projects = &.{};
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.grafignore", .data = "" });
    _ = try h.run(.@"claude-code", .@"prompt-submit", try h.payload(",\"prompt\":\"x\""));
    try h.tmp.dir.deleteFile(testing.io, "repo/.grafignore");

    try testing.expectEqualStrings("", h.out.written());
    try testing.expectEqual(@as(usize, 0), stub.count.load(.acquire));
    try testing.expectEqualStrings("", try h.spoolText());

    stub.status = 500;
    _ = try h.run(.@"claude-code", .@"session-start", try h.payload(""));
    try testing.expectEqualStrings("", h.out.written());

    stub.status = 200;
    stub.body = "  \n";
    _ = try h.run(.@"claude-code", .@"session-start", try h.payload(""));
    try testing.expectEqualStrings("", h.out.written());
}

const Collector = struct {
    arena: Allocator,
    seen: *std.ArrayList([]const u8),
    fail_after: ?usize = null,

    fn handle(c: Collector, entry: spool.Entry) anyerror!void {
        if (c.fail_after) |n| if (c.seen.items.len >= n) return error.DaemonBusy;
        try c.seen.append(c.arena, try std.fmt.allocPrint(c.arena, "{s}/{s}/{s}", .{ entry.harness, entry.event, entry.session_id orelse "-" }));
    }
};

test "drainSpool replays every line, removes the spool, and re-delivers after a failed drain" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const state_dir = try h.path("state/graf");
    try testing.expectEqual(@as(usize, 0), try spool.drain(h.arena(), testing.io, state_dir, Collector{ .arena = h.arena(), .seen = undefined }, Collector.handle));

    _ = try h.run(.@"claude-code", .stop, try h.payload(""));
    _ = try h.run(.codex, .@"session-end", try h.payload(""));
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "extra", .data = "" });

    var seen: std.ArrayList([]const u8) = .empty;
    try testing.expectError(error.DaemonBusy, spool.drain(h.arena(), testing.io, state_dir, Collector{ .arena = h.arena(), .seen = &seen, .fail_after = 1 }, Collector.handle));
    try testing.expectEqual(@as(usize, 1), seen.items.len);
    try testing.expectEqualStrings("", try h.spoolText());

    _ = try h.run(.@"claude-code", .@"session-end", try h.payload(""));

    seen.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 3), try spool.drain(h.arena(), testing.io, state_dir, Collector{ .arena = h.arena(), .seen = &seen }, Collector.handle));
    try testing.expectEqualStrings("claude-code/stop/sess-1", seen.items[0]);
    try testing.expectEqualStrings("codex/session-end/sess-1", seen.items[1]);
    try testing.expectEqualStrings("claude-code/session-end/sess-1", seen.items[2]);
    try testing.expectEqualStrings("", try h.spoolText());
    try testing.expectEqual(@as(usize, 0), try spool.drain(h.arena(), testing.io, state_dir, Collector{ .arena = h.arena(), .seen = &seen }, Collector.handle));
}

test "responseText accepts plain, markdown and JSON shapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("hi", (try hooks.responseText(arena, .{ .status = 200, .content_type = "text/plain; charset=utf-8", .body = "hi\n" })).?);
    try testing.expectEqualStrings("r", (try hooks.responseText(arena, .{ .status = 200, .content_type = "application/json", .body = "{\"recall\":\"r\"}" })).?);
    try testing.expectEqualStrings("t", (try hooks.responseText(arena, .{ .status = 200, .content_type = "", .body = "{\"text\":\"t\"}" })).?);
    try testing.expect((try hooks.responseText(arena, .{ .status = 200, .content_type = "application/json", .body = "{\"other\":1}" })) == null);
    try testing.expect((try hooks.responseText(arena, .{ .status = 200, .content_type = "application/json", .body = "[1]" })) == null);
    try testing.expect((try hooks.responseText(arena, .{ .status = 404, .content_type = "text/plain", .body = "nope" })) == null);
}
