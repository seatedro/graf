const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");
const pg = @import("pg");
const ingest = @import("mod.zig");
const postgres = @import("postgres.zig");
const pipeline = @import("pipeline.zig");
const extract = @import("extract.zig");
const resolve = @import("resolve.zig");
const consolidate = @import("consolidate.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Id = core.Id;

fn vec(arena: Allocator, parts: []const struct { usize, f32 }) ![]f32 {
    const v = try arena.alloc(f32, store.embedding_dims);
    @memset(v, 0);
    for (parts) |p| v[p[0]] = p[1];
    return v;
}

const Seed = struct {
    s: *store.Store,
    conn: *pg.Conn,
    arena: Allocator,
    graph: Id,

    fn entity(seed: Seed, name: []const u8, ty: core.EntityType, emb: []const f32, description: []const u8) !Id {
        const id = Id.v7(seed.s.io);
        const norm = try core.text.norm(seed.arena, name);
        _ = try seed.conn.exec(
            \\INSERT INTO entity (id, graph_id, name, norm, type, description, name_emb, created_seq, updated_seq)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7::float4[]::vector(512)::halfvec(512), 1, 1)
        , .{ @as([]const u8, &id.bytes), @as([]const u8, &seed.graph.bytes), name, norm, @tagName(ty), description, emb });
        try seed.alias(id, name);
        return id;
    }

    fn alias(seed: Seed, id: Id, name: []const u8) !void {
        _ = try seed.conn.exec(
            \\INSERT INTO entity_alias (graph_id, norm, entity_id, alias) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING
        , .{ @as([]const u8, &seed.graph.bytes), try core.text.norm(seed.arena, name), @as([]const u8, &id.bytes), name });
    }

    fn fact(seed: Seed, subject: Id, relation: []const u8, object: ?Id, text: []const u8, project: []const u8) !Id {
        const id = Id.v7(seed.s.io);
        const obj: ?[]const u8 = if (object) |*o| &o.bytes else null;
        _ = try seed.conn.exec(
            \\INSERT INTO fact (id, graph_id, subject_id, relation, object_id, object_value, text, project, scope, valid, known,
            \\  author, confidence, emb, created_seq)
            \\VALUES ($1, $2, $3, $4, $5, CASE WHEN $5::uuid IS NULL THEN 'x' END, $6, $7, 'project', tstzrange(now(), NULL),
            \\  tstzrange(now(), NULL), 'user', 0.9, array_fill(0.1::real, ARRAY[512])::vector(512)::halfvec(512), 1)
        , .{ @as([]const u8, &id.bytes), @as([]const u8, &seed.graph.bytes), @as([]const u8, &subject.bytes), relation, obj, text, project });
        return id;
    }

    fn facts(seed: Seed, subject: Id, n: i32, project: []const u8) !void {
        _ = try seed.conn.exec(
            \\INSERT INTO fact (id, graph_id, subject_id, relation, object_value, text, project, scope, valid, known, author, confidence, emb, created_seq)
            \\SELECT gen_random_uuid(), $1, $2, 'uses', 'dep ' || n, 'uses dep ' || n, $4, 'project', tstzrange(now(), NULL), tstzrange(now(), NULL),
            \\  'user', 0.9, array_fill(0.1::real, ARRAY[512])::vector(512)::halfvec(512), 1
            \\FROM generate_series(1, $3::int) n
        , .{ @as([]const u8, &seed.graph.bytes), @as([]const u8, &subject.bytes), n, project });
    }

    fn duplicate(seed: Seed, a: Id, b: Id, score: f32) !void {
        _ = try seed.conn.exec(
            \\INSERT INTO possible_duplicate (id, graph_id, entity_a, entity_b, score) VALUES ($1, $2, $3, $4, $5)
        , .{ @as([]const u8, &Id.v7(seed.s.io).bytes), @as([]const u8, &seed.graph.bytes), @as([]const u8, &a.bytes), @as([]const u8, &b.bytes), score });
    }

    fn count(seed: Seed, sql: []const u8, args: anytype) !i64 {
        var row = (try seed.conn.row(sql, args)) orelse return error.NoRows;
        defer row.deinit() catch {};
        return row.get(i64, 0);
    }

    fn gid(seed: *const Seed) []const u8 {
        return &seed.graph.bytes;
    }

    fn mergedInto(seed: Seed, id: Id) !?Id {
        var row = (try seed.conn.row("SELECT merged_into FROM entity WHERE id = $1", .{@as([]const u8, &id.bytes)})) orelse return error.NoRows;
        defer row.deinit() catch {};
        const raw = try row.get(?[]const u8, 0) orelse return null;
        return try store.idFromPg(raw);
    }

    fn inventoryDrift(seed: Seed) !i64 {
        return seed.count(
            \\SELECT count(*) FROM entity e JOIN graph_entity_rank r ON r.id = e.id
            \\WHERE e.graph_id = $1 AND (r.live <> (e.merged_into IS NULL) OR r.degree <> (
            \\  SELECT count(*) FROM fact f WHERE f.graph_id = e.graph_id AND f.object_id IS NOT NULL AND (f.subject_id = e.id OR f.object_id = e.id)))
        , .{seed.gid()});
    }
};

const Judge = struct {
    const Rule = struct { []const u8, []const u8, f64 };

    rules: []const Rule,
    asked: usize = 0,
    prompts: std.ArrayList([]const u8) = .empty,

    pub fn decisionEnabled(_: *Judge) bool {
        return true;
    }

    pub fn decide(j: *Judge, arena: Allocator, req: llm.DecisionRequest) ![]const llm.Answer {
        const out = try arena.alloc(llm.Answer, req.questions.len);
        for (req.questions, out) |q, *a| {
            const prompt = q.yes_no;
            try j.prompts.append(arena, prompt);
            var p: f64 = 0.5;
            for (j.rules) |r| {
                if (std.mem.indexOf(u8, prompt, r[0]) != null and std.mem.indexOf(u8, prompt, r[1]) != null) p = r[2];
            }
            a.* = .{ .yes_no = p };
        }

        j.asked += req.questions.len;
        return out;
    }

    pub fn structured(_: *Judge, _: Allocator, _: llm.StructuredRequest) !pipeline.Completion {
        return error.Unexpected;
    }
};

fn find(r: consolidate.Report, a: []const u8, b: []const u8) ?consolidate.Decision {
    for (r.decisions) |d| {
        const x = d.candidate.a.name;
        const y = d.candidate.b.name;
        if ((std.mem.eql(u8, x, a) and std.mem.eql(u8, y, b)) or (std.mem.eql(u8, x, b) and std.mem.eql(u8, y, a))) return d;
    }
    return null;
}

test "prefetch surfaces first names and project phrasings that name-only cosine misses, and keeps numbered siblings apart" {
    var s = try store.testing.openWith(.{ .pool_size = 4 });
    defer s.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const conn = try s.pool.acquire();
    defer conn.release();
    const seed: Seed = .{ .s = &s, .conn = conn, .arena = arena, .graph = try store.testing.freshGraph(&s) };

    const relay = try seed.entity("brinelog relay", .software, try vec(arena, &.{.{ 9, 1 }}), "");
    const hollis = try seed.entity("Maren Hollis", .person, try vec(arena, &.{ .{ 0, 0.44 }, .{ 1, 0.898 } }), "Engineer on the brinelog relay.");
    try seed.alias(hollis, "M. Hollis");
    try seed.alias(hollis, "Maren");
    _ = try seed.fact(hollis, "owns", relay, "Maren Hollis owns the brinelog relay.", "brinelog");
    const slots = try seed.entity("quay slot ordering research", .project, try vec(arena, &.{.{ 2, 1 }}), "Research on berth slot ordering.");
    const phase = try seed.entity("Mooring Phase 1", .project, try vec(arena, &.{.{ 4, 1 }}), "First rollout phase of Mooring.");

    const raw: ingest.ExtractResult = .{
        .skip = null,
        .entities = &.{
            .{ .ref = "n1", .name = "maren", .type = .person, .aliases = &.{}, .description = "Engineer." },
            .{ .ref = "n2", .name = "maren-brackwater", .type = .person, .aliases = &.{}, .description = "Engineer." },
            .{ .ref = "n3", .name = "quay slot order research", .type = .project, .aliases = &.{}, .description = "" },
            .{ .ref = "n4", .name = "Mooring Phase 2", .type = .project, .aliases = &.{}, .description = "" },
        },
        .facts = &.{},
        .new_relations = &.{},
    };
    const checked = try extract.check(arena, raw, "maren and maren-brackwater discussed the slot order research and Mooring Phase 2", 0);

    const embs = [_][]const f32{
        try vec(arena, &.{.{ 0, 1 }}),
        try vec(arena, &.{.{ 0, 1 }}),
        try vec(arena, &.{ .{ 2, 0.72 }, .{ 3, 0.694 } }),
        try vec(arena, &.{ .{ 4, 0.99 }, .{ 5, 0.141 } }),
    };
    var req: pipeline.PrefetchRequest = .{
        .project = "quayline",
        .entity_types = &.{ .person, .person, .project, .project },
        .entity_norms = &.{ &.{"maren"}, &.{"maren brackwater"}, &.{"quay slot order research"}, &.{"mooring phase 2"} },
        .entity_embs = &embs,
        .fact_subject = &.{},
        .fact_object = &.{},
        .fact_relations = &.{},
        .fact_opposed = &.{},
        .fact_embs = &.{},
        .fact_texts = &.{},
    };

    var b: postgres.PgBackend = .{ .store = &s, .graph_id = seed.graph, .io = s.io };
    const pre = try b.prefetch(arena, req);
    const p = try resolve.plan(arena, checked, pre);

    try testing.expectEqual(resolve.EntityDecision.new, p.entities[0].decision);
    const cand = resolve.findEntity(pre, hollis).?;
    try testing.expect(cand.cosine < 0.5);
    try testing.expectEqualStrings("Engineer on the brinelog relay.", cand.description);
    try testing.expectEqualStrings("M. Hollis", cand.aliases[0]);
    try testing.expectEqualStrings("maren", cand.via[0]);
    try testing.expectEqualStrings("Maren Hollis owns the brinelog relay.", cand.facts[0]);
    try testing.expect(!cand.shares_project);

    try testing.expectEqual(resolve.EntityDecision.new, p.entities[1].decision);
    try testing.expectEqual(resolve.EntityDecision.ask, p.entities[2].decision);
    try testing.expect(p.entities[2].gray[0].eql(slots));
    try testing.expectEqual(resolve.EntityDecision.new, p.entities[3].decision);
    for (pre.entities) |c| if (c.item == 3 and c.id.eql(phase)) try testing.expect(c.cosine > 0.95);

    req.project = "brinelog";
    const same_team = try b.prefetch(arena, req);
    const p2 = try resolve.plan(arena, checked, same_team);
    try testing.expect(resolve.findEntity(same_team, hollis).?.shares_project);
    for (p2.entities[0..2]) |e| {
        try testing.expectEqual(resolve.EntityDecision.ask, e.decision);
        try testing.expect(e.gray[0].eql(hollis));
    }

    const q = try resolve.decisionQuestions(arena, p2, checked, same_team);
    try testing.expect(std.mem.indexOf(u8, q.asks[0].choice.prompt, "share a first name") != null);
    try testing.expect(std.mem.indexOf(u8, q.asks[0].choice.options[0].description, "known facts: Maren Hollis owns the brinelog relay.; active in this entry's project") != null);
}

test "consolidate previews without writing, then merges, keeps apart, and never re-asks a decided pair" {
    var s = try store.testing.openWith(.{ .pool_size = 4 });
    defer s.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const conn = try s.pool.acquire();
    defer conn.release();
    const seed: Seed = .{ .s = &s, .conn = conn, .arena = arena, .graph = try store.testing.freshGraph(&s) };

    const relay = try seed.entity("brinelog relay", .software, try vec(arena, &.{.{ 9, 1 }}), "");
    const maren = try seed.entity("maren", .person, try vec(arena, &.{.{ 0, 1 }}), "Engineer.");
    const hollis = try seed.entity("Maren Hollis", .person, try vec(arena, &.{ .{ 0, 0.44 }, .{ 1, 0.898 } }), "Engineer on the brinelog relay.");
    const okafor = try seed.entity("Maren Okafor", .person, try vec(arena, &.{ .{ 0, 0.5 }, .{ 6, 0.866 } }), "Designer.");
    _ = try seed.fact(maren, "works_on", relay, "maren works on the brinelog relay.", "brinelog");
    _ = try seed.fact(hollis, "owns", relay, "Maren Hollis owns the brinelog relay.", "brinelog");
    try seed.facts(hollis, 2, "brinelog");
    try seed.facts(okafor, 1, "quayline");

    const ordering = try seed.entity("quay slot ordering research", .project, try vec(arena, &.{.{ 2, 1 }}), "");
    const order = try seed.entity("quay slot order research", .project, try vec(arena, &.{ .{ 2, 0.72 }, .{ 3, 0.694 } }), "");
    try seed.facts(ordering, 3, "tide");
    try seed.facts(order, 1, "tide");
    try seed.duplicate(order, ordering, 0.85);

    const phase1 = try seed.entity("Mooring Phase 1", .project, try vec(arena, &.{.{ 4, 1 }}), "");
    const phase2 = try seed.entity("Mooring Phase 2", .project, try vec(arena, &.{ .{ 4, 0.99 }, .{ 5, 0.141 } }), "");
    try seed.duplicate(phase1, phase2, 0.97);

    const ops = try seed.entity("Harbor Ops", .organization, try vec(arena, &.{.{ 7, 1 }}), "");
    const operations = try seed.entity("Harbor Operations", .organization, try vec(arena, &.{ .{ 7, 0.95 }, .{ 8, 0.312 } }), "");
    try seed.facts(ops, store.max_merge_facts + 1, "harbor");
    try seed.facts(operations, store.max_merge_facts + 1, "harbor");
    try seed.duplicate(ops, operations, 0.9);

    var judge: Judge = .{ .rules = &.{
        .{ "\"maren\" (person)", "\"Maren Hollis\" (person)", 0.94 },
        .{ "\"maren\" (person)", "\"Maren Okafor\" (person)", 0.04 },
        .{ "\"quay slot ordering research\"", "\"quay slot order research\"", 0.91 },
        .{ "\"Harbor Ops\"", "\"Harbor Operations\"", 0.93 },
    } };

    const preview = try consolidate.run(Judge, arena, &s, &judge, seed.graph, .{ .dry_run = true });
    const merge = find(preview, "maren", "Maren Hollis").?;
    try testing.expectEqual(consolidate.Action.merge, merge.action);
    try testing.expect(merge.from.?.id.eql(maren) and merge.into.?.id.eql(hollis));
    try testing.expectEqualStrings("brinelog relay", merge.overlap.shared_neighbors[0]);
    try testing.expectEqualStrings("brinelog", merge.overlap.shared_projects[0]);

    const variant = find(preview, "quay slot ordering research", "quay slot order research").?;
    try testing.expectEqual(consolidate.Action.merge, variant.action);
    try testing.expect(variant.from.?.id.eql(order));
    try testing.expectEqual(consolidate.Action.keep_apart, find(preview, "maren", "Maren Okafor").?.action);
    try testing.expectEqual(consolidate.Action.unsure, find(preview, "Maren Hollis", "Maren Okafor").?.action);
    try testing.expectEqual(consolidate.Action.incompatible, find(preview, "Mooring Phase 1", "Mooring Phase 2").?.action);
    try testing.expectEqual(consolidate.Action.too_large, find(preview, "Harbor Ops", "Harbor Operations").?.action);
    try testing.expectEqual(@as(usize, 5), judge.asked);
    for (judge.prompts.items) |prompt| try testing.expect(std.mem.indexOf(u8, prompt, "Mooring") == null);

    try testing.expectEqual(@as(i64, 0), try seed.count("SELECT count(*) FROM entity WHERE graph_id = $1 AND merged_into IS NOT NULL", .{seed.gid()}));
    try testing.expectEqual(@as(i64, 3), try seed.count("SELECT count(*) FROM possible_duplicate WHERE graph_id = $1 AND status = 'open'", .{seed.gid()}));
    try testing.expectEqual(@as(i64, 0), try seed.count("SELECT count(*) FROM must_not_merge WHERE graph_id = $1", .{seed.gid()}));
    try testing.expectEqual(@as(i64, 0), try seed.count("SELECT count(*) FROM merge_log WHERE graph_id = $1", .{seed.gid()}));
    try testing.expectEqual(@as(i64, 0), try seed.count("SELECT count(*) FROM commit_log WHERE graph_id = $1", .{seed.gid()}));

    const applied = try consolidate.run(Judge, arena, &s, &judge, seed.graph, .{});
    try testing.expectEqual(@as(usize, 2), applied.count(.merge));
    try testing.expect((try seed.mergedInto(maren)).?.eql(hollis));
    try testing.expect((try seed.mergedInto(order)).?.eql(ordering));
    try testing.expect(try seed.mergedInto(ops) == null and try seed.mergedInto(operations) == null);
    try testing.expect(try seed.mergedInto(phase1) == null and try seed.mergedInto(phase2) == null);

    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM must_not_merge WHERE graph_id = $1 AND entity_a = least($2::uuid, $3::uuid) AND entity_b = greatest($2::uuid, $3::uuid)", .{ seed.gid(), @as([]const u8, &maren.bytes), @as([]const u8, &okafor.bytes) }));
    try testing.expectEqual(@as(i64, 0), try seed.count("SELECT count(*) FROM possible_duplicate WHERE graph_id = $1 AND status = 'open'", .{seed.gid()}));
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM possible_duplicate WHERE graph_id = $1 AND status = 'merged' AND entity_a = $2", .{ seed.gid(), @as([]const u8, &order.bytes) }));
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM possible_duplicate WHERE graph_id = $1 AND status = 'rejected' AND entity_a = $2", .{ seed.gid(), @as([]const u8, &phase1.bytes) }));
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM possible_duplicate WHERE graph_id = $1 AND status = 'too_large'", .{seed.gid()}));
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM possible_duplicate WHERE graph_id = $1 AND status = 'unsure'", .{seed.gid()}));
    try testing.expectEqual(@as(i64, 2), try seed.count("SELECT count(*) FROM merge_log WHERE graph_id = $1 AND subject_facts IS NOT NULL", .{seed.gid()}));
    try testing.expectEqual(@as(i64, 2), try seed.count("SELECT count(*) FROM commit_log WHERE graph_id = $1 AND entry_id IS NULL", .{seed.gid()}));
    try testing.expectEqual(@as(i64, 0), try seed.inventoryDrift());
    try testing.expectEqual(@as(i64, 2), try seed.count("SELECT degree FROM graph_entity_rank WHERE id = $1", .{@as([]const u8, &relay.bytes)}));

    const asked = judge.asked;
    const again = try consolidate.run(Judge, arena, &s, &judge, seed.graph, .{});
    try testing.expectEqual(@as(usize, 0), again.candidates);
    try testing.expectEqual(asked, judge.asked);
}

test "graf merge and unmerge round-trip facts, aliases and inventories, and keep the pair apart" {
    var s = try store.testing.openWith(.{ .pool_size = 4 });
    defer s.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const conn = try s.pool.acquire();
    defer conn.release();
    const seed: Seed = .{ .s = &s, .conn = conn, .arena = arena, .graph = try store.testing.freshGraph(&s) };

    const kestrel = try seed.entity("kestrel", .software, try vec(arena, &.{.{ 0, 1 }}), "");
    const cli = try seed.entity("Kestrel CLI", .software, try vec(arena, &.{.{ 1, 1 }}), "");
    const relay = try seed.entity("relay", .software, try vec(arena, &.{.{ 2, 1 }}), "");
    const juno = try seed.entity("Juno", .person, try vec(arena, &.{.{ 3, 1 }}), "");
    try seed.alias(cli, "kcli");
    const uses = try seed.fact(cli, "uses", relay, "Kestrel CLI uses relay.", "brinelog");
    const needs = try seed.fact(relay, "depends_on", cli, "relay depends on Kestrel CLI.", "brinelog");
    try seed.facts(kestrel, 3, "brinelog");

    const from = (try consolidate.lookup(arena, conn, seed.graph, "kestrel cli")).found;
    const into = (try consolidate.lookup(arena, conn, seed.graph, "kestrel")).found;
    try testing.expect(from.id.eql(cli) and into.id.eql(kestrel));
    try testing.expect((try consolidate.lookup(arena, conn, seed.graph, "kcli")).found.id.eql(cli));
    try testing.expectEqual(consolidate.Lookup.missing, try consolidate.lookup(arena, conn, seed.graph, "osprey"));
    try testing.expectError(error.IncompatibleTypes, consolidate.mergeManual(&s, seed.graph, (try consolidate.lookup(arena, conn, seed.graph, "Juno")).found, into, "x", .{}));
    _ = juno;

    const preview = (try consolidate.mergeManual(&s, seed.graph, from, into, "same tool", .{ .dry_run = true })).merged;
    try testing.expectEqual(@as(usize, 2), preview.moved_facts);
    try testing.expect(try seed.mergedInto(cli) == null);

    const merged = (try consolidate.mergeManual(&s, seed.graph, from, into, "same tool", .{})).merged;
    try testing.expect((try seed.mergedInto(cli)).?.eql(kestrel));
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM fact WHERE id = $1 AND subject_id = $2", .{ @as([]const u8, &uses.bytes), @as([]const u8, &kestrel.bytes) }));
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM fact WHERE id = $1 AND object_id = $2", .{ @as([]const u8, &needs.bytes), @as([]const u8, &kestrel.bytes) }));
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM entity_alias WHERE entity_id = $1 AND norm = 'kcli'", .{@as([]const u8, &kestrel.bytes)}));
    try testing.expectEqual(@as(i64, 0), try seed.inventoryDrift());

    const found = try consolidate.findMerge(arena, conn, seed.graph, "Kestrel CLI");
    try testing.expect(found.eql(merged.log_id));

    const undone = try s.unmerge(seed.graph, found, "different tools", false);
    try testing.expectEqual(@as(usize, 2), undone.restored_facts);
    try testing.expect(try seed.mergedInto(cli) == null);
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM fact WHERE id = $1 AND subject_id = $2 AND object_id = $3", .{ @as([]const u8, &uses.bytes), @as([]const u8, &cli.bytes), @as([]const u8, &relay.bytes) }));
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM fact WHERE id = $1 AND subject_id = $2 AND object_id = $3", .{ @as([]const u8, &needs.bytes), @as([]const u8, &relay.bytes), @as([]const u8, &cli.bytes) }));
    try testing.expectEqual(@as(i64, 3), try seed.count("SELECT count(*) FROM fact WHERE subject_id = $1", .{@as([]const u8, &kestrel.bytes)}));
    try testing.expectEqual(@as(i64, 0), try seed.count("SELECT count(*) FROM entity_alias WHERE entity_id = $1 AND norm IN ('kcli', 'kestrel cli')", .{@as([]const u8, &kestrel.bytes)}));
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM must_not_merge WHERE graph_id = $1", .{seed.gid()}));
    try testing.expectEqual(@as(i64, 1), try seed.count("SELECT count(*) FROM merge_log WHERE id = $1 AND undone_seq IS NOT NULL", .{@as([]const u8, &found.bytes)}));
    try testing.expectEqual(@as(i64, 0), try seed.inventoryDrift());
    try testing.expectEqual(@as(i64, 2), try seed.count("SELECT degree FROM graph_entity_rank WHERE id = $1", .{@as([]const u8, &cli.bytes)}));

    try testing.expectError(error.AlreadyUndone, s.unmerge(seed.graph, found, "again", false));
    try testing.expectError(error.MergeNotFound, consolidate.findMerge(arena, conn, seed.graph, "Kestrel CLI"));
    try testing.expectEqual(store.merging.Skip.blocked, (try consolidate.mergeManual(&s, seed.graph, from, into, "again", .{})).skipped);
    try testing.expect((try consolidate.mergeManual(&s, seed.graph, from, into, "operator override", .{ .force = true })) == .merged);
}

test "consolidate candidates gate on type, markers and first names" {
    const side = struct {
        fn of(name: []const u8, norm: []const u8, ty: core.EntityType) consolidate.Side {
            return .{ .id = .nil, .name = name, .norm = norm, .type = ty };
        }
    }.of;

    try testing.expect(consolidate.worthAsking(.{ .a = side("maren", "maren", .person), .b = side("Maren Hollis", "maren hollis", .person), .cosine = 0.44 }));
    try testing.expect(!consolidate.worthAsking(.{ .a = side("Juno", "juno", .person), .b = side("Maren Juno", "maren juno", .person), .cosine = 0.70 }));
    try testing.expect(!consolidate.worthAsking(.{ .a = side("Lane B", "lane b", .task), .b = side("Lane D", "lane d", .task), .cosine = 0.95, .lexical = 0.6 }));
    try testing.expect(!consolidate.worthAsking(.{ .a = side("TICKET-1", "ticket 1", .task), .b = side("TICKET-2", "ticket 2", .task), .cosine = 0.98, .lexical = 0.7 }));
    try testing.expect(!consolidate.worthAsking(.{ .a = side("Mooring", "mooring", .organization), .b = side("Mooring", "mooring", .software), .cosine = 1, .lexical = 1 }));
    try testing.expect(consolidate.worthAsking(.{ .a = side("Slot Ordering", "slot ordering", .project), .b = side("slot order review", "slot order review", .project), .cosine = 0.70, .lexical = 0.52 }));
    try testing.expect(!consolidate.worthAsking(.{ .a = side("Brinelog", "brinelog", .project), .b = side("Quayline", "quayline", .project), .cosine = 0.70, .lexical = 0.1 }));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const types = try consolidate.parseTypes(arena_state.allocator(), "person, project");
    try testing.expectEqual(@as(usize, 2), types.len);
    try testing.expectError(error.UnknownEntityType, consolidate.parseTypes(arena_state.allocator(), "people"));
}
