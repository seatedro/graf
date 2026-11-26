const std = @import("std");
const core = @import("core");
const pg = @import("pg");
const store = @import("mod.zig");
const committer = @import("commit.zig");

const Store = store.Store;
const Id = core.Id;

pub const MergeOptions = struct {
    orient: bool = true,
    force: bool = false,
    dry_run: bool = false,
};

pub const Skip = enum { same, missing, blocked, too_large };

pub const Merged = struct {
    log_id: Id,
    seq: i64,
    from: Id,
    into: Id,
    moved_facts: usize,
};

pub const MergeOutcome = union(enum) {
    merged: Merged,
    skipped: Skip,
};

pub const Unmerged = struct {
    seq: i64,
    from: Id,
    into: Id,
    restored_facts: usize,
};

const Tx = struct {
    conn: *pg.Conn,
    gid: []const u8,
    done: bool = false,

    fn open(s: *Store, graph_id: *const Id) !Tx {
        const conn = try s.pool.acquire();
        errdefer conn.release();

        try conn.begin();
        _ = try conn.exec("SELECT pg_advisory_xact_lock(hashtextextended('graf:' || $1::uuid::text, 0))", .{@as([]const u8, &graph_id.bytes)});
        return .{ .conn = conn, .gid = &graph_id.bytes };
    }

    fn nextSeq(tx: *Tx) !i64 {
        var row = (try tx.conn.row("SELECT COALESCE(max(seq), 0)::int8 + 1 FROM commit_log WHERE graph_id = $1", .{tx.gid})).?;
        defer row.deinit() catch {};
        return row.get(i64, 0);
    }

    fn log(tx: *Tx, seq: i64, entities: []const []const u8, facts: []const []const u8) !void {
        _ = try tx.conn.exec(
            \\INSERT INTO commit_log (graph_id, seq, entry_id, committed_at, touched_entities, touched_facts)
            \\SELECT $1, $2, NULL, clock_timestamp(),
            \\  ARRAY(SELECT DISTINCT x FROM (
            \\    SELECT unnest($3::uuid[]) AS x
            \\    UNION SELECT subject_id FROM fact WHERE id = ANY($4::uuid[])
            \\    UNION SELECT object_id FROM fact WHERE id = ANY($4::uuid[]) AND object_id IS NOT NULL) q ORDER BY x),
            \\  ARRAY(SELECT DISTINCT x FROM unnest($4::uuid[]) AS x ORDER BY x)
        , .{ tx.gid, seq, entities, facts });
        _ = try tx.conn.exec("SELECT pg_notify('graf_commit', json_build_object('graph_id', $1::uuid, 'seq', $2::int8)::text)", .{ tx.gid, seq });
    }

    fn finish(tx: *Tx, dry_run: bool) !void {
        tx.done = true;
        if (dry_run) return tx.conn.rollback();
        return tx.conn.commit();
    }

    fn close(tx: *Tx) void {
        if (!tx.done) tx.conn.rollback() catch {};
        tx.conn.release();
    }
};

fn blocked(conn: *pg.Conn, gid: []const u8, a: *const Id, b: *const Id) !bool {
    var row = (try conn.row(
        \\SELECT 1 FROM must_not_merge WHERE graph_id = $1 AND entity_a = least($2::uuid, $3::uuid) AND entity_b = greatest($2::uuid, $3::uuid)
    , .{ gid, @as([]const u8, &a.bytes), @as([]const u8, &b.bytes) })) orelse return false;
    row.deinit() catch {};
    return true;
}

const settle_duplicates_sql =
    \\UPDATE possible_duplicate SET status = $4, reason = $5, decided_at = now()
    \\WHERE graph_id = $1 AND status = 'open'
    \\  AND ((entity_a = $2 AND entity_b = $3) OR (entity_a = $3 AND entity_b = $2))
;

pub fn merge(s: *Store, graph_id: Id, from: Id, into: Id, reason: []const u8, opts: MergeOptions) !MergeOutcome {
    if (from.eql(into)) return .{ .skipped = .same };

    var arena_state = std.heap.ArenaAllocator.init(s.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tx = try Tx.open(s, &graph_id);
    defer tx.close();

    const f = try committer.mergeSide(tx.conn, tx.gid, &from) orelse return .{ .skipped = .missing };
    const i = try committer.mergeSide(tx.conn, tx.gid, &into) orelse return .{ .skipped = .missing };
    if (!opts.force) {
        if (try blocked(tx.conn, tx.gid, &from, &into)) return .{ .skipped = .blocked };
        if (@min(f.facts, i.facts) > committer.max_merge_facts) return .{ .skipped = .too_large };
    }

    const swap = opts.orient and committer.shouldSwap(f, i);
    const m: core.ChangeSet.Merge = if (swap) .{ .from = into, .into = from, .reason = reason } else .{ .from = from, .into = into, .reason = reason };

    const seq = try tx.nextSeq();
    var entities: std.ArrayList([]const u8) = .empty;
    var facts: std.ArrayList([]const u8) = .empty;
    const log_id = try committer.applyMerge(s, a, tx.conn, tx.gid, seq, &m, &entities, &facts);
    _ = try tx.conn.exec(settle_duplicates_sql, .{ tx.gid, @as([]const u8, &m.from.bytes), @as([]const u8, &m.into.bytes), "merged", reason });
    try tx.log(seq, entities.items, facts.items);

    try tx.finish(opts.dry_run);
    return .{ .merged = .{ .log_id = log_id, .seq = seq, .from = m.from, .into = m.into, .moved_facts = facts.items.len } };
}

pub fn unmerge(s: *Store, graph_id: Id, merge_id: Id, reason: []const u8, dry_run: bool) !Unmerged {
    var arena_state = std.heap.ArenaAllocator.init(s.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tx = try Tx.open(s, &graph_id);
    defer tx.close();
    const mid: []const u8 = &merge_id.bytes;

    var from: Id = undefined;
    var into: Id = undefined;
    {
        var row = (try tx.conn.row(
            \\SELECT m.from_id, m.into_id, m.undone_seq IS NOT NULL,
            \\  COALESCE((SELECT f.merged_into = m.into_id FROM entity f WHERE f.id = m.from_id), false)
            \\  AND COALESCE((SELECT i.merged_into IS NULL FROM entity i WHERE i.id = m.into_id), false)
            \\FROM merge_log m WHERE m.id = $1 AND m.graph_id = $2
        , .{ mid, tx.gid })) orelse return error.MergeNotFound;
        defer row.deinit() catch {};

        from = try store.idFromPg(try row.get([]const u8, 0));
        into = try store.idFromPg(try row.get([]const u8, 1));
        if (try row.get(bool, 2)) return error.AlreadyUndone;
        if (!try row.get(bool, 3)) return error.MergeSuperseded;
    }

    const seq = try tx.nextSeq();
    const restored = try committer.collectIds(a, tx.conn,
        \\WITH m AS (SELECT * FROM merge_log WHERE id = $1),
        \\subjects AS (
        \\  SELECT unnest(COALESCE(m.subject_facts, ARRAY(
        \\    SELECT f.id FROM fact f WHERE f.id = ANY(m.moved_facts) AND f.subject_id = m.into_id))) AS id FROM m
        \\), objects AS (
        \\  SELECT unnest(COALESCE(m.object_facts, ARRAY(
        \\    SELECT f.id FROM fact f WHERE f.id = ANY(m.moved_facts) AND f.object_id = m.into_id AND f.subject_id <> m.into_id))) AS id FROM m
        \\)
        \\UPDATE fact f SET
        \\  subject_id = CASE WHEN f.id IN (SELECT id FROM subjects) AND f.subject_id = m.into_id THEN m.from_id ELSE f.subject_id END,
        \\  object_id = CASE WHEN f.id IN (SELECT id FROM objects) AND f.object_id = m.into_id THEN m.from_id ELSE f.object_id END
        \\FROM m
        \\WHERE f.graph_id = $2 AND (f.id IN (SELECT id FROM subjects) OR f.id IN (SELECT id FROM objects))
        \\  AND (f.subject_id = m.into_id OR f.object_id = m.into_id)
        \\RETURNING f.id
    , .{ mid, tx.gid });

    _ = try tx.conn.exec("UPDATE entity SET merged_into = NULL, updated_seq = $3 WHERE id = $1 AND graph_id = $2", .{ @as([]const u8, &from.bytes), tx.gid, seq });
    _ = try tx.conn.exec(
        \\DELETE FROM entity_alias al USING merge_log m
        \\WHERE m.id = $1 AND al.entity_id = m.into_id AND al.norm = ANY(COALESCE(m.added_aliases, ARRAY(
        \\  SELECT x.norm FROM entity_alias x WHERE x.entity_id = m.from_id
        \\    AND x.norm <> (SELECT e.norm FROM entity e WHERE e.id = m.into_id))))
    , .{mid});
    _ = try tx.conn.exec(
        \\DELETE FROM entity_mention em USING merge_log m
        \\WHERE m.id = $1 AND em.entity_id = m.into_id AND em.entry_id = ANY(COALESCE(m.added_mentions, '{}'))
    , .{mid});
    _ = try tx.conn.exec("UPDATE merge_log SET undone_seq = $2 WHERE id = $1", .{ mid, seq });
    _ = try tx.conn.exec(
        \\INSERT INTO must_not_merge (graph_id, entity_a, entity_b, reason)
        \\VALUES ($1, least($2::uuid, $3::uuid), greatest($2::uuid, $3::uuid), $4)
        \\ON CONFLICT (graph_id, entity_a, entity_b) DO UPDATE SET reason = excluded.reason
    , .{ tx.gid, @as([]const u8, &from.bytes), @as([]const u8, &into.bytes), reason });
    _ = try tx.conn.exec(settle_duplicates_sql, .{ tx.gid, @as([]const u8, &from.bytes), @as([]const u8, &into.bytes), "rejected", reason });

    const entities = [_][]const u8{ &from.bytes, &into.bytes };
    try tx.log(seq, &entities, restored);

    try tx.finish(dry_run);
    return .{ .seq = seq, .from = from, .into = into, .restored_facts = restored.len };
}

pub fn keepApart(s: *Store, graph_id: Id, a: Id, b: Id, reason: []const u8) !void {
    const conn = try s.pool.acquire();
    defer conn.release();

    const gid: []const u8 = &graph_id.bytes;
    _ = try conn.exec(
        \\INSERT INTO must_not_merge (graph_id, entity_a, entity_b, reason)
        \\VALUES ($1, least($2::uuid, $3::uuid), greatest($2::uuid, $3::uuid), $4)
        \\ON CONFLICT (graph_id, entity_a, entity_b) DO NOTHING
    , .{ gid, @as([]const u8, &a.bytes), @as([]const u8, &b.bytes), reason });
    _ = try conn.exec(settle_duplicates_sql, .{ gid, @as([]const u8, &a.bytes), @as([]const u8, &b.bytes), "rejected", reason });
}
