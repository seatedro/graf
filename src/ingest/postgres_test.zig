const std = @import("std");
const core = @import("core");
const store = @import("store");
const pg = @import("pg");
const postgres = @import("postgres.zig");
const jobs = @import("jobs.zig");
const workers = @import("workers.zig");
const rebase = @import("rebase.zig");
const pipeline = @import("pipeline.zig");

const testing = std.testing;
const Id = core.Id;

const seed_sql =
    \\WITH g AS (INSERT INTO graph (id, name) VALUES ($1::uuid, $1::text) RETURNING id),
    \\s AS (INSERT INTO source (id, graph_id, harness, external_id) SELECT $2::uuid, id, 'test', $2::text FROM g RETURNING id, graph_id),
    \\done AS (
    \\  INSERT INTO entry (id, graph_id, source_id, seq_in_source, kind, author, body, content_hash, reference_time, status, extraction)
    \\  SELECT $3::uuid, graph_id, id, 1, 'turns', 'user', '{"text":"We picked SQLite for the brackwater cache."}', sha256(convert_to($3::text, 'UTF8')), now() - interval '1 hour', 'committed',
    \\    '{"facts":[{"text":"The brackwater cache chose SQLite."}]}'
    \\  FROM s RETURNING id, graph_id),
    \\live AS (
    \\  INSERT INTO entry (id, graph_id, source_id, seq_in_source, kind, author, body, content_hash, reference_time, status, lease_owner, lease_token, lease_until)
    \\  SELECT $4::uuid, graph_id, id, 2, 'turns', 'user', '{"text":"switch it to Postgres"}', sha256(convert_to($4::text, 'UTF8')), now(), 'extracting', 'test', 7, now() + interval '5 minutes'
    \\  FROM s RETURNING id),
    \\a AS (
    \\  INSERT INTO entity (id, graph_id, name, norm, type, name_emb, created_seq, updated_seq)
    \\  SELECT $5::uuid, graph_id, 'brackwater cache', 'brackwater cache', 'code', array_fill(0.1::real, ARRAY[512])::vector(512)::halfvec(512), 1, 1 FROM done RETURNING id, graph_id),
    \\b AS (
    \\  INSERT INTO entity (id, graph_id, name, norm, type, name_emb, created_seq, updated_seq)
    \\  SELECT $6::uuid, graph_id, 'SQLite', 'sqlite', 'software', array_fill(-0.1::real, ARRAY[512])::vector(512)::halfvec(512), 1, 1 FROM a RETURNING id, graph_id),
    \\al AS (INSERT INTO entity_alias (graph_id, norm, entity_id, alias) SELECT graph_id, 'brackwater cache service', id, 'brackwater cache service' FROM a),
    \\f AS (
    \\  INSERT INTO fact (id, graph_id, subject_id, relation, object_id, text, scope, valid, known, author, confidence, emb, created_seq)
    \\  SELECT $7::uuid, a.graph_id, a.id, 'chose', b.id, 'The brackwater cache chose SQLite.', 'project', tstzrange(now() - interval '1 hour', NULL), tstzrange(now(), NULL), 'user', 0.9,
    \\    array_fill(0.1::real, ARRAY[512])::vector(512)::halfvec(512), 1
    \\  FROM a, b RETURNING id, graph_id),
    \\ev AS (INSERT INTO fact_evidence (fact_id, entry_id, kind, quote) SELECT f.id, done.id, 'stated', 'We picked SQLite' FROM f, done),
    \\cl AS (INSERT INTO commit_log (graph_id, seq, entry_id, touched_entities, touched_facts) SELECT f.graph_id, 1, done.id, ARRAY[$5::uuid, $6::uuid], ARRAY[f.id] FROM f, done)
    \\INSERT INTO relation (graph_id, name, description, cardinality, status)
    \\SELECT id, 'cached_by', 'Subject is cached by the object.', 'many', 'proposed' FROM g
    \\UNION ALL SELECT id, 'chose', 'Subject decided in favor of the object.', 'many', 'core' FROM g
;

fn ids(io: std.Io, comptime n: usize) [n]Id {
    var out: [n]Id = undefined;
    for (&out) |*id| id.* = Id.v7(io);
    return out;
}

fn scalar(comptime T: type, conn: *pg.Conn, sql: []const u8, args: anytype) !T {
    var row = (try conn.row(sql, args)) orelse return error.NoRows;
    defer row.deinit() catch {};
    return row.get(T, 0);
}

test "ingest SQL runs against the store schema" {
    var s = try store.testing.open();
    defer s.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const graph, const source, const done, const live, const cache, const sqlite, const fact = ids(io, 7);
    var bufs: [7][36]u8 = undefined;
    const t = [_][]const u8{
        postgres.idText(graph, &bufs[0]), postgres.idText(source, &bufs[1]), postgres.idText(done, &bufs[2]),
        postgres.idText(live, &bufs[3]),  postgres.idText(cache, &bufs[4]),  postgres.idText(sqlite, &bufs[5]),
        postgres.idText(fact, &bufs[6]),
    };
    const conn = try s.pool.acquire();
    defer conn.release();
    _ = conn.exec(seed_sql, .{ t[0], t[1], t[2], t[3], t[4], t[5], t[6] }) catch |err| {
        if (conn.err) |e| std.debug.print("seed: {s}\n", .{e.message});
        return err;
    };

    var b: postgres.PgBackend = .{ .store = &s, .graph_id = graph, .io = io };
    const lease: store.Lease = .{ .entry_id = live, .graph_id = graph, .token = 7, .entry = undefined };

    const emb = try arena.alloc(f32, 512);
    @memset(emb, 0.1);
    try b.saveRelationEmbeddings(lease, &.{ "cached_by", "chose" }, &.{ emb, emb });

    const ctx = try b.loadContext(arena, lease);
    try testing.expectEqual(@as(usize, 1), ctx.prior.len);
    try testing.expectEqualStrings("The brackwater cache chose SQLite.", ctx.prior[0].facts[0]);
    var saw_proposed = false;
    var chose_emb: usize = 0;
    for (ctx.relations) |rel| {
        if (std.mem.eql(u8, rel.name, "cached_by")) saw_proposed = rel.status == .proposed and rel.emb.len == 512;
        if (std.mem.eql(u8, rel.name, "chose")) chose_emb = rel.emb.len;
    }
    try testing.expect(saw_proposed);
    try testing.expectEqual(@as(usize, 512), chose_emb);
    try testing.expect(ctx.relations.len >= core.ontology.core_relations.len + 1);

    const pre = try b.prefetch(arena, lease, .{
        .graph_id = graph,
        .entity_norms = &.{ &.{"brackwater cache service"}, &.{"postgres"} },
        .entity_embs = &.{ emb, emb },
        .fact_subject = &.{0},
        .fact_object = &.{1},
        .fact_relations = &.{"chose"},
        .fact_opposed = &.{"rejected"},
        .fact_embs = &.{emb},
        .fact_texts = &.{"The brackwater cache chose Postgres."},
    });
    try testing.expectEqual(@as(i64, 1), pre.base_seq);
    var alias_hit = false;
    for (pre.entities) |e| if (e.item == 0 and e.id.eql(cache)) {
        alias_hit = e.alias_match;
    };
    try testing.expect(alias_hit);
    try testing.expect(pre.facts.len >= 1);
    try testing.expect(pre.facts[0].id.eql(fact));
    try testing.expect(pre.facts[0].valid_lower != null);

    const touched = try postgres.jsonRow(rebase.Touched, arena, conn, postgres.touched_sql, .{ t[0], @as(i64, 0), @as(i64, 1) });
    try testing.expectEqual(@as(usize, 2), touched.entities.len);
    try testing.expectEqual(@as(usize, 1), touched.facts.len);
    try testing.expect(touched.facts[0].active);

    _ = try conn.exec(postgres.bump_sql, .{try std.fmt.allocPrint(arena, "{{\"entities\":[\"{s}\"],\"facts\":[\"{s}\"]}}", .{ t[4], t[6] })});
    try testing.expectEqual(@as(i32, 2), try scalar(i32, conn, "SELECT facts_since_summary FROM entity WHERE id = $1::uuid", .{t[4]}));

    try postgres.finishOn(arena, conn, io, lease, .{ .requeue = .{ .delay_ms = 1000, .count_attempt = true, .reason = "transient provider failure" } });
    try testing.expectEqualStrings("queued", try scalar([]const u8, conn, "SELECT status FROM entry WHERE id = $1::uuid", .{t[3]}));
    try testing.expectEqual(@as(i32, 1), try scalar(i32, conn, "SELECT attempts FROM entry WHERE id = $1::uuid", .{t[3]}));
    try testing.expectError(error.LeaseLost, postgres.finishOn(arena, conn, io, lease, .{ .dead = "late" }));

    _ = try conn.exec("UPDATE entry SET status = 'extracting', lease_token = 8 WHERE id = $1::uuid", .{t[3]});
    const relet: store.Lease = .{ .entry_id = live, .graph_id = graph, .token = 8, .entry = undefined };
    try postgres.finishOn(arena, conn, io, relet, .{ .split = .{ .{ .text = "switch it" }, .{ .text = "to Postgres" } } });
    try testing.expectEqualStrings("split", try scalar([]const u8, conn, "SELECT status FROM entry WHERE id = $1::uuid", .{t[3]}));
    try testing.expectEqual(@as(i64, 2), try scalar(i64, conn, "SELECT count(*) FROM entry WHERE graph_id = $1::uuid AND status = 'queued'", .{t[0]}));

    const due = try postgres.jsonRow([]const jobs.DueEntity, arena, conn, jobs.due_summaries_sql, .{ t[0], @as(i32, 5) });
    try testing.expectEqual(@as(usize, 0), due.len);
    try testing.expect(try jobs.runDailyPromotion(conn, graph));
    try testing.expect(!try jobs.runDailyPromotion(conn, graph));
    try testing.expectEqual(@as(i32, 1), try scalar(i32, conn, "SELECT entries FROM relation WHERE graph_id = $1::uuid AND name = 'chose'", .{t[0]}));

    _ = try workers.tryLead(conn);
}
