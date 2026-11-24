const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");
const pg = @import("pg");
const pipeline = @import("pipeline.zig");
const resolve = @import("resolve.zig");
const rebase = @import("rebase.zig");
const prompt = @import("prompt.zig");

const Allocator = std.mem.Allocator;
const Id = core.Id;

pub const ClientModel = struct {
    client: *llm.Client,
    last: ?llm.Failure = null,

    const has_failure_out = @hasField(llm.StructuredRequest, "failure");
    const has_repaired = @hasField(llm.StructuredResponse, "repaired");

    fn blank() llm.Failure {
        return .{ .class = .network_not_sent, .certainty = .not_sent };
    }

    fn capture(m: *ClientModel, slot: *const llm.Failure, err: anyerror) anyerror {
        m.last = if (err != error.ProviderFailed) null else if (comptime has_failure_out) slot.* else m.client.last_failure;
        return err;
    }

    fn completion(r: llm.StructuredResponse) pipeline.Completion {
        return .{ .json = r.json, .repaired = if (comptime has_repaired) r.repaired else false };
    }

    pub fn structured(m: *ClientModel, arena: Allocator, req_in: llm.StructuredRequest) !pipeline.Completion {
        var req = req_in;
        var slot = blank();
        if (comptime has_failure_out) req.failure = &slot;
        const r = m.client.structured(arena, req) catch |err| return m.capture(&slot, err);
        return completion(r);
    }

    pub fn repair(m: *ClientModel, arena: Allocator, req_in: llm.StructuredRequest, broken: []const u8, problem: []const u8) !pipeline.Completion {
        var req = req_in;
        var slot = blank();
        if (comptime has_failure_out) req.failure = &slot;
        if (comptime @hasDecl(llm.Client, "repair")) {
            const r = m.client.repair(arena, req, broken, problem) catch |err| return m.capture(&slot, err);
            return .{ .json = r.json, .repaired = true };
        }
        req.purpose = .repair;
        req.system = prompt.repair_system;
        req.user = try prompt.repairUser(arena, problem, broken);
        const r = m.client.structured(arena, req) catch |err| return m.capture(&slot, err);
        return .{ .json = r.json, .repaired = true };
    }

    pub fn embed(m: *ClientModel, arena: Allocator, req_in: llm.EmbedRequest) !llm.EmbedResponse {
        var req = req_in;
        var slot = blank();
        if (comptime @hasField(llm.EmbedRequest, "failure")) req.failure = &slot;
        return m.client.embed(arena, req) catch |err| return m.capture(&slot, err);
    }

    pub fn decide(m: *ClientModel, arena: Allocator, purpose: core.types.LlmPurpose, questions: []const llm.Question) ![]const llm.Answer {
        return m.client.decide(arena, purpose, questions);
    }

    pub fn decisionEnabled(m: *ClientModel) bool {
        return m.client.config.decisionEnabled();
    }

    pub fn failure(m: *ClientModel) ?pipeline.ModelFailure {
        const f = m.last orelse return null;
        const disposition: pipeline.Disposition = if (comptime @hasField(llm.Failure, "disposition"))
            std.meta.stringToEnum(pipeline.Disposition, @tagName(f.disposition)) orelse .dead
        else
            pipeline.dispositionForClass(@tagName(f.class));
        return .{ .disposition = disposition, .retry_after_ms = f.retry_after_ms };
    }
};

pub fn idText(id: Id, buf: *[36]u8) []const u8 {
    return id.toString(buf);
}

pub fn jsonRow(comptime T: type, arena: Allocator, conn: *pg.Conn, sql: []const u8, args: anytype) !T {
    var row = (try conn.row(sql, args)) orelse return error.NoRows;
    defer row.deinit() catch {};
    const text = try arena.dupe(u8, try row.get([]const u8, 0));
    return std.json.parseFromSliceLeaky(T, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn logPgError(conn: *pg.Conn, err: anyerror) anyerror {
    if (err == error.PG) if (conn.err) |e| std.log.err("postgres: {s}", .{e.message});
    return err;
}

pub const context_sql =
    \\WITH me AS (SELECT source_id FROM entry WHERE id = $1::uuid)
    \\SELECT json_build_object(
    \\  'prior', COALESCE((SELECT json_agg(p ORDER BY p.reference_time) FROM (
    \\      SELECT (extract(epoch FROM e.reference_time) * 1000000)::bigint AS reference_time,
    \\             COALESCE((SELECT json_agg(x->>'text') FROM jsonb_array_elements(e.extraction->'facts') x), '[]'::json) AS facts,
    \\             left(COALESCE(e.body->>'text', (SELECT string_agg(t->>'text', ' ') FROM jsonb_array_elements(e.body->'turns') t), ''), 300) AS excerpt
    \\      FROM entry e, me
    \\      WHERE me.source_id IS NOT NULL AND e.source_id = me.source_id AND e.status = 'committed' AND e.id <> $1::uuid
    \\      ORDER BY e.seq_in_source DESC, e.reference_time DESC LIMIT 3) p), '[]'::json),
    \\  'relations', COALESCE((SELECT json_agg(json_build_object(
    \\      'name', p.name, 'cardinality', p.cardinality, 'opposes', p.opposes, 'status', p.status,
    \\      'mapped_to', p.mapped_to, 'description', p.description,
    \\      'emb', COALESCE(pe.emb::text::json, '[]'::json)) ORDER BY p.name)
    \\    FROM relation p LEFT JOIN relation_embedding pe ON pe.graph_id = p.graph_id AND pe.name = p.name
    \\    WHERE p.graph_id = $2::uuid), '[]'::json),
    \\  'core_embeddings', COALESCE((SELECT json_agg(json_build_object('name', pe.name, 'emb', pe.emb::text::json))
    \\    FROM relation_embedding pe WHERE pe.graph_id = $2::uuid), '[]'::json)
    \\)::text
;

pub const prefetch_sql =
    \\WITH req AS (SELECT $1::jsonb AS r),
    \\ent_in AS (
    \\  SELECT (e.ord - 1)::int AS item, (e.value->'emb')::text::halfvec(512) AS emb
    \\  FROM req, jsonb_array_elements(r->'entities') WITH ORDINALITY e(value, ord)
    \\),
    \\ent_norms AS (
    \\  SELECT (e.ord - 1)::int AS item, n.value #>> '{}' AS norm
    \\  FROM req, jsonb_array_elements(r->'entities') WITH ORDINALITY e(value, ord), jsonb_array_elements(e.value->'norms') n
    \\),
    \\hits AS (
    \\  SELECT en.item, COALESCE(x.merged_into, x.id) AS id, true AS alias
    \\  FROM ent_norms en JOIN entity_alias a ON a.graph_id = $2::uuid AND a.norm = en.norm JOIN entity x ON x.id = a.entity_id
    \\  UNION ALL
    \\  SELECT en.item, COALESCE(x.merged_into, x.id), true
    \\  FROM ent_norms en JOIN entity x ON x.graph_id = $2::uuid AND x.norm = en.norm
    \\  UNION ALL
    \\  SELECT ei.item, k.id, false FROM ent_in ei CROSS JOIN LATERAL (
    \\    SELECT x.id FROM entity x WHERE x.graph_id = $2::uuid AND x.merged_into IS NULL AND x.name_emb IS NOT NULL
    \\    ORDER BY x.name_emb <=> ei.emb LIMIT 5) k
    \\  UNION ALL
    \\  SELECT en.item, COALESCE(x.merged_into, x.id), false FROM ent_norms en CROSS JOIN LATERAL (
    \\    SELECT a.entity_id FROM entity_alias a WHERE a.graph_id = $2::uuid AND a.norm % en.norm
    \\    ORDER BY similarity(a.norm, en.norm) DESC LIMIT 5) t JOIN entity x ON x.id = t.entity_id
    \\),
    \\ent_out AS (
    \\  SELECT h.item, x.id, x.name, x.norm, x.type, bool_or(h.alias) AS alias_match,
    \\         CASE WHEN x.name_emb IS NULL THEN 0 ELSE 1 - (x.name_emb <=> ei.emb) END AS cosine
    \\  FROM hits h JOIN entity x ON x.id = h.id AND x.merged_into IS NULL JOIN ent_in ei ON ei.item = h.item
    \\  GROUP BY h.item, x.id, x.name, x.norm, x.type, x.name_emb, ei.emb
    \\),
    \\fact_in AS (
    \\  SELECT (f.ord - 1)::int AS item, (f.value->>'subject')::int AS subject, (f.value->>'object')::int AS object,
    \\         f.value->>'relation' AS relation, f.value->>'opposed' AS opposed, f.value->>'text' AS text,
    \\         (f.value->'emb')::text::halfvec(512) AS emb
    \\  FROM req, jsonb_array_elements(r->'facts') WITH ORDINALITY f(value, ord)
    \\),
    \\linked AS (
    \\  SELECT item, id FROM ent_out WHERE alias_match OR cosine >= 0.70
    \\),
    \\fact_hits AS (
    \\  SELECT fi.item, f.id FROM fact_in fi JOIN linked l ON l.item = fi.subject
    \\  JOIN fact f ON f.graph_id = $2::uuid AND f.subject_id = l.id AND upper_inf(f.known) AND upper_inf(f.valid)
    \\    AND (f.relation = fi.relation OR f.relation = fi.opposed)
    \\  UNION
    \\  SELECT fi.item, f.id FROM fact_in fi JOIN linked l ON l.item = fi.object
    \\  JOIN fact f ON f.graph_id = $2::uuid AND f.object_id = l.id AND upper_inf(f.known) AND upper_inf(f.valid)
    \\    AND f.relation = fi.relation
    \\  UNION
    \\  SELECT fi.item, k.id FROM fact_in fi CROSS JOIN LATERAL (
    \\    SELECT f.id FROM fact f WHERE f.graph_id = $2::uuid AND upper_inf(f.known) AND upper_inf(f.valid)
    \\    ORDER BY f.emb <=> fi.emb LIMIT 8) k
    \\  UNION
    \\  SELECT fi.item, k.id FROM fact_in fi CROSS JOIN LATERAL (
    \\    SELECT f.id FROM fact f, replace(plainto_tsquery('english', fi.text)::text, '&', '|') q
    \\    WHERE q <> '' AND f.graph_id = $2::uuid AND upper_inf(f.known) AND upper_inf(f.valid) AND f.tsv @@ q::tsquery
    \\    ORDER BY ts_rank_cd(f.tsv, q::tsquery) DESC LIMIT 8) k
    \\),
    \\fact_out AS (
    \\  SELECT h.item, f.id, f.subject_id, f.relation, f.qualifier, f.object_id, f.object_value, f.text, f.confidence,
    \\         CASE WHEN lower_inf(f.valid) OR NOT isfinite(lower(f.valid)) THEN NULL ELSE (extract(epoch FROM lower(f.valid)) * 1000000)::bigint END AS valid_lower,
    \\         CASE WHEN upper_inf(f.valid) OR NOT isfinite(upper(f.valid)) THEN NULL ELSE (extract(epoch FROM upper(f.valid)) * 1000000)::bigint END AS valid_upper,
    \\         1 - (f.emb <=> fi.emb) AS cosine
    \\  FROM fact_hits h JOIN fact f ON f.id = h.id JOIN fact_in fi ON fi.item = h.item
    \\)
    \\SELECT json_build_object(
    \\  'base_seq', (SELECT COALESCE(MAX(seq), 0) FROM commit_log WHERE graph_id = $2::uuid),
    \\  'entities', COALESCE((SELECT json_agg(ent_out) FROM ent_out), '[]'::json),
    \\  'facts', COALESCE((SELECT json_agg(fact_out) FROM fact_out), '[]'::json),
    \\  'blocked', COALESCE((SELECT json_agg(json_build_object('a', m.entity_a, 'b', m.entity_b)) FROM must_not_merge m
    \\    WHERE m.graph_id = $2::uuid AND m.entity_a IN (SELECT id FROM ent_out) AND m.entity_b IN (SELECT id FROM ent_out)), '[]'::json)
    \\)::text
;

pub const touched_sql =
    \\WITH log AS (SELECT touched_entities, touched_facts FROM commit_log WHERE graph_id = $1::uuid AND seq > $2 AND seq <= $3),
    \\te AS (SELECT DISTINCT unnest(touched_entities) AS id FROM log),
    \\tf AS (SELECT DISTINCT unnest(touched_facts) AS id FROM log)
    \\SELECT json_build_object(
    \\  'entities', COALESCE((SELECT json_agg(json_build_object(
    \\      'id', e.id, 'name', e.name, 'norm', e.norm, 'type', e.type, 'merged_into', e.merged_into,
    \\      'aliases', COALESCE((SELECT json_agg(a.norm) FROM entity_alias a WHERE a.entity_id = e.id), '[]'::json),
    \\      'emb', COALESCE(e.name_emb::text::json, '[]'::json)))
    \\    FROM entity e JOIN te ON te.id = e.id), '[]'::json),
    \\  'facts', COALESCE((SELECT json_agg(json_build_object(
    \\      'active', upper_inf(f.known) AND upper_inf(f.valid),
    \\      'fact', json_build_object('item', 0, 'id', f.id, 'subject_id', f.subject_id, 'relation', f.relation,
    \\        'qualifier', f.qualifier, 'object_id', f.object_id, 'object_value', f.object_value, 'text', f.text,
    \\        'confidence', f.confidence,
    \\        'valid_lower', CASE WHEN lower_inf(f.valid) OR NOT isfinite(lower(f.valid)) THEN NULL ELSE (extract(epoch FROM lower(f.valid)) * 1000000)::bigint END,
    \\        'valid_upper', CASE WHEN upper_inf(f.valid) OR NOT isfinite(upper(f.valid)) THEN NULL ELSE (extract(epoch FROM upper(f.valid)) * 1000000)::bigint END)))
    \\    FROM fact f JOIN tf ON tf.id = f.id), '[]'::json)
    \\)::text
;

const ContextRow = struct {
    prior: []const prompt.PriorEntry = &.{},
    relations: []const resolve.RelationRow = &.{},
    core_embeddings: []const struct { name: []const u8, emb: []const f32 } = &.{},
};

pub const PgBackend = struct {
    store: *store.Store,
    graph_id: Id,
    io: std.Io,
    worker: []const u8 = "graf",

    pub fn claim(b: *PgBackend, arena: Allocator) !?store.Lease {
        return b.store.claim(arena, b.graph_id, b.worker);
    }

    pub fn loadContext(b: *PgBackend, arena: Allocator, lease: store.Lease) !pipeline.Context {
        const conn = try b.store.pool.acquire();
        defer conn.release();
        var ebuf: [36]u8 = undefined;
        var gbuf: [36]u8 = undefined;
        const row = jsonRow(ContextRow, arena, conn, context_sql, .{ idText(lease.entry_id, &ebuf), idText(b.graph_id, &gbuf) }) catch |err| return logPgError(conn, err);
        var preds: std.ArrayList(resolve.RelationRow) = .empty;
        try preds.appendSlice(arena, row.relations);
        for (core.ontology.core_relations) |cp| {
            var present = false;
            for (row.relations) |p| if (std.mem.eql(u8, p.name, cp.name)) {
                present = true;
            };
            if (present) continue;
            var emb: []const f32 = &.{};
            for (row.core_embeddings) |ce| if (std.mem.eql(u8, ce.name, cp.name)) {
                emb = ce.emb;
            };
            try preds.append(arena, .{ .name = cp.name, .cardinality = cp.cardinality, .opposes = cp.opposes, .status = .core, .description = cp.description, .emb = emb });
        }
        return .{ .prior = row.prior, .relations = preds.items };
    }

    pub fn saveExtraction(b: *PgBackend, lease: store.Lease, json: []const u8) !void {
        return b.store.saveExtraction(lease, json);
    }

    pub fn saveRelationEmbeddings(b: *PgBackend, lease: store.Lease, names: []const []const u8, embs: []const []const f32) !void {
        _ = lease;
        var arena_state = std.heap.ArenaAllocator.init(b.store.allocator);
        defer arena_state.deinit();
        const payload = try std.json.Stringify.valueAlloc(arena_state.allocator(), .{ .names = names, .embs = embs }, .{});
        const conn = try b.store.pool.acquire();
        defer conn.release();
        var gbuf: [36]u8 = undefined;
        _ = conn.exec(
            \\INSERT INTO relation_embedding (graph_id, name, emb)
            \\SELECT $1::uuid, n.value #>> '{}', (($2::jsonb)->'embs'->((n.ord - 1)::int))::text::halfvec(512)
            \\FROM jsonb_array_elements(($2::jsonb)->'names') WITH ORDINALITY n(value, ord)
            \\ON CONFLICT (graph_id, name) DO UPDATE SET emb = EXCLUDED.emb
        , .{ idText(b.graph_id, &gbuf), payload }) catch |err| return logPgError(conn, err);
    }

    pub fn prefetch(b: *PgBackend, arena: Allocator, lease: store.Lease, req: pipeline.PrefetchRequest) !resolve.Prefetch {
        _ = lease;
        const payload = try prefetchPayload(arena, req);
        const conn = try b.store.pool.acquire();
        defer conn.release();
        var gbuf: [36]u8 = undefined;
        try conn.begin();
        errdefer conn.rollback() catch {};
        _ = conn.exec("SET LOCAL hnsw.iterative_scan = relaxed_order", .{}) catch |err| return logPgError(conn, err);
        const out = jsonRow(resolve.Prefetch, arena, conn, prefetch_sql, .{ payload, idText(b.graph_id, &gbuf) }) catch |err| return logPgError(conn, err);
        try conn.commit();
        return out;
    }

    pub fn saveChangeSet(b: *PgBackend, lease: store.Lease, cs: *const core.ChangeSet) !void {
        return b.store.saveChangeSet(lease, cs);
    }

    const RebaseCtx = struct {
        arena: Allocator,
        graph_id: Id,
        reference_time: core.Micros,
        io: std.Io,
        duplicates: []const rebase.PossibleDuplicate = &.{},

        fn run(ptr: *anyopaque, conn: *pg.Conn, cs: *core.ChangeSet, base_seq: i64, latest_seq: i64) anyerror!void {
            const ctx: *RebaseCtx = @ptrCast(@alignCast(ptr));
            var gbuf: [36]u8 = undefined;
            const touched = jsonRow(rebase.Touched, ctx.arena, conn, touched_sql, .{ idText(ctx.graph_id, &gbuf), base_seq, latest_seq }) catch |err| return logPgError(conn, err);
            const out = try rebase.apply(ctx.arena, cs, touched, pipeline.now(ctx.io), ctx.reference_time);
            ctx.duplicates = out.possible_duplicates;
        }
    };

    pub fn commit(b: *PgBackend, arena: Allocator, lease: store.Lease, cs: *const core.ChangeSet) !store.CommitResult {
        var ctx: RebaseCtx = .{ .arena = arena, .graph_id = b.graph_id, .reference_time = lease.entry.reference_time, .io = b.io };
        const result = try b.store.commit(lease, cs, .{ .ptr = &ctx, .run = RebaseCtx.run });
        if (result == .committed and ctx.duplicates.len > 0) try b.recordDuplicates(arena, ctx.duplicates);
        return result;
    }

    fn recordDuplicates(b: *PgBackend, arena: Allocator, dups: []const rebase.PossibleDuplicate) !void {
        var rows: std.ArrayList(struct { id: Id, a: Id, b: Id, score: f32 }) = .empty;
        for (dups) |d| try rows.append(arena, .{ .id = Id.v7(b.io), .a = d.a, .b = d.b, .score = d.score });
        const payload = try std.json.Stringify.valueAlloc(arena, rows.items, .{});
        const conn = try b.store.pool.acquire();
        defer conn.release();
        var gbuf: [36]u8 = undefined;
        _ = conn.exec(
            \\INSERT INTO possible_duplicate (id, graph_id, entity_a, entity_b, score)
            \\SELECT (d->>'id')::uuid, $1::uuid, (d->>'a')::uuid, (d->>'b')::uuid, (d->>'score')::real
            \\FROM jsonb_array_elements($2::jsonb) d
            \\WHERE EXISTS (SELECT 1 FROM entity WHERE id = (d->>'a')::uuid) AND EXISTS (SELECT 1 FROM entity WHERE id = (d->>'b')::uuid)
        , .{ idText(b.graph_id, &gbuf), payload }) catch |err| return logPgError(conn, err);
    }

    pub fn afterCommit(b: *PgBackend, arena: Allocator, lease: store.Lease, cs: *const core.ChangeSet) !void {
        _ = lease;
        var entities: std.ArrayList(Id) = .empty;
        for (cs.new_facts) |nf| {
            try entities.append(arena, nf.fact.subject_id);
            switch (nf.fact.object) {
                .entity => |o| try entities.append(arena, o),
                .value => {},
            }
        }
        var facts: std.ArrayList(Id) = .empty;
        for (cs.invalidations) |inv| try facts.append(arena, inv.fact_id);
        for (cs.retractions) |r| try facts.append(arena, r.fact_id);
        if (entities.items.len == 0 and facts.items.len == 0) return;
        const payload = try std.json.Stringify.valueAlloc(arena, .{ .entities = entities.items, .facts = facts.items }, .{});
        const conn = try b.store.pool.acquire();
        defer conn.release();
        _ = conn.exec(bump_sql, .{payload}) catch |err| return logPgError(conn, err);
    }

    pub fn finish(b: *PgBackend, lease: store.Lease, t: pipeline.Transition) !void {
        var arena_state = std.heap.ArenaAllocator.init(b.store.allocator);
        defer arena_state.deinit();
        const conn = try b.store.pool.acquire();
        defer conn.release();
        try finishOn(arena_state.allocator(), conn, b.io, lease, t);
    }
};

pub const bump_sql =
    \\WITH ids AS (
    \\  SELECT x::uuid AS id FROM jsonb_array_elements_text(($1::jsonb)->'entities') x
    \\  UNION ALL
    \\  SELECT f.subject_id FROM fact f WHERE f.id IN (SELECT y::uuid FROM jsonb_array_elements_text(($1::jsonb)->'facts') y)
    \\)
    \\UPDATE entity e SET facts_since_summary = e.facts_since_summary + c.n
    \\FROM (SELECT id, count(*)::int AS n FROM ids GROUP BY id) c WHERE e.id = c.id
;

const fence = " WHERE id = $1::uuid AND lease_token = $2 AND status IN ('extracting', 'extracted', 'staged')";
const release = ", lease_owner = NULL, lease_token = NULL, lease_until = NULL";

pub fn finishOn(arena: Allocator, conn: *pg.Conn, io: std.Io, lease: store.Lease, t: pipeline.Transition) !void {
    var ebuf: [36]u8 = undefined;
    const eid = idText(lease.entry_id, &ebuf);
    const affected: ?i64 = switch (t) {
        .skipped => |why| conn.exec("UPDATE entry SET status = 'skipped', warnings = warnings || jsonb_build_array($3::text)" ++ release ++ fence, .{ eid, lease.token, why }),
        .dead => |why| conn.exec("UPDATE entry SET status = 'dead', last_error = jsonb_build_object('reason', $3::text)" ++ release ++ fence, .{ eid, lease.token, why }),
        .requeue => |r| conn.exec(
            "UPDATE entry SET status = CASE WHEN extraction IS NULL THEN 'queued' ELSE 'extracted' END, attempts = attempts + $3, " ++
                "not_before = now() + make_interval(secs => $4::float8 / 1000), last_error = jsonb_build_object('reason', $5::text)" ++ release ++ fence,
            .{ eid, lease.token, @as(i32, if (r.count_attempt) 1 else 0), @as(f64, @floatFromInt(r.delay_ms)), r.reason },
        ),
        .split => |halves| blk: {
            try conn.begin();
            errdefer conn.rollback() catch {};
            const n = (conn.exec("UPDATE entry SET status = 'split'" ++ release ++ fence, .{ eid, lease.token }) catch |err| return logPgError(conn, err)) orelse 0;
            if (n == 0) {
                try conn.rollback();
                break :blk 0;
            }
            for (halves) |h| {
                const body = try std.json.Stringify.valueAlloc(arena, h, .{});
                var cbuf: [36]u8 = undefined;
                _ = conn.exec(
                    \\INSERT INTO entry (id, graph_id, source_id, seq_in_source, kind, project, author, body, content_hash, reference_time)
                    \\SELECT $2::uuid, graph_id, source_id, seq_in_source, kind, project, author, $3::jsonb, sha256(convert_to($3::text, 'UTF8')), reference_time
                    \\FROM entry WHERE id = $1::uuid
                    \\ON CONFLICT (graph_id, content_hash) DO NOTHING
                , .{ eid, idText(Id.v7(io), &cbuf), body }) catch |err| return logPgError(conn, err);
            }
            try conn.commit();
            break :blk n;
        },
    } catch |err| return logPgError(conn, err);
    if ((affected orelse 0) == 0) return error.LeaseLost;
}

pub fn prefetchPayload(arena: Allocator, req: pipeline.PrefetchRequest) ![]const u8 {
    const E = struct { norms: []const []const u8, emb: []const f32 };
    const F = struct { subject: u32, object: ?u32, relation: []const u8, opposed: ?[]const u8, text: []const u8, emb: []const f32 };
    const ents = try arena.alloc(E, req.entity_norms.len);
    for (ents, 0..) |*e, i| e.* = .{ .norms = req.entity_norms[i], .emb = req.entity_embs[i] };
    const facts = try arena.alloc(F, req.fact_subject.len);
    for (facts, 0..) |*f, j| f.* = .{
        .subject = req.fact_subject[j],
        .object = req.fact_object[j],
        .relation = req.fact_relations[j],
        .opposed = req.fact_opposed[j],
        .text = req.fact_texts[j],
        .emb = req.fact_embs[j],
    };
    return std.json.Stringify.valueAlloc(arena, .{ .entities = ents, .facts = facts }, .{});
}
