const std = @import("std");
const core = @import("core");
const ingest = @import("mod.zig");
const pipeline = @import("pipeline.zig");
const fakes = @import("testing.zig");
const time = @import("time.zig");

const testing = std.testing;
const Driver = pipeline.Driver(fakes.MemoryBackend, fakes.FakeModel);

const Harness = struct {
    backend: fakes.MemoryBackend,
    model: fakes.FakeModel,
    config: core.Config = .{},

    fn init() !Harness {
        return .{ .backend = try .init(testing.allocator, testing.io), .model = .init(testing.allocator) };
    }

    fn deinit(h: *Harness) void {
        h.backend.deinit();
        h.model.deinit();
    }

    fn driver(h: *Harness) Driver {
        return .{ .backend = &h.backend, .model = &h.model, .config = &h.config, .graph_id = fakes.MemoryBackend.graph, .io = testing.io };
    }

    fn step(h: *Harness) !ingest.Outcome {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const lease = h.backend.claim() orelse return error.NothingQueued;
        var d = h.driver();
        return d.process(arena_state.allocator(), lease);
    }
};

fn at(s: []const u8) core.Micros {
    return time.parse(s) catch unreachable;
}

const relay_marco =
    \\{"skip":null,"entities":[{"ref":"n1","name":"Relay","type":"software","aliases":[],"description":"Request gateway."},{"ref":"n2","name":"Marco","type":"person","aliases":[],"description":"Engineer."}],
    \\"facts":[{"subject":"n1","relation":"has_oncall","qualifier":null,"object":"n2","value":null,"text":"Marco is on call for Relay.","rationale":null,"valid_from":null,"valid_to":null,"time_basis":"reference","scope":"project","author":"agent","quote":"Marco is currently on call for Relay."},
    \\{"subject":"n1","relation":"located_at","qualifier":null,"object":null,"value":"infra/relay","text":"Relay lives under infra/relay.","rationale":null,"valid_from":null,"valid_to":null,"time_basis":"reference","scope":"project","author":"agent","quote":"Relay lives under infra/relay"}],"new_relations":[]}
;

const relay_elena =
    \\{"skip":null,"entities":[{"ref":"n1","name":"Relay","type":"software","aliases":[],"description":"Request gateway."},{"ref":"n2","name":"Elena","type":"person","aliases":[],"description":"Engineer."}],
    \\"facts":[{"subject":"n1","relation":"has_oncall","qualifier":null,"object":"n2","value":null,"text":"Elena is on call for Relay.","rationale":null,"valid_from":"2026-11-20T17:00:00Z","valid_to":null,"time_basis":"relative","scope":"project","author":"user","quote":"Elena took over on call for Relay starting today at 17:00 UTC."}],"new_relations":[]}
;

const elena_restated =
    \\{"skip":null,"entities":[{"ref":"n1","name":"relay","type":"software","aliases":[],"description":""},{"ref":"n2","name":"Elena","type":"person","aliases":[],"description":""}],
    \\"facts":[{"subject":"n1","relation":"has_oncall","qualifier":null,"object":"n2","value":null,"text":"Elena is on call for Relay.","rationale":null,"valid_from":null,"valid_to":null,"time_basis":"reference","scope":"project","author":"user","quote":"Elena has Relay on call this week."}],"new_relations":[]}
;

const skip_json = "{\"skip\":\"test output only\",\"entities\":[],\"facts\":[],\"new_relations\":[]}";

fn turns(comptime text: []const u8) []const core.Turn {
    return &.{.{ .role = .user, .text = text }};
}

test "entries flow through extraction, resolution and commit into the expected graph" {
    var h = try Harness.init();
    defer h.deinit();

    const entry1 = try h.backend.add("session-a", at("2026-11-19T22:00:00Z"), "acme/monorepo", turns("Relay lives under infra/relay. Marco is currently on call for Relay."));
    const entry2 = try h.backend.add("session-b", at("2026-11-20T18:00:00Z"), "acme/monorepo", turns("Heads up: Elena took over on call for Relay starting today at 17:00 UTC."));
    const entry3 = try h.backend.add("session-c", at("2026-11-22T09:00:00Z"), "acme/monorepo", turns("Elena has Relay on call this week."));
    const entry4 = try h.backend.add("session-d", at("2026-11-22T10:00:00Z"), null, turns("run the tests"));

    try h.model.push(.{ .json = relay_marco });
    try testing.expectEqual(ingest.Outcome.committed, try h.step());
    try testing.expectEqual(@as(u32, 1), h.model.count(.extract));
    try testing.expectEqual(@as(u32, 0), h.model.count(.resolve));
    try testing.expectEqual(@as(u32, 1), h.model.count(.embed_batch));
    try testing.expectEqual(@as(usize, 2), h.backend.entities.items.len);
    try testing.expectEqual(@as(usize, 2), h.backend.facts.items.len);

    try h.model.push(.{ .json = relay_elena });
    try h.model.push(.{ .json = "{\"entity_links\":[],\"fact_verdicts\":[{\"fact_index\":0,\"duplicate_of\":null,\"contradicts\":[{\"fact\":\"F1\",\"kind\":\"changed\",\"at\":null}]}]}" });
    try testing.expectEqual(ingest.Outcome.committed, try h.step());
    try testing.expectEqual(@as(u32, 1), h.model.count(.resolve));
    try testing.expectEqual(@as(usize, 3), h.backend.entities.items.len);
    const resolution_prompt = h.model.requests.items[2].user;
    try testing.expect(std.mem.indexOf(u8, resolution_prompt, "Marco is on call for Relay.") != null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var marco_fact: ?core.Fact = null;
    var elena_fact: ?core.Fact = null;
    for (h.backend.facts.items) |f| {
        if (std.mem.eql(u8, f.fact.text, "Marco is on call for Relay.")) marco_fact = f.fact;
        if (std.mem.eql(u8, f.fact.text, "Elena is on call for Relay.")) elena_fact = f.fact;
    }
    try testing.expectEqual(@as(?core.Micros, at("2026-11-20T17:00:00Z")), marco_fact.?.valid.upper);
    try testing.expectEqual(core.types.EndKind.changed, marco_fact.?.end_kind.?);
    try testing.expect(marco_fact.?.known.upper == null);
    try testing.expect(elena_fact.?.valid.upper == null);
    try testing.expect(marco_fact.?.subject_id.eql(elena_fact.?.subject_id));
    try testing.expectEqual(@as(usize, 2), (try h.backend.activeFacts(arena)).len);

    try h.model.push(.{ .json = elena_restated });
    try testing.expectEqual(ingest.Outcome.committed, try h.step());
    try testing.expectEqual(@as(u32, 1), h.model.count(.resolve));
    try testing.expectEqual(@as(usize, 3), h.backend.facts.items.len);
    try testing.expectApproxEqAbs(@as(f32, 0.93), h.backend.fact(elena_fact.?.id).?.fact.confidence, 1e-6);

    try h.model.push(.{ .json = skip_json });
    try testing.expectEqual(ingest.Outcome.skipped, try h.step());
    try testing.expectEqual(@as(u32, 3), h.model.count(.embed_batch));

    for ([_]core.Id{ entry1, entry2, entry3 }) |id| try testing.expectEqual(core.types.EntryStatus.committed, h.backend.row(id).status);
    try testing.expectEqual(core.types.EntryStatus.skipped, h.backend.row(entry4).status);
    try testing.expectEqual(@as(u32, 5), h.model.count(.extract) + h.model.count(.resolve));
}

test "a crash after extraction resumes without paying for extraction again" {
    var h = try Harness.init();
    defer h.deinit();
    const entry = try h.backend.add("session-a", at("2026-11-19T22:00:00Z"), null, turns("Relay lives under infra/relay. Marco is currently on call for Relay."));
    try h.model.push(.{ .json = relay_marco });
    h.backend.crash_after_extraction = true;
    try testing.expectError(error.SimulatedCrash, h.step());
    try testing.expectEqual(core.types.EntryStatus.extracted, h.backend.row(entry).status);
    try testing.expectEqual(@as(u32, 1), h.model.count(.extract));

    h.backend.crash_after_extraction = false;
    h.backend.expireLease(entry);
    try testing.expectEqual(ingest.Outcome.committed, try h.step());
    try testing.expectEqual(@as(u32, 1), h.model.count(.extract));
    try testing.expectEqual(@as(usize, 2), h.backend.facts.items.len);
}

test "a lost lease fences the commit" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.backend.add("session-a", at("2026-11-19T22:00:00Z"), null, turns("Relay lives under infra/relay. Marco is currently on call for Relay."));
    try h.model.push(.{ .json = relay_marco });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var lease = h.backend.claim().?;
    lease.token += 100;
    var d = h.driver();
    try testing.expectError(error.LeaseLost, d.process(arena_state.allocator(), lease));
    try testing.expectEqual(@as(usize, 0), h.backend.facts.items.len);
}

test "provider failures requeue, kill, or split the entry" {
    var h = try Harness.init();
    defer h.deinit();
    const entry = try h.backend.add("session-a", at("2026-11-19T22:00:00Z"), null, turns("Relay lives under infra/relay. Marco is currently on call for Relay."));

    try h.model.push(.{ .fail = .http_5xx });
    try testing.expectEqual(ingest.Outcome.requeued, try h.step());
    try testing.expectEqual(core.types.EntryStatus.queued, h.backend.row(entry).status);
    try h.model.push(.{ .fail = .auth_401_403 });
    try testing.expectEqual(ingest.Outcome.requeued, try h.step());
    try testing.expectEqual(@as(i32, 1), h.backend.row(entry).attempts);
    try h.model.push(.{ .fail = .timeout });
    try testing.expectEqual(ingest.Outcome.requeued, try h.step());
    try h.model.push(.{ .fail = .timeout });
    try testing.expectEqual(ingest.Outcome.dead, try h.step());
    try testing.expectEqual(core.types.EntryStatus.dead, h.backend.row(entry).status);

    const long = try h.backend.add("session-b", at("2026-11-19T23:00:00Z"), null, &.{
        .{ .role = .user, .text = "first half of a very long session" },
        .{ .role = .assistant, .text = "second half of a very long session" },
    });
    try h.model.push(.{ .fail = .context_overflow });
    try testing.expectEqual(ingest.Outcome.split, try h.step());
    try testing.expectEqual(core.types.EntryStatus.split, h.backend.row(long).status);
    try testing.expectEqual(@as(usize, 4), h.backend.entries.items.len);
    try testing.expectEqual(@as(usize, 1), h.backend.entries.items[2].entry.body.turns.len);

    var h2 = try Harness.init();
    defer h2.deinit();
    const rejected = try h2.backend.add("session-c", at("2026-11-19T23:30:00Z"), null, turns("hi"));
    try h2.model.push(.{ .fail = .invalid_request_400 });
    try testing.expectEqual(ingest.Outcome.dead, try h2.step());
    try testing.expectEqual(core.types.EntryStatus.dead, h2.backend.row(rejected).status);
}

test "malformed extraction output gets one repair, then the entry dies" {
    var h = try Harness.init();
    defer h.deinit();
    const ok = try h.backend.add("session-a", at("2026-11-19T22:00:00Z"), null, turns("Relay lives under infra/relay. Marco is currently on call for Relay."));
    try h.model.push(.{ .json = "```json\n{\"skip\": null}\n```" });
    try h.model.push(.{ .json = relay_marco });
    try testing.expectEqual(ingest.Outcome.committed, try h.step());
    try testing.expectEqual(@as(u32, 1), h.model.count(.repair));
    try testing.expectEqual(core.types.EntryStatus.committed, h.backend.row(ok).status);

    const bad = try h.backend.add("session-b", at("2026-11-19T23:00:00Z"), null, turns("something"));
    try h.model.push(.{ .json = "not json" });
    try h.model.push(.{ .json = "still not json" });
    try testing.expectEqual(ingest.Outcome.dead, try h.step());
    try testing.expectEqual(core.types.EntryStatus.dead, h.backend.row(bad).status);
}

test "an unusable resolution answer falls back to the deterministic rules" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.backend.add("session-a", at("2026-11-19T22:00:00Z"), null, turns("Relay lives under infra/relay. Marco is currently on call for Relay."));
    _ = try h.backend.add("session-b", at("2026-11-20T18:00:00Z"), null, turns("Heads up: Elena took over on call for Relay starting today at 17:00 UTC."));
    try h.model.push(.{ .json = relay_marco });
    try testing.expectEqual(ingest.Outcome.committed, try h.step());
    try h.model.push(.{ .json = relay_elena });
    try h.model.push(.{ .json = "{\"entity_links\":[{\"ref\":\"n9\",\"existing\":\"E7\"}],\"fact_verdicts\":[]}" });
    try h.model.push(.{ .json = "garbage" });
    try testing.expectEqual(ingest.Outcome.committed, try h.step());
    try testing.expectEqual(@as(u32, 1), h.model.count(.repair));
    var ended: usize = 0;
    for (h.backend.facts.items) |f| if (f.fact.end_kind == .changed) {
        ended += 1;
    };
    try testing.expectEqual(@as(usize, 1), ended);
}
