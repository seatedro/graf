const std = @import("std");
const core = @import("core");
const pg = @import("pg");
const db = @import("db.zig");
const text = @import("text.zig");
const time = @import("time.zig");
const mod = @import("mod.zig");
const Hit = mod.Hit;

pub const Profile = struct {
    entity: core.Entity,
    aliases: []const []const u8 = &.{},
};

pub const Neighbor = struct {
    entity: core.Entity,
    facts: []const Hit = &.{},
};

pub const EntityResult = struct {
    entity: Profile,
    /// Other live entities that share the looked-up name, e.g. a tool and a concept.
    alternatives: []const core.Entity = &.{},
    facts: []const Hit = &.{},
    neighbors: []const Neighbor = &.{},
    as_of: core.Micros,
};

const entity_columns = "e.id, e.graph_id, e.name, e.norm, e.type, e.description, e.summary";

fn readEntity(arena: std.mem.Allocator, row: anytype, start: usize) !core.Entity {
    return .{
        .id = try db.id(row, start),
        .graph_id = try db.id(row, start + 1),
        .name = try db.text(arena, row, start + 2),
        .norm = try db.text(arena, row, start + 3),
        .type = db.entityType(try row.get([]const u8, start + 4)),
        .description = try db.text(arena, row, start + 5),
        .summary = try db.text(arena, row, start + 6),
    };
}

const resolve_sql =
    \\WITH RECURSIVE start AS (
    \\  SELECT m.id FROM entity m WHERE m.graph_id = $1 AND (m.id = $2::uuid OR m.norm = $3::text)
    \\  UNION SELECT a.entity_id FROM entity_alias a WHERE a.graph_id = $1 AND a.norm = $3::text
    \\  UNION SELECT id FROM (
    \\    SELECT a.entity_id AS id FROM entity_alias a
    \\    WHERE $4::bool AND a.graph_id = $1 AND a.norm % $3::text ORDER BY similarity(a.norm, $3::text) DESC LIMIT 5) t
    \\), chain(id, merged_into, depth) AS (
    \\  SELECT e.id, e.merged_into, 0 FROM entity e JOIN start s ON s.id = e.id
    \\  UNION ALL SELECT e.id, e.merged_into, c.depth + 1 FROM chain c JOIN entity e ON e.id = c.merged_into WHERE c.depth < 8
    \\)
    \\SELECT 
++ entity_columns ++
    \\,
    \\  (SELECT count(*) FROM fact f WHERE (f.subject_id = e.id OR f.object_id = e.id) AND upper_inf(f.sys) AND upper_inf(f.valid)) AS n
    \\FROM entity e WHERE e.id IN (SELECT id FROM chain WHERE merged_into IS NULL)
    \\ORDER BY n DESC, e.id LIMIT 6
;

const as_of = "coalesce($3::timestamptz, now())";

const facts_sql =
    \\SELECT 
++ db.hit_columns ++
    \\
    \\FROM fact f JOIN entity se ON se.id = f.subject_id LEFT JOIN entity oe ON oe.id = f.object_id
    \\WHERE f.graph_id = $1 AND (f.subject_id = $2 OR f.object_id = $2)
    \\  AND ($5::bool OR upper_inf(f.sys))
    \\  AND (f.valid @> 
++ as_of ++
    \\ OR ($4::bool AND upper(f.valid) <= 
++ as_of ++
    \\))
    \\ORDER BY upper_inf(f.sys) DESC, upper_inf(f.valid) DESC, f.confidence DESC, lower(f.valid) DESC NULLS LAST, f.id
    \\LIMIT 200
;

const neighbors_sql =
    \\WITH hop1 AS (
    \\  SELECT DISTINCT CASE WHEN f.subject_id = $2 THEN f.object_id ELSE f.subject_id END AS id
    \\  FROM fact f WHERE f.graph_id = $1 AND (f.subject_id = $2 OR f.object_id = $2) AND f.object_id IS NOT NULL
    \\    AND upper_inf(f.sys) AND f.valid @> 
++ as_of ++
    \\
    \\), n AS (
    \\  SELECT 
++ entity_columns ++
    \\,
    \\    (SELECT count(*) FROM fact f WHERE (f.subject_id = e.id OR f.object_id = e.id) AND upper_inf(f.sys) AND f.valid @> 
++ as_of ++
    \\) AS deg
    \\  FROM hop1 h JOIN entity e ON e.id = h.id WHERE e.id <> $2 ORDER BY deg DESC, e.id LIMIT 12
    \\)
    \\SELECT n.id, n.graph_id, n.name, n.norm, n.type, n.description, n.summary, n.deg, x.* FROM n LEFT JOIN LATERAL (
    \\  SELECT 
++ db.hit_columns ++
    \\
    \\  FROM fact f JOIN entity se ON se.id = f.subject_id LEFT JOIN entity oe ON oe.id = f.object_id
    \\  WHERE $4::int = 2 AND f.graph_id = $1 AND (f.subject_id = n.id OR f.object_id = n.id)
    \\    AND f.subject_id <> $2 AND f.object_id IS DISTINCT FROM $2
    \\    AND upper_inf(f.sys) AND f.valid @> 
++ as_of ++
    \\
    \\  ORDER BY f.confidence DESC, lower(f.valid) DESC NULLS LAST, f.id LIMIT 5) x ON true
    \\ORDER BY n.deg DESC, n.id
;

pub fn lookup(e: *mod.Engine, arena: std.mem.Allocator, params: mod.EntityParams) !EntityResult {
    const conn = try e.store.pool.acquire();
    defer conn.release();

    const as_id: ?core.Id = core.Id.parse(params.name_or_id) catch null;
    const key = try text.norm(arena, params.name_or_id);
    var found: std.ArrayList(core.Entity) = .empty;
    for ([_]bool{ false, true }) |fuzzy| {
        var result = try db.query(conn, arena, resolve_sql, .{ &e.graph_id.bytes, if (as_id) |i| @as(?[]const u8, &i.bytes) else null, key, fuzzy });
        defer result.deinit();
        while (try result.next()) |row| try found.append(arena, try readEntity(arena, row, 0));
        if (found.items.len > 0) break;
    }
    if (found.items.len == 0) return error.EntityNotFound;
    const root = found.items[0];

    var aliases: std.ArrayList([]const u8) = .empty;
    {
        var result = try db.query(
            conn,
            arena,
            "SELECT DISTINCT a.alias FROM entity_alias a JOIN entity m ON m.id = a.entity_id WHERE a.graph_id = $1 AND (m.id = $2 OR m.merged_into = $2) AND a.alias <> $3 ORDER BY 1 LIMIT 20",
            .{ &e.graph_id.bytes, &root.id.bytes, root.name },
        );
        defer result.deinit();
        while (try result.next()) |row| try aliases.append(arena, try db.text(arena, row, 0));
    }

    var facts: std.ArrayList(Hit) = .empty;
    {
        var result = try db.query(conn, arena, facts_sql, .{ &e.graph_id.bytes, &root.id.bytes, params.as_of, params.include_history, params.include_retracted });
        defer result.deinit();
        while (try result.next()) |row| try facts.append(arena, try db.readHit(arena, row));
    }

    var neighbors: std.ArrayList(Neighbor) = .empty;
    {
        var result = try db.query(conn, arena, neighbors_sql, .{ &e.graph_id.bytes, &root.id.bytes, params.as_of, @as(i32, if (params.depth >= 2) 2 else 1) });
        defer result.deinit();
        var current: ?*Neighbor = null;
        var current_facts: std.ArrayList(Hit) = .empty;
        while (try result.next()) |row| {
            const id = try db.id(row, 0);
            if (current == null or !current.?.entity.id.eql(id)) {
                if (current) |c| c.facts = current_facts.items;
                current_facts = .empty;
                try neighbors.append(arena, .{ .entity = try readEntity(arena, row, 0) });
                current = &neighbors.items[neighbors.items.len - 1];
            }
            if (try row.get(?[]const u8, 8) != null) {
                var r = Shifted(@TypeOf(row)){ .row = row, .by = 8 };
                try current_facts.append(arena, try db.readHit(arena, &r));
            }
        }
        if (current) |c| c.facts = current_facts.items;
    }

    return .{
        .entity = .{ .entity = root, .aliases = aliases.items },
        .alternatives = found.items[1..],
        .facts = facts.items,
        .neighbors = neighbors.items,
        .as_of = params.as_of orelse time.now(e.io),
    };
}

fn Shifted(comptime Row: type) type {
    return struct {
        row: Row,
        by: usize,

        pub fn get(s: *@This(), comptime T: type, col: usize) !T {
            return s.row.get(T, col + s.by);
        }
    };
}

pub const ForgetTarget = struct {
    fact_id: ?core.Id = null,
    query: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub const ForgetResult = struct {
    forgotten: []const Hit = &.{},
    /// Set when a query matched several facts: nothing was forgotten.
    candidates: []const Hit = &.{},
};

const candidates_sql =
    \\SELECT 
++ db.hit_columns ++
    \\
    \\FROM fact f JOIN entity se ON se.id = f.subject_id LEFT JOIN entity oe ON oe.id = f.object_id
    \\WHERE f.graph_id = $1 AND upper_inf(f.sys)
    \\  AND (($2::uuid IS NOT NULL AND f.id = $2::uuid)
    \\    OR ($3::text IS NOT NULL AND (f.tsv @@ plainto_tsquery('english', $3::text) OR f.text ILIKE '%' || $3::text || '%')))
    \\ORDER BY ts_rank_cd(f.tsv, plainto_tsquery('english', coalesce($3::text, ''))) DESC, f.confidence DESC, f.id
    \\LIMIT 10
;

pub fn forget(e: *mod.Engine, arena: std.mem.Allocator, target: ForgetTarget) !ForgetResult {
    if (target.fact_id == null and (target.query == null or target.query.?.len == 0)) return error.MissingForgetTarget;
    const conn = try e.store.pool.acquire();
    defer conn.release();

    var matches: std.ArrayList(Hit) = .empty;
    {
        var result = try db.query(conn, arena, candidates_sql, .{
            &e.graph_id.bytes,
            if (target.fact_id) |i| @as(?[]const u8, &i.bytes) else null,
            if (target.fact_id == null) target.query else null,
        });
        defer result.deinit();
        while (try result.next()) |row| try matches.append(arena, try db.readHit(arena, row));
    }
    if (matches.items.len == 0) return .{};
    if (matches.items.len > 1) return .{ .candidates = matches.items };

    const hit = matches.items[0];
    var fact_hex: [36]u8 = undefined;
    const note = try std.json.Stringify.valueAlloc(arena, .{
        .text = try std.fmt.allocPrint(arena, "Forget: {s}{s}{s}", .{ hit.fact.text, if (target.reason != null) " Reason: " else "", target.reason orelse "" }),
        .forget = hit.fact.id.toString(&fact_hex),
        .at = time.now(e.io),
    }, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(note, &hash, .{});
    const episode_id = core.Id.v7(e.io);
    const quote: ?[]const u8 = if (target.reason) |r| r[0..@min(r.len, 200)] else null;

    try conn.begin();
    errdefer conn.rollback() catch {};
    const updated = try db.exec(conn,
        \\UPDATE fact SET sys = tstzrange(lower(sys), greatest(now(), lower(sys) + interval '1 microsecond')), end_kind = 'forgotten'
        \\WHERE graph_id = $1 AND id = $2 AND upper_inf(sys)
    , .{ &e.graph_id.bytes, &hit.fact.id.bytes });
    if ((updated orelse 0) == 0) {
        try conn.rollback();
        return .{};
    }
    _ = try db.exec(conn,
        \\INSERT INTO episode (id, graph_id, kind, project, asserted_by, body, content_hash, reference_time, status)
        \\VALUES ($1, $2, 'note', $3, 'user', $4::jsonb, $5, now(), 'committed')
    , .{ &episode_id.bytes, &e.graph_id.bytes, hit.fact.project, note, @as([]const u8, &hash) });
    _ = try db.exec(
        conn,
        "INSERT INTO fact_provenance (fact_id, episode_id, role, quote) VALUES ($1, $2, 'forgotten', $3)",
        .{ &hit.fact.id.bytes, &episode_id.bytes, quote },
    );
    _ = try db.exec(conn, "NOTIFY graf_commit", .{});
    try conn.commit();

    var forgotten = hit;
    forgotten.fact.end_kind = .forgotten;
    forgotten.fact.sys.upper = time.now(e.io);
    return .{ .forgotten = try arena.dupe(Hit, &.{forgotten}) };
}
