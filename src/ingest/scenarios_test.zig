const std = @import("std");
const core = @import("core");
const ingest = @import("mod.zig");
const extract = @import("extract.zig");
const resolve = @import("resolve.zig");
const fakes = @import("testing.zig");

const testing = std.testing;
const Id = core.Id;
const ChangeSet = core.ChangeSet;

fn id(n: u8) Id {
    return Id.fromParts(@as(u48, n) << 8, @splat(n));
}

const graph = Id.fromParts(1, @splat(0));

const at = fakes.at;

fn ent(ref: []const u8, name: []const u8, ty: core.EntityType) ingest.ExtractedEntity {
    return .{ .ref = ref, .name = name, .type = ty, .aliases = &.{}, .description = "" };
}

fn fct(subject: []const u8, relation: []const u8, object: ?[]const u8, value: ?[]const u8, quote: []const u8) ingest.ExtractedFact {
    return .{
        .subject = subject,
        .relation = relation,
        .qualifier = null,
        .object = object,
        .value = value,
        .text = quote,
        .rationale = null,
        .valid_from = null,
        .valid_to = null,
        .time_basis = .reference,
        .scope = .project,
        .author = .user,
        .quote = quote,
    };
}

const Scenario = struct {
    arena: std.mem.Allocator,
    reference_time: core.Micros,
    body: []const u8,
    raw: ingest.ExtractResult,
    prefetch: resolve.Prefetch = .{},
    resolution: ?ingest.ResolveResult = null,

    const Out = struct { cs: ChangeSet, plan: resolve.Plan, checked: extract.Checked };

    fn run(s: Scenario) !Out {
        const checked = try extract.check(s.arena, s.raw, s.body, s.reference_time);
        const p = try resolve.plan(s.arena, checked, s.prefetch);
        const verdict = if (s.resolution) |r| (try resolve.interpret(s.arena, p, checked, r)).verdict else try resolve.Verdict.none(s.arena, p);
        const ent_vecs = try s.arena.alloc([]const f32, checked.result.entities.len);
        @memset(ent_vecs, &.{ 1, 0 });
        const fact_vecs = try s.arena.alloc([]const f32, checked.result.facts.len);
        @memset(fact_vecs, &.{ 0, 1 });
        const cs = try resolve.build(s.arena, .{
            .entry = .{ .graph_id = graph, .reference_time = s.reference_time, .project = "lantern" },
            .commit_time = s.reference_time + 1000,
            .io = testing.io,
        }, checked, s.prefetch, p, .{ .entities = ent_vecs, .facts = fact_vecs }, verdict);
        return .{ .cs = cs, .plan = p, .checked = checked };
    }
};

const relay = id(10);
const hollis = id(11);
const hollis_oncall = id(50);

fn relayOncallPrefetch(item_subject: u32, item_object: u32, fact_item: u32) resolve.Prefetch {
    _ = item_object;
    return .{
        .base_seq = 7,
        .entities = &.{
            .{ .item = item_subject, .id = relay, .name = "Relay", .norm = "relay", .type = .software, .alias_match = true, .cosine = 1.0 },
            .{ .item = 1, .id = hollis, .name = "Hollis", .norm = "hollis", .type = .person, .cosine = 0.55 },
        },
        .facts = &.{.{
            .item = fact_item,
            .id = hollis_oncall,
            .subject_id = relay,
            .relation = "has_oncall",
            .object_id = hollis,
            .text = "Hollis is on call for Relay.",
            .valid_lower = at("2026-11-19T22:00:00Z"),
            .confidence = 0.9,
        }},
    };
}

test "an on-call handoff ends the previous holder at the stated time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var handoff = fct("n1", "has_oncall", "n2", null, "Juno took over on call for Relay starting today at 17:00 UTC");
    handoff.valid_from = "2026-11-20T17:00:00Z";
    handoff.time_basis = .explicit;
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-20T18:00:00Z"),
        .body = "Heads up: Juno took over on call for Relay starting today at 17:00 UTC. Hollis rotated off.",
        .raw = .{ .skip = null, .entities = &.{ ent("n1", "Relay", .software), ent("n2", "Juno", .person) }, .facts = &.{handoff}, .new_relations = &.{} },
        .prefetch = relayOncallPrefetch(0, 1, 0),
    }).run();
    const cs = out.cs;
    try testing.expectEqual(@as(i64, 7), cs.base_seq);
    try testing.expectEqual(@as(usize, 1), cs.new_entities.len);
    try testing.expectEqualStrings("Juno", cs.new_entities[0].name);
    try testing.expectEqual(@as(usize, 1), cs.new_facts.len);
    try testing.expect(cs.new_facts[0].fact.subject_id.eql(relay));
    try testing.expectEqual(@as(usize, 1), cs.invalidations.len);
    try testing.expect(cs.invalidations[0].fact_id.eql(hollis_oncall));
    try testing.expectEqual(at("2026-11-20T17:00:00Z"), cs.invalidations[0].valid_upper);
    try testing.expect(cs.invalidations[0].ended_by.?.eql(cs.new_facts[0].fact.id));
    try testing.expectEqual(@as(usize, 0), cs.retractions.len);
    try testing.expect(out.plan.needsResolution());
}

test "a handoff that also says the previous holder rotated off ends it once and adds one row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var handoff = fct("n1", "has_oncall", "n2", null, "Juno took over on call for Relay starting today at 17:00 UTC");
    handoff.valid_from = "2026-11-20T17:00:00Z";
    handoff.time_basis = .explicit;
    var rotated = fct("n1", "has_oncall", "n3", null, "Hollis rotated off");
    rotated.valid_to = "2026-11-20T17:00:00Z";
    rotated.time_basis = .explicit;
    const prefetch: resolve.Prefetch = .{
        .entities = &.{
            .{ .item = 0, .id = relay, .name = "Relay", .norm = "relay", .type = .software, .alias_match = true, .cosine = 1.0 },
            .{ .item = 2, .id = hollis, .name = "Hollis", .norm = "hollis", .type = .person, .alias_match = true, .cosine = 1.0 },
        },
        .facts = &.{.{
            .item = 0,
            .id = hollis_oncall,
            .subject_id = relay,
            .relation = "has_oncall",
            .object_id = hollis,
            .text = "Hollis is on call for Relay.",
            .valid_lower = at("2026-11-19T22:00:00Z"),
            .confidence = 0.9,
        }},
    };
    const orders = [_][]const ingest.ExtractedFact{ &.{ handoff, rotated }, &.{ rotated, handoff } };
    for (orders) |facts| {
        const out = try (Scenario{
            .arena = arena,
            .reference_time = at("2026-11-20T18:00:00Z"),
            .body = "Heads up: Juno took over on call for Relay starting today at 17:00 UTC. Hollis rotated off.",
            .raw = .{ .skip = null, .entities = &.{ ent("n1", "Relay", .software), ent("n2", "Juno", .person), ent("n3", "Hollis", .person) }, .facts = facts, .new_relations = &.{} },
            .prefetch = prefetch,
        }).run();
        try testing.expectEqual(@as(usize, 2), out.checked.result.facts.len);
        try testing.expectEqual(@as(usize, 1), out.cs.new_facts.len);
        try testing.expectEqualStrings("Juno took over on call for Relay starting today at 17:00 UTC", out.cs.new_facts[0].fact.text);
        try testing.expectEqual(@as(usize, 1), out.cs.invalidations.len);
        try testing.expect(out.cs.invalidations[0].fact_id.eql(hollis_oncall));
        try testing.expectEqual(at("2026-11-20T17:00:00Z"), out.cs.invalidations[0].valid_upper);
        try testing.expectEqual(@as(usize, 1), out.cs.restatements.len);
        try testing.expect(out.cs.restatements[0].fact_id.eql(hollis_oncall));
    }
}

fn endedHollisPrefetch() resolve.Prefetch {
    return .{
        .entities = &.{
            .{ .item = 0, .id = relay, .name = "Relay", .norm = "relay", .type = .software, .alias_match = true, .cosine = 1.0 },
            .{ .item = 1, .id = hollis, .name = "Hollis", .norm = "hollis", .type = .person, .alias_match = true, .cosine = 1.0 },
        },
        .facts = &.{.{
            .item = 0,
            .id = hollis_oncall,
            .subject_id = relay,
            .relation = "has_oncall",
            .object_id = hollis,
            .text = "Hollis is on call for Relay.",
            .valid_lower = at("2026-11-19T22:00:00Z"),
            .valid_upper = at("2026-11-20T17:00:00Z"),
            .confidence = 0.9,
        }},
    };
}

test "restating a fact that already ended adds a new period instead of evidence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var back = fct("n1", "has_oncall", "n2", null, "Hollis is back on call for Relay since this morning.");
    back.valid_from = "2026-11-25T08:00:00Z";
    back.time_basis = .relative;
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-25T09:00:00Z"),
        .body = "Hollis is back on call for Relay since this morning.",
        .raw = .{ .skip = null, .entities = &.{ ent("n1", "Relay", .software), ent("n2", "Hollis", .person) }, .facts = &.{back}, .new_relations = &.{} },
        .prefetch = endedHollisPrefetch(),
    }).run();
    try testing.expectEqual(@as(usize, 0), out.cs.restatements.len);
    try testing.expectEqual(@as(usize, 1), out.cs.new_facts.len);
    try testing.expectEqual(@as(usize, 0), out.cs.invalidations.len);
}

test "a dated historical on-call period never ends the current holder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var past = fct("n1", "has_oncall", "n2", null, "Priya was on call for Relay from November 10, 2026 until November 17, 2026");
    past.valid_from = "2026-11-10T00:00:00Z";
    past.valid_to = "2026-11-17T00:00:00Z";
    past.time_basis = .explicit;
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-21T20:00:00Z"),
        .body = "Historical note: Priya was on call for Relay from November 10, 2026 until November 17, 2026, before Hollis.",
        .raw = .{ .skip = null, .entities = &.{ ent("n1", "Relay", .software), ent("n2", "Priya", .person) }, .facts = &.{past}, .new_relations = &.{} },
        .prefetch = relayOncallPrefetch(0, 1, 0),
    }).run();
    try testing.expectEqual(@as(usize, 0), out.cs.invalidations.len);
    try testing.expectEqual(@as(usize, 0), out.cs.retractions.len);
    try testing.expectEqual(@as(?core.Micros, at("2026-11-17T00:00:00Z")), out.cs.new_facts[0].fact.valid.upper);
    try testing.expectEqual(@as(?core.Micros, at("2026-11-10T00:00:00Z")), out.cs.new_facts[0].fact.valid.lower);
}

test "an undated backfill that predates current state is bounded by it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var past = fct("n1", "has_oncall", "n2", null, "Priya was on call for Relay before Hollis");
    past.valid_from = "2026-11-10T00:00:00Z";
    past.time_basis = .explicit;
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-21T20:00:00Z"),
        .body = "Priya was on call for Relay before Hollis",
        .raw = .{ .skip = null, .entities = &.{ ent("n1", "Relay", .software), ent("n2", "Priya", .person) }, .facts = &.{past}, .new_relations = &.{} },
        .prefetch = relayOncallPrefetch(0, 1, 0),
    }).run();
    try testing.expectEqual(@as(usize, 0), out.cs.invalidations.len);
    try testing.expectEqual(@as(?core.Micros, at("2026-11-19T22:00:00Z")), out.cs.new_facts[0].fact.valid.upper);
}

test "gaining a feature ends the opposed lacks_feature fact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const driver = id(20);
    const lacks = id(60);
    const pipelining = id(61);
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-21T17:00:00Z"),
        .body = "Good news: COPY support was merged into pg.zig today! So pg.zig now supports COPY.",
        .raw = .{ .skip = null, .entities = &.{ent("n1", "pg.zig", .software)}, .facts = &.{fct("n1", "supports_feature", null, "COPY", "So pg.zig now supports COPY.")}, .new_relations = &.{} },
        .prefetch = .{
            .entities = &.{.{ .item = 0, .id = driver, .name = "pg.zig", .norm = "pg zig", .type = .software, .alias_match = true, .cosine = 1 }},
            .facts = &.{
                .{ .item = 0, .id = lacks, .subject_id = driver, .relation = "lacks_feature", .object_value = "COPY", .text = "pg.zig lacks COPY.", .valid_lower = at("2026-11-19T20:15:00Z"), .confidence = 0.7 },
                .{ .item = 0, .id = pipelining, .subject_id = driver, .relation = "lacks_feature", .object_value = "pipelining", .text = "pg.zig lacks pipelining.", .valid_lower = at("2026-11-19T20:15:00Z"), .confidence = 0.7 },
            },
        },
    }).run();
    try testing.expectEqual(@as(usize, 1), out.cs.invalidations.len);
    try testing.expect(out.cs.invalidations[0].fact_id.eql(lacks));
    try testing.expectEqual(at("2026-11-21T17:00:00Z"), out.cs.invalidations[0].valid_upper);
    try testing.expectEqual(@as(usize, 0), out.cs.new_entities.len);
}

test "switching a setting ends only the same qualifier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lantern = id(30);
    const old_model = id(70);
    const other_setting = id(71);
    var switch_fact = fct("n1", "has_setting", null, "model-b", "switch lantern's extraction_model setting from model-a to model-b");
    switch_fact.qualifier = "extraction_model";
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-21T19:00:00Z"),
        .body = "Actually let's switch lantern's extraction_model setting from model-a to model-b",
        .raw = .{ .skip = null, .entities = &.{ent("n1", "Lantern", .project)}, .facts = &.{switch_fact}, .new_relations = &.{} },
        .prefetch = .{
            .entities = &.{.{ .item = 0, .id = lantern, .name = "lantern", .norm = "lantern", .type = .project, .alias_match = true, .cosine = 1 }},
            .facts = &.{
                .{ .item = 0, .id = old_model, .subject_id = lantern, .relation = "has_setting", .qualifier = "extraction_model", .object_value = "model-a", .text = "lantern extraction_model is model-a", .valid_lower = at("2026-11-20T21:00:00Z"), .confidence = 0.9 },
                .{ .item = 0, .id = other_setting, .subject_id = lantern, .relation = "has_setting", .qualifier = "zig_version", .object_value = "0.17.1", .text = "lantern pins zig 0.17.1", .valid_lower = at("2026-11-18T18:00:00Z"), .confidence = 0.9 },
            },
        },
    }).run();
    try testing.expectEqual(@as(usize, 1), out.cs.invalidations.len);
    try testing.expect(out.cs.invalidations[0].fact_id.eql(old_model));
    try testing.expectEqual(at("2026-11-21T19:00:00Z"), out.cs.invalidations[0].valid_upper);
}

test "a correction the resolution call marks was_wrong retracts instead of ending" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lantern = id(30);
    const go = id(31);
    const uses_go = id(80);
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-21T09:00:00Z"),
        .body = "That's wrong. Lantern uses Rust for its backend, not Go. We never used Go.",
        .raw = .{ .skip = null, .entities = &.{ ent("n1", "Lantern", .project), ent("n2", "Rust", .other) }, .facts = &.{fct("n1", "uses", "n2", null, "Lantern uses Rust for its backend, not Go")}, .new_relations = &.{} },
        .prefetch = .{
            .entities = &.{.{ .item = 0, .id = lantern, .name = "Lantern", .norm = "lantern", .type = .project, .alias_match = true, .cosine = 1 }},
            .facts = &.{.{ .item = 0, .id = uses_go, .subject_id = lantern, .relation = "uses", .object_id = go, .text = "Lantern uses Go for its backend.", .valid_lower = at("2026-11-20T19:00:00Z"), .confidence = 0.7, .cosine = 0.8 }},
        },
        .resolution = .{
            .entity_links = &.{},
            .fact_verdicts = &.{.{ .fact_index = 0, .duplicate_of = null, .contradicts = &.{.{ .fact = "F1", .kind = .was_wrong, .at = null }} }},
        },
    }).run();
    try testing.expectEqual(@as(usize, 0), out.cs.invalidations.len);
    try testing.expectEqual(@as(usize, 1), out.cs.retractions.len);
    try testing.expect(out.cs.retractions[0].fact_id.eql(uses_go));
    try testing.expectEqual(core.types.EndKind.retracted, out.cs.retractions[0].end_kind);
    var saw_retracted = false;
    for (out.cs.evidence) |ev| if (ev.fact_id.eql(uses_go) and ev.kind == .retracted) {
        saw_retracted = true;
    };
    try testing.expect(saw_retracted);
}

test "restating an existing fact restates it instead of duplicating" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lantern = id(30);
    const pg = id(32);
    const uses_pg = id(90);
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-22T16:00:00Z"),
        .body = "Remember we already chose Postgres 17 for lantern.",
        .raw = .{ .skip = null, .entities = &.{ ent("n1", "lantern", .project), ent("n2", "Postgres", .software) }, .facts = &.{fct("n1", "uses", "n2", null, "we already chose Postgres 17 for lantern")}, .new_relations = &.{} },
        .prefetch = .{
            .entities = &.{
                .{ .item = 0, .id = lantern, .name = "Lantern", .norm = "lantern", .type = .project, .alias_match = true, .cosine = 1 },
                .{ .item = 1, .id = pg, .name = "PostgreSQL", .norm = "postgresql", .type = .software, .alias_match = true, .cosine = 0.95 },
            },
            .facts = &.{.{ .item = 0, .id = uses_pg, .subject_id = lantern, .relation = "uses", .object_id = pg, .text = "Lantern uses Postgres 17.", .valid_lower = at("2026-11-18T18:00:00Z"), .confidence = 0.9 }},
        },
    }).run();
    try testing.expectEqual(@as(usize, 0), out.cs.new_facts.len);
    try testing.expectEqual(@as(usize, 1), out.cs.restatements.len);
    try testing.expect(out.cs.restatements[0].fact_id.eql(uses_pg));
    try testing.expectApproxEqAbs(@as(f32, 0.93), out.cs.restatements[0].confidence, 1e-6);
    try testing.expectEqual(core.types.EvidenceKind.restated, out.cs.evidence[0].kind);
    try testing.expect(!out.plan.needsResolution());
    try testing.expectEqual(@as(usize, 1), out.cs.new_aliases.len);
    try testing.expectEqualStrings("postgres", out.cs.new_aliases[0].norm);
}

test "an alias spelling merges deterministically into the existing entity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const driver = id(20);
    var e = ent("n1", "pg-zig", .software);
    e.aliases = &.{"the zig postgres driver"};
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-20T16:30:00Z"),
        .body = "Since pg-zig has no COPY, we'll batch commit inserts with unnest.",
        .raw = .{ .skip = null, .entities = &.{e}, .facts = &.{fct("n1", "lacks_feature", null, "COPY", "Since pg-zig has no COPY")}, .new_relations = &.{} },
        .prefetch = .{ .entities = &.{.{ .item = 0, .id = driver, .name = "pg.zig", .norm = "pg zig", .type = .software, .alias_match = true, .cosine = 0.97 }} },
    }).run();
    try testing.expectEqual(@as(usize, 0), out.cs.new_entities.len);
    try testing.expect(out.cs.new_facts[0].fact.subject_id.eql(driver));
    try testing.expectEqual(@as(usize, 1), out.cs.new_aliases.len);
    try testing.expectEqualStrings("the zig postgres driver", out.cs.new_aliases[0].alias);
    try testing.expect(out.cs.mentions[0].eql(driver));
}

test "same-name entities of incompatible types never merge without the model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vx_tool = id(40);
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-23T03:00:00Z"),
        .body = "We compared the vx coding agent against the VX currency rates dataset.",
        .raw = .{ .skip = null, .entities = &.{ ent("n1", "VX currency rates", .dataset), ent("n2", "vx", .dataset) }, .facts = &.{}, .new_relations = &.{} },
        .prefetch = .{ .entities = &.{
            .{ .item = 1, .id = vx_tool, .name = "vx", .norm = "vx", .type = .software, .alias_match = true, .cosine = 0.99 },
        } },
    }).run();
    try testing.expectEqual(resolve.EntityDecision.ask, out.plan.entities[1].decision);
    try testing.expectEqual(@as(usize, 2), out.cs.new_entities.len);
    try testing.expectEqual(@as(usize, 0), out.cs.merges.len);
}

test "an organization and its similarly named software stay apart, and a person never joins a group" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const brackwater_org = id(41);
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-21T01:00:00Z"),
        .body = "Brackwater maintains brackwater-box, a sandbox tool. Brackwater Robotics is a different company.",
        .raw = .{ .skip = null, .entities = &.{ ent("n1", "brackwater-box", .software), ent("n2", "Brackwater", .person) }, .facts = &.{}, .new_relations = &.{} },
        .prefetch = .{ .entities = &.{
            .{ .item = 0, .id = brackwater_org, .name = "Brackwater", .norm = "brackwater", .type = .organization, .cosine = 0.86 },
            .{ .item = 1, .id = brackwater_org, .name = "Brackwater", .norm = "brackwater", .type = .organization, .alias_match = true, .cosine = 1.0 },
        } },
        .resolution = .{
            .entity_links = &.{ .{ .ref = "n1", .existing = "E1" }, .{ .ref = "n2", .existing = "E1" } },
            .fact_verdicts = &.{},
        },
    }).run();
    try testing.expectEqual(resolve.EntityDecision.new, out.plan.entities[0].decision);
    try testing.expectEqual(resolve.EntityDecision.new, out.plan.entities[1].decision);
    try testing.expectEqual(@as(usize, 2), out.cs.new_entities.len);
}

test "a gray-band entity links only when the resolution call names one of its candidates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const driver = id(20);
    const unrelated = id(21);
    const base: Scenario = .{
        .arena = arena,
        .reference_time = at("2026-11-20T16:30:00Z"),
        .body = "the zig driver needs a separate branch per Zig release",
        .raw = .{ .skip = null, .entities = &.{ent("n1", "the zig driver", .software)}, .facts = &.{}, .new_relations = &.{} },
        .prefetch = .{ .entities = &.{
            .{ .item = 0, .id = driver, .name = "pg.zig", .norm = "pg zig", .type = .software, .cosine = 0.84 },
            .{ .item = 0, .id = unrelated, .name = "zig", .norm = "zig", .type = .software, .cosine = 0.60 },
        } },
    };
    var linked = base;
    linked.resolution = .{ .entity_links = &.{.{ .ref = "n1", .existing = "E1" }}, .fact_verdicts = &.{} };
    const a = try linked.run();
    try testing.expectEqual(@as(usize, 0), a.cs.new_entities.len);
    try testing.expect(a.cs.mentions[0].eql(driver));
    try testing.expectEqual(@as(usize, 1), a.plan.entity_labels.len);

    var bogus = base;
    bogus.resolution = .{ .entity_links = &.{.{ .ref = "n1", .existing = "E9" }}, .fact_verdicts = &.{} };
    const b = try bogus.run();
    try testing.expectEqual(@as(usize, 1), b.cs.new_entities.len);

    const c = try base.run();
    try testing.expectEqual(@as(usize, 1), c.cs.new_entities.len);
}

test "one entry ends at most five existing facts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const subject = id(30);
    var facts: [7]resolve.CandidateFact = undefined;
    for (&facts, 0..) |*f, k| f.* = .{
        .item = 0,
        .id = id(@intCast(100 + k)),
        .subject_id = subject,
        .relation = "uses",
        .object_value = "old tool",
        .text = "old",
        .valid_lower = at("2026-11-01T00:00:00Z"),
        .confidence = 0.7,
        .cosine = 0.9,
    };
    var verdicts: [7]ingest.Contradiction = undefined;
    var labels: [7][2]u8 = undefined;
    for (&verdicts, 0..) |*v, k| {
        labels[k] = .{ 'F', @intCast('1' + k) };
        v.* = .{ .fact = &labels[k], .kind = .changed, .at = null };
    }
    const out = try (Scenario{
        .arena = arena,
        .reference_time = at("2026-11-22T00:00:00Z"),
        .body = "lantern now uses only the new tool",
        .raw = .{ .skip = null, .entities = &.{ent("n1", "lantern", .project)}, .facts = &.{fct("n1", "uses", null, "new tool", "lantern now uses only the new tool")}, .new_relations = &.{} },
        .prefetch = .{
            .entities = &.{.{ .item = 0, .id = subject, .name = "lantern", .norm = "lantern", .type = .project, .alias_match = true, .cosine = 1 }},
            .facts = &facts,
        },
        .resolution = .{ .entity_links = &.{}, .fact_verdicts = &.{.{ .fact_index = 0, .duplicate_of = null, .contradicts = &verdicts }} },
    }).run();
    try testing.expectEqual(@as(usize, 7), out.plan.facts[0].candidates.len);
    try testing.expectEqual(@as(usize, 5), out.cs.invalidations.len);
    var capped: usize = 0;
    for (out.cs.warnings) |w| if (std.mem.indexOf(u8, w, "more than 5") != null) {
        capped += 1;
    };
    try testing.expectEqual(@as(usize, 2), capped);
}

test "a new relation close to a known one collapses onto it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw: ingest.ExtractResult = .{
        .skip = null,
        .entities = &.{ ent("n1", "flaky test", .concept), ent("n2", "retry patch", .code) },
        .facts = &.{fct("n1", "resolved_by", "n2", null, "the flaky test was resolved by the retry patch")},
        .new_relations = &.{.{ .name = "resolved_by", .description = "Subject was resolved by the object.", .object_kind = .entity }},
    };
    const checked = try extract.check(arena, raw, "the flaky test was resolved by the retry patch", at("2026-11-22T00:00:00Z"));
    const prefetch: resolve.Prefetch = .{ .relations = &.{.{ .name = "fixed_by", .status = .core, .emb = &.{ 1, 0, 0 } }} };
    const novel = try resolve.novelRelations(arena, checked, prefetch);
    try testing.expectEqual(@as(usize, 1), novel.len);
    const p = try resolve.plan(arena, checked, prefetch);
    const cs = try resolve.build(arena, .{
        .entry = .{ .graph_id = graph, .reference_time = at("2026-11-22T00:00:00Z") },
        .commit_time = at("2026-11-22T00:00:01Z"),
        .io = testing.io,
    }, checked, prefetch, p, .{ .entities = &.{ &.{1}, &.{1} }, .facts = &.{&.{1}}, .relations = &.{&.{ 0.97, 0.1, 0 }} }, try resolve.Verdict.none(arena, p));
    try testing.expectEqualStrings("fixed_by", cs.new_facts[0].fact.relation);
    try testing.expectEqual(@as(usize, 1), cs.new_relations.len);
    try testing.expectEqualStrings("fixed_by", cs.new_relations[0].mapped_to.?);
}

test "decision-model probabilities become a verdict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lantern = id(30);
    const old = id(80);
    const raw: ingest.ExtractResult = .{ .skip = null, .entities = &.{ent("n1", "Lantern", .project)}, .facts = &.{fct("n1", "uses", null, "rust", "Lantern uses Rust, not Go")}, .new_relations = &.{} };
    const checked = try extract.check(arena, raw, "Lantern uses Rust, not Go", at("2026-11-21T09:00:00Z"));
    const prefetch: resolve.Prefetch = .{
        .entities = &.{.{ .item = 0, .id = lantern, .name = "Lantern", .norm = "lantern", .type = .project, .alias_match = true, .cosine = 1 }},
        .facts = &.{.{ .item = 0, .id = old, .subject_id = lantern, .relation = "uses", .object_value = "go", .text = "Lantern uses Go.", .valid_lower = at("2026-11-20T00:00:00Z"), .confidence = 0.7, .cosine = 0.8 }},
    };
    const p = try resolve.plan(arena, checked, prefetch);
    const q = try resolve.decisionQuestions(arena, p, checked, prefetch);
    try testing.expectEqual(@as(usize, 3), q.questions.len);
    const v = try resolve.verdictFromProbabilities(arena, p, q.questions, &.{ 0.1, 0.92, 0.85 }, .{});
    try testing.expect(v.duplicates[0] == null);
    try testing.expectEqual(@as(usize, 1), v.contradictions[0].len);
    try testing.expectEqual(ingest.ConflictKind.was_wrong, v.contradictions[0][0].kind);
    const v2 = try resolve.verdictFromProbabilities(arena, p, q.questions, &.{ 0.9, 0.95, 0.1 }, .{});
    try testing.expect(v2.duplicates[0].?.eql(old));
    try testing.expectEqual(@as(usize, 0), v2.contradictions[0].len);
}
