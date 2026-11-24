//! LLM and embeddings client workstream (spec 5). Vendor-neutral: speaks the public
//! OpenAI Responses, Anthropic Messages, OpenAI Chat Completions, and embeddings wire
//! formats against whatever `base_url` the user configures. No provider, gateway or
//! proxy is named in code; cost headers and model ids come from config.
//!
//! Planned layout (owned by this workstream): transport.zig (std.http.Client pool,
//! deadlines), codecs per wire route, schema_gen.zig (comptime JSON Schema from Zig
//! types), recovery.zig (pure retry state machine), limiter.zig (global limiter,
//! spend cap, priority lanes), decision.zig (typed decision-model backend).

const std = @import("std");
const core = @import("core");

pub const Route = core.config.Route;

/// Provider failure classes and their handling (spec 5.4).
pub const ErrorClass = enum {
    network_not_sent,
    timeout,
    http_5xx,
    overloaded_529,
    rate_limited_429,
    context_overflow,
    auth_401_403,
    quota_exhausted,
    invalid_request_400,
};

/// Whether a failed request may have reached the provider (and been billed).
pub const DeliveryCertainty = enum { not_sent, possibly_sent };

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
};

pub const Cost = struct {
    usd: f64 = 0,
    status: core.types.CostStatus = .missing,
};

/// Interactive calls (query embeddings, `memory_remember(wait=true)`) jump the queue.
pub const Priority = enum { interactive, background };

/// Details of the last failed call, filled when a call returns `error.ProviderFailed`.
pub const Failure = struct {
    class: ErrorClass,
    certainty: DeliveryCertainty,
    http_status: ?u16 = null,
    retry_after_ms: ?u32 = null,
    message: []const u8 = "",
};

pub const StructuredRequest = struct {
    purpose: core.types.LlmPurpose,
    episode_id: ?core.Id = null,
    /// Cached prefix. Must be byte-identical across calls to hit prompt caches.
    system: []const u8,
    user: []const u8,
    schema_name: []const u8,
    /// Strict JSON Schema, normally from `jsonSchema(T)`.
    schema_json: []const u8,
    priority: Priority = .background,
};

pub const StructuredResponse = struct {
    /// The raw JSON object the model returned, already unwrapped from the wire format.
    json: []const u8,
    model: []const u8,
    usage: Usage,
    cost: Cost,
    latency_ms: u32,
};

pub const EmbedRequest = struct {
    purpose: core.types.LlmPurpose,
    episode_id: ?core.Id = null,
    inputs: []const []const u8,
    priority: Priority = .background,
};

pub const EmbedResponse = struct {
    /// One vector per input, in input order, each `embed.dimensions` long.
    vectors: []const []const f32,
    usage: Usage,
    cost: Cost,
};

/// A batched question for the typed decision-model backend (spec 5.2, 6.2).
pub const Question = union(enum) {
    /// Probability that the statement is true.
    yes_no: []const u8,
    /// Probability distribution over the options.
    choice: struct { prompt: []const u8, options: []const []const u8 },
};

pub const Answer = union(enum) {
    yes_no: f64,
    choice: []const f64,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const core.Config,
    ledger: ?core.LlmLedger,
    last_failure: ?Failure = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: *const core.Config, ledger: ?core.LlmLedger) Client {
        return .{ .allocator = allocator, .io = io, .config = config, .ledger = ledger };
    }

    pub fn deinit(c: *Client) void {
        c.* = undefined;
    }

    /// One structured completion on the configured route, with transport retries,
    /// limiter permits and a ledger row per attempt.
    pub fn structured(c: *Client, arena: std.mem.Allocator, req: StructuredRequest) !StructuredResponse {
        _ = c;
        _ = arena;
        _ = req;
        return core.NotImplemented;
    }

    /// One batched embeddings request.
    pub fn embed(c: *Client, arena: std.mem.Allocator, req: EmbedRequest) !EmbedResponse {
        _ = c;
        _ = arena;
        _ = req;
        return core.NotImplemented;
    }

    /// One batched typed-decision request. Fails with `error.DecisionDisabled` when
    /// no decision backend is configured, so callers fall back.
    pub fn decide(c: *Client, arena: std.mem.Allocator, purpose: core.types.LlmPurpose, questions: []const Question) ![]const Answer {
        _ = arena;
        _ = purpose;
        _ = questions;
        if (!c.config.decisionEnabled()) return error.DecisionDisabled;
        return core.NotImplemented;
    }
};

/// Strict JSON Schema for `T` (`additionalProperties: false`, every field required,
/// optionals as `[type, "null"]`), generated at compile time (spec 5.2).
pub fn jsonSchema(comptime T: type) []const u8 {
    @compileError("llm.jsonSchema is not implemented yet; requested for " ++ @typeName(T));
}

test {
    std.testing.refAllDecls(@This());
}

test "decide reports a disabled backend so callers can fall back" {
    const cfg: core.Config = .{};
    var client = Client.init(std.testing.allocator, std.testing.io, &cfg, null);
    defer client.deinit();
    try std.testing.expectError(error.DecisionDisabled, client.decide(std.testing.allocator, .rerank, &.{}));
}
