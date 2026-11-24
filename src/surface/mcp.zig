const std = @import("std");
const api = @import("api.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const protocol_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

pub const instructions =
    "graf is your persistent memory across sessions and harnesses. " ++
    "Call memory_search before starting work on a topic, and whenever the user refers to past decisions, preferences or project state. " ++
    "Call memory_entity to inspect one person, repo, service or concept in depth. " ++
    "Call memory_remember for durable facts the user states and for decisions that were made; " ++
    "call memory_forget for facts that are wrong or obsolete. " ++
    "Results carry validity dates, confidence and source; prefer current, high-confidence facts and say when memory is uncertain. " ++
    "Transcripts are captured automatically, so do not remember routine chatter.";

pub const tool_names = [_][]const u8{ "memory_search", "memory_entity", "memory_remember", "memory_forget" };
const tool_ops = [tool_names.len]api.Op{ .search, .entity, .remember, .forget };

const tools_json =
    \\[
    \\{"name":"memory_search",
    \\ "description":"Search persistent memory: facts, decisions, preferences and project state from past sessions.",
    \\ "inputSchema":{"type":"object","additionalProperties":false,"required":["query"],"properties":{
    \\  "query":{"type":"string","description":"What to look for, in natural language."},
    \\  "project":{"type":"string","description":"Project to search; \"*\" for all. Defaults to the current project."},
    \\  "as_of":{"type":"string","description":"ISO 8601. What was true at this time."},
    \\  "known_at":{"type":"string","description":"ISO 8601. What memory knew at this time."},
    \\  "include_history":{"type":"boolean","description":"Include superseded facts."},
    \\  "harness":{"type":"string","enum":["claude-code","codex","pi","fx","capy","api","cli","mcp"],"description":"Only facts captured from this harness."},
    \\  "max_tokens":{"type":"integer","minimum":1,"maximum":4000,"default":1500}}}},
    \\{"name":"memory_entity",
    \\ "description":"Show one entity (person, repo, service, file, concept) with its facts and relations.",
    \\ "inputSchema":{"type":"object","additionalProperties":false,"required":["name_or_id"],"properties":{
    \\  "name_or_id":{"type":"string","description":"Entity name, alias or id."},
    \\  "depth":{"type":"integer","enum":[1,2],"default":1,"description":"Relation hops to include."},
    \\  "as_of":{"type":"string","description":"ISO 8601. What was true at this time."},
    \\  "include_history":{"type":"boolean","description":"Include superseded facts."},
    \\  "include_retracted":{"type":"boolean","description":"Include forgotten facts."},
    \\  "max_tokens":{"type":"integer","minimum":1,"maximum":4000,"default":1500}}}},
    \\{"name":"memory_remember",
    \\ "description":"Store a durable fact, decision or preference the user stated. Not for routine chatter.",
    \\ "inputSchema":{"type":"object","additionalProperties":false,"required":["text"],"properties":{
    \\  "text":{"type":"string","description":"The fact, in one or two self-contained sentences."},
    \\  "project":{"type":"string","description":"Project it belongs to. Defaults to the current project."},
    \\  "scope":{"type":"string","enum":["project","global"],"default":"project"},
    \\  "valid_from":{"type":"string","description":"ISO 8601. When it became true. Defaults to now."},
    \\  "wait":{"type":"boolean","default":true,"description":"Wait until the fact is stored."}}}},
    \\{"name":"memory_forget",
    \\ "description":"Retract a wrong or obsolete fact. Give fact_id, or query to find it.",
    \\ "inputSchema":{"type":"object","additionalProperties":false,"anyOf":[{"required":["fact_id"]},{"required":["query"]}],"properties":{
    \\  "fact_id":{"type":"string","format":"uuid","description":"Id of the fact, from a search result."},
    \\  "query":{"type":"string","description":"Describes the fact when the id is unknown."},
    \\  "reason":{"type":"string","description":"Why it is wrong or obsolete."}}}}
    \\]
;

const parse_error = -32700;
const invalid_request = -32600;
const method_not_found = -32601;
const invalid_params = -32602;

const Outcome = union(enum) {
    result: []const u8,
    failure: struct { code: i32, message: []const u8 },
};

pub fn handleMessage(arena: Allocator, handler: api.Handler, version: []const u8, line: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try errorResponse(arena, .null, parse_error, "Parse error"),
    };
    const msg = switch (parsed) {
        .object => |o| o,
        else => return try errorResponse(arena, .null, invalid_request, "Invalid request: expected a JSON-RPC object"),
    };
    const id = msg.get("id");
    const method = msg.get("method") orelse {
        if (msg.get("result") != null or msg.get("error") != null) return null;
        return try errorResponse(arena, id orelse .null, invalid_request, "Invalid request: missing method");
    };
    const jsonrpc = msg.get("jsonrpc") orelse Value.null;
    if (method != .string or jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0"))
        return try errorResponse(arena, id orelse .null, invalid_request, "Invalid request");
    const request_id = id orelse return null;

    return switch (try dispatch(arena, handler, version, method.string, msg.get("params"))) {
        .result => |raw| try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{s}}}", .{ std.json.fmt(request_id, .{}), raw }),
        .failure => |f| try errorResponse(arena, request_id, f.code, f.message),
    };
}

pub fn supportsVersion(version: []const u8) bool {
    for (protocol_versions) |known| if (std.mem.eql(u8, known, version)) return true;
    return false;
}

pub fn handlePost(arena: Allocator, handler: api.Handler, version: []const u8, body: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '[') return handleMessage(arena, handler, version, body);
    const parsed = std.json.parseFromSliceLeaky(Value, arena, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try errorResponse(arena, .null, parse_error, "Parse error"),
    };
    if (parsed.array.items.len == 0) return try errorResponse(arena, .null, invalid_request, "Invalid request: empty batch");
    var out: std.Io.Writer.Allocating = .init(arena);
    var replies: usize = 0;
    for (parsed.array.items) |message| {
        const raw = try std.json.Stringify.valueAlloc(arena, message, .{});
        const reply = try handleMessage(arena, handler, version, raw) orelse continue;
        try out.writer.writeByte(if (replies == 0) '[' else ',');
        try out.writer.writeAll(reply);
        replies += 1;
    }
    if (replies == 0) return null;
    try out.writer.writeByte(']');
    return out.written();
}

pub fn serveStdio(gpa: Allocator, handler: api.Handler, version: []const u8, in: *std.Io.Reader, out: *std.Io.Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var line: std.Io.Writer.Allocating = .init(arena);
        _ = in.streamDelimiterEnding(&line.writer, '\n') catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
        };
        const at_end = in.bufferedLen() == 0;
        if (!at_end) in.toss(1);
        const message = std.mem.trim(u8, line.written(), " \t\r");
        if (message.len > 0) {
            if (try handleMessage(arena, handler, version, message)) |response| {
                try out.writeAll(response);
                try out.writeByte('\n');
                try out.flush();
            }
        }
        if (at_end) return;
    }
}

fn errorResponse(arena: Allocator, id: Value, code: i32, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"error\":{f}}}", .{
        std.json.fmt(id, .{}),
        std.json.fmt(.{ .code = code, .message = message }, .{}),
    });
}

fn fail(code: i32, message: []const u8) Outcome {
    return .{ .failure = .{ .code = code, .message = message } };
}

fn dispatch(arena: Allocator, handler: api.Handler, version: []const u8, method: []const u8, params: ?Value) !Outcome {
    if (std.mem.eql(u8, method, "initialize")) {
        var requested: []const u8 = "";
        if (params) |p| if (p == .object) if (p.object.get("protocolVersion")) |v| if (v == .string) {
            requested = v.string;
        };
        const negotiated = for (protocol_versions) |known| {
            if (std.mem.eql(u8, known, requested)) break known;
        } else protocol_versions[0];
        return .{ .result = try std.json.Stringify.valueAlloc(arena, .{
            .protocolVersion = negotiated,
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = "graf", .version = version },
            .instructions = instructions,
        }, .{}) };
    }
    if (std.mem.eql(u8, method, "ping")) return .{ .result = "{}" };
    if (std.mem.eql(u8, method, "tools/list")) {
        const defs = try std.json.parseFromSliceLeaky(Value, arena, tools_json, .{});
        return .{ .result = try std.json.Stringify.valueAlloc(arena, .{ .tools = defs }, .{}) };
    }
    if (std.mem.eql(u8, method, "tools/call")) return callTool(arena, handler, params);
    return fail(method_not_found, "Method not found");
}

fn callTool(arena: Allocator, handler: api.Handler, params: ?Value) !Outcome {
    const p = params orelse return fail(invalid_params, "Invalid params: missing params");
    if (p != .object) return fail(invalid_params, "Invalid params: expected an object");
    const name = p.object.get("name") orelse return fail(invalid_params, "Invalid params: missing tool name");
    if (name != .string) return fail(invalid_params, "Invalid params: tool name must be a string");
    const index = for (tool_names, 0..) |tool, i| {
        if (std.mem.eql(u8, tool, name.string)) break i;
    } else return fail(invalid_params, try std.fmt.allocPrint(arena, "Unknown tool: {s}", .{name.string}));

    const arguments = p.object.get("arguments") orelse Value{ .object = try .init(arena, &.{}, &.{}) };
    if (arguments != .object) return fail(invalid_params, "Invalid params: arguments must be an object");

    const defs = try std.json.parseFromSliceLeaky(Value, arena, tools_json, .{});
    const schema = defs.array.items[index].object.get("inputSchema").?;
    if (try validate(arena, schema, arguments)) |problem| return toolResult(arena, problem, true);

    const body = try std.json.Stringify.valueAlloc(arena, arguments, .{});
    const reply = handler.handle(arena, .{ .op = tool_ops[index], .body = body }) catch |err|
        return toolResult(arena, @errorName(err), true);
    const is_error = reply.status >= 400;
    return toolResult(arena, replyText(arena, reply.body, if (is_error) "error" else "text"), is_error);
}

fn toolResult(arena: Allocator, text: []const u8, is_error: bool) !Outcome {
    const Content = struct { type: []const u8 = "text", text: []const u8 };
    return .{ .result = try std.json.Stringify.valueAlloc(arena, .{
        .content = &[_]Content{.{ .text = text }},
        .isError = is_error,
    }, .{}) };
}

fn replyText(arena: Allocator, body: []const u8, field: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch return body;
    if (parsed != .object) return body;
    const value = parsed.object.get(field) orelse return body;
    return if (value == .string) value.string else body;
}

fn validate(arena: Allocator, schema: Value, arguments: Value) !?[]const u8 {
    const properties = schema.object.get("properties").?.object;
    var it = arguments.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const property = properties.get(name) orelse
            return try std.fmt.allocPrint(arena, "Invalid arguments: unknown argument '{s}'", .{name});
        if (!matchesProperty(property.object, entry.value_ptr.*))
            return try std.fmt.allocPrint(arena, "Invalid arguments: '{s}' must match {f}", .{ name, std.json.fmt(property, .{}) });
    }
    if (schema.object.get("required")) |required| {
        if (missingRequired(required, arguments)) |name|
            return try std.fmt.allocPrint(arena, "Invalid arguments: '{s}' is required", .{name});
    }
    if (schema.object.get("anyOf")) |alternatives| {
        for (alternatives.array.items) |alternative| {
            if (missingRequired(alternative.object.get("required").?, arguments) == null) break;
        } else return try std.fmt.allocPrint(arena, "Invalid arguments: need one of {f}", .{std.json.fmt(alternatives, .{})});
    }
    return null;
}

fn missingRequired(required: Value, arguments: Value) ?[]const u8 {
    for (required.array.items) |name| {
        if (!arguments.object.contains(name.string)) return name.string;
    }
    return null;
}

fn matchesProperty(property: std.json.ObjectMap, value: Value) bool {
    const kind = property.get("type").?.string;
    const type_ok = if (std.mem.eql(u8, kind, "string"))
        value == .string
    else if (std.mem.eql(u8, kind, "integer"))
        value == .integer
    else
        value == .bool;
    if (!type_ok) return false;
    if (property.get("enum")) |allowed| {
        for (allowed.array.items) |option| {
            if (option == .string and std.mem.eql(u8, option.string, value.string)) break;
            if (option == .integer and option.integer == value.integer) break;
        } else return false;
    }
    if (property.get("minimum")) |min| if (value.integer < min.integer) return false;
    if (property.get("maximum")) |max| if (value.integer > max.integer) return false;
    return true;
}

const testing = std.testing;

const FakeHandler = struct {
    ops: std.ArrayList(api.Op) = .empty,
    bodies: std.ArrayList([]const u8) = .empty,

    fn handler(f: *FakeHandler) api.Handler {
        return .{ .ptr = f, .vtable = &.{ .handle = handle } };
    }

    fn deinit(f: *FakeHandler) void {
        for (f.bodies.items) |b| testing.allocator.free(b);
        f.bodies.deinit(testing.allocator);
        f.ops.deinit(testing.allocator);
    }

    fn handle(ptr: *anyopaque, arena: Allocator, req: api.Request) anyerror!api.Reply {
        const f: *FakeHandler = @ptrCast(@alignCast(ptr));
        try f.ops.append(testing.allocator, req.op);
        try f.bodies.append(testing.allocator, try testing.allocator.dupe(u8, req.body));
        if (std.mem.find(u8, req.body, "boom") != null) return error.StoreUnavailable;
        if (req.op == .forget) return api.errorReply(arena, 404, "no matching fact");
        return .{ .body = try std.fmt.allocPrint(arena, "{{\"text\":\"# {t}\\nok\"}}", .{req.op}) };
    }
};

fn lookup(v: Value, path: []const []const u8) Value {
    var cur = v;
    for (path) |key| {
        cur = switch (cur) {
            .object => |o| o.get(key) orelse return .null,
            .array => |a| a.items[std.fmt.parseInt(usize, key, 10) catch unreachable],
            else => return .null,
        };
    }
    return cur;
}

fn expectToolResult(arena: Allocator, line: []const u8, id: i64, text: []const u8, is_error: bool) !void {
    const v = try std.json.parseFromSliceLeaky(Value, arena, line, .{});
    try testing.expectEqual(id, lookup(v, &.{"id"}).integer);
    try testing.expectEqualStrings("text", lookup(v, &.{ "result", "content", "0", "type" }).string);
    try testing.expectEqualStrings(text, lookup(v, &.{ "result", "content", "0", "text" }).string);
    try testing.expectEqual(is_error, lookup(v, &.{ "result", "isError" }).bool);
}

fn expectToolError(arena: Allocator, line: []const u8, id: i64, text_prefix: []const u8) !void {
    const v = try std.json.parseFromSliceLeaky(Value, arena, line, .{});
    try testing.expectEqual(id, lookup(v, &.{"id"}).integer);
    try testing.expect(std.mem.startsWith(u8, lookup(v, &.{ "result", "content", "0", "text" }).string, text_prefix));
    try testing.expect(lookup(v, &.{ "result", "isError" }).bool);
}

test "stdio session conformance" {
    var fake: FakeHandler = .{};
    defer fake.deinit();
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":"list","method":"tools/list"}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"db choice","project":"*","max_tokens":200}}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"memory_entity","arguments":{"name_or_id":"brackwater","depth":2}}}
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"memory_remember","arguments":{"text":"We use Postgres.","scope":"global"}}}
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"memory_forget","arguments":{"query":"old db","reason":"moved"}}}
        \\{"jsonrpc":"2.0","id":7,"method":"ping"}
        \\{"jsonrpc":"2.0","id":8,"method":"resources/list"}
        \\{not json
        \\
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"memory_delete","arguments":{}}}
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"x","colour":"red"}}}
        \\{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"memory_forget","arguments":{"reason":"r"}}}
        \\{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"x","max_tokens":9000}}}
        \\{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"memory_entity","arguments":{"name_or_id":"a","depth":3}}}
        \\{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"memory_search","arguments":{"query":"boom"}}}
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}
        \\{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"memory_remember"}}
    ;
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try serveStdio(testing.allocator, fake.handler(), "1.2.3", &in, &out.writer);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const output = out.written();
    try testing.expect(std.mem.endsWith(u8, output, "\n"));
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, output[0 .. output.len - 1], '\n');
    while (it.next()) |line| try lines.append(arena, line);
    try testing.expectEqual(16, lines.items.len);

    const init_reply = try std.json.parseFromSliceLeaky(Value, arena, lines.items[0], .{});
    try testing.expectEqual(1, lookup(init_reply, &.{"id"}).integer);
    try testing.expectEqualStrings("2.0", lookup(init_reply, &.{"jsonrpc"}).string);
    try testing.expectEqualStrings("2025-03-26", lookup(init_reply, &.{ "result", "protocolVersion" }).string);
    try testing.expectEqual(false, lookup(init_reply, &.{ "result", "capabilities", "tools", "listChanged" }).bool);
    try testing.expectEqualStrings("graf", lookup(init_reply, &.{ "result", "serverInfo", "name" }).string);
    try testing.expectEqualStrings("1.2.3", lookup(init_reply, &.{ "result", "serverInfo", "version" }).string);
    try testing.expectEqualStrings(instructions, lookup(init_reply, &.{ "result", "instructions" }).string);

    const list_reply = try std.json.parseFromSliceLeaky(Value, arena, lines.items[1], .{});
    try testing.expectEqualStrings("list", lookup(list_reply, &.{"id"}).string);
    const listed = lookup(list_reply, &.{ "result", "tools" }).array.items;
    try testing.expectEqual(4, listed.len);
    for (listed, tool_names) |tool, name| {
        try testing.expectEqualStrings(name, lookup(tool, &.{"name"}).string);
        try testing.expectEqualStrings("object", lookup(tool, &.{ "inputSchema", "type" }).string);
        try testing.expectEqual(false, lookup(tool, &.{ "inputSchema", "additionalProperties" }).bool);
        try testing.expect(lookup(tool, &.{"description"}).string.len > 0);
    }

    try expectToolResult(arena, lines.items[2], 3, "# search\nok", false);
    try expectToolResult(arena, lines.items[3], 4, "# entity\nok", false);
    try expectToolResult(arena, lines.items[4], 5, "# remember\nok", false);
    try expectToolResult(arena, lines.items[5], 6, "no matching fact", true);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}", lines.items[6]);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", lines.items[7]);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}", lines.items[8]);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32602,\"message\":\"Unknown tool: memory_delete\"}}", lines.items[9]);
    try expectToolError(arena, lines.items[10], 10, "Invalid arguments: unknown argument 'colour'");
    try expectToolError(arena, lines.items[11], 11, "Invalid arguments: need one of");
    try expectToolError(arena, lines.items[12], 12, "Invalid arguments: 'max_tokens' must match");
    try expectToolError(arena, lines.items[13], 13, "Invalid arguments: 'depth' must match");
    try expectToolResult(arena, lines.items[14], 14, "StoreUnavailable", true);
    try expectToolError(arena, lines.items[15], 15, "Invalid arguments: 'text' is required");

    try testing.expectEqualSlices(api.Op, &.{ .search, .entity, .remember, .forget, .search }, fake.ops.items);
    try testing.expectEqualStrings("{\"query\":\"db choice\",\"project\":\"*\",\"max_tokens\":200}", fake.bodies.items[0]);
    try testing.expectEqualStrings("{\"name_or_id\":\"brackwater\",\"depth\":2}", fake.bodies.items[1]);
    try testing.expectEqualStrings("{\"text\":\"We use Postgres.\",\"scope\":\"global\"}", fake.bodies.items[2]);
    try testing.expectEqualStrings("{\"query\":\"old db\",\"reason\":\"moved\"}", fake.bodies.items[3]);
}

test "initialize falls back to the newest protocol version" {
    var fake: FakeHandler = .{};
    defer fake.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reply = (try handleMessage(arena, fake.handler(), "0", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\"}}")).?;
    const v = try std.json.parseFromSliceLeaky(Value, arena, reply, .{});
    try testing.expectEqualStrings("2025-06-18", lookup(v, &.{ "result", "protocolVersion" }).string);
    try testing.expectEqual(null, try handleMessage(arena, fake.handler(), "0", "{\"jsonrpc\":\"2.0\",\"method\":\"unknown/notification\"}"));
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid request: expected a JSON-RPC object\"}}",
        (try handleMessage(arena, fake.handler(), "0", "[1,2]")).?,
    );
}
