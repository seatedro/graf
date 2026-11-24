const std = @import("std");
const ingest = @import("mod.zig");

pub fn strict(comptime T: type) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        break :blk render(T, false);
    };
}

fn typeName(comptime name: []const u8, comptime nullable: bool) []const u8 {
    return if (nullable) "{\"type\":[\"" ++ name ++ "\",\"null\"]" else "{\"type\":\"" ++ name ++ "\"";
}

fn render(comptime T: type, comptime nullable: bool) []const u8 {
    switch (@typeInfo(T)) {
        .optional => |o| return render(o.child, true),
        .bool => return typeName("boolean", nullable) ++ "}",
        .int => return typeName("integer", nullable) ++ "}",
        .float => return typeName("number", nullable) ++ "}",
        .@"enum" => |e| {
            var values: []const u8 = "";
            for (e.field_names, 0..) |n, i| values = values ++ (if (i > 0) "," else "") ++ "\"" ++ n ++ "\"";
            if (nullable) values = values ++ ",null";
            return typeName("string", nullable) ++ ",\"enum\":[" ++ values ++ "]}";
        },
        .pointer => |p| {
            if (p.child == u8) return typeName("string", nullable) ++ "}";
            return typeName("array", nullable) ++ ",\"items\":" ++ render(p.child, false) ++ "}";
        },
        .@"struct" => |s| {
            var props: []const u8 = "";
            var required: []const u8 = "";
            for (s.field_names, s.field_types, 0..) |n, F, i| {
                const sep = if (i > 0) "," else "";
                props = props ++ sep ++ "\"" ++ n ++ "\":" ++ render(F, false);
                required = required ++ sep ++ "\"" ++ n ++ "\"";
            }
            return typeName("object", nullable) ++ ",\"properties\":{" ++ props ++ "},\"required\":[" ++ required ++ "],\"additionalProperties\":false}";
        },
        else => @compileError("no JSON Schema mapping for " ++ @typeName(T)),
    }
}

pub const extract_result = strict(ingest.ExtractResult);
pub const resolve_result = strict(ingest.ResolveResult);

test "schemas are valid JSON, strict, and nullable where optional" {
    const gpa = std.testing.allocator;
    inline for (.{ extract_result, resolve_result }) |s| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, s, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("additionalProperties").?.bool == false);
    }
    try std.testing.expect(std.mem.indexOf(u8, extract_result, "\"skip\":{\"type\":[\"string\",\"null\"]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, extract_result, "\"time_basis\":{\"type\":\"string\",\"enum\":[\"explicit\",\"relative\",\"reference\"]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolve_result, "\"fact_index\":{\"type\":\"integer\"}") != null);
}
