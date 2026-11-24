const std = @import("std");
const pg = @import("pg");
const store = @import("mod.zig");

const dims = store.embedding_dims;

fn fillEmbeddings(out: []f32, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (out) |*v| v.* = r.float(f32) * 2 - 1;
}

test "seam: halfvec(512) rows batch-inserted as flat float4[] slices round-trip" {
    var s = try store.testing.open();
    defer s.close();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const conn = try s.pool.acquire();
    defer conn.release();

    _ = try conn.exec("DROP TABLE IF EXISTS pg_temp.seam_vec", .{});
    _ = try conn.exec("CREATE TEMP TABLE seam_vec (id uuid PRIMARY KEY, emb halfvec(512) NOT NULL)", .{});
    _ = try conn.exec("CREATE INDEX ON seam_vec USING hnsw (emb halfvec_cosine_ops) WITH (m = 16, ef_construction = 128)", .{});

    {
        var row = (try conn.row("SELECT count(*)::int FROM unnest('{{1,2},{3,4},{5,6}}'::float4[][])", .{})).?;
        defer row.deinit() catch {};
        try std.testing.expectEqual(@as(i32, 6), try row.get(i32, 0));
    }

    const n = 40;
    var id_bytes: [n][16]u8 = undefined;
    var ids: [n][]const u8 = undefined;
    for (&id_bytes, &ids) |*bytes, *id| {
        bytes.* = store.Id.v7(io).bytes;
        id.* = bytes;
    }

    const embs = try gpa.alloc(f32, n * dims);
    defer gpa.free(embs);
    fillEmbeddings(embs, 1);

    _ = try conn.exec(
        \\INSERT INTO seam_vec (id, emb)
        \\SELECT t.id, ($2::float4[])[(t.i - 1) * 512 + 1 : t.i * 512]::halfvec(512)
        \\FROM unnest($1::uuid[]) WITH ORDINALITY AS t(id, i)
    , .{ &ids, embs });

    for ([_]usize{ 0, n - 1 }) |i| {
        var row = (try conn.row("SELECT (SELECT count(*)::int FROM seam_vec), (SELECT emb::float4[] FROM seam_vec WHERE id = $1)", .{ids[i]})).?;
        defer row.deinit() catch {};

        try std.testing.expectEqual(@as(i32, n), try row.get(i32, 0));
        var it = try row.get(pg.Iterator(f32), 1);
        try std.testing.expectEqual(@as(usize, dims), it.len());

        var k: usize = 0;
        while (it.next()) |v| : (k += 1) {
            try std.testing.expectApproxEqAbs(embs[i * dims + k], v, 1e-3);
        }
    }
}

test "seam: hnsw.iterative_scan = relaxed_order keeps a selective filter from under-returning" {
    var s = try store.testing.open();
    defer s.close();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const conn = try s.pool.acquire();
    defer conn.release();

    _ = try conn.exec("DROP TABLE IF EXISTS pg_temp.seam_knn", .{});
    _ = try conn.exec("CREATE TEMP TABLE seam_knn (id uuid PRIMARY KEY, graph int NOT NULL, emb halfvec(512) NOT NULL)", .{});
    _ = try conn.exec("CREATE INDEX ON seam_knn USING hnsw (emb halfvec_cosine_ops) WITH (m = 16, ef_construction = 64)", .{});

    const n = 1500;
    const ids = try gpa.alloc([]const u8, n);
    defer gpa.free(ids);
    const id_bytes = try gpa.alloc([16]u8, n);
    defer gpa.free(id_bytes);
    const graphs = try gpa.alloc(i32, n);
    defer gpa.free(graphs);
    const embs = try gpa.alloc(f32, n * dims);
    defer gpa.free(embs);

    for (0..n) |i| {
        id_bytes[i] = store.Id.v7(io).bytes;
        ids[i] = &id_bytes[i];
        graphs[i] = if (i % 50 == 0) 1 else 2;
    }
    fillEmbeddings(embs, 42);

    _ = try conn.exec(
        \\INSERT INTO seam_knn (id, graph, emb)
        \\SELECT t.id, t.g, ($3::float4[])[(t.i - 1) * 512 + 1 : t.i * 512]::halfvec(512)
        \\FROM unnest($1::uuid[], $2::int[]) WITH ORDINALITY AS t(id, g, i)
    , .{ ids, graphs, embs });
    _ = try conn.exec("ANALYZE seam_knn", .{});

    const query = embs[dims .. 2 * dims];
    const knn = "SELECT count(*)::int FROM (SELECT id FROM seam_knn WHERE graph = 1 ORDER BY emb <=> $1::float4[]::halfvec(512) LIMIT 10) q";

    var counts: [2]i32 = undefined;
    for ([_][]const u8{ "off", "relaxed_order" }, &counts) |mode, *count| {
        try conn.begin();
        defer conn.rollback() catch {};

        _ = try conn.exec("SET LOCAL enable_seqscan = off", .{});
        _ = try conn.exec("SET LOCAL hnsw.ef_search = 40", .{});
        const set = try std.fmt.allocPrint(gpa, "SET LOCAL hnsw.iterative_scan = {s}", .{mode});
        defer gpa.free(set);
        _ = try conn.exec(set, .{});

        var row = (try conn.row(knn, .{query})).?;
        defer row.deinit() catch {};
        count.* = try row.get(i32, 0);
    }

    try std.testing.expect(counts[0] < 10);
    try std.testing.expectEqual(@as(i32, 10), counts[1]);
}

test "seam: pg_advisory_xact_lock excludes a second transaction until commit" {
    var s = try store.testing.open();
    defer s.close();

    const a = try s.pool.acquire();
    defer a.release();
    const b = try s.pool.acquire();
    defer b.release();
    const try_lock = "SELECT pg_try_advisory_xact_lock(hashtextextended('graf:seam-test', 0))";

    try a.begin();
    _ = try a.exec("SELECT pg_advisory_xact_lock(hashtextextended('graf:seam-test', 0))", .{});

    try b.begin();
    {
        var row = (try b.row(try_lock, .{})).?;
        defer row.deinit() catch {};
        try std.testing.expect(!try row.get(bool, 0));
    }
    try b.rollback();

    try a.commit();

    try b.begin();
    {
        var row = (try b.row(try_lock, .{})).?;
        defer row.deinit() catch {};
        try std.testing.expect(try row.get(bool, 0));
    }
    try b.rollback();
}

test "seam: LISTEN receives a NOTIFY sent inside a committed transaction, not a rolled-back one" {
    var s = try store.testing.open();
    defer s.close();

    var listener = try s.pool.newListener();
    defer listener.deinit();
    try listener.listen("graf_seam_test", .{});

    const conn = try s.pool.acquire();
    defer conn.release();

    try conn.begin();
    _ = try conn.exec("SELECT pg_notify('graf_seam_test', 'rolled-back')", .{});
    try conn.rollback();

    try conn.begin();
    _ = try conn.exec("SELECT pg_notify('graf_seam_test', 'hello')", .{});
    try conn.commit();

    try std.testing.expectEqualStrings("hello", try store.testing.nextNotification(&listener, "graf_seam_test"));
}
