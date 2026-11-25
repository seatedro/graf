const std = @import("std");
const core = @import("core");
const pg = @import("pg");
const store = @import("mod.zig");

const Store = store.Store;
const Lease = store.Lease;
const Id = core.Id;

pub fn ensureGraph(s: *Store, name: []const u8) !Id {
    const conn = try s.pool.acquire();
    defer conn.release();

    const fresh = Id.v7(s.io);
    _ = try conn.exec("INSERT INTO graph (id, name) VALUES ($1, $2) ON CONFLICT (name) DO NOTHING", .{ @as([]const u8, &fresh.bytes), name });
    var row = (try conn.row("SELECT id FROM graph WHERE name = $1", .{name})) orelse return error.GraphNotFound;
    const id = try store.idFromPg(try row.get([]const u8, 0));
    try row.deinit();

    const relations = core.ontology.core_relations;
    var names: [relations.len][]const u8 = undefined;
    var descriptions: [relations.len][]const u8 = undefined;
    var cardinalities: [relations.len][]const u8 = undefined;
    var opposes: [relations.len]?[]const u8 = undefined;
    var object_kinds: [relations.len][]const u8 = undefined;

    for (relations, 0..) |relation, i| {
        names[i] = relation.name;
        descriptions[i] = relation.description;
        cardinalities[i] = @tagName(relation.cardinality);
        opposes[i] = relation.opposes;
        object_kinds[i] = @tagName(relation.object_kind);
    }

    _ = try conn.exec(
        \\INSERT INTO relation (graph_id, name, description, cardinality, opposes, object_kind, status)
        \\SELECT $1, t.name, t.description, t.cardinality, t.opposes, t.object_kind, 'core'
        \\FROM unnest($2::text[], $3::text[], $4::text[], $5::text[], $6::text[])
        \\  AS t(name, description, cardinality, opposes, object_kind)
        \\ON CONFLICT (graph_id, name) DO NOTHING
    , .{ @as([]const u8, &id.bytes), &names, &descriptions, &cardinalities, &opposes, &object_kinds });

    return id;
}

pub fn enqueue(s: *Store, graph_id: Id, draft_in: *const core.EntryDraft) !core.EntrySink.Outcome {
    var arena_state = std.heap.ArenaAllocator.init(s.allocator);
    defer arena_state.deinit();

    const redacted = try core.redactDraft(arena_state.allocator(), draft_in.*);
    const draft = &redacted;

    const hash = try store.contentHash(s.allocator, draft);
    const body = try std.json.Stringify.valueAlloc(s.allocator, draft.body, .{});
    defer s.allocator.free(body);

    const conn = try s.pool.acquire();
    defer conn.release();

    try conn.begin();
    errdefer conn.rollback() catch {};

    var source_buf: [16]u8 = undefined;
    var source_id: ?[]const u8 = null;
    if (draft.source) |src| {
        const fresh = Id.v7(s.io);
        var row = (try conn.row(
            \\INSERT INTO source (id, graph_id, harness, external_id, project, agent, model)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7)
            \\ON CONFLICT (graph_id, harness, external_id) DO UPDATE SET
            \\  project = COALESCE(EXCLUDED.project, source.project),
            \\  agent = COALESCE(EXCLUDED.agent, source.agent),
            \\  model = COALESCE(EXCLUDED.model, source.model),
            \\  updated_at = now()
            \\RETURNING id
        , .{ @as([]const u8, &fresh.bytes), @as([]const u8, &graph_id.bytes), @tagName(src.harness), src.external_id, src.project, src.agent, src.model })).?;

        @memcpy(&source_buf, try row.get([]const u8, 0));
        try row.deinit();
        source_id = &source_buf;
    }

    const id = Id.v7(s.io);
    var inserted = false;
    {
        var row = try conn.row(
            \\INSERT INTO entry (id, graph_id, source_id, seq_in_source, kind, project, author, body, content_hash, reference_time, backfill)
            \\VALUES ($1, $2, $3,
            \\  CASE WHEN $4::int = 0 AND $3::uuid IS NOT NULL
            \\    THEN (SELECT COALESCE(max(seq_in_source), 0) + 1 FROM entry WHERE source_id = $3::uuid)
            \\    ELSE $4::int END,
            \\  $5, $6, $7, $8::jsonb, $9, $10, $11)
            \\ON CONFLICT (graph_id, content_hash) DO NOTHING
            \\RETURNING id
        , .{
            @as([]const u8, &id.bytes), @as([]const u8, &graph_id.bytes), source_id,
            draft.seq_in_source,        @tagName(draft.kind),             draft.project,
            @tagName(draft.author),     body,                             @as([]const u8, &hash),
            draft.reference_time,       draft.backfill,
        });

        if (row) |*r| {
            inserted = true;
            try r.deinit();
        }
    }

    if (draft.cursor) |cursor| if (source_id) |sid| {
        _ = try conn.exec("UPDATE source SET cursor = $2, updated_at = now() WHERE id = $1", .{ sid, cursor });
    };

    if (inserted) {
        var gbuf: [36]u8 = undefined;
        _ = try conn.exec("SELECT pg_notify('graf_queue', $1)", .{graph_id.toString(&gbuf)});
    }

    try conn.commit();
    return if (inserted) .{ .queued = id } else .duplicate;
}

pub fn loadCursor(s: *Store, arena: std.mem.Allocator, graph_id: Id, source: *const core.SourceKey) !?[]const u8 {
    var row = (try s.pool.row(
        "SELECT cursor FROM source WHERE graph_id = $1 AND harness = $2 AND external_id = $3",
        .{ @as([]const u8, &graph_id.bytes), @tagName(source.harness), source.external_id },
    )) orelse return null;
    defer row.deinit() catch {};
    const cursor = try row.get(?[]const u8, 0) orelse return null;
    return try arena.dupe(u8, cursor);
}

pub fn claim(s: *Store, arena: std.mem.Allocator, graph_id: Id, worker: []const u8, backfill_daily_usd: ?f64) !?Lease {
    const allow_backfill = if (backfill_daily_usd) |cap| try store.spend.spent(s, graph_id, core.time.now(s.io)) < cap else true;

    var row = (try s.pool.row(
        \\WITH next AS (
        \\  SELECT e.id FROM entry e
        \\  WHERE e.graph_id = $1
        \\    AND e.status IN ('queued', 'extracting', 'extracted', 'staged')
        \\    AND (e.lease_until IS NULL OR e.lease_until < now())
        \\    AND (e.status <> 'extracting' OR e.lease_until < now())
        \\    AND (e.not_before IS NULL OR e.not_before <= now())
        \\    AND (NOT e.backfill OR $4::bool)
        \\    AND NOT EXISTS (
        \\      SELECT 1 FROM entry p
        \\      WHERE p.source_id = e.source_id
        \\        AND p.backfill = e.backfill
        \\        AND p.status IN ('queued', 'extracting', 'extracted', 'staged', 'committing')
        \\        AND (p.seq_in_source, p.reference_time, p.id) < (e.seq_in_source, e.reference_time, e.id))
        \\  ORDER BY e.backfill, e.reference_time, e.seq_in_source, e.id
        \\  LIMIT 1
        \\  FOR UPDATE SKIP LOCKED
        \\)
        \\UPDATE entry e SET
        \\  status = CASE WHEN e.status IN ('queued', 'extracting') THEN 'extracting' ELSE e.status END,
        \\  attempts = e.attempts + CASE WHEN e.status IN ('queued', 'extracting') THEN 1 ELSE 0 END,
        \\  lease_owner = $2,
        \\  lease_token = nextval('entry_lease_token'),
        \\  lease_until = now() + $3::int * interval '1 millisecond'
        \\FROM next WHERE e.id = next.id
        \\RETURNING e.id, e.source_id, e.seq_in_source, e.kind, e.project, e.author, e.body::text,
        \\  e.content_hash, e.reference_time, e.status, e.attempts, e.lease_token, e.base_seq,
        \\  e.commit_seq, e.cost_usd::float8, e.extraction::text
    , .{ @as([]const u8, &graph_id.bytes), worker, @as(i32, @intCast(s.lease_ms)), allow_backfill })) orelse return null;
    defer row.deinit() catch {};

    const id = try store.idFromPg(try row.get([]const u8, 0));
    const source_raw = try row.get(?[]const u8, 1);
    const hash_raw = try row.get([]const u8, 7);
    if (hash_raw.len != 32) return error.InvalidContentHash;
    const body = try std.json.parseFromSliceLeaky(core.EntryBody, arena, try row.get([]const u8, 6), .{ .allocate = .alloc_always });
    const project = try row.get(?[]const u8, 4);
    const extraction = try row.get(?[]const u8, 15);
    const token = try row.get(i64, 11);

    return .{
        .entry_id = id,
        .graph_id = graph_id,
        .token = token,
        .entry = .{
            .id = id,
            .graph_id = graph_id,
            .source_id = if (source_raw) |raw| try store.idFromPg(raw) else null,
            .seq_in_source = try row.get(i32, 2),
            .kind = std.meta.stringToEnum(core.types.EntryKind, try row.get([]const u8, 3)) orelse return error.InvalidEntryRow,
            .project = if (project) |p| try arena.dupe(u8, p) else null,
            .author = std.meta.stringToEnum(core.types.Author, try row.get([]const u8, 5)) orelse return error.InvalidEntryRow,
            .body = body,
            .content_hash = hash_raw[0..32].*,
            .reference_time = try row.get(i64, 8),
            .status = std.meta.stringToEnum(core.types.EntryStatus, try row.get([]const u8, 9)) orelse return error.InvalidEntryRow,
            .attempts = try row.get(i32, 10),
            .lease_token = token,
            .base_seq = try row.get(?i64, 12),
            .commit_seq = try row.get(?i64, 13),
            .cost_usd = try row.get(f64, 14),
        },
        .extraction_json = if (extraction) |e| try arena.dupe(u8, e) else null,
    };
}

pub fn heartbeat(s: *Store, lease: Lease) !void {
    const n = try s.pool.exec(
        \\UPDATE entry SET lease_until = now() + $3::int * interval '1 millisecond'
        \\WHERE id = $1 AND lease_token = $2 AND status IN ('extracting', 'extracted', 'staged')
    , .{ @as([]const u8, &lease.entry_id.bytes), lease.token, @as(i32, @intCast(s.lease_ms)) });
    if ((n orelse 0) == 0) return error.LeaseLost;
}

pub fn saveExtraction(s: *Store, lease: Lease, extraction_json: []const u8) !void {
    const n = try s.pool.exec(
        \\UPDATE entry SET extraction = $3::jsonb, status = 'extracted'
        \\WHERE id = $1 AND lease_token = $2 AND status IN ('extracting', 'extracted')
    , .{ @as([]const u8, &lease.entry_id.bytes), lease.token, extraction_json });
    if ((n orelse 0) == 0) return error.LeaseLost;
}

pub fn saveChangeSet(s: *Store, lease: Lease, change_set: *const core.ChangeSet) !void {
    const json = try std.json.Stringify.valueAlloc(s.allocator, change_set.*, .{});
    defer s.allocator.free(json);

    const n = try s.pool.exec(
        \\UPDATE entry SET change_set = $3::jsonb, base_seq = $4, status = 'staged'
        \\WHERE id = $1 AND lease_token = $2 AND status IN ('extracted', 'staged')
    , .{ @as([]const u8, &lease.entry_id.bytes), lease.token, json, change_set.base_seq });
    if ((n orelse 0) == 0) return error.LeaseLost;
}
