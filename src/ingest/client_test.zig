const std = @import("std");
const core = @import("core");
const llm = @import("llm");
const store = @import("store");
const ingest = @import("mod.zig");
const pipeline = @import("pipeline.zig");
const postgres = @import("postgres.zig");
const fakes = @import("testing.zig");

const testing = std.testing;
const Replay = llm.transport.Replay;
const Driver = pipeline.Driver(fakes.MemoryBackend, postgres.ClientModel);
const PgDriver = pipeline.Driver(postgres.PgBackend, postgres.ClientModel);
const at = fakes.at;
const turns = fakes.turns;

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

fn embeddingsOk(comptime n: usize, comptime width: usize) Replay.Step {
    comptime {
        var data: []const u8 = "";
        for (0..n) |i| {
            var vec: []const u8 = "";
            for (0..width) |k| vec = vec ++ (if (k > 0) "," else "") ++ (if (k == i % width) "1.0" else "0.0");
            data = data ++ (if (i > 0) "," else "") ++ std.fmt.comptimePrint("{{\"object\":\"embedding\",\"embedding\":[{s}],\"index\":{d}}}", .{ vec, i });
        }

        return .{ .capture = "HTTP/1.1 200 OK\ncontent-type: application/json\n\n" ++
            "{\"object\":\"list\",\"data\":[" ++ data ++ "],\"model\":\"example-embedding-model\",\"usage\":{\"prompt_tokens\":10,\"total_tokens\":10}}" };
    }
}

const context_overflow: Replay.Step = .{ .capture = "HTTP/1.1 400 Bad Request\ncontent-type: application/json\n\n" ++
    "{\"error\":{\"message\":\"Your input exceeds the context window of this model.\",\"type\":\"invalid_request_error\",\"param\":\"input\",\"code\":\"context_length_exceeded\"}}" };

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

test "an entry runs through the real client into the committed graph" {
    var h: Harness = undefined;
    try h.init(&.{ comptime responsesOk(fakes.relay_hollis), comptime embeddingsOk(4, dims) });
    defer h.deinit();

    const entry = try h.backend.add("session-a", at("2026-11-19T22:00:00Z"), "brackwater/monorepo", turns("Relay lives under infra/relay. Hollis is currently on call for Relay."));

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

    const entry = try h.backend.add("session-a", at("2026-11-19T22:00:00Z"), null, &.{
        .{ .role = .user, .text = "first half of a very long session" },
        .{ .role = .assistant, .text = "second half of a very long session" },
    });

    try testing.expectEqual(ingest.Outcome.split, try h.step());
    try testing.expectEqual(core.types.EntryStatus.split, h.backend.row(entry).status);
    try testing.expectEqual(@as(usize, 1), h.replay.sent.items.len);
}

test "an entry commits through the store into Postgres" {
    var s = try store.testing.open();
    defer s.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var h: Harness = undefined;
    try h.init(&.{ comptime responsesOk(fakes.relay_hollis), comptime embeddingsOk(4, store.embedding_dims) });
    defer h.deinit();
    h.cfg.embed.dimensions = store.embedding_dims;

    const graph = try store.testing.freshGraph(&s);
    const draft: core.EntryDraft = .{
        .source = .{ .harness = .cli, .external_id = "session-a", .project = "brackwater/monorepo" },
        .kind = .turns,
        .project = "brackwater/monorepo",
        .author = .user,
        .body = .{ .turns = turns("Relay lives under infra/relay. Hollis is currently on call for Relay.") },
        .reference_time = at("2026-11-19T22:00:00Z"),
    };

    const entry = switch (try s.enqueue(graph, &draft)) {
        .queued => |id| id,
        .duplicate => return error.UnexpectedDuplicate,
    };

    var backend: postgres.PgBackend = .{ .store = &s, .graph_id = graph, .io = testing.io };
    const lease = (try backend.claim(arena)) orelse return error.NothingQueued;
    try testing.expect(lease.entry_id.eql(entry));

    var d: PgDriver = .{ .backend = &backend, .model = &h.model, .config = &h.cfg, .graph_id = graph, .io = testing.io };
    try testing.expectEqual(ingest.Outcome.committed, try d.process(arena, lease));
    try testing.expectEqual(@as(usize, 0), h.replay.remaining());

    const conn = try s.pool.acquire();
    defer conn.release();
    var gbuf: [36]u8 = undefined;
    var ebuf: [36]u8 = undefined;
    const g = graph.toString(&gbuf);
    const Counts = struct { status: []const u8, entities: i64, facts: i64, evidence: i64, commits: i64, relay_since_summary: i64 };

    const got = try postgres.jsonRow(Counts, arena, conn,
        \\SELECT json_build_object(
        \\  'status', (SELECT status FROM entry WHERE id = $2::uuid),
        \\  'entities', (SELECT count(*) FROM entity WHERE graph_id = $1::uuid AND merged_into IS NULL),
        \\  'facts', (SELECT count(*) FROM fact WHERE graph_id = $1::uuid AND upper_inf(known) AND upper_inf(valid)),
        \\  'evidence', (SELECT count(*) FROM fact_evidence WHERE entry_id = $2::uuid AND kind = 'stated'),
        \\  'commits', (SELECT count(*) FROM commit_log WHERE graph_id = $1::uuid AND entry_id = $2::uuid),
        \\  'relay_since_summary', (SELECT facts_since_summary FROM entity WHERE graph_id = $1::uuid AND norm = 'relay')
        \\)::text
    , .{ g, entry.toString(&ebuf) });

    try testing.expectEqualStrings("committed", got.status);
    try testing.expectEqual(@as(i64, 2), got.entities);
    try testing.expectEqual(@as(i64, 2), got.facts);
    try testing.expectEqual(@as(i64, 2), got.evidence);
    try testing.expectEqual(@as(i64, 1), got.commits);
    try testing.expectEqual(@as(i64, 2), got.relay_since_summary);
}
