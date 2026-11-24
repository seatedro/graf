const std = @import("std");
const llm = @import("llm");
const ingest = @import("mod.zig");

pub const strict = llm.jsonSchema;

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
