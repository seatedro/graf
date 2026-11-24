const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;

pub const result_budget: usize = 1500;
pub const args_budget: usize = 600;
pub const read_error_budget: usize = 300;

pub fn headTail(arena: Allocator, text: []const u8, budget: usize) Allocator.Error![]const u8 {
    if (text.len <= budget) return text;

    const half = budget / 2;
    var head_end = half;
    while (head_end > 0 and isContinuation(text[head_end])) head_end -= 1;
    var tail_start = text.len - half;
    while (tail_start < text.len and isContinuation(text[tail_start])) tail_start += 1;

    return std.fmt.allocPrint(arena, "{s}\n[... {d} bytes elided ...]\n{s}", .{
        text[0..head_end],
        tail_start - head_end,
        text[tail_start..],
    });
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

pub fn clean(arena: Allocator, scratch: Allocator, text: []const u8) Allocator.Error![]const u8 {
    return arena.dupe(u8, try core.redact(scratch, text));
}

pub fn cleanBounded(arena: Allocator, scratch: Allocator, text: []const u8, budget: usize) Allocator.Error![]const u8 {
    const redacted = try core.redact(scratch, text);
    return arena.dupe(u8, try headTail(scratch, redacted, budget));
}

pub const RawTool = struct {
    name: []const u8,
    args: ?std.json.Value = null,
    args_text: ?[]const u8 = null,
};

pub const Call = struct {
    name: []const u8,
    read: ?Read = null,
    args_preview: []const u8 = "",

    pub const Read = struct {
        path: []const u8,
        offset: ?u64 = null,
        limit: ?u64 = null,
    };
};

pub fn prepareCall(arena: Allocator, scratch: Allocator, raw: RawTool) Allocator.Error!Call {
    const name = try arena.dupe(u8, raw.name);

    if (isReadTool(raw.name)) {
        if (raw.args) |args| if (readPath(args)) |path| {
            return .{ .name = name, .read = .{
                .path = try clean(arena, scratch, path),
                .offset = intField(args, &.{ "offset", "start_line", "line", "startLine" }),
                .limit = intField(args, &.{ "limit", "lines", "line_count" }),
            } };
        };
    }

    if (commandText(raw)) |cmd| {
        if (shellRead(cmd)) |read| {
            return .{ .name = name, .read = .{
                .path = try clean(arena, scratch, read.path),
                .offset = read.first,
                .limit = if (read.first != null and read.last != null) read.last.? - read.first.? + 1 else null,
            } };
        }
        return .{ .name = name, .args_preview = try cleanBounded(arena, scratch, cmd, args_budget) };
    }

    const text = if (raw.args) |args|
        try std.json.Stringify.valueAlloc(scratch, args, .{})
    else
        raw.args_text orelse "";
    return .{ .name = name, .args_preview = try cleanBounded(arena, scratch, text, args_budget) };
}

pub fn finishCall(arena: Allocator, scratch: Allocator, call: Call, result: ?[]const u8, is_error: bool) Allocator.Error!core.ToolCall {
    if (call.read) |read| {
        const first = read.offset orelse 1;
        const lines: ?u64 = if (result) |r| (if (is_error) null else countLines(r)) else read.limit;

        const preview = if (lines) |n|
            (if (n == 0)
                read.path
            else
                try std.fmt.allocPrint(arena, "{s}:{d}-{d}", .{ read.path, first, first + n - 1 }))
        else if (read.offset != null)
            try std.fmt.allocPrint(arena, "{s}:{d}-", .{ read.path, first })
        else
            read.path;

        const result_preview = if (is_error and result != null)
            try cleanBounded(arena, scratch, result.?, read_error_budget)
        else
            "";

        return .{ .name = call.name, .args_preview = preview, .result_preview = result_preview };
    }

    return .{
        .name = call.name,
        .args_preview = call.args_preview,
        .result_preview = if (result) |r| try cleanBounded(arena, scratch, r, result_budget) else "",
    };
}

pub fn countLines(text: []const u8) u64 {
    if (text.len == 0) return 0;
    var n: u64 = std.mem.count(u8, text, "\n");
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

const read_tools = [_][]const u8{ "read", "read_file", "readfile", "view", "view_file", "open_file" };

pub fn isReadTool(name: []const u8) bool {
    for (read_tools) |t| if (std.ascii.eqlIgnoreCase(name, t)) return true;
    return false;
}

fn readPath(args: std.json.Value) ?[]const u8 {
    if (args != .object) return null;
    for ([_][]const u8{ "file_path", "path", "filePath", "file", "filename", "target_file" }) |key| {
        if (args.object.get(key)) |v| if (v == .string and v.string.len > 0) return v.string;
    }
    return null;
}

fn intField(args: std.json.Value, keys: []const []const u8) ?u64 {
    if (args != .object) return null;
    for (keys) |key| if (args.object.get(key)) |v| switch (v) {
        .integer => |i| if (i >= 0) return @intCast(i),
        .float => |f| if (f >= 0) return @intFromFloat(f),
        .string => |s| return std.fmt.parseInt(u64, s, 10) catch null,
        else => {},
    };
    return null;
}

pub fn commandText(raw: RawTool) ?[]const u8 {
    const args = raw.args orelse return null;
    if (args != .object) return null;

    for ([_][]const u8{ "command", "cmd" }) |key| {
        const v = args.object.get(key) orelse continue;
        switch (v) {
            .string => |s| return s,
            .array => |arr| {
                if (arr.items.len == 0) continue;
                const last = arr.items[arr.items.len - 1];
                if (last != .string) continue;
                if (arr.items.len == 1) return last.string;
                if (arr.items.len >= 3 and arr.items[0] == .string and isShell(arr.items[0].string)) return last.string;
            },
            else => {},
        }
    }
    return null;
}

fn isShell(argv0: []const u8) bool {
    const base = std.fs.path.basename(argv0);
    return std.mem.eql(u8, base, "bash") or std.mem.eql(u8, base, "sh") or std.mem.eql(u8, base, "zsh");
}

pub const ShellRead = struct { path: []const u8, first: ?u64 = null, last: ?u64 = null };

pub fn shellRead(command: []const u8) ?ShellRead {
    const cmd = std.mem.trim(u8, command, " \t\r\n");
    if (std.mem.indexOfAny(u8, cmd, "|;&<>`$\n") != null) return null;

    var words: [6][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |w| {
        if (n == words.len) return null;
        words[n] = w;
        n += 1;
    }

    if (n < 2) return null;
    const prog = words[0];
    if (std.mem.eql(u8, prog, "cat") and n == 2) return .{ .path = unquote(words[1]) };
    if (std.mem.eql(u8, prog, "nl") and n == 3 and std.mem.eql(u8, words[1], "-ba")) return .{ .path = unquote(words[2]) };

    if (std.mem.eql(u8, prog, "sed") and n == 4 and std.mem.eql(u8, words[1], "-n")) {
        const range = unquote(words[2]);
        if (range.len < 2 or range[range.len - 1] != 'p') return null;
        const comma = std.mem.indexOfScalar(u8, range, ',') orelse return null;
        const first = std.fmt.parseInt(u64, range[0..comma], 10) catch return null;
        const last = std.fmt.parseInt(u64, range[comma + 1 .. range.len - 1], 10) catch return null;
        if (last < first) return null;
        return .{ .path = unquote(words[3]), .first = first, .last = last };
    }

    return null;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '\'' or s[0] == '"') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

pub fn estimateTokens(turn: core.Turn) usize {
    var bytes: usize = turn.text.len;
    for (turn.tool_calls) |tc| bytes += tc.name.len + tc.args_preview.len + tc.result_preview.len + 8;
    return (bytes * 10 + 37) / 38;
}

pub fn dupeTurn(arena: Allocator, turn: core.Turn) Allocator.Error!core.Turn {
    const calls = try arena.alloc(core.ToolCall, turn.tool_calls.len);
    for (turn.tool_calls, calls) |src, *dst| dst.* = try dupeToolCall(arena, src);
    return .{ .role = turn.role, .text = try arena.dupe(u8, turn.text), .tool_calls = calls, .ts = turn.ts };
}

pub fn dupeToolCall(arena: Allocator, call: core.ToolCall) Allocator.Error!core.ToolCall {
    return .{
        .name = try arena.dupe(u8, call.name),
        .args_preview = try arena.dupe(u8, call.args_preview),
        .result_preview = try arena.dupe(u8, call.result_preview),
    };
}

pub fn jsonTimestamp(v: ?std.json.Value) ?core.Micros {
    const value = v orelse return null;
    return switch (value) {
        .integer => |ms| ms * std.time.us_per_ms,
        .float => |ms| @intFromFloat(ms * std.time.us_per_ms),
        .string => |s| core.time.parseIso(s) catch null,
        else => null,
    };
}

const testing = std.testing;

test "headTail keeps both ends and respects utf-8" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("short", try headTail(arena, "short", 10));

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "ab");
    for (0..20) |_| try buf.appendSlice(arena, "\xc3\xa9");
    try buf.appendSlice(arena, "yz");
    const long = buf.items;
    const out = try headTail(arena, long, 10);

    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expect(std.mem.startsWith(u8, out, "ab"));
    try testing.expect(std.mem.endsWith(u8, out, "yz"));
    try testing.expect(std.mem.indexOf(u8, out, "bytes elided") != null);
}

test "file reads collapse to a path and line range" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"file_path\":\"/repo/src/main.zig\",\"offset\":10,\"limit\":5}", .{});
    const call = try prepareCall(arena, arena, .{ .name = "Read", .args = args });
    const tc = try finishCall(arena, arena, call, "a\nb\nc\nd\ne\n", false);

    try testing.expectEqualStrings("/repo/src/main.zig:10-14", tc.args_preview);
    try testing.expectEqualStrings("", tc.result_preview);

    const sed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":[\"bash\",\"-lc\",\"sed -n '20,60p' src/x.zig\"]}", .{});
    const shell = try finishCall(arena, arena, try prepareCall(arena, arena, .{ .name = "shell", .args = sed }), "lots of code", false);
    try testing.expectEqualStrings("src/x.zig:20-20", shell.args_preview);

    try testing.expect(shellRead("cat a.txt | grep x") == null);
    try testing.expect(shellRead("cat a b") == null);
    try testing.expectEqualStrings("a.txt", shellRead("cat 'a.txt'").?.path);
}

test "command output keeps head and tail; arguments are bounded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":\"zig build test\"}", .{});
    const call = try prepareCall(arena, arena, .{ .name = "Bash", .args = args });
    const filler = try arena.alloc(u8, 5000);
    @memset(filler, 'x');
    const output = try std.mem.concat(arena, u8, &.{ "HEAD-MARKER\n", filler, "\nTAIL-MARKER" });
    const tc = try finishCall(arena, arena, call, output, false);

    try testing.expectEqualStrings("zig build test", tc.args_preview);
    try testing.expect(tc.result_preview.len < result_budget + 64);
    try testing.expect(std.mem.startsWith(u8, tc.result_preview, "HEAD-MARKER"));
    try testing.expect(std.mem.endsWith(u8, tc.result_preview, "TAIL-MARKER"));
}

test "json timestamps take epoch milliseconds or iso strings" {
    try testing.expectEqual(@as(?core.Micros, 1_000), jsonTimestamp(.{ .integer = 1 }));
    try testing.expectEqual(@as(?core.Micros, 1_763_658_000_123_000), jsonTimestamp(.{ .string = "2025-11-20T17:00:00.123Z" }));
    try testing.expectEqual(@as(?core.Micros, null), jsonTimestamp(.{ .string = "yesterday" }));
}
