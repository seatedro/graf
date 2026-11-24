const std = @import("std");
const core = @import("core");
const store = @import("store");
const pg = @import("pg");
const db = @import("db.zig");
const rank = @import("rank.zig");
const time = @import("time.zig");
const mod = @import("mod.zig");

const as_of = "coalesce($4::timestamptz, now())";
const known_at = "coalesce($5::timestamptz, now())";
const qvec = "$3::float4[]::halfvec(512)";
const tsq = "replace(plainto_tsquery('english', $2::text)::text, '&', '|')::tsquery";

const eligible =
    "f.graph_id = $1 AND f.known @> " ++ known_at ++
    " AND (f.valid @> " ++ as_of ++ " OR ($7::bool AND upper(f.valid) <= " ++ as_of ++ "))" ++
    " AND ($6::text = '*' OR f.scope = 'global' OR f.project = $6::text)" ++
    " AND ($8::text IS NULL OR EXISTS (SELECT 1 FROM fact_evidence hp JOIN entry he ON he.id = hp.entry_id" ++
    " JOIN source hs ON hs.id = he.source_id WHERE hp.fact_id = f.id AND hs.harness = $8::text))";

pub const sql =
    \\WITH vec AS (
    \\  SELECT id, row_number() OVER (ORDER BY d) AS r FROM (
    \\    SELECT f.id, f.emb <=> 
++ qvec ++
    \\ AS d FROM fact f
    \\    WHERE $3::float4[] IS NOT NULL AND 
++ eligible ++
    \\
    \\    ORDER BY f.emb <=> 
++ qvec ++
    \\ LIMIT 30) v
    \\), lex AS (
    \\  SELECT id, row_number() OVER (ORDER BY rk DESC, id) AS r FROM (
    \\    SELECT f.id, ts_rank_cd(f.tsv, 
++ tsq ++
    \\) AS rk FROM fact f
    \\    WHERE f.tsv @@ 
++ tsq ++
    \\ AND 
++ eligible ++
    \\
    \\    ORDER BY rk DESC LIMIT 30) l
    \\), seed_hits AS (
    \\  SELECT a.entity_id AS id, 2.0 + length(a.norm) / 100.0 AS score FROM entity_alias a
    \\  WHERE a.graph_id = $1 AND length(a.norm) >= 2 AND position(' ' || a.norm || ' ' IN ' ' || $9::text || ' ') > 0
    \\  UNION ALL
    \\  SELECT e.id, 2.0 + length(e.norm) / 100.0 FROM entity e
    \\  WHERE e.graph_id = $1 AND length(e.norm) >= 2 AND position(' ' || e.norm || ' ' IN ' ' || $9::text || ' ') > 0
    \\  UNION ALL
    \\  SELECT a.entity_id, 1.0 + word_similarity(a.norm, $9::text) FROM entity_alias a
    \\  WHERE a.graph_id = $1 AND length(a.norm) >= 3 AND a.norm <% $9::text
    \\  UNION ALL
    \\  SELECT id, sim FROM (
    \\    SELECT e.id, 1 - (e.name_emb <=> 
++ qvec ++
    \\) AS sim FROM entity e
    \\    WHERE $3::float4[] IS NOT NULL AND e.graph_id = $1 AND e.merged_into IS NULL AND e.name_emb IS NOT NULL
    \\    ORDER BY e.name_emb <=> 
++ qvec ++
    \\ LIMIT 6) ev WHERE sim >= 0.35
    \\), seeds AS (
    \\  SELECT id AS entity_id, row_number() OVER (ORDER BY score DESC, id) AS sr FROM (
    \\    SELECT coalesce(e.merged_into, e.id) AS id, max(h.score) AS score
    \\    FROM seed_hits h JOIN entity e ON e.id = h.id GROUP BY 1
    \\    ORDER BY 2 DESC, 1 LIMIT 6) s
    \\), hop AS (
    \\  SELECT id, row_number() OVER (ORDER BY sr, hr, id) AS r FROM (
    \\    SELECT DISTINCT ON (x.id) x.id, s.sr, x.hr FROM seeds s
    \\    CROSS JOIN LATERAL (
    \\      SELECT f.id, row_number() OVER (ORDER BY CASE WHEN $3::float4[] IS NULL THEN 0 ELSE f.emb <=> 
++ qvec ++
    \\ END, f.confidence DESC, f.id) AS hr
    \\      FROM fact f WHERE (f.subject_id = s.entity_id OR f.object_id = s.entity_id) AND 
++ eligible ++
    \\
    \\      ORDER BY hr LIMIT 6) x
    \\    ORDER BY x.id, s.sr, x.hr) g
    \\), cand AS (
    \\  SELECT id, max(rv) AS rv, max(rl) AS rl, max(rg) AS rg FROM (
    \\    SELECT id, r AS rv, NULL::bigint AS rl, NULL::bigint AS rg FROM vec
    \\    UNION ALL SELECT id, NULL, r, NULL FROM lex
    \\    UNION ALL SELECT id, NULL, NULL, r FROM hop) u GROUP BY id
    \\)
    \\SELECT 
++ db.hit_columns ++
    \\,
    \\  f.emb::real[], c.rv, c.rl, c.rg, se.description, se.summary, extract(epoch FROM 
++ as_of ++
    \\)::float8
    \\FROM cand c JOIN fact f ON f.id = c.id
    \\JOIN entity se ON se.id = f.subject_id
    \\LEFT JOIN entity oe ON oe.id = f.object_id
;

pub const Options = struct {
    embed: bool = true,
    rerank: bool = true,
};

pub fn run(e: *mod.Engine, arena: std.mem.Allocator, params: mod.SearchParams, opts: Options) !mod.SearchResult {
    const qnorm = try store.normalizeAlias(arena, params.query);
    const qemb: ?[]const f32 = if (!opts.embed) null else if (e.embedder) |em| em.embedQuery(arena, params.query) catch |err| blk: {
        db.log.warn("query embedding failed, searching without vectors: {s}", .{@errorName(err)});
        break :blk null;
    } else null;
    const filter = rank.ProjectFilter.from(params.project);

    var rows: std.ArrayList(Row) = .empty;
    var entities: std.ArrayList(core.Entity) = .empty;
    var as_of_us: core.Micros = 0;
    {
        const conn = try e.store.pool.acquire();
        defer conn.release();
        conn.begin() catch |err| {
            db.logError(conn, err, "search");
            return err;
        };
        errdefer conn.rollback() catch {};
        _ = conn.exec("SET LOCAL hnsw.iterative_scan = relaxed_order", .{}) catch |err| {
            db.logError(conn, err, "search");
            return err;
        };
        var result = conn.queryOpts(sql, .{
            &e.graph_id.bytes,
            params.query,
            qemb,
            params.as_of,
            params.known_at,
            filter.sqlParam(),
            params.include_history,
            if (params.harness) |h| @tagName(h) else null,
            qnorm,
        }, .{ .allocator = arena }) catch |err| {
            db.logError(conn, err, "search");
            return err;
        };
        defer result.deinit();
        var seen: std.AutoHashMapUnmanaged(core.Id, void) = .empty;
        while (try result.next()) |row| {
            const hit = try db.readHit(arena, row);
            const c = db.hit_column_count;
            try rows.append(arena, .{
                .hit = hit,
                .emb = try db.floats(arena, row, c),
                .ranks = .{ .vec = rankOf(try row.get(?i64, c + 1)), .lex = rankOf(try row.get(?i64, c + 2)), .graph = rankOf(try row.get(?i64, c + 3)) },
            });
            as_of_us = @intFromFloat(try row.get(f64, c + 6) * std.time.us_per_s);
            const gop = try seen.getOrPut(arena, hit.fact.subject_id);
            if (!gop.found_existing) try entities.append(arena, .{
                .id = hit.fact.subject_id,
                .graph_id = hit.fact.graph_id,
                .name = hit.subject_name,
                .norm = "",
                .type = hit.subject_type,
                .description = try db.text(arena, row, c + 4),
                .summary = try db.text(arena, row, c + 5),
            });
        }
        try conn.commit();
    }
    if (rows.items.len == 0) as_of_us = params.as_of orelse time.now(e.io);

    const cands = try arena.alloc(rank.Candidate, rows.items.len);
    for (rows.items, cands) |r, *c| {
        const f = r.hit.fact;
        const since = f.valid.lower orelse f.known.lower;
        c.* = .{
            .rrf = rank.rrf(r.ranks),
            .factors = rank.scopeBoost(filter, f.scope, f.project) * rank.recencyFactor(rank.ageDays(as_of_us, since)) * rank.confidenceFactor(f.confidence),
            .emb = r.emb,
        };
    }

    const reranked = opts.rerank and try rerank(e, arena, params.query, rows.items, cands);
    rank.score(cands, reranked);
    const order = try rank.mmr(arena, cands);
    const hits = try arena.alloc(mod.Hit, order.len);
    for (order, hits) |i, *h| {
        h.* = rows.items[i].hit;
        h.score = cands[i].score;
    }
    return .{ .hits = hits, .entities = entities.items, .reranked = reranked, .as_of = as_of_us };
}

const Row = struct {
    hit: mod.Hit,
    emb: []const f32,
    ranks: rank.Ranks,
};

fn rankOf(v: ?i64) ?u32 {
    return if (v) |x| @intCast(x) else null;
}

fn rerank(e: *mod.Engine, arena: std.mem.Allocator, query: []const u8, rows: []const Row, cands: []rank.Candidate) !bool {
    const reranker = e.reranker orelse return false;
    if (cands.len == 0) return false;
    const top = try rank.byRrf(arena, cands);
    const n = @min(top.len, rank.rerank_top);
    const texts = try arena.alloc([]const u8, n);
    for (top[0..n], texts) |i, *t| t.* = rows[i].hit.fact.text;

    var task_arena = std.heap.ArenaAllocator.init(e.gpa);
    defer task_arena.deinit();
    const probs = (try scoreWithin(e.io, reranker, task_arena.allocator(), query, texts, e.config.decision.rerank_timeout_ms)) orelse return false;
    if (probs.len != n) {
        db.log.warn("reranker returned {d} scores for {d} candidates; using fallback order", .{ probs.len, n });
        return false;
    }
    for (top[0..n], probs) |i, p| cands[i].relevance = std.math.clamp(p, 0, 1);
    return true;
}

const Race = union(enum) {
    scored: anyerror![]const f64,
    timeout: std.Io.Cancelable!void,
};

fn scoreWithin(io: std.Io, reranker: mod.Reranker, arena: std.mem.Allocator, query: []const u8, texts: []const []const u8, timeout_ms: u32) !?[]const f64 {
    var buf: [2]Race = undefined;
    var select = std.Io.Select(Race).init(io, &buf);
    defer select.cancelDiscard();
    select.concurrent(.scored, mod.Reranker.score, .{ reranker, arena, query, texts }) catch return null;
    select.concurrent(.timeout, std.Io.sleep, .{ io, .fromMilliseconds(timeout_ms), .awake }) catch return null;
    switch (try select.await()) {
        .scored => |res| return res catch |err| {
            if (err != error.DecisionDisabled) db.log.warn("rerank failed, using fallback order: {s}", .{@errorName(err)});
            return null;
        },
        .timeout => {
            db.log.info("rerank exceeded {d} ms, using fallback order", .{timeout_ms});
            return null;
        },
    }
}
