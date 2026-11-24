const std = @import("std");
const core = @import("core");
const state = @import("state.zig");
const project = @import("project.zig");
const http = @import("hooks_http.zig");
const spool = @import("hooks_spool.zig");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;

pub const Event = enum { @"session-start", @"prompt-submit", stop, @"session-end" };

pub const max_recall_prompt_bytes = 2048;

pub fn networkBudget(event: Event) Io.Duration {
    return .fromMilliseconds(switch (event) {
        .@"session-start" => 200,
        .@"prompt-submit" => 60,
        .stop, .@"session-end" => 35,
    });
}

pub fn supports(harness: core.Harness) bool {
    return harness == .@"claude-code" or harness == .codex;
}

const Payload = struct {
    session_id: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    hook_event_name: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

pub fn run(arena: Allocator, io: Io, env: *const Environ.Map, config: *const core.Config, harness: core.Harness, event: Event, stdin_json: []const u8, out: *std.Io.Writer) !void {
    const start = Io.Clock.Timestamp.now(io, .awake);
    if (!supports(harness)) return;
    defer if (harness == .codex and event == .stop) out.writeAll("{}\n") catch {};

    const payload = std.json.parseFromSliceLeaky(Payload, arena, stdin_json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
    const state_dir = try state.dir(arena, env);
    if (state_dir) |d| if (state.isPaused(io, d)) return;

    const proj = if (payload.cwd) |cwd| try project.derive(arena, io, cwd) else null;
    if (try project.isExcluded(arena, io, config, .{
        .cwd = payload.cwd,
        .project = proj,
        .transcript_path = payload.transcript_path,
        .home = env.get("HOME"),
    })) return;

    const call: Call = .{
        .arena = arena,
        .io = io,
        .endpoints = try endpoints(arena, io, config, env),
        .token = config.serve.token,
    };
    const deadline = start.addDuration(.{ .raw = networkBudget(event), .clock = .awake });

    switch (event) {
        .@"session-start" => {
            const p = proj orelse return;
            const target = try std.fmt.allocPrint(arena, "/v1/brief?project={s}", .{try http.percentEncode(arena, p)});
            const response = http.withinDeadline(io, deadline, fetch, .{ call, call.request("GET", target, null) }) orelse return;
            try emit(arena, out, "SessionStart", response catch return);
        },
        .@"prompt-submit" => {
            const session_id = payload.session_id orelse return;
            const prompt = payload.prompt orelse return;
            const sid = try http.percentEncode(arena, session_id);
            const warm_body = try std.json.Stringify.valueAlloc(arena, .{ .prompt = prompt }, .{});
            const warm_target = try std.fmt.allocPrint(arena, "/v1/sessions/{s}/warm", .{sid});
            const recall_target = try std.fmt.allocPrint(arena, "/v1/sessions/{s}/recall?prompt={s}", .{ sid, try http.percentEncode(arena, truncateUtf8(prompt, max_recall_prompt_bytes)) });
            const response = http.withinDeadline(io, deadline, warmThenFetch, .{
                call,
                call.request("POST", warm_target, warm_body),
                call.request("GET", recall_target, null),
            }) orelse return;
            try emit(arena, out, "UserPromptSubmit", response catch return);
        },
        .stop, .@"session-end" => {
            const body = try std.json.Stringify.valueAlloc(arena, .{
                .harness = @tagName(harness),
                .session_id = payload.session_id,
                .transcript_path = payload.transcript_path,
                .cwd = payload.cwd,
            }, .{});
            const accepted = blk: {
                const result = http.withinDeadline(io, deadline, fetch, .{ call, call.request("POST", "/v1/hooks/flush", body) }) orelse break :blk false;
                const response = result catch break :blk false;
                break :blk response.ok();
            };
            if (accepted) return;
            const dir = state_dir orelse return;
            spool.append(arena, io, dir, .{
                .ts = Io.Clock.real.now(io).toMicroseconds(),
                .harness = @tagName(harness),
                .event = @tagName(event),
                .session_id = payload.session_id,
                .transcript_path = payload.transcript_path,
                .cwd = payload.cwd,
            }) catch {};
        },
    }
}

const Call = struct {
    arena: Allocator,
    io: Io,
    endpoints: []const http.Endpoint,
    token: []const u8,

    fn request(c: Call, method: []const u8, target: []const u8, body: ?[]const u8) http.Request {
        return .{ .method = method, .target = target, .token = c.token, .body = body };
    }
};

fn fetch(c: Call, request: http.Request) http.Error!http.Response {
    const stream = try http.connect(c.io, c.endpoints);
    defer stream.close(c.io);
    try http.send(c.io, stream, request);
    return http.receive(c.arena, c.io, stream);
}

fn warmThenFetch(c: Call, warm: http.Request, request: http.Request) http.Error!http.Response {
    if (http.connect(c.io, c.endpoints)) |stream| {
        defer stream.close(c.io);
        http.send(c.io, stream, warm) catch |err| if (err == error.Canceled) return err;
    } else |err| if (err == error.Canceled) return err;
    return fetch(c, request);
}

fn endpoints(arena: Allocator, io: Io, config: *const core.Config, env: *const Environ.Map) Allocator.Error![]const http.Endpoint {
    var list: std.ArrayList(http.Endpoint) = .empty;
    if (try state.socketPath(arena, config, env)) |path| {
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| try list.append(arena, .{ .unix = path }) else |_| {}
    }
    if (http.parseListen(config.serve.listen)) |addr| try list.append(arena, .{ .tcp = addr });
    return list.items;
}

fn emit(arena: Allocator, out: *std.Io.Writer, hook_event_name: []const u8, response: http.Response) !void {
    const text = try responseText(arena, response) orelse return;
    try std.json.Stringify.value(.{ .hookSpecificOutput = .{
        .hookEventName = hook_event_name,
        .additionalContext = text,
    } }, .{}, out);
    try out.writeByte('\n');
}

pub fn responseText(arena: Allocator, response: http.Response) Allocator.Error!?[]const u8 {
    if (!response.ok()) return null;
    const body = std.mem.trim(u8, response.body, " \t\r\n");
    if (body.len == 0) return null;
    const is_json = http.containsIgnoreCase(response.content_type, "json") or
        (response.content_type.len == 0 and body[0] == '{');
    if (!is_json) return body;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (value != .object) return null;
    for ([_][]const u8{ "text", "brief", "recall" }) |key| {
        const field = value.object.get(key) orelse continue;
        if (field != .string) continue;
        const text = std.mem.trim(u8, field.string, " \t\r\n");
        return if (text.len == 0) null else text;
    }
    return null;
}

fn truncateUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

test {
    _ = http;
    _ = @import("hooks_test.zig");
}
