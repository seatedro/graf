const std = @import("std");
const core = @import("core");
const llm = @import("llm");
const ingest = @import("mod.zig");
const pipeline = @import("pipeline.zig");
const postgres = @import("postgres.zig");
const fakes = @import("testing.zig");
const time = @import("time.zig");

const testing = std.testing;
const Replay = llm.transport.Replay;
const Driver = pipeline.Driver(fakes.MemoryBackend, postgres.ClientModel);

const dims = 8;

fn jsonString(comptime s: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "\"";
        for (s) |c| out = out ++ switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            else => &[_]u8{c},
        };
        return out ++ "\"";
    }
}

fn responsesOk(comptime json: []const u8) Replay.Step {
    return .{ .capture = "HTTP/1.1 200 OK\ncontent-type: application/json\n\n" ++
        "{\"id\":\"resp_1\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"example-model\"," ++
        "\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":" ++ jsonString(json) ++ "}]}]," ++
        "\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}" };
}

fn embeddingsOk(comptime n: usize) Replay.Step {
    comptime {
        var data: []const u8 = "";
        for (0..n) |i| {
            var vec: []const u8 = "";
            for (0..dims) |k| vec = vec ++ (if (k > 0) "," else "") ++ (if (k == i % dims) "1.0" else "0.0");
            data = data ++ (if (i > 0) "," else "") ++ std.fmt.comptimePrint("{{\"object\":\"embedding\",\"embedding\":[{s}],\"index\":{d}}}", .{ vec, i });
        }
        return .{ .capture = "HTTP/1.1 200 OK\ncontent-type: application/json\n\n" ++
            "{\"object\":\"list\",\"data\":[" ++ data ++ "],\"model\":\"example-embedding-model\",\"usage\":{\"prompt_tokens\":10,\"total_tokens\":10}}" };
    }
}

const context_overflow: Replay.Step = .{ .capture = "HTTP/1.1 400 Bad Request\ncontent-type: application/json\n\n" ++
    "{\"error\":{\"message\":\"Your input exceeds the context window of this model.\",\"type\":\"invalid_request_error\",\"param\":\"input\",\"code\":\"context_length_exceeded\"}}" };

const relay_marco =
    \\{"skip":null,"entities":[{"ref":"n1","name":"Relay","type":"software","aliases":[],"description":"Request gateway."},{"ref":"n2","name":"Marco","type":"person","aliases":[],"description":"Engineer."}],
    \\"facts":[{"subject":"n1","relation":"has_oncall","qualifier":null,"object":"n2","value":null,"text":"Marco is on call for Relay.","rationale":null,"valid_from":null,"valid_to":null,"time_basis":"reference","scope":"project","author":"agent","quote":"Marco is currently on call for Relay."},
    \\{"subject":"n1","relation":"located_at","qualifier":null,"object":null,"value":"infra/relay","text":"Relay lives under infra/relay.","rationale":null,"valid_from":null,"valid_to":null,"time_basis":"reference","scope":"project","author":"agent","quote":"Relay lives under infra/relay"}],"new_relations":[]}
;

const Harness = struct {
    cfg: core.Config,
    replay: Replay,
    client: llm.Client,
    model: postgres.ClientModel,
    backend: fakes.MemoryBackend,

    fn init(h: *Harness, steps: []const Replay.Step) !void {
        h.cfg = .{
            .llm = .{ .base_url = "https://llm.example.test/v1", .api_key = "test-key", .route = .@"openai-responses", .model = "example-model" },
            .embed = .{ .base_url = "https://llm.example.test/v1", .api_key = "test-key", .model = "example-embedding-model", .dimensions = dims },
        };
        h.replay = .init(testing.allocator, steps);
        h.client = .init(testing.allocator, testing.io, &h.cfg, null);
        h.client.transport = h.replay.transport();
        h.client.policy = .{ .transient_backoff_ms = &.{ 1, 1, 1 }, .rate_limit_backoff_ms = &.{ 1, 1, 1, 1 } };
        h.model = .{ .client = &h.client };
        h.backend = try .init(testing.allocator, testing.io);
    }

    fn deinit(h: *Harness) void {
        h.backend.deinit();
        h.client.deinit();
        h.replay.deinit();
    }

    fn step(h: *Harness) !ingest.Outcome {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const lease = h.backend.claim() orelse return error.NothingQueued;
        var d: Driver = .{ .backend = &h.backend, .model = &h.model, .config = &h.cfg, .graph_id = fakes.MemoryBackend.graph, .io = testing.io };
        return d.process(arena_state.allocator(), lease);
    }
};

fn turns(comptime text: []const u8) []const core.Turn {
    return &.{.{ .role = .user, .text = text }};
}

test "an entry runs through the real client into the committed graph" {
    var h: Harness = undefined;
    try h.init(&.{ comptime responsesOk(relay_marco), comptime embeddingsOk(4) });
    defer h.deinit();

    const entry = try h.backend.add("session-a", try time.parse("2026-11-19T22:00:00Z"), "acme/monorepo", turns("Relay lives under infra/relay. Marco is currently on call for Relay."));
    try testing.expectEqual(ingest.Outcome.committed, try h.step());
    try testing.expectEqual(core.types.EntryStatus.committed, h.backend.row(entry).status);
    try testing.expectEqual(@as(usize, 2), h.backend.entities.items.len);
    try testing.expectEqual(@as(usize, 2), h.backend.facts.items.len);
    try testing.expectEqual(@as(usize, 0), h.replay.remaining());
    try testing.expect(std.mem.endsWith(u8, h.replay.sent.items[0].url, "/responses"));
    try testing.expect(std.mem.endsWith(u8, h.replay.sent.items[1].url, "/embeddings"));
}

test "a context overflow from the provider splits the entry" {
    var h: Harness = undefined;
    try h.init(&.{context_overflow});
    defer h.deinit();

    const entry = try h.backend.add("session-a", try time.parse("2026-11-19T22:00:00Z"), null, &.{
        .{ .role = .user, .text = "first half of a very long session" },
        .{ .role = .assistant, .text = "second half of a very long session" },
    });
    try testing.expectEqual(ingest.Outcome.split, try h.step());
    try testing.expectEqual(core.types.EntryStatus.split, h.backend.row(entry).status);
    try testing.expectEqual(@as(usize, 1), h.replay.sent.items.len);
}
