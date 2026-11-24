const std = @import("std");
const core = @import("core");
const pg = @import("pg");
const store = @import("mod.zig");

const Store = store.Store;
const Id = core.Id;
const testing = std.testing;

fn emb(seed: u64) [store.embedding_dims]f32 {
    var out: [store.embedding_dims]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(seed);
    for (&out) |*v| v.* = prng.random().float(f32) - 0.5;
    return out;
}

fn note(source: []const u8, text: []const u8, t: i64) core.EntryDraft {
    return .{
        .source = .{ .harness = .cli, .external_id = source, .project = "example.test/graf" },
        .kind = .note,
        .project = "example.test/graf",
        .author = .user,
        .body = .{ .text = text },
        .reference_time = t,
    };
}

fn enqueueNew(s: *Store, g: Id, draft: core.EntryDraft) !Id {
    return switch (try s.enqueue(g, &draft)) {
        .queued => |id| id,
        .duplicate => error.UnexpectedDuplicate,
    };
}

fn status(s: *Store, id: Id) ![]const u8 {
    var row = (try s.pool.row("SELECT status FROM entry WHERE id = $1", .{@as([]const u8, &id.bytes)})).?;
    defer row.deinit() catch {};
    const st = std.meta.stringToEnum(core.types.EntryStatus, try row.get([]const u8, 0)) orelse return error.UnknownStatus;
    return @tagName(st);
}

fn scalarI64(s: *Store, sql: []const u8, args: anytype) !i64 {
    var row = (try s.pool.row(sql, args)).?;
    defer row.deinit() catch {};
    return row.get(i64, 0);
}

fn claimAfterLeaseExpires(s: *Store, arena: std.mem.Allocator, g: Id, worker: []const u8) !store.Lease {
    for (0..100) |_| {
        if (try s.claim(arena, g, worker)) |lease| return lease;
        try s.io.sleep(.fromMilliseconds(20), .awake);
    }
    return error.LeaseNeverExpired;
}

fn stage(s: *Store, lease: store.Lease, cs: *const core.ChangeSet) !void {
    try s.saveExtraction(lease, "{\"skip\":null,\"entities\":[],\"facts\":[],\"new_relations\":[]}");
    try s.saveChangeSet(lease, cs);
}

fn entity(s: *Store, name: []const u8, ty: core.EntityType) core.ChangeSet.NewEntity {
    return .{ .id = Id.v7(s.io), .name = name, .norm = name, .type = ty };
}

fn newFact(s: *Store, g: Id, subject: Id, relation: []const u8, object: core.types.FactObject, text: []const u8, valid_from: i64, e: []const f32) core.ChangeSet.NewFact {
    return .{
        .fact = .{
            .id = Id.v7(s.io),
            .graph_id = g,
            .subject_id = subject,
            .relation = relation,
            .object = object,
            .text = text,
            .project = "example.test/graf",
            .scope = .project,
            .valid = .{ .lower = valid_from },
            .known = .{},
            .author = .user,
            .confidence = 0.9,
        },
        .emb = e,
    };
}

const day: i64 = 86_400 * std.time.us_per_s;

test "ensureGraph is idempotent and seeds the core relations once" {
    var s = try store.testing.open();
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    var name_buf: [64]u8 = undefined;
    var row = (try s.pool.row("SELECT name FROM graph WHERE id = $1", .{@as([]const u8, &g.bytes)})).?;
    const name = try std.fmt.bufPrint(&name_buf, "{s}", .{try row.get([]const u8, 0)});
    try row.deinit();
    try testing.expect(g.eql(try s.ensureGraph(name)));
    const n = try scalarI64(&s, "SELECT count(*) FROM relation WHERE graph_id = $1 AND status = 'core'", .{@as([]const u8, &g.bytes)});
    try testing.expectEqual(@as(i64, core.ontology.core_relations.len), n);
    const opposed = try scalarI64(&s, "SELECT count(*) FROM relation WHERE graph_id = $1 AND name = 'chose' AND opposes = 'rejected'", .{@as([]const u8, &g.bytes)});
    try testing.expectEqual(@as(i64, 1), opposed);
}

test "enqueue redacts the entry before hashing and storing it" {
    var s = try store.testing.open();
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    const secret = "sk-proj-Q7f2LmN9pR4sT8vW1xY5zA3bC6dE0gH2jK4mN7pQ";
    const raw = note("sess-redact", "the key is " ++ secret, 1_000);
    const id = try enqueueNew(&s, g, raw);

    var row = (try s.pool.row("SELECT body::text FROM entry WHERE id = $1", .{@as([]const u8, &id.bytes)})).?;
    defer row.deinit() catch {};
    try testing.expect(std.mem.indexOf(u8, try row.get([]const u8, 0), secret) == null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const redacted = try core.redactDraft(arena.allocator(), raw);
    try testing.expect(try s.enqueue(g, &redacted) == .duplicate);
}

test "enqueue dedupes on content, advances the cursor, numbers the source and notifies" {
    var s = try store.testing.open();
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    var gbuf: [36]u8 = undefined;

    var listener = try s.pool.newListener();
    defer listener.deinit();
    try listener.listen("graf_queue", .{});

    var draft = note("sess-1", "graf uses Postgres 17", 1_000);
    draft.cursor = "120";
    const sink = s.sink(g);
    const first = try sink.enqueue(&draft);
    try testing.expect(first == .queued);

    try testing.expectEqualStrings(g.toString(&gbuf), try store.testing.nextNotification(&listener, "graf_queue"));

    draft.cursor = "240";
    draft.reference_time = 2_000;
    try testing.expect(try sink.enqueue(&draft) == .duplicate);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cursor = try sink.loadCursor(arena.allocator(), &draft.source.?);
    try testing.expectEqualStrings("240", cursor.?);
    const unknown: core.SourceKey = .{ .harness = .codex, .external_id = "nope" };
    try testing.expect(try sink.loadCursor(arena.allocator(), &unknown) == null);

    const second = try enqueueNew(&s, g, note("sess-1", "graf pins Zig 0.17.1", 3_000));
    const seq = try scalarI64(&s, "SELECT seq_in_source::int8 FROM entry WHERE id = $1", .{@as([]const u8, &second.bytes)});
    try testing.expectEqual(@as(i64, 2), seq);
    const total = try scalarI64(&s, "SELECT count(*) FROM entry WHERE graph_id = $1", .{@as([]const u8, &g.bytes)});
    try testing.expectEqual(@as(i64, 2), total);
}

test "claim serializes each source, runs sources concurrently, and returns the body" {
    var s = try store.testing.open();
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const a1 = try enqueueNew(&s, g, note("A", "first in A", 1_000));
    const a2 = try enqueueNew(&s, g, note("A", "second in A", 2_000));
    const b1 = try enqueueNew(&s, g, note("B", "first in B", 3_000));

    const l1 = (try s.claim(a, g, "w1")).?;
    try testing.expect(l1.entry_id.eql(a1));
    try testing.expectEqualStrings("first in A", l1.entry.body.text.?);
    try testing.expectEqual(core.types.EntryStatus.extracting, l1.entry.status);
    try testing.expectEqual(@as(i32, 1), l1.entry.attempts);
    try testing.expect(l1.extraction_json == null);

    const l2 = (try s.claim(a, g, "w2")).?;
    try testing.expect(l2.entry_id.eql(b1));
    try testing.expect(l2.token > l1.token);
    try testing.expect(try s.claim(a, g, "w3") == null);

    try stage(&s, l1, &.{ .base_seq = 0 });
    try testing.expect(try s.claim(a, g, "w3") == null);
    try testing.expect(try s.commit(l1, &.{ .base_seq = 0 }, null) == .committed);

    const l3 = (try s.claim(a, g, "w3")).?;
    try testing.expect(l3.entry_id.eql(a2));
}

test "a lost lease is reclaimed without repeating the extraction and fences the old worker" {
    var s = try store.testing.openWith(.{ .pool_size = 3, .lease_ms = 150 });
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entry_id = try enqueueNew(&s, g, note("crash", "graf uses pg.zig", 1_000));
    const old = (try s.claim(a, g, "old")).?;
    try testing.expect(try s.claim(a, g, "other") == null);

    const retry = try claimAfterLeaseExpires(&s, a, g, "retry");
    try testing.expect(retry.entry_id.eql(entry_id));
    try testing.expectEqual(@as(i32, 2), retry.entry.attempts);
    try testing.expectError(error.LeaseLost, s.saveExtraction(old, "{}"));
    try s.saveExtraction(retry, "{\"facts\":[1]}");

    const resumed = try claimAfterLeaseExpires(&s, a, g, "resumed");
    try testing.expectEqual(core.types.EntryStatus.extracted, resumed.entry.status);
    try testing.expectEqual(@as(i32, 2), resumed.entry.attempts);
    try testing.expectEqualStrings("{\"facts\": [1]}", resumed.extraction_json.?);
    try testing.expectError(error.LeaseLost, s.heartbeat(retry));
    try s.heartbeat(resumed);

    try s.saveChangeSet(resumed, &.{ .base_seq = 0 });
    try testing.expectError(error.LeaseLost, s.saveChangeSet(retry, &.{ .base_seq = 0 }));
    try testing.expect(try s.commit(retry, &.{ .base_seq = 0 }, null) == .fenced);
    try testing.expectEqualStrings("staged", try status(&s, entry_id));
    const res = try s.commit(resumed, &.{ .base_seq = 0 }, null);
    try testing.expectEqual(@as(i64, 1), res.committed.seq);
    try testing.expect(try s.commit(resumed, &.{ .base_seq = 0 }, null) == .fenced);
    try testing.expectEqualStrings("committed", try status(&s, entry_id));
}

test "commit applies entities, aliases, facts, merges, invalidations, retractions and the logs" {
    var s = try store.testing.open();
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    const gid: []const u8 = &g.bytes;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t0: i64 = 1_763_000_000_000_000;

    var graf = entity(&s, "graf", .project);
    const graf_emb = emb(1);
    graf.name_emb = &graf_emb;
    var pgzig = entity(&s, "pg.zig", .software);
    pgzig.norm = "pg zig";
    pgzig.aliases = &.{ "pg-zig", "karlseguin's driver" };
    const dup = entity(&s, "pgzig driver", .software);
    const hollis = entity(&s, "Hollis", .person);

    const e1 = emb(2);
    const e2 = emb(3);
    const e3 = emb(4);
    const uses = newFact(&s, g, graf.id, "uses", .{ .entity = pgzig.id }, "graf uses pg.zig.", t0, &e1);
    const lacks = newFact(&s, g, dup.id, "lacks_feature", .{ .value = "COPY" }, "pg.zig lacks COPY.", t0, &e2);
    const oncall = newFact(&s, g, graf.id, "has_oncall", .{ .entity = hollis.id }, "Hollis is on call for graf.", t0, &e3);

    const en1 = try enqueueNew(&s, g, note("commit", "entry one", t0));
    const l1 = (try s.claim(a, g, "w")).?;
    try testing.expect(l1.entry_id.eql(en1));
    const cs1: core.ChangeSet = .{
        .base_seq = 0,
        .new_entities = &.{ graf, pgzig, dup, hollis },
        .new_facts = &.{ uses, lacks, oncall },
        .evidence = &.{ .{ .fact_id = uses.fact.id, .kind = .stated, .quote = "we use pg.zig" }, .{ .fact_id = lacks.fact.id, .kind = .stated } },
        .mentions = &.{ graf.id, pgzig.id },
        .new_relations = &.{.{ .name = "benchmarked_on", .description = "Subject was benchmarked on the object." }},
    };
    try stage(&s, l1, &cs1);
    try testing.expectEqual(@as(i64, 1), (try s.commit(l1, &cs1, null)).committed.seq);

    const aliases = try scalarI64(&s, "SELECT count(*) FROM entity_alias WHERE entity_id = $1 AND norm IN ('pg zig', 'karlseguin s driver')", .{@as([]const u8, &pgzig.id.bytes)});
    try testing.expectEqual(@as(i64, 2), aliases);
    const with_emb = try scalarI64(&s, "SELECT count(*) FROM entity WHERE graph_id = $1 AND name_emb IS NOT NULL", .{gid});
    try testing.expectEqual(@as(i64, 1), with_emb);
    try testing.expectEqual(@as(i64, 1), try scalarI64(&s, "SELECT count(*) FROM relation WHERE graph_id = $1 AND name = 'benchmarked_on' AND status = 'proposed'", .{gid}));
    try testing.expectEqual(@as(i64, 2), try scalarI64(&s, "SELECT count(*) FROM entity_mention WHERE entry_id = $1", .{@as([]const u8, &en1.bytes)}));
    {
        var row = (try s.pool.row(
            "SELECT emb::float4[], lower(valid), upper_inf(valid), upper_inf(known), object_id IS NOT NULL FROM fact WHERE id = $1",
            .{@as([]const u8, &uses.fact.id.bytes)},
        )).?;
        defer row.deinit() catch {};
        var it = try row.get(pg.Iterator(f32), 0);
        var i: usize = 0;
        while (it.next()) |v| : (i += 1) try testing.expectApproxEqAbs(e1[i], v, 1e-3);
        try testing.expectEqual(@as(usize, 512), i);
        try testing.expectEqual(t0, try row.get(i64, 1));
        try testing.expect(try row.get(bool, 2));
        try testing.expect(try row.get(bool, 3));
        try testing.expect(try row.get(bool, 4));
    }

    var commits = try s.pool.newListener();
    defer commits.deinit();
    try commits.listen("graf_commit", .{});

    const juno = entity(&s, "Juno", .person);
    const e4 = emb(5);
    const e5 = emb(6);
    const handoff = newFact(&s, g, graf.id, "has_oncall", .{ .entity = juno.id }, "Juno is on call for graf.", t0 + day, &e4);
    const supports = newFact(&s, g, pgzig.id, "supports_feature", .{ .value = "COPY" }, "pg.zig supports COPY.", t0 + day, &e5);
    const en2 = try enqueueNew(&s, g, note("commit", "entry two", t0 + day));
    const l2 = (try s.claim(a, g, "w")).?;
    try testing.expect(l2.entry_id.eql(en2));
    const cs2: core.ChangeSet = .{
        .base_seq = 1,
        .new_entities = &.{juno},
        .merges = &.{.{ .from = dup.id, .into = pgzig.id, .reason = "E2 high similarity" }},
        .new_facts = &.{ handoff, supports },
        .restatements = &.{.{ .fact_id = uses.fact.id, .confidence = 0.93 }},
        .invalidations = &.{
            .{ .fact_id = oncall.fact.id, .valid_upper = t0 + day, .ended_by = handoff.fact.id },
            .{ .fact_id = uses.fact.id, .valid_upper = t0 - day, .ended_by = null },
        },
        .retractions = &.{.{ .fact_id = lacks.fact.id, .end_kind = .retracted, .ended_by = supports.fact.id }},
        .evidence = &.{.{ .fact_id = uses.fact.id, .kind = .restated }},
        .warnings = &.{"from the pipeline"},
    };
    try s.recordCall(&.{ .id = Id.v7(s.io), .graph_id = g, .entry_id = en2, .purpose = .extract, .route = "openai-responses", .model = "example-model", .attempt = 1, .ok = true, .cost_usd = 0.0042, .cost_status = .priced, .latency_ms = 900, .started_at = core.time.now(s.io) });
    try stage(&s, l2, &cs2);
    try testing.expectEqual(@as(i64, 2), (try s.commit(l2, &cs2, null)).committed.seq);

    const Payload = struct { graph_id: []const u8, seq: i64, project: ?[]const u8 };
    const payload = try std.json.parseFromSliceLeaky(Payload, a, try store.testing.nextNotification(&commits, "graf_commit"), .{ .allocate = .alloc_always });
    var gbuf: [36]u8 = undefined;
    try testing.expectEqualStrings(g.toString(&gbuf), payload.graph_id);
    try testing.expectEqual(@as(i64, 2), payload.seq);
    try testing.expectEqualStrings("example.test/graf", payload.project.?);

    {
        var row = (try s.pool.row("SELECT merged_into FROM entity WHERE id = $1", .{@as([]const u8, &dup.id.bytes)})).?;
        defer row.deinit() catch {};
        try testing.expect(pgzig.id.eql(try store.idFromPg(try row.get([]const u8, 0))));
    }
    try testing.expectEqual(@as(i64, 2), try scalarI64(&s, "SELECT count(*) FROM fact WHERE subject_id = $1", .{@as([]const u8, &pgzig.id.bytes)}));
    try testing.expectEqual(@as(i64, 1), try scalarI64(&s, "SELECT count(*) FROM entity_alias WHERE entity_id = $1 AND norm = 'pgzig driver'", .{@as([]const u8, &pgzig.id.bytes)}));
    try testing.expectEqual(@as(i64, 1), try scalarI64(&s, "SELECT count(*) FROM merge_log WHERE graph_id = $1 AND seq = 2 AND $2::uuid = ANY(moved_facts)", .{ gid, @as([]const u8, &lacks.fact.id.bytes) }));

    {
        var row = (try s.pool.row("SELECT upper(valid), end_kind, ended_by, upper_inf(known) FROM fact WHERE id = $1", .{@as([]const u8, &oncall.fact.id.bytes)})).?;
        defer row.deinit() catch {};
        try testing.expectEqual(t0 + day, try row.get(i64, 0));
        try testing.expectEqualStrings("changed", try row.get([]const u8, 1));
        try testing.expect(handoff.fact.id.eql(try store.idFromPg(try row.get([]const u8, 2))));
        try testing.expect(try row.get(bool, 3));
    }
    {
        var row = (try s.pool.row("SELECT upper_inf(valid), confidence, upper_inf(known) FROM fact WHERE id = $1", .{@as([]const u8, &uses.fact.id.bytes)})).?;
        defer row.deinit() catch {};
        try testing.expect(try row.get(bool, 0));
        try testing.expectApproxEqAbs(@as(f32, 0.93), try row.get(f32, 1), 1e-6);
        try testing.expect(try row.get(bool, 2));
    }
    {
        var row = (try s.pool.row("SELECT upper_inf(known), end_kind, upper_inf(valid) FROM fact WHERE id = $1", .{@as([]const u8, &lacks.fact.id.bytes)})).?;
        defer row.deinit() catch {};
        try testing.expect(!try row.get(bool, 0));
        try testing.expectEqualStrings("retracted", try row.get([]const u8, 1));
        try testing.expect(try row.get(bool, 2));
    }
    try testing.expectEqual(@as(i64, 2), try scalarI64(&s, "SELECT count(*) FROM fact_evidence WHERE fact_id = $1", .{@as([]const u8, &uses.fact.id.bytes)}));
    {
        var row = (try s.pool.row(
            \\SELECT status, commit_seq, cost_usd::float8, jsonb_array_length(warnings),
            \\  warnings->>1 LIKE 'invalidation of fact % skipped%'
            \\FROM entry WHERE id = $1
        , .{@as([]const u8, &en2.bytes)})).?;
        defer row.deinit() catch {};
        try testing.expectEqualStrings("committed", try row.get([]const u8, 0));
        try testing.expectEqual(@as(i64, 2), try row.get(i64, 1));
        try testing.expectApproxEqAbs(@as(f64, 0.0042), try row.get(f64, 2), 1e-9);
        try testing.expectEqual(@as(i32, 2), try row.get(i32, 3));
        try testing.expect(try row.get(bool, 4));
    }
    {
        var row = (try s.pool.row(
            \\SELECT $2::uuid = ANY(touched_entities), $3::uuid = ANY(touched_entities), $4::uuid = ANY(touched_facts),
            \\  $5::uuid = ANY(touched_facts), cardinality(touched_facts)
            \\FROM commit_log WHERE graph_id = $1 AND seq = 2
        , .{ gid, @as([]const u8, &hollis.id.bytes), @as([]const u8, &juno.id.bytes), @as([]const u8, &oncall.fact.id.bytes), @as([]const u8, &lacks.fact.id.bytes) })).?;
        defer row.deinit() catch {};
        inline for (0..4) |i| try testing.expect(try row.get(bool, i));
        try testing.expectEqual(@as(i32, 5), try row.get(i32, 4));
    }
}

const RebaseProbe = struct {
    calls: std.atomic.Value(u32) = .init(0),
    seen_latest: std.atomic.Value(i64) = .init(0),

    fn rebase(p: *RebaseProbe) store.Rebase {
        return .{ .ptr = p, .run = run };
    }

    fn run(ptr: *anyopaque, conn: *pg.Conn, cs: *core.ChangeSet, base_seq: i64, latest_seq: i64) anyerror!void {
        _ = conn;
        _ = cs;
        _ = base_seq;
        const p: *RebaseProbe = @ptrCast(@alignCast(ptr));
        _ = p.calls.fetchAdd(1, .seq_cst);
        p.seen_latest.store(latest_seq, .seq_cst);
    }
};

const Racer = struct {
    s: *Store,
    lease: store.Lease,
    cs: *const core.ChangeSet,
    probe: *RebaseProbe,
    start: *std.atomic.Value(bool),
    result: anyerror!store.CommitResult = error.NotRun,

    fn go(r: *Racer) void {
        while (!r.start.load(.acquire)) std.atomic.spinLoopHint();
        r.result = r.s.commit(r.lease, r.cs, r.probe.rebase());
    }
};

test "two committers racing on one graph get consecutive seqs and the loser rebases" {
    var s = try store.testing.openWith(.{ .pool_size = 4 });
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try enqueueNew(&s, g, note("race-a", "a", 1_000));
    _ = try enqueueNew(&s, g, note("race-b", "b", 2_000));
    const la = (try s.claim(a, g, "a")).?;
    const lb = (try s.claim(a, g, "b")).?;
    const ea = entity(&s, "alpha", .concept);
    const eb = entity(&s, "beta", .concept);
    const csa: core.ChangeSet = .{ .base_seq = 0, .new_entities = &.{ea} };
    const csb: core.ChangeSet = .{ .base_seq = 0, .new_entities = &.{eb} };
    try stage(&s, la, &csa);
    try stage(&s, lb, &csb);

    var probe: RebaseProbe = .{};
    var start: std.atomic.Value(bool) = .init(false);
    var ra: Racer = .{ .s = &s, .lease = la, .cs = &csa, .probe = &probe, .start = &start };
    var rb: Racer = .{ .s = &s, .lease = lb, .cs = &csb, .probe = &probe, .start = &start };
    const ta = try std.Thread.spawn(.{}, Racer.go, .{&ra});
    const tb = try std.Thread.spawn(.{}, Racer.go, .{&rb});
    start.store(true, .release);
    ta.join();
    tb.join();

    const sa = (try ra.result).committed.seq;
    const sb = (try rb.result).committed.seq;
    try testing.expectEqual(@as(i64, 3), sa + sb);
    try testing.expect(sa != sb);
    try testing.expectEqual(@as(u32, 1), probe.calls.load(.seq_cst));
    try testing.expectEqual(@as(i64, 1), probe.seen_latest.load(.seq_cst));
    try testing.expectEqual(@as(i64, 2), try scalarI64(&s, "SELECT count(*) FROM commit_log WHERE graph_id = $1", .{@as([]const u8, &g.bytes)}));
}

const DedupRebase = struct {
    arena: std.mem.Allocator,
    graph: Id,

    fn run(ptr: *anyopaque, conn: *pg.Conn, cs: *core.ChangeSet, base_seq: i64, latest_seq: i64) anyerror!void {
        const self: *DedupRebase = @ptrCast(@alignCast(ptr));
        var kept: std.ArrayList(core.ChangeSet.NewFact) = .empty;
        var restate: std.ArrayList(core.ChangeSet.Restatement) = .empty;
        var evidence: std.ArrayList(core.ChangeSet.Evidence) = .empty;
        for (cs.new_facts) |nf| {
            var row = try conn.row(
                \\SELECT f.id, f.confidence FROM fact f JOIN commit_log c ON c.graph_id = f.graph_id AND f.id = ANY(c.touched_facts)
                \\WHERE c.graph_id = $1 AND c.seq > $2 AND c.seq <= $3 AND f.subject_id = $4 AND f.relation = $5
                \\  AND f.object_value = $6 AND upper_inf(f.valid) AND upper_inf(f.known)
            , .{ @as([]const u8, &self.graph.bytes), base_seq, latest_seq, @as([]const u8, &nf.fact.subject_id.bytes), nf.fact.relation, nf.fact.object.value });
            if (row) |*r| {
                defer r.deinit() catch {};
                const existing = try store.idFromPg(try r.get([]const u8, 0));
                const c = try r.get(f32, 1);
                try restate.append(self.arena, .{ .fact_id = existing, .confidence = c + (1 - c) * 0.3 });
                try evidence.append(self.arena, .{ .fact_id = existing, .kind = .restated });
            } else try kept.append(self.arena, nf);
        }
        cs.new_facts = kept.items;
        cs.restatements = restate.items;
        cs.evidence = evidence.items;
    }
};

test "a rebase sees the commits it missed and its rewrite is what lands" {
    var s = try store.testing.open();
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const subject = entity(&s, "graf", .project);
    _ = try enqueueNew(&s, g, note("seed", "seed", 500));
    const ls = (try s.claim(a, g, "seed")).?;
    const seed_cs: core.ChangeSet = .{ .base_seq = 0, .new_entities = &.{subject} };
    try stage(&s, ls, &seed_cs);
    _ = try s.commit(ls, &seed_cs, null);

    const e1 = emb(7);
    const e2 = emb(8);
    const first = newFact(&s, g, subject.id, "has_setting", .{ .value = "Postgres 17" }, "graf stores data in Postgres 17.", 1_000, &e1);
    const second = newFact(&s, g, subject.id, "has_setting", .{ .value = "Postgres 17" }, "graf uses Postgres 17 for storage.", 2_000, &e2);

    _ = try enqueueNew(&s, g, note("x", "one", 1_000));
    _ = try enqueueNew(&s, g, note("y", "two", 2_000));
    const l1 = (try s.claim(a, g, "1")).?;
    const l2 = (try s.claim(a, g, "2")).?;
    const cs1: core.ChangeSet = .{ .base_seq = 1, .new_facts = &.{first}, .evidence = &.{.{ .fact_id = first.fact.id, .kind = .stated }} };
    const cs2: core.ChangeSet = .{ .base_seq = 1, .new_facts = &.{second}, .evidence = &.{.{ .fact_id = second.fact.id, .kind = .stated }} };
    try stage(&s, l1, &cs1);
    try stage(&s, l2, &cs2);

    var dedup: DedupRebase = .{ .arena = a, .graph = g };
    const rb: store.Rebase = .{ .ptr = &dedup, .run = DedupRebase.run };
    try testing.expectEqual(@as(i64, 2), (try s.commit(l1, &cs1, rb)).committed.seq);
    try testing.expectEqual(@as(i64, 3), (try s.commit(l2, &cs2, rb)).committed.seq);

    const gid: []const u8 = &g.bytes;
    try testing.expectEqual(@as(i64, 1), try scalarI64(&s, "SELECT count(*) FROM fact WHERE graph_id = $1", .{gid}));
    try testing.expectEqual(@as(i64, 2), try scalarI64(&s, "SELECT count(*) FROM fact_evidence WHERE fact_id = $1", .{@as([]const u8, &first.fact.id.bytes)}));
    var row = (try s.pool.row(
        "SELECT confidence, (SELECT jsonb_array_length(change_set->'new_facts') FROM entry WHERE id = $2) FROM fact WHERE id = $1",
        .{ @as([]const u8, &first.fact.id.bytes), @as([]const u8, &l2.entry_id.bytes) },
    )).?;
    defer row.deinit() catch {};
    try testing.expectApproxEqAbs(@as(f32, 0.93), try row.get(f32, 0), 1e-6);
    try testing.expectEqual(@as(i32, 0), try row.get(i32, 1));
}

test "commit rejects embeddings of the wrong width and leaves the entry staged" {
    var s = try store.testing.open();
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const subject = entity(&s, "graf", .project);
    const short = [_]f32{ 0.1, 0.2 };
    const bad = newFact(&s, g, subject.id, "uses", .{ .value = "Zig" }, "graf uses Zig.", 1_000, &short);
    const entry_id = try enqueueNew(&s, g, note("bad", "bad", 1_000));
    const l = (try s.claim(a, g, "w")).?;
    const cs: core.ChangeSet = .{ .base_seq = 0, .new_entities = &.{subject}, .new_facts = &.{bad} };
    try stage(&s, l, &cs);
    try testing.expectError(error.InvalidEmbedding, s.commit(l, &cs, null));
    try testing.expectEqualStrings("staged", try status(&s, entry_id));
    try testing.expectEqual(@as(i64, 0), try scalarI64(&s, "SELECT count(*) FROM entity WHERE graph_id = $1", .{@as([]const u8, &g.bytes)}));
}

test "the ledger records every attempt and sums spend from a point in time" {
    var s = try store.testing.open();
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    var prng = std.Random.DefaultPrng.init(@intCast(core.time.now(s.io)));
    const since: i64 = 4_102_444_800_000_000 + @as(i64, prng.random().intRangeAtMost(i64, 0, 300 * 365 * day));

    const ledger = s.ledger();
    try ledger.record(&.{ .id = Id.v7(s.io), .graph_id = g, .purpose = .extract, .route = "openai-responses", .model = "example-model", .attempt = 1, .ok = false, .error_class = "rate_limited_429", .http_status = 429, .latency_ms = 120, .started_at = since + 1 });
    try ledger.record(&.{ .id = Id.v7(s.io), .graph_id = g, .purpose = .extract, .route = "openai-responses", .model = "example-model", .attempt = 2, .ok = true, .input_tokens = 900, .output_tokens = 300, .cost_usd = 0.0031, .cost_status = .priced, .latency_ms = 1500, .started_at = since + 2 });
    try ledger.record(&.{ .id = Id.v7(s.io), .graph_id = g, .purpose = .embed_batch, .route = "embeddings", .model = "example-embed", .attempt = 1, .ok = true, .cost_usd = 0.0002, .cost_status = .estimated, .latency_ms = 80, .started_at = since + 3 });

    const window = (try ledger.spentSince(since)) - (try ledger.spentSince(since + 10));
    try testing.expectApproxEqAbs(@as(f64, 0.0033), window, 1e-9);
    try testing.expectEqual(@as(i64, 3), try scalarI64(&s, "SELECT count(*) FROM llm_call WHERE graph_id = $1", .{@as([]const u8, &g.bytes)}));
    try testing.expectEqual(@as(i64, 1), try scalarI64(&s, "SELECT count(*) FROM llm_call WHERE graph_id = $1 AND outcome = 'error' AND http_status = 429", .{@as([]const u8, &g.bytes)}));
}

test "the ledger fills a missing graph id from the entry, then from the bound graph" {
    var s = try store.testing.open();
    defer s.close();
    const g = try store.testing.freshGraph(&s);
    const gid: []const u8 = &g.bytes;
    const entry_id = try enqueueNew(&s, g, note("ledger", "ledger entry", 1_000));

    const ledger = s.ledger();
    try ledger.record(&.{ .id = Id.v7(s.io), .graph_id = .nil, .entry_id = entry_id, .purpose = .extract, .route = "openai-responses", .model = "example-model", .attempt = 1, .ok = true, .latency_ms = 10, .started_at = core.time.now(s.io) });
    try testing.expectError(error.PG, ledger.record(&.{ .id = Id.v7(s.io), .graph_id = .nil, .purpose = .embed_query, .route = "embeddings", .model = "example-embed", .attempt = 1, .ok = true, .latency_ms = 10, .started_at = core.time.now(s.io) }));
    _ = s.sink(g);
    try ledger.record(&.{ .id = Id.v7(s.io), .graph_id = .nil, .purpose = .embed_query, .route = "embeddings", .model = "example-embed", .attempt = 1, .ok = true, .latency_ms = 10, .started_at = core.time.now(s.io) });
    try testing.expectEqual(@as(i64, 2), try scalarI64(&s, "SELECT count(*) FROM llm_call WHERE graph_id = $1", .{gid}));
}
