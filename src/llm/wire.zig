const std = @import("std");
const core = @import("core");
const Route = core.config.Route;
const CostStatus = core.types.CostStatus;
const Value = std.json.Value;

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
};

pub const Prompt = struct {
    model: []const u8,
    system: []const u8,
    user: []const u8,
    schema_name: []const u8,
    schema_json: []const u8,
    max_output_tokens: u32,
};

pub fn path(route: Route) []const u8 {
    return switch (route) {
        .@"openai-responses" => "/responses",
        .@"anthropic-messages" => "/messages",
        .@"openai-chat" => "/chat/completions",
    };
}

pub fn writeStructuredRequest(route: Route, p: Prompt, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("model");
    try s.write(p.model);
    switch (route) {
        .@"openai-responses" => {
            try s.objectField("instructions");
            try s.write(p.system);
            try s.objectField("input");
            try s.beginArray();
            try writeMessage(&s, "user", p.user);
            try s.endArray();
            try s.objectField("text");
            try s.beginObject();
            try s.objectField("format");
            try s.beginObject();
            try s.objectField("type");
            try s.write("json_schema");
            try s.objectField("name");
            try s.write(p.schema_name);
            try s.objectField("strict");
            try s.write(true);
            try s.objectField("schema");
            try writeRaw(&s, p.schema_json);
            try s.endObject();
            try s.endObject();
            try s.objectField("max_output_tokens");
            try s.write(p.max_output_tokens);
            try s.objectField("store");
            try s.write(false);
        },
        .@"anthropic-messages" => {
            try s.objectField("max_tokens");
            try s.write(p.max_output_tokens);
            try s.objectField("system");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("type");
            try s.write("text");
            try s.objectField("text");
            try s.write(p.system);
            try s.objectField("cache_control");
            try s.beginObject();
            try s.objectField("type");
            try s.write("ephemeral");
            try s.endObject();
            try s.endObject();
            try s.endArray();
            try s.objectField("messages");
            try s.beginArray();
            try writeMessage(&s, "user", p.user);
            try s.endArray();
            try s.objectField("output_config");
            try s.beginObject();
            try s.objectField("format");
            try s.beginObject();
            try s.objectField("type");
            try s.write("json_schema");
            try s.objectField("schema");
            try writeRaw(&s, p.schema_json);
            try s.endObject();
            try s.endObject();
        },
        .@"openai-chat" => {
            try s.objectField("messages");
            try s.beginArray();
            try writeMessage(&s, "system", p.system);
            try writeMessage(&s, "user", p.user);
            try s.endArray();
            try s.objectField("response_format");
            try s.beginObject();
            try s.objectField("type");
            try s.write("json_schema");
            try s.objectField("json_schema");
            try s.beginObject();
            try s.objectField("name");
            try s.write(p.schema_name);
            try s.objectField("strict");
            try s.write(true);
            try s.objectField("schema");
            try writeRaw(&s, p.schema_json);
            try s.endObject();
            try s.endObject();
        },
    }
    try s.endObject();
}

fn writeMessage(s: *std.json.Stringify, role: []const u8, content: []const u8) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("role");
    try s.write(role);
    try s.objectField("content");
    try s.write(content);
    try s.endObject();
}

fn writeRaw(s: *std.json.Stringify, raw: []const u8) std.Io.Writer.Error!void {
    try s.beginWriteRaw();
    try s.writer.writeAll(raw);
    s.endWriteRaw();
}

pub const Stop = enum {
    complete,
    truncated,
    refused,
};

pub const Decoded = struct {
    text: []const u8,
    usage: Usage = .{},
    body_cost: ?f64 = null,
    body_cost_status: ?CostStatus = null,
    stop: Stop = .complete,
    detail: []const u8 = "",
    model: ?[]const u8 = null,
};

pub const DecodeError = error{ MalformedResponse, OutOfMemory };

pub fn decodeStructured(route: Route, arena: std.mem.Allocator, body: []const u8) DecodeError!Decoded {
    const root = try parseObject(arena, body);
    var out: Decoded = .{ .text = "", .model = str(root.get("model")) };
    readBodyCost(root, &out);
    switch (route) {
        .@"openai-responses" => {
            if (obj(root.get("usage"))) |u| {
                const cached = int(obj(u.get("input_tokens_details")), "cached_tokens");
                out.usage = .{
                    .input_tokens = int(u, "input_tokens") -| cached,
                    .output_tokens = int(u, "output_tokens"),
                    .cache_read_tokens = cached,
                };
            }
            if (eqlOpt(str(root.get("status")), "incomplete")) {
                const reason = str((obj(root.get("incomplete_details")) orelse root).get("reason")) orelse "";
                if (std.mem.eql(u8, reason, "content_filter")) {
                    out.stop = .refused;
                    out.detail = "content_filter";
                } else out.stop = .truncated;
            }
            var text: std.ArrayList(u8) = .empty;
            const output = arr(root.get("output")) orelse return error.MalformedResponse;
            for (output) |item_v| {
                const item = obj(item_v) orelse continue;
                if (!eqlOpt(str(item.get("type")), "message")) continue;
                for (arr(item.get("content")) orelse continue) |part_v| {
                    const part = obj(part_v) orelse continue;
                    const kind = str(part.get("type")) orelse continue;
                    if (std.mem.eql(u8, kind, "output_text")) {
                        try text.appendSlice(arena, str(part.get("text")) orelse "");
                    } else if (std.mem.eql(u8, kind, "refusal")) {
                        out.stop = .refused;
                        out.detail = str(part.get("refusal")) orelse "refusal";
                    }
                }
            }
            out.text = text.items;
        },
        .@"anthropic-messages" => {
            if (obj(root.get("usage"))) |u| out.usage = .{
                .input_tokens = int(u, "input_tokens"),
                .output_tokens = int(u, "output_tokens"),
                .cache_read_tokens = int(u, "cache_read_input_tokens"),
                .cache_write_tokens = int(u, "cache_creation_input_tokens"),
            };
            const stop = str(root.get("stop_reason")) orelse "";
            if (std.mem.eql(u8, stop, "max_tokens")) out.stop = .truncated;
            if (std.mem.eql(u8, stop, "refusal")) {
                out.stop = .refused;
                out.detail = "refusal";
            }
            var text: std.ArrayList(u8) = .empty;
            const content = arr(root.get("content")) orelse return error.MalformedResponse;
            for (content) |block_v| {
                const block = obj(block_v) orelse continue;
                if (eqlOpt(str(block.get("type")), "text")) try text.appendSlice(arena, str(block.get("text")) orelse "");
            }
            out.text = text.items;
        },
        .@"openai-chat" => {
            if (obj(root.get("usage"))) |u| {
                const cached = int(obj(u.get("prompt_tokens_details")), "cached_tokens");
                out.usage = .{
                    .input_tokens = int(u, "prompt_tokens") -| cached,
                    .output_tokens = int(u, "completion_tokens"),
                    .cache_read_tokens = cached,
                };
            }
            const choices = arr(root.get("choices")) orelse return error.MalformedResponse;
            if (choices.len == 0) return error.MalformedResponse;
            const choice = obj(choices[0]) orelse return error.MalformedResponse;
            const finish = str(choice.get("finish_reason")) orelse "";
            if (std.mem.eql(u8, finish, "length")) out.stop = .truncated;
            if (std.mem.eql(u8, finish, "content_filter")) {
                out.stop = .refused;
                out.detail = "content_filter";
            }
            const message = obj(choice.get("message")) orelse return error.MalformedResponse;
            if (str(message.get("refusal"))) |refusal| {
                out.stop = .refused;
                out.detail = refusal;
            }
            out.text = stripFences(str(message.get("content")) orelse "");
        },
    }
    return out;
}

pub fn stripFences(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "```")) return t;
    const first_nl = std.mem.findScalar(u8, t, '\n') orelse return t;
    var inner = t[first_nl + 1 ..];
    inner = std.mem.trimEnd(u8, inner, " \t\r\n");
    if (std.mem.endsWith(u8, inner, "```")) inner = inner[0 .. inner.len - 3];
    return std.mem.trim(u8, inner, " \t\r\n");
}

pub fn writeEmbedRequest(model: []const u8, inputs: []const []const u8, dimensions: u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("model");
    try s.write(model);
    try s.objectField("input");
    try s.write(inputs);
    try s.objectField("dimensions");
    try s.write(dimensions);
    try s.objectField("encoding_format");
    try s.write("float");
    try s.endObject();
}

pub const DecodedEmbeddings = struct {
    vectors: []const []const f32,
    usage: Usage = .{},
    body_cost: ?f64 = null,
    body_cost_status: ?CostStatus = null,
};

pub fn decodeEmbeddings(arena: std.mem.Allocator, body: []const u8, n_inputs: usize, dimensions: u32) DecodeError!DecodedEmbeddings {
    const root = try parseObject(arena, body);
    const rows = arr(root.get("data")) orelse return error.MalformedResponse;
    if (rows.len != n_inputs) return error.MalformedResponse;

    const vectors = try arena.alloc([]const f32, n_inputs);
    const seen = try arena.alloc(bool, n_inputs);
    @memset(seen, false);
    var by_index = true;
    for (rows) |row_v| {
        const row = obj(row_v) orelse return error.MalformedResponse;
        const idx_v = row.get("index") orelse {
            by_index = false;
            break;
        };
        if (idx_v != .integer or idx_v.integer < 0 or idx_v.integer >= n_inputs or seen[@intCast(idx_v.integer)]) {
            by_index = false;
            break;
        }
        seen[@intCast(idx_v.integer)] = true;
    }

    for (rows, 0..) |row_v, pos| {
        const row = obj(row_v).?;
        const values = arr(row.get("embedding")) orelse return error.MalformedResponse;
        if (values.len != dimensions) return error.MalformedResponse;
        const vec = try arena.alloc(f32, values.len);
        for (values, vec) |v, *dst| dst.* = @floatCast(number(v) orelse return error.MalformedResponse);
        const slot: usize = if (by_index) @intCast(row.get("index").?.integer) else pos;
        vectors[slot] = vec;
    }

    var out: DecodedEmbeddings = .{ .vectors = vectors };
    if (obj(root.get("usage"))) |u| out.usage.input_tokens = int(u, "prompt_tokens");
    var tmp: Decoded = .{ .text = "" };
    readBodyCost(root, &tmp);
    out.body_cost = tmp.body_cost;
    out.body_cost_status = tmp.body_cost_status;
    return out;
}

pub fn errorMessage(arena: std.mem.Allocator, body: []const u8) []const u8 {
    const root = parseObject(arena, body) catch return body;
    if (obj(root.get("error"))) |e| if (str(e.get("message"))) |m| return m;
    if (str(root.get("error"))) |m| return m;
    if (str(root.get("message"))) |m| return m;
    return body;
}

fn readBodyCost(root: std.json.ObjectMap, out: anytype) void {
    const u = obj(root.get("usage")) orelse return;
    out.body_cost = if (u.get("cost")) |c| number(c) else null;
    if (str(u.get("cost_status"))) |s| out.body_cost_status = std.meta.stringToEnum(CostStatus, s);
}

pub fn parseObject(arena: std.mem.Allocator, body: []const u8) DecodeError!std.json.ObjectMap {
    const v = std.json.parseFromSliceLeaky(Value, arena, body, .{ .duplicate_field_behavior = .use_last }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedResponse,
    };
    return obj(v) orelse error.MalformedResponse;
}

fn obj(v: ?Value) ?std.json.ObjectMap {
    const x = v orelse return null;
    return if (x == .object) x.object else null;
}

fn arr(v: ?Value) ?[]const Value {
    const x = v orelse return null;
    return if (x == .array) x.array.items else null;
}

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

pub fn number(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn int(o: ?std.json.ObjectMap, key: []const u8) u32 {
    const m = o orelse return 0;
    const v = m.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| std.math.cast(u32, i) orelse 0,
        .float => |f| if (f >= 0 and f < 4e9) @intFromFloat(f) else 0,
        else => 0,
    };
}

test "fence stripping" {
    try std.testing.expectEqualStrings("{\"a\":1}", stripFences("```json\n{\"a\":1}\n```\n"));
    try std.testing.expectEqualStrings("{\"a\":1}", stripFences("  {\"a\":1} "));
    try std.testing.expectEqualStrings("{}", stripFences("```\n{}\n```"));
}

test "embeddings decode by index when present and by position when not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const indexed = try decodeEmbeddings(arena, "{\"data\":[{\"index\":1,\"embedding\":[0.5,1]},{\"index\":0,\"embedding\":[2,3]}],\"usage\":{\"prompt_tokens\":7}}", 2, 2);
    try std.testing.expectEqual(@as(f32, 2), indexed.vectors[0][0]);
    try std.testing.expectEqual(@as(f32, 0.5), indexed.vectors[1][0]);
    try std.testing.expectEqual(@as(u32, 7), indexed.usage.input_tokens);
    const positional = try decodeEmbeddings(arena, "{\"data\":[{\"embedding\":[0.5,1]},{\"embedding\":[2,3]}]}", 2, 2);
    try std.testing.expectEqual(@as(f32, 0.5), positional.vectors[0][0]);
    try std.testing.expectError(error.MalformedResponse, decodeEmbeddings(arena, "{\"data\":[{\"embedding\":[0.5]}]}", 1, 2));
    try std.testing.expectError(error.MalformedResponse, decodeEmbeddings(arena, "{\"data\":[]}", 1, 2));
}
