const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;

pub const Kind = enum { api_key, jwt, pem, assignment, bearer, url_credentials, high_entropy };

pub fn redact(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    _ = arena;
    return text;
}
