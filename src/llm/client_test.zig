const std = @import("std");
const core = @import("core");
const llm = @import("mod.zig");
const transport = llm.transport;
const Replay = transport.Replay;
const testing = std.testing;

fn fixture(comptime name: []const u8) Replay.Step {
    return .{ .capture = @embedFile("fixtures/" ++ name ++ ".http") };
}

const Ledger = struct {
    rows: std.ArrayList(core.LlmCall) = .empty,
    spent: f64 = 0,

    fn ledger(l: *Ledger) core.LlmLedger {
        return .{ .ptr = l, .vtable = &.{ .record = record, .spentSince = spentSince } };
    }

    fn record(ptr: *anyopaque, call: *const core.LlmCall) anyerror!void {
        const l: *Ledger = @ptrCast(@alignCast(ptr));
        try l.rows.append(testing.allocator, call.*);
    }

    fn spentSince(ptr: *anyopaque, _: core.Micros) anyerror!f64 {
        const l: *Ledger = @ptrCast(@alignCast(ptr));
        return l.spent;
    }

    fn deinit(l: *Ledger) void {
        l.rows.deinit(testing.allocator);
    }
};

const Harness = struct {
    cfg: core.Config,
    ledger: Ledger = .{},
    replay: Replay,
    client: llm.Client,
    arena: std.heap.ArenaAllocator,

    fn init(h: *Harness, route: core.config.Route, steps: []const Replay.Step) void {
        h.cfg = .{
            .llm = .{
                .base_url = "https://llm.example.test/v1/",
                .api_key = "test-key",
                .route = route,
                .model = "example-model",
                .cost_header = "x-example-cost-usd",
            },
            .embed = .{
                .base_url = "https://llm.example.test/v1",
                .api_key = "test-key",
                .model = "example-embedding-model",
                .cost_header = "x-example-cost-usd",
            },
        };
        h.ledger = .{};
        h.replay = .init(testing.allocator, steps);
        h.arena = .init(testing.allocator);
        h.client = .init(testing.allocator, testing.io, &h.cfg, h.ledger.ledger());
        h.client.transport = h.replay.transport();
        h.client.policy = .{ .transient_backoff_ms = &.{ 1, 1, 1 }, .rate_limit_backoff_ms = &.{ 1, 1, 1, 1 } };
    }

    fn deinit(h: *Harness) void {
        h.client.deinit();
        h.replay.deinit();
        h.ledger.deinit();
        h.arena.deinit();
    }

    fn a(h: *Harness) std.mem.Allocator {
        return h.arena.allocator();
    }

    fn sentJson(h: *Harness, i: usize) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, h.a(), h.replay.sent.items[i].body, .{});
    }

    fn sentHeader(h: *Harness, i: usize, name: []const u8) ?[]const u8 {
        for (h.replay.sent.items[i].headers) |hdr| if (std.ascii.eqlIgnoreCase(hdr.name, name)) return hdr.value;
        return null;
    }
};

const Entities = struct {
    entities: []const struct {
        name: []const u8,
        type: enum { person, project, software, other },
    },
};

const schema = llm.jsonSchema(Entities);

fn request(failure: ?*llm.Failure) llm.StructuredRequest {
    return .{
        .purpose = .extract,
        .system = "Extract the named entities from the note. Reply with JSON only.",
        .user = "Note: Dana moved the brackwater-indexer project from the zork-db library to the pgvector extension.",
        .schema_name = "entities",
        .schema_json = schema,
        .failure = failure,
    };
}

fn get(v: std.json.Value, path: []const []const u8) std.json.Value {
    var cur = v;
    for (path) |p| cur = cur.object.get(p).?;
    return cur;
}

test "openai-responses: strict json_schema request, typed decode, header cost, one ledger row" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{fixture("responses_ok")});
    defer h.deinit();
    const out = try h.client.structuredAs(Entities, h.a(), request(null));
    try testing.expectEqual(@as(usize, 4), out.value.entities.len);
    try testing.expectEqualStrings("brackwater-indexer", out.value.entities[1].name);
    try testing.expectEqual(core.types.CostStatus.priced, out.response.cost.status);
    try testing.expectEqual(@as(f64, 0.0001116), out.response.cost.usd);
    try testing.expectEqual(@as(u32, 103), out.response.usage.input_tokens);
    try testing.expectEqual(@as(u32, 44), out.response.usage.output_tokens);

    try testing.expectEqualStrings("https://llm.example.test/v1/responses", h.replay.sent.items[0].url);
    try testing.expectEqualStrings("Bearer test-key", h.sentHeader(0, "authorization").?);
    const body = try h.sentJson(0);
    try testing.expectEqualStrings("json_schema", get(body, &.{ "text", "format", "type" }).string);
    try testing.expect(get(body, &.{ "text", "format", "strict" }).bool);
    try testing.expectEqual(false, get(body, &.{ "text", "format", "schema", "additionalProperties" }).bool);
    try testing.expectEqualStrings(request(null).system, get(body, &.{"instructions"}).string);

    try testing.expectEqual(@as(usize, 1), h.ledger.rows.items.len);
    const row = h.ledger.rows.items[0];
    try testing.expect(row.ok);
    try testing.expectEqual(core.types.LlmPurpose.extract, row.purpose);
    try testing.expectEqualStrings("openai-responses", row.route);
    try testing.expectEqual(@as(?i32, 200), row.http_status);
    try testing.expectEqual(@as(i32, 1), row.attempt);
    try testing.expectEqual(@as(f64, 0.0001116), row.cost_usd);
}

test "anthropic-messages: native output_config format and a cached system block, no forced tool" {
    var h: Harness = undefined;
    h.init(.@"anthropic-messages", &.{fixture("messages_ok")});
    defer h.deinit();
    const out = try h.client.structuredAs(Entities, h.a(), request(null));
    try testing.expectEqual(@as(usize, 4), out.value.entities.len);
    try testing.expectEqual(@as(u32, 376), out.response.usage.input_tokens);
    try testing.expectEqual(@as(f64, 0.0000751), out.response.cost.usd);

    try testing.expectEqualStrings("https://llm.example.test/v1/messages", h.replay.sent.items[0].url);
    try testing.expectEqualStrings("test-key", h.sentHeader(0, "x-api-key").?);
    try testing.expect(h.sentHeader(0, "anthropic-version") != null);
    try testing.expect(h.sentHeader(0, "authorization") == null);
    const body = try h.sentJson(0);
    try testing.expectEqualStrings("json_schema", get(body, &.{ "output_config", "format", "type" }).string);
    const system = get(body, &.{"system"}).array.items[0];
    try testing.expectEqualStrings("ephemeral", get(system, &.{ "cache_control", "type" }).string);
    try testing.expect(body.object.get("tool_choice") == null);
    try testing.expect(body.object.get("tools") == null);
}

test "openai-chat: fenced JSON is unwrapped" {
    var h: Harness = undefined;
    h.init(.@"openai-chat", &.{fixture("chat_fenced")});
    defer h.deinit();
    const out = try h.client.structuredAs(Entities, h.a(), request(null));
    try testing.expectEqualStrings("Dana", out.value.entities[0].name);
    try testing.expectEqualStrings("https://llm.example.test/v1/chat/completions", h.replay.sent.items[0].url);
    const body = try h.sentJson(0);
    try testing.expectEqualStrings("json_schema", get(body, &.{ "response_format", "type" }).string);
    try testing.expectEqualStrings("system", get(body, &.{"messages"}).array.items[0].object.get("role").?.string);
}

test "429 with Retry-After waits, cools the route down, then succeeds" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{ fixture("responses_429"), fixture("responses_ok") });
    defer h.deinit();
    const start = llm.limiter.nowMs(testing.io);
    _ = try h.client.structured(h.a(), request(null));
    try testing.expect(llm.limiter.nowMs(testing.io) - start >= 1000);
    try testing.expectEqual(@as(usize, 2), h.ledger.rows.items.len);
    try testing.expectEqualStrings("rate_limited_429", h.ledger.rows.items[0].error_class.?);
    try testing.expectEqual(@as(?i32, 429), h.ledger.rows.items[0].http_status);
    try testing.expectEqual(@as(i32, 2), h.ledger.rows.items[1].attempt);
    try testing.expect(h.client.limiter.routes.get(.@"openai-responses").cooldown_until_ms >= start + 1000);
}

test "anthropic 429 and 529 retry, the 529 cooling the route" {
    var h: Harness = undefined;
    h.init(.@"anthropic-messages", &.{ fixture("messages_529"), fixture("messages_ok") });
    defer h.deinit();
    _ = try h.client.structured(h.a(), request(null));
    try testing.expectEqualStrings("overloaded_529", h.ledger.rows.items[0].error_class.?);
    try testing.expect(h.client.limiter.routes.get(.@"anthropic-messages").cooldown_until_ms > 0);
}

test "5xx retries unchanged, then succeeds" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{ fixture("responses_500"), fixture("responses_500"), fixture("responses_ok") });
    defer h.deinit();
    _ = try h.client.structured(h.a(), request(null));
    try testing.expectEqual(@as(usize, 3), h.replay.sent.items.len);
    try testing.expectEqualStrings(h.replay.sent.items[0].body, h.replay.sent.items[2].body);
    try testing.expectEqualStrings("http_5xx", h.ledger.rows.items[1].error_class.?);
}

test "transient failures give up with requeue after three retries" {
    var h: Harness = undefined;
    h.init(.@"openai-chat", &.{ fixture("chat_502"), fixture("chat_502"), fixture("chat_502"), fixture("chat_502"), fixture("chat_ok") });
    defer h.deinit();
    var failure: llm.Failure = undefined;
    try testing.expectError(error.ProviderFailed, h.client.structured(h.a(), request(&failure)));
    try testing.expectEqual(llm.ErrorClass.http_5xx, failure.class);
    try testing.expectEqual(llm.Disposition.requeue, failure.disposition);
    try testing.expectEqual(@as(?u16, 502), failure.http_status);
    try testing.expectEqual(@as(usize, 4), h.replay.sent.items.len);
    try testing.expectEqual(@as(usize, 4), h.ledger.rows.items.len);
}

test "a connection that never opened is not_sent and retried" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{ .{ .failure = .{ .err = error.ConnectionRefused, .sent = false } }, fixture("responses_ok") });
    defer h.deinit();
    _ = try h.client.structured(h.a(), request(null));
    try testing.expectEqualStrings("network_not_sent", h.ledger.rows.items[0].error_class.?);
    try testing.expectEqual(@as(?i32, null), h.ledger.rows.items[0].http_status);
}

test "a timeout after sending is possibly_sent" {
    var h: Harness = undefined;
    const t: Replay.Step = .{ .failure = .{ .err = error.Canceled, .sent = true, .timed_out = true } };
    h.init(.@"openai-responses", &.{ t, t, t, t });
    defer h.deinit();
    var failure: llm.Failure = undefined;
    try testing.expectError(error.ProviderFailed, h.client.structured(h.a(), request(&failure)));
    try testing.expectEqual(llm.ErrorClass.timeout, failure.class);
    try testing.expectEqual(llm.DeliveryCertainty.possibly_sent, failure.certainty);
}

test "context overflow is never retried: split" {
    inline for (.{ .{ core.config.Route.@"openai-responses", "responses_context_overflow" }, .{ core.config.Route.@"anthropic-messages", "messages_context_overflow" } }) |case| {
        var h: Harness = undefined;
        h.init(case[0], &.{ fixture(case[1]), fixture("responses_ok") });
        defer h.deinit();
        var failure: llm.Failure = undefined;
        try testing.expectError(error.ProviderFailed, h.client.structured(h.a(), request(&failure)));
        try testing.expectEqual(llm.ErrorClass.context_overflow, failure.class);
        try testing.expectEqual(llm.Disposition.split, failure.disposition);
        try testing.expectEqual(@as(usize, 1), h.replay.sent.items.len);
    }
}

test "output cut off at the token limit splits the entry" {
    var h: Harness = undefined;
    h.init(.@"anthropic-messages", &.{fixture("messages_truncated")});
    defer h.deinit();
    var failure: llm.Failure = undefined;
    try testing.expectError(error.ProviderFailed, h.client.structured(h.a(), request(&failure)));
    try testing.expectEqual(llm.Disposition.split, failure.disposition);
    try testing.expectEqual(@as(i32, 560008), h.ledger.rows.items[0].input_tokens);
    try testing.expect(h.ledger.rows.items[0].cost_usd > 0);
}

test "401 halts the route until resumed, without retrying" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{ fixture("responses_401"), fixture("responses_ok") });
    defer h.deinit();
    var failure: llm.Failure = undefined;
    try testing.expectError(error.ProviderFailed, h.client.structured(h.a(), request(&failure)));
    try testing.expectEqual(llm.ErrorClass.auth_401_403, failure.class);
    try testing.expectEqual(llm.Disposition.pause_route, failure.disposition);
    try testing.expectEqualStrings("Authentication failed: invalid API key", failure.message);
    try testing.expectError(error.RouteHalted, h.client.structured(h.a(), request(null)));
    try testing.expectEqual(@as(usize, 1), h.replay.sent.items.len);
    h.client.resumeRoutes();
    _ = try h.client.structured(h.a(), request(null));
    try testing.expectEqual(@as(usize, 2), h.replay.sent.items.len);
}

test "anthropic 401 and a used-up quota both pause the route" {
    var h: Harness = undefined;
    h.init(.@"anthropic-messages", &.{fixture("messages_401")});
    defer h.deinit();
    try testing.expectError(error.ProviderFailed, h.client.structured(h.a(), request(null)));
    try testing.expectEqual(llm.Disposition.pause_route, h.client.last_failure.?.disposition);

    var q: Harness = undefined;
    q.init(.@"openai-responses", &.{fixture("responses_429_quota")});
    defer q.deinit();
    try testing.expectError(error.ProviderFailed, q.client.structured(q.a(), request(null)));
    try testing.expectEqual(llm.ErrorClass.quota_exhausted, q.client.last_failure.?.class);
    try testing.expectEqual(@as(?llm.limiter.HaltReason, .quota), q.client.limiter.haltedReason(testing.io, .@"openai-responses"));
}

test "400 is dead with the provider's diagnostic" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{fixture("responses_400_model")});
    defer h.deinit();
    var failure: llm.Failure = undefined;
    try testing.expectError(error.ProviderFailed, h.client.structured(h.a(), request(&failure)));
    try testing.expectEqual(llm.Disposition.dead, failure.disposition);
    try testing.expectEqualStrings("Invalid request: unknown model: no-such-model", failure.message);
}

test "malformed JSON gets one fresh repair request that leaves the original untouched" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{ fixture("responses_bad_json"), fixture("responses_ok") });
    defer h.deinit();
    const req = request(null);
    const out = try h.client.structured(h.a(), req);
    try testing.expect(out.repaired);
    try testing.expectEqual(@as(usize, 2), h.replay.sent.items.len);

    const first = try h.sentJson(0);
    const second = try h.sentJson(1);
    try testing.expectEqualStrings(req.user, get(first, &.{"input"}).array.items[0].object.get("content").?.string);
    try testing.expectEqualStrings(req.system, get(second, &.{"instructions"}).string);
    const repair_text = get(second, &.{"input"}).array.items[0].object.get("content").?.string;
    try testing.expect(std.mem.indexOf(u8, repair_text, "{\"entities\":[{\"name\":\"Dana\"") != null);
    try testing.expect(std.mem.indexOf(u8, repair_text, "not valid JSON") != null);
    try testing.expect(std.mem.indexOf(u8, repair_text, req.user) == null);
    try testing.expect(get(second, &.{ "text", "format", "strict" }).bool);

    try testing.expectEqual(core.types.LlmPurpose.extract, h.ledger.rows.items[0].purpose);
    try testing.expectEqualStrings("invalid_output", h.ledger.rows.items[0].error_class.?);
    try testing.expectEqual(core.types.LlmPurpose.repair, h.ledger.rows.items[1].purpose);
    try testing.expect(h.ledger.rows.items[1].ok);
}

test "a schema mismatch is repaired once, then dead" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{ fixture("responses_wrong_shape"), fixture("responses_ok") });
    defer h.deinit();
    const out = try h.client.structuredAs(Entities, h.a(), request(null));
    try testing.expect(out.response.repaired);
    const repair_text = get(try h.sentJson(1), &.{"input"}).array.items[0].object.get("content").?.string;
    try testing.expect(std.mem.indexOf(u8, repair_text, "does not match the schema") != null);

    var d: Harness = undefined;
    d.init(.@"openai-responses", &.{ fixture("responses_bad_json"), fixture("responses_bad_json"), fixture("responses_ok") });
    defer d.deinit();
    var failure: llm.Failure = undefined;
    try testing.expectError(error.ProviderFailed, d.client.structured(d.a(), request(&failure)));
    try testing.expectEqual(llm.ErrorClass.invalid_output, failure.class);
    try testing.expectEqual(llm.Disposition.dead, failure.disposition);
    try testing.expectEqual(@as(usize, 2), d.replay.sent.items.len);
}

test "explicit repair sends only the repair request" {
    var h: Harness = undefined;
    h.init(.@"anthropic-messages", &.{fixture("messages_ok")});
    defer h.deinit();
    const out = try h.client.repair(h.a(), request(null), "{\"entities\":[{\"name\":\"F9\"}]}", "fact F9 refers to an unknown entity");
    try testing.expect(out.repaired);
    try testing.expectEqual(@as(usize, 1), h.replay.sent.items.len);
    const text = get(try h.sentJson(0), &.{"messages"}).array.items[0].object.get("content").?.string;
    try testing.expect(std.mem.indexOf(u8, text, "fact F9 refers to an unknown entity") != null);
    try testing.expectEqual(core.types.LlmPurpose.repair, h.ledger.rows.items[0].purpose);
}

test "embeddings: dimensions in the request, rows placed by index or by position" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{ fixture("embeddings_ok"), fixture("embeddings_no_index") });
    defer h.deinit();
    const inputs = [_][]const u8{ "brackwater-indexer uses pgvector", "Dana owns brackwater-indexer" };
    const a = try h.client.embed(h.a(), .{ .purpose = .embed_batch, .inputs = &inputs });
    try testing.expectEqual(@as(usize, 2), a.vectors.len);
    try testing.expectEqual(@as(usize, 512), a.vectors[1].len);
    try testing.expectEqual(core.types.CostStatus.priced, a.cost.status);
    const body = try h.sentJson(0);
    try testing.expectEqual(@as(i64, 512), get(body, &.{"dimensions"}).integer);
    try testing.expectEqualStrings("https://llm.example.test/v1/embeddings", h.replay.sent.items[0].url);

    const b = try h.client.embed(h.a(), .{ .purpose = .embed_query, .inputs = &inputs, .priority = .interactive });
    try testing.expectEqual(a.vectors[0][0], b.vectors[0][0]);
    try testing.expectEqual(a.vectors[1][511], b.vectors[1][511]);
    try testing.expectEqualStrings("embeddings", h.ledger.rows.items[1].route);
    try testing.expectEqual(core.types.LlmPurpose.embed_query, h.ledger.rows.items[1].purpose);
}

test "decide: generic request, calibrated answers, rerank fails fast so search can fall back" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{ fixture("decision_ok"), fixture("responses_500"), fixture("decision_ok") });
    defer h.deinit();
    h.cfg.decision = .{ .base_url = "https://decide.example.test", .path = "/v1/decide", .api_key = "d-key", .model = "decider-1" };
    const qs = [_]llm.Question{
        .{ .yes_no = "Is F3 the same fact?" },
        .{ .choice = .{ .prompt = "Which entity?", .options = &.{ "E1", "E2", "neither" } } },
    };
    const answers = try h.client.decide(h.a(), .resolve, &qs);
    try testing.expectEqual(@as(f64, 0.93), answers[0].yes_no);
    try testing.expectEqualStrings("https://decide.example.test/v1/decide", h.replay.sent.items[0].url);
    try testing.expectEqualStrings("Bearer d-key", h.sentHeader(0, "authorization").?);
    try testing.expectEqual(core.types.CostStatus.priced, h.ledger.rows.items[0].cost_status);
    try testing.expectEqualStrings("typed-decisions", h.ledger.rows.items[0].route);

    var failure: llm.Failure = undefined;
    _ = &failure;
    try testing.expectError(error.ProviderFailed, h.client.decide(h.a(), .rerank, &qs));
    try testing.expectEqual(@as(usize, 2), h.replay.sent.items.len);
}

test "the spend cap stops background calls before they are sent" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{fixture("responses_ok")});
    defer h.deinit();
    h.ledger.spent = 150.0;
    try testing.expectError(error.SpendCapReached, h.client.structured(h.a(), request(null)));
    try testing.expectEqual(@as(usize, 0), h.replay.sent.items.len);
    var r = request(null);
    r.priority = .interactive;
    _ = try h.client.structured(h.a(), r);
}

test "cancelAll stops a call" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{fixture("responses_ok")});
    defer h.deinit();
    h.client.cancelAll();
    try testing.expectError(error.Canceled, h.client.structured(h.a(), request(null)));
    try testing.expectEqual(@as(usize, 0), h.replay.sent.items.len);
}

test "a missing model is a configuration error, not a provider call" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{});
    defer h.deinit();
    h.cfg.llm.model = "";
    try testing.expectError(error.ModelNotConfigured, h.client.structured(h.a(), request(null)));
}

const Case = struct {
    route: ?core.config.Route,
    ok: []const u8,
    rate_limited: []const u8,
    server_error: []const u8,
    overflow: []const u8,
    unauthorized: []const u8,
    malformed: []const u8,
};

const cases = [_]Case{
    .{ .route = .@"openai-responses", .ok = "responses_ok", .rate_limited = "responses_429", .server_error = "responses_500", .overflow = "responses_context_overflow", .unauthorized = "responses_401", .malformed = "responses_bad_json" },
    .{ .route = .@"anthropic-messages", .ok = "messages_ok", .rate_limited = "messages_429", .server_error = "messages_500", .overflow = "messages_context_overflow", .unauthorized = "messages_401", .malformed = "messages_bad_json" },
    .{ .route = .@"openai-chat", .ok = "chat_ok", .rate_limited = "responses_429", .server_error = "chat_502", .overflow = "responses_context_overflow", .unauthorized = "responses_401", .malformed = "chat_bad_json" },
    .{ .route = null, .ok = "embeddings_ok", .rate_limited = "responses_429", .server_error = "responses_500", .overflow = "responses_context_overflow", .unauthorized = "responses_401", .malformed = "embeddings_cut_off" },
};

const all_fixtures = .{
    "responses_ok", "responses_429", "responses_500", "responses_context_overflow", "responses_401",      "responses_bad_json",
    "messages_ok",  "messages_429",  "messages_500",  "messages_context_overflow",  "messages_401",       "messages_bad_json",
    "chat_ok",      "chat_502",      "chat_bad_json", "embeddings_ok",              "embeddings_cut_off",
};

fn step(name: []const u8) Replay.Step {
    inline for (all_fixtures) |f| if (std.mem.eql(u8, f, name)) return fixture(f);
    unreachable;
}

const embed_inputs = [_][]const u8{ "brackwater-indexer uses pgvector", "Dana owns brackwater-indexer" };

fn callRoute(h: *Harness, c: Case, failure: *llm.Failure) !void {
    if (c.route == null) {
        _ = try h.client.embed(h.a(), .{ .purpose = .embed_batch, .inputs = &embed_inputs, .failure = failure });
    } else {
        _ = try h.client.structuredAs(Entities, h.a(), request(failure));
    }
}

test "every route replays success, 429, 5xx, context overflow, 401 and malformed output with no network" {
    for (cases) |c| {
        const route = c.route orelse .@"openai-responses";
        var failure: llm.Failure = undefined;
        {
            var h: Harness = undefined;
            h.init(route, &.{step(c.ok)});
            defer h.deinit();
            try callRoute(&h, c, &failure);
            try testing.expect(h.ledger.rows.items[0].ok);
            try testing.expectEqual(core.types.CostStatus.priced, h.ledger.rows.items[0].cost_status);
        }
        {
            var h: Harness = undefined;
            h.init(route, &.{ step(c.rate_limited), step(c.ok) });
            defer h.deinit();
            try callRoute(&h, c, &failure);
            try testing.expectEqualStrings("rate_limited_429", h.ledger.rows.items[0].error_class.?);
            try testing.expectEqual(@as(usize, 2), h.ledger.rows.items.len);
        }
        {
            var h: Harness = undefined;
            h.init(route, &.{ step(c.server_error), step(c.ok) });
            defer h.deinit();
            try callRoute(&h, c, &failure);
            try testing.expectEqualStrings("http_5xx", h.ledger.rows.items[0].error_class.?);
        }
        {
            var h: Harness = undefined;
            h.init(route, &.{ step(c.overflow), step(c.ok) });
            defer h.deinit();
            try testing.expectError(error.ProviderFailed, callRoute(&h, c, &failure));
            try testing.expectEqual(llm.Disposition.split, failure.disposition);
            try testing.expectEqual(@as(usize, 1), h.replay.sent.items.len);
        }
        {
            var h: Harness = undefined;
            h.init(route, &.{ step(c.unauthorized), step(c.ok) });
            defer h.deinit();
            try testing.expectError(error.ProviderFailed, callRoute(&h, c, &failure));
            try testing.expectEqual(llm.Disposition.pause_route, failure.disposition);
            try testing.expectEqual(@as(usize, 1), h.replay.sent.items.len);
        }
        {
            var h: Harness = undefined;
            h.init(route, &.{ step(c.malformed), step(c.ok) });
            defer h.deinit();
            try callRoute(&h, c, &failure);
            try testing.expectEqual(@as(usize, 2), h.ledger.rows.items.len);
            const expected: core.types.LlmPurpose = if (c.route == null) .embed_batch else .repair;
            try testing.expectEqual(expected, h.ledger.rows.items[1].purpose);
        }
    }
}

test "without a cost header, the configured rate table prices the call as estimated" {
    var h: Harness = undefined;
    h.init(.@"openai-responses", &.{fixture("responses_ok")});
    defer h.deinit();
    h.cfg.llm.cost_header = "";
    h.cfg.llm.rates = &.{"example-model input=2 output=8"};
    h.client.rates = h.cfg.llm.rates;
    const out = try h.client.structured(h.a(), request(null));
    try testing.expectEqual(core.types.CostStatus.estimated, out.cost.status);
    try testing.expectApproxEqAbs(@as(f64, (103.0 * 2 + 44.0 * 8) / 1_000_000.0), out.cost.usd, 1e-12);
}
