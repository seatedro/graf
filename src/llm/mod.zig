const std = @import("std");
const core = @import("core");

pub const Route = core.config.Route;

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

pub const Priority = enum { interactive, background };

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
    system: []const u8,
    user: []const u8,
    schema_name: []const u8,
    schema_json: []const u8,
    priority: Priority = .background,
};

pub const StructuredResponse = struct {
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
    vectors: []const []const f32,
    usage: Usage,
    cost: Cost,
};

pub const Question = union(enum) {
    yes_no: []const u8,
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

    pub fn structured(c: *Client, arena: std.mem.Allocator, req: StructuredRequest) !StructuredResponse {
        _ = c;
        _ = arena;
        _ = req;
        return core.NotImplemented;
    }

    pub fn embed(c: *Client, arena: std.mem.Allocator, req: EmbedRequest) !EmbedResponse {
        _ = c;
        _ = arena;
        _ = req;
        return core.NotImplemented;
    }

    pub fn decide(c: *Client, arena: std.mem.Allocator, purpose: core.types.LlmPurpose, questions: []const Question) ![]const Answer {
        _ = arena;
        _ = purpose;
        _ = questions;
        if (!c.config.decisionEnabled()) return error.DecisionDisabled;
        return core.NotImplemented;
    }
};

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
