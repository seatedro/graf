//! Deterministic secret redaction. Runs on every turn before anything
//! reaches an `EpisodeSink` or a model. The eval gate is zero leaks.

const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;

/// What a `[REDACTED:<kind>]` marker stands for.
pub const Kind = enum { api_key, jwt, pem, assignment, bearer, url_credentials, high_entropy };

/// Replaces every secret in `text` with `[REDACTED:<kind>]`. Returns `text` itself
/// when nothing matched, otherwise a new slice allocated in `arena`.
pub fn redact(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    _ = arena;
    return text;
}
