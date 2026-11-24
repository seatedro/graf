const std = @import("std");

pub fn jsonSchema(comptime T: type) []const u8 {
    const s = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        break :blk schemaOf(T);
    };
    return s;
}

fn schemaOf(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .optional => |o| nullable(o.child),
        else => nonNull(T),
    };
}

fn nullable(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .optional => @compileError("nested optionals have no JSON encoding: ?" ++ @typeName(T)),
        .bool => "{\"type\":[\"boolean\",\"null\"]}",
        .int, .comptime_int => "{\"type\":[\"integer\",\"null\"]}",
        .float, .comptime_float => "{\"type\":[\"number\",\"null\"]}",
        .@"enum" => "{\"type\":[\"string\",\"null\"],\"enum\":[" ++ enumValues(T) ++ ",null]}",
        .pointer, .array => if (isString(T))
            "{\"type\":[\"string\",\"null\"]}"
        else
            "{\"type\":[\"array\",\"null\"],\"items\":" ++ schemaOf(elemOf(T)) ++ "}",
        .@"struct", .@"union" => "{\"anyOf\":[" ++ schemaOf(T) ++ ",{\"type\":\"null\"}]}",
        else => unsupported(T),
    };
}

fn nonNull(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "{\"type\":\"boolean\"}",
        .int, .comptime_int => "{\"type\":\"integer\"}",
        .float, .comptime_float => "{\"type\":\"number\"}",
        .@"enum" => "{\"type\":\"string\",\"enum\":[" ++ enumValues(T) ++ "]}",
        .pointer, .array => if (isString(T))
            "{\"type\":\"string\"}"
        else
            "{\"type\":\"array\",\"items\":" ++ schemaOf(elemOf(T)) ++ "}",
        .@"struct" => |s| if (s.is_tuple) unsupported(T) else object(T),
        .@"union" => |u| if (u.tag_type == null) unsupported(T) else taggedUnion(T),
        else => unsupported(T),
    };
}

fn object(comptime T: type) []const u8 {
    const info = @typeInfo(T).@"struct";
    var props: []const u8 = "";
    var required: []const u8 = "";

    for (info.field_names, info.field_types, 0..) |name, F, i| {
        const sep = if (i == 0) "" else ",";
        props = props ++ sep ++ quote(name) ++ ":" ++ withDescription(schemaOf(F), fieldDescription(T, name));
        required = required ++ sep ++ quote(name);
    }

    return "{\"type\":\"object\",\"properties\":{" ++ props ++ "},\"required\":[" ++ required ++ "],\"additionalProperties\":false}";
}

fn taggedUnion(comptime T: type) []const u8 {
    const info = @typeInfo(T).@"union";
    var variants: []const u8 = "";

    for (info.field_names, info.field_types, 0..) |name, F, i| {
        if (F == void) @compileError("void union payloads are not supported in schemas: " ++ @typeName(T) ++ "." ++ name);
        variants = variants ++ (if (i == 0) "" else ",") ++
            "{\"type\":\"object\",\"properties\":{" ++ quote(name) ++ ":" ++ schemaOf(F) ++
            "},\"required\":[" ++ quote(name) ++ "],\"additionalProperties\":false}";
    }

    return "{\"anyOf\":[" ++ variants ++ "]}";
}

fn fieldDescription(comptime T: type, comptime name: []const u8) []const u8 {
    if (!@hasDecl(T, "schema_descriptions")) return "";
    const D = @TypeOf(T.schema_descriptions);
    if (!@hasField(D, name)) return "";
    return @field(T.schema_descriptions, name);
}

fn withDescription(comptime schema: []const u8, comptime description: []const u8) []const u8 {
    if (description.len == 0) return schema;
    return "{\"description\":" ++ quote(description) ++ "," ++ schema[1..];
}

fn enumValues(comptime T: type) []const u8 {
    var out: []const u8 = "";
    for (@typeInfo(T).@"enum".field_names, 0..) |name, i| out = out ++ (if (i == 0) "" else ",") ++ quote(name);
    return out;
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        .array => |a| a.child == u8,
        else => false,
    };
}

fn elemOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) p.child else unsupported(T),
        .array => |a| a.child,
        else => unsupported(T),
    };
}

fn quote(comptime s: []const u8) []const u8 {
    var out: []const u8 = "\"";
    for (s) |c| out = out ++ switch (c) {
        '"' => "\\\"",
        '\\' => "\\\\",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        else => if (c < 0x20) @compileError("control character in schema string") else &[_]u8{c},
    };
    return out ++ "\"";
}

fn unsupported(comptime T: type) noreturn {
    @compileError("llm.jsonSchema: no strict JSON Schema for " ++ @typeName(T));
}

const TestExtract = struct {
    entities: []const struct {
        ref: []const u8,
        name: []const u8,
        type: enum { person, organization, project, repository, code, software, ai_model, dataset, document, decision, task, change, session, environment, run, problem, concept, event, other },
        aliases: []const []const u8,
        existing: ?[]const u8,
    },
    facts: []const struct {
        subject: []const u8,
        relation: []const u8,
        object: ?[]const u8,
        value: ?[]const u8,
        qualifier: ?[]const u8,
        text: []const u8,
        quote: []const u8,
        rationale: []const u8,
        valid_from: ?[]const u8,
        valid_to: ?[]const u8,
        confidence: f64,
        retracts: bool,
    },
    skip: bool,

    pub const schema_descriptions = .{ .skip = "True when the entry holds no durable facts." };
};

test "strict schema for an extraction-shaped struct" {
    const schema = jsonSchema(TestExtract);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("object", root.get("type").?.string);
    try std.testing.expectEqual(false, root.get("additionalProperties").?.bool);
    try std.testing.expectEqual(@as(usize, 3), root.get("required").?.array.items.len);

    const skip = root.get("properties").?.object.get("skip").?.object;
    try std.testing.expectEqualStrings("True when the entry holds no durable facts.", skip.get("description").?.string);

    const entity = root.get("properties").?.object.get("entities").?.object.get("items").?.object;
    try std.testing.expectEqual(false, entity.get("additionalProperties").?.bool);
    try std.testing.expectEqual(@as(usize, 5), entity.get("required").?.array.items.len);
    const existing = entity.get("properties").?.object.get("existing").?.object.get("type").?.array.items;
    try std.testing.expectEqualStrings("string", existing[0].string);
    try std.testing.expectEqualStrings("null", existing[1].string);
    const kinds = entity.get("properties").?.object.get("type").?.object.get("enum").?.array.items;
    try std.testing.expectEqual(@as(usize, 19), kinds.len);

    const fact = root.get("properties").?.object.get("facts").?.object.get("items").?.object;
    try std.testing.expectEqual(@as(usize, 12), fact.get("required").?.array.items.len);
    try std.testing.expectEqualStrings("number", fact.get("properties").?.object.get("confidence").?.object.get("type").?.string);
}

test "the schema's type decodes a conforming reply and rejects drift" {
    const reply =
        \\{"entities":[{"ref":"e1","name":"pg.zig","type":"software","aliases":["pg-zig"],"existing":null}],
        \\ "facts":[{"subject":"e1","relation":"supports_feature","object":null,"value":"COPY","qualifier":null,
        \\   "text":"pg.zig supports COPY","quote":"it has COPY now","rationale":"stated","valid_from":"2026-11-20T00:00:00Z",
        \\   "valid_to":null,"confidence":0.9,"retracts":false}],"skip":false}
    ;

    const ok = try std.json.parseFromSlice(TestExtract, std.testing.allocator, reply, .{ .duplicate_field_behavior = .@"error" });
    defer ok.deinit();

    try std.testing.expectEqualStrings("pg.zig", ok.value.entities[0].name);
    try std.testing.expect(ok.value.facts[0].object == null);

    const extra = "{\"entities\":[],\"facts\":[],\"skip\":true,\"note\":1}";
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(TestExtract, std.testing.allocator, extra, .{}));
    const dup = "{\"entities\":[],\"facts\":[],\"skip\":true,\"skip\":false}";
    try std.testing.expectError(error.DuplicateField, std.json.parseFromSlice(TestExtract, std.testing.allocator, dup, .{ .duplicate_field_behavior = .@"error" }));
}

test "nullable objects, arrays, tagged unions and escaping" {
    const Inner = struct { n: i32 };
    const T = struct {
        maybe_obj: ?Inner,
        maybe_list: ?[]const u32,
        pick: union(enum) { id: []const u8, score: f32 },
        @"quoted\"name": bool,
    };

    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{" ++
            "\"maybe_obj\":{\"anyOf\":[{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\"}},\"required\":[\"n\"],\"additionalProperties\":false},{\"type\":\"null\"}]}," ++
            "\"maybe_list\":{\"type\":[\"array\",\"null\"],\"items\":{\"type\":\"integer\"}}," ++
            "\"pick\":{\"anyOf\":[{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"],\"additionalProperties\":false}," ++
            "{\"type\":\"object\",\"properties\":{\"score\":{\"type\":\"number\"}},\"required\":[\"score\"],\"additionalProperties\":false}]}," ++
            "\"quoted\\\"name\":{\"type\":\"boolean\"}" ++
            "},\"required\":[\"maybe_obj\",\"maybe_list\",\"pick\",\"quoted\\\"name\"],\"additionalProperties\":false}",
        jsonSchema(T),
    );

    const v = try std.json.parseFromSlice(T, std.testing.allocator, "{\"maybe_obj\":null,\"maybe_list\":[1,2],\"pick\":{\"score\":0.5},\"quoted\\\"name\":true}", .{});
    defer v.deinit();
    try std.testing.expectEqual(@as(f32, 0.5), v.value.pick.score);
}
