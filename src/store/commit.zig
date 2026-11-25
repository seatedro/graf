const std = @import("std");
const core = @import("core");
const pg = @import("pg");
const store = @import("mod.zig");

const Store = store.Store;
const Lease = store.Lease;
const Id = core.Id;
const dims = store.embedding_dims;

pub fn commit(s: *Store, lease: Lease, change_set: *const core.ChangeSet, rebase: ?store.Rebase) !store.CommitResult {
    var arena_state = std.heap.ArenaAllocator.init(s.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const gid: []const u8 = &lease.graph_id.bytes;
    const eid: []const u8 = &lease.entry_id.bytes;

    const conn = try s.pool.acquire();
    defer conn.release();

    try conn.begin();
    var done = false;
    defer if (!done) conn.rollback() catch {};

    _ = try conn.exec("SELECT pg_advisory_xact_lock(hashtextextended('graf:' || $1::uuid::text, 0))", .{gid});

    const fenced = try conn.exec(
        "UPDATE entry SET status = 'committing' WHERE id = $1 AND graph_id = $2 AND lease_token = $3 AND status = 'staged'",
        .{ eid, gid, lease.token },
    );
    if ((fenced orelse 0) == 0) {
        done = true;
        try conn.rollback();
        return .fenced;
    }

    var latest: i64 = undefined;
    var commit_ts: i64 = undefined;
    {
        var row = (try conn.row("SELECT COALESCE(max(seq), 0)::int8, clock_timestamp() FROM commit_log WHERE graph_id = $1", .{gid})).?;
        latest = try row.get(i64, 0);
        commit_ts = try row.get(i64, 1);
        try row.deinit();
    }

    var cs = change_set.*;
    if (latest > cs.base_seq) if (rebase) |r| try r.run(r.ptr, conn, &cs, cs.base_seq, latest);
    const seq = latest + 1;

    var touched_entities: std.ArrayList([]const u8) = .empty;
    var touched_facts: std.ArrayList([]const u8) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    try warnings.appendSlice(a, cs.warnings);

    try insertEntities(a, conn, gid, seq, &cs, &touched_entities);
    var applied_merges: std.ArrayList(core.ChangeSet.Merge) = .empty;
    for (0..cs.merges.len) |k| {
        const m = try orientMerge(s, a, conn, gid, &cs, k, &warnings) orelse continue;
        try applyMerge(s, a, conn, gid, seq, &m, &touched_entities, &touched_facts);
        try applied_merges.append(a, m);
    }
    cs.merges = applied_merges.items;
    try insertFacts(a, conn, gid, seq, commit_ts, cs.new_facts, &touched_facts);

    if (cs.restatements.len != 0) {
        const ids = try a.alloc([]const u8, cs.restatements.len);
        const conf = try a.alloc(f32, cs.restatements.len);
        for (cs.restatements, ids, conf) |*r, *id, *c| {
            id.* = &r.fact_id.bytes;
            c.* = r.confidence;
        }

        _ = try conn.exec(
            \\UPDATE fact f SET confidence = t.c
            \\FROM unnest($2::uuid[], $3::float4[]) AS t(id, c)
            \\WHERE f.id = t.id AND f.graph_id = $1
        , .{ gid, ids, conf });
        try touched_facts.appendSlice(a, ids);
    }

    if (cs.invalidations.len != 0) {
        const ids = try a.alloc([]const u8, cs.invalidations.len);
        const uppers = try a.alloc(i64, cs.invalidations.len);
        const ended_by = try a.alloc(?[]const u8, cs.invalidations.len);
        for (cs.invalidations, ids, uppers, ended_by) |*inv, *id, *up, *by| {
            id.* = &inv.fact_id.bytes;
            up.* = inv.valid_upper;
            by.* = if (inv.ended_by) |*e| &e.bytes else null;
        }

        const applied = try collectIds(a, conn,
            \\UPDATE fact f SET
            \\  valid = tstzrange(lower(f.valid), t.upper),
            \\  end_kind = 'changed',
            \\  ended_by = COALESCE(t.ended_by, f.ended_by)
            \\FROM unnest($2::uuid[], $3::timestamptz[], $4::uuid[]) AS t(id, upper, ended_by)
            \\WHERE f.id = t.id AND f.graph_id = $1
            \\  AND (upper_inf(f.valid) OR t.upper < upper(f.valid))
            \\  AND (lower_inf(f.valid) OR t.upper >= lower(f.valid))
            \\RETURNING f.id
        , .{ gid, ids, uppers, ended_by });

        for (cs.invalidations) |inv| {
            if (containsId(applied, &inv.fact_id.bytes)) continue;
            var buf: [36]u8 = undefined;
            try warnings.append(a, try std.fmt.allocPrint(a, "invalidation of fact {s} skipped: valid range already ends earlier or would end before it starts", .{inv.fact_id.toString(&buf)}));
        }
        try touched_facts.appendSlice(a, applied);
    }

    if (cs.retractions.len != 0) {
        const ids = try a.alloc([]const u8, cs.retractions.len);
        const kinds = try a.alloc([]const u8, cs.retractions.len);
        const ended_by = try a.alloc(?[]const u8, cs.retractions.len);
        for (cs.retractions, ids, kinds, ended_by) |*r, *id, *k, *by| {
            id.* = &r.fact_id.bytes;
            k.* = @tagName(r.end_kind);
            by.* = if (r.ended_by) |*e| &e.bytes else null;
        }

        const applied = try collectIds(a, conn,
            \\UPDATE fact f SET known = tstzrange(lower(f.known), $2), end_kind = t.end_kind, ended_by = t.ended_by
            \\FROM unnest($3::uuid[], $4::text[], $5::uuid[]) AS t(id, end_kind, ended_by)
            \\WHERE f.id = t.id AND f.graph_id = $1 AND upper_inf(f.known)
            \\RETURNING f.id
        , .{ gid, commit_ts, ids, kinds, ended_by });
        try touched_facts.appendSlice(a, applied);
    }

    if (cs.evidence.len != 0) {
        const ids = try a.alloc([]const u8, cs.evidence.len);
        const evidence_kinds = try a.alloc([]const u8, cs.evidence.len);
        const quotes = try a.alloc(?[]const u8, cs.evidence.len);
        for (cs.evidence, ids, evidence_kinds, quotes) |*ev, *id, *kind, *q| {
            id.* = &ev.fact_id.bytes;
            kind.* = @tagName(ev.kind);
            q.* = ev.quote;
        }

        _ = try conn.exec(
            \\INSERT INTO fact_evidence (fact_id, entry_id, kind, quote)
            \\SELECT t.fact_id, $1, t.kind, t.quote FROM unnest($2::uuid[], $3::text[], $4::text[]) AS t(fact_id, kind, quote)
            \\ON CONFLICT DO NOTHING
        , .{ eid, ids, evidence_kinds, quotes });
    }

    if (cs.mentions.len != 0) {
        const ids = try a.alloc([]const u8, cs.mentions.len);
        for (cs.mentions, ids) |*m, *id| id.* = &m.bytes;
        _ = try conn.exec(
            \\INSERT INTO entity_mention (entity_id, entry_id)
            \\SELECT DISTINCT t.id, $1::uuid FROM unnest($2::uuid[]) AS t(id)
            \\ON CONFLICT DO NOTHING
        , .{ eid, ids });
        try touched_entities.appendSlice(a, ids);
    }

    if (cs.new_relations.len != 0) {
        const n = cs.new_relations.len;
        const names = try a.alloc([]const u8, n);
        const descriptions = try a.alloc([]const u8, n);
        const cardinalities = try a.alloc([]const u8, n);
        const opposes = try a.alloc(?[]const u8, n);
        const object_kinds = try a.alloc([]const u8, n);
        const statuses = try a.alloc([]const u8, n);
        const mapped = try a.alloc(?[]const u8, n);

        for (cs.new_relations, 0..) |relation, i| {
            names[i] = relation.name;
            descriptions[i] = relation.description;
            cardinalities[i] = @tagName(relation.cardinality);
            opposes[i] = relation.opposes;
            object_kinds[i] = @tagName(relation.object_kind);
            statuses[i] = @tagName(relation.status);
            mapped[i] = relation.mapped_to;
        }

        _ = try conn.exec(
            \\INSERT INTO relation (graph_id, name, description, cardinality, opposes, object_kind, status, mapped_to)
            \\SELECT $1, t.* FROM unnest($2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[], $8::text[])
            \\  AS t(name, description, cardinality, opposes, object_kind, status, mapped_to)
            \\ON CONFLICT (graph_id, name) DO NOTHING
        , .{ gid, names, descriptions, cardinalities, opposes, object_kinds, statuses, mapped });
    }

    _ = try conn.exec(
        \\INSERT INTO commit_log (graph_id, seq, entry_id, committed_at, touched_entities, touched_facts)
        \\SELECT $1, $2, $3, $4,
        \\  ARRAY(SELECT DISTINCT x FROM (
        \\    SELECT unnest($5::uuid[]) AS x
        \\    UNION SELECT subject_id FROM fact WHERE id = ANY($6::uuid[])
        \\    UNION SELECT object_id FROM fact WHERE id = ANY($6::uuid[]) AND object_id IS NOT NULL) q ORDER BY x),
        \\  ARRAY(SELECT DISTINCT x FROM unnest($6::uuid[]) AS x ORDER BY x)
    , .{ gid, seq, eid, commit_ts, touched_entities.items, touched_facts.items });

    const final_json = try std.json.Stringify.valueAlloc(a, cs, .{});
    const warnings_json = try std.json.Stringify.valueAlloc(a, warnings.items, .{});
    _ = try conn.exec(
        \\UPDATE entry SET status = 'committed', commit_seq = $2, change_set = $3::jsonb,
        \\  warnings = warnings || $4::jsonb, lease_until = NULL,
        \\  cost_usd = (SELECT COALESCE(sum(cost_usd), 0) FROM llm_call WHERE entry_id = $1)
        \\WHERE id = $1
    , .{ eid, seq, final_json, warnings_json });

    _ = try conn.exec(
        \\SELECT pg_notify('graf_commit', json_build_object(
        \\  'graph_id', $1::uuid, 'seq', $2::int8, 'project', (SELECT project FROM entry WHERE id = $3))::text)
    , .{ gid, seq, eid });

    done = true;
    try conn.commit();
    return .{ .committed = .{ .seq = seq } };
}

fn insertEntities(a: std.mem.Allocator, conn: *pg.Conn, gid: []const u8, seq: i64, cs: *const core.ChangeSet, touched: *std.ArrayList([]const u8)) !void {
    var alias_norms: std.ArrayList([]const u8) = .empty;
    var alias_ids: std.ArrayList([]const u8) = .empty;
    var alias_texts: std.ArrayList([]const u8) = .empty;

    if (cs.new_entities.len != 0) {
        const n = cs.new_entities.len;
        const ids = try a.alloc([]const u8, n);
        const names = try a.alloc([]const u8, n);
        const norms = try a.alloc([]const u8, n);
        const types = try a.alloc([]const u8, n);
        const descriptions = try a.alloc([]const u8, n);
        const offsets = try a.alloc(i32, n);
        var flat: std.ArrayList(f32) = .empty;

        for (cs.new_entities, 0..) |*e, i| {
            ids[i] = &e.id.bytes;
            names[i] = e.name;
            norms[i] = e.norm;
            types[i] = @tagName(e.type);
            descriptions[i] = e.description;
            offsets[i] = 0;

            if (e.name_emb.len != 0) {
                if (e.name_emb.len != dims) return error.InvalidEmbedding;
                offsets[i] = @intCast(flat.items.len + 1);
                try flat.appendSlice(a, e.name_emb);
            }

            try alias_norms.append(a, e.norm);
            try alias_ids.append(a, ids[i]);
            try alias_texts.append(a, e.name);
            for (e.aliases) |alias| {
                try alias_norms.append(a, try core.text.norm(a, alias));
                try alias_ids.append(a, ids[i]);
                try alias_texts.append(a, alias);
            }
        }

        _ = try conn.exec(
            \\INSERT INTO entity (id, graph_id, name, norm, type, description, name_emb, created_seq, updated_seq)
            \\SELECT t.id, $1, t.name, t.norm, t.type, t.description,
            \\  CASE WHEN t.off > 0 THEN ($8::float4[])[t.off : t.off + 511]::halfvec(512) END, $9, $9
            \\FROM unnest($2::uuid[], $3::text[], $4::text[], $5::text[], $6::text[], $7::int[])
            \\  AS t(id, name, norm, type, description, off)
        , .{ gid, ids, names, norms, types, descriptions, offsets, flat.items, seq });
        try touched.appendSlice(a, ids);
    }

    for (cs.new_aliases) |*al| {
        try alias_norms.append(a, al.norm);
        try alias_ids.append(a, &al.entity_id.bytes);
        try alias_texts.append(a, al.alias);
    }

    if (alias_norms.items.len != 0) {
        _ = try conn.exec(
            \\INSERT INTO entity_alias (graph_id, norm, entity_id, alias)
            \\SELECT $1, t.norm, t.entity_id, t.alias FROM unnest($2::text[], $3::uuid[], $4::text[]) AS t(norm, entity_id, alias)
            \\WHERE t.norm <> ''
            \\ON CONFLICT DO NOTHING
        , .{ gid, alias_norms.items, alias_ids.items, alias_texts.items });
    }
}

pub const max_merge_facts = 100;

const MergeSide = struct { created_seq: i64, facts: i64 };

fn mergeSide(conn: *pg.Conn, gid: []const u8, id: *const Id) !?MergeSide {
    var row = (try conn.row(
        \\SELECT e.created_seq,
        \\  (SELECT count(*) FROM fact f WHERE f.graph_id = $1 AND (f.subject_id = e.id OR f.object_id = e.id))
        \\FROM entity e WHERE e.id = $2 AND e.graph_id = $1 AND e.merged_into IS NULL
    , .{ gid, @as([]const u8, &id.bytes) })) orelse return null;
    defer row.deinit() catch {};

    return .{ .created_seq = try row.get(i64, 0), .facts = try row.get(i64, 1) };
}

fn orientMerge(s: *Store, a: std.mem.Allocator, conn: *pg.Conn, gid: []const u8, cs: *core.ChangeSet, k: usize, warnings: *std.ArrayList([]const u8)) !?core.ChangeSet.Merge {
    const m = cs.merges[k];
    if (m.from.eql(m.into)) return null;

    var fbuf: [36]u8 = undefined;
    var ibuf: [36]u8 = undefined;
    const from = try mergeSide(conn, gid, &m.from);
    const into = try mergeSide(conn, gid, &m.into);
    if (from == null or into == null) {
        try warnings.append(a, try std.fmt.allocPrint(a, "merge of {s} into {s} skipped: an entity is missing or already merged", .{ m.from.toString(&fbuf), m.into.toString(&ibuf) }));
        return null;
    }

    const f = from.?;
    const i = into.?;
    if (@min(f.facts, i.facts) > max_merge_facts) {
        try warnings.append(a, try std.fmt.allocPrint(a, "merge of {s} into {s} skipped: both hold more than {d} facts", .{ m.from.toString(&fbuf), m.into.toString(&ibuf), max_merge_facts }));
        const dup_id = Id.v7(s.io);
        _ = try conn.exec(
            \\INSERT INTO possible_duplicate (id, graph_id, entity_a, entity_b, score) VALUES ($1, $2, $3, $4, 1)
        , .{ @as([]const u8, &dup_id.bytes), gid, @as([]const u8, &m.from.bytes), @as([]const u8, &m.into.bytes) });
        return null;
    }

    const swap = f.facts > i.facts or (f.facts == i.facts and f.created_seq < i.created_seq);
    if (!swap) return m;

    try redirect(a, cs, m.into, m.from);
    return .{ .from = m.into, .into = m.from, .reason = m.reason };
}

fn redirect(a: std.mem.Allocator, cs: *core.ChangeSet, old: Id, new: Id) !void {
    const to = struct {
        fn f(id: Id, o: Id, n: Id) Id {
            return if (id.eql(o)) n else id;
        }
    }.f;

    const facts = try a.dupe(core.ChangeSet.NewFact, cs.new_facts);
    for (facts) |*nf| {
        nf.fact.subject_id = to(nf.fact.subject_id, old, new);
        switch (nf.fact.object) {
            .entity => |o| nf.fact.object = .{ .entity = to(o, old, new) },
            .value => {},
        }
    }

    const mentions = try a.dupe(Id, cs.mentions);
    for (mentions) |*id| id.* = to(id.*, old, new);

    const aliases = try a.dupe(core.ChangeSet.Alias, cs.new_aliases);
    for (aliases) |*al| al.entity_id = to(al.entity_id, old, new);

    const merges = try a.dupe(core.ChangeSet.Merge, cs.merges);
    for (merges) |*m| {
        m.from = to(m.from, old, new);
        m.into = to(m.into, old, new);
    }

    cs.new_facts = facts;
    cs.mentions = mentions;
    cs.new_aliases = aliases;
    cs.merges = merges;
}

fn applyMerge(s: *Store, a: std.mem.Allocator, conn: *pg.Conn, gid: []const u8, seq: i64, m: *const core.ChangeSet.Merge, touched_entities: *std.ArrayList([]const u8), touched_facts: *std.ArrayList([]const u8)) !void {
    const log_id = Id.v7(s.io);
    const moved = try collectIds(a, conn,
        \\WITH moved AS (
        \\  UPDATE fact SET
        \\    subject_id = CASE WHEN subject_id = $2 THEN $3 ELSE subject_id END,
        \\    object_id = CASE WHEN object_id = $2 THEN $3 ELSE object_id END
        \\  WHERE graph_id = $1 AND (subject_id = $2 OR object_id = $2)
        \\  RETURNING id
        \\), retired AS (
        \\  UPDATE entity SET merged_into = $3, updated_seq = $4 WHERE id = $2 AND graph_id = $1 RETURNING id
        \\), aliases AS (
        \\  INSERT INTO entity_alias (graph_id, norm, entity_id, alias)
        \\  SELECT graph_id, norm, $3, alias FROM entity_alias WHERE entity_id = $2
        \\  ON CONFLICT DO NOTHING RETURNING 1
        \\), mentions AS (
        \\  INSERT INTO entity_mention (entity_id, entry_id)
        \\  SELECT $3, entry_id FROM entity_mention WHERE entity_id = $2
        \\  ON CONFLICT DO NOTHING RETURNING 1
        \\), logged AS (
        \\  INSERT INTO merge_log (id, graph_id, seq, from_id, into_id, reason, moved_facts)
        \\  SELECT $5, $1, $4, $2, $3, $6, ARRAY(SELECT id FROM moved ORDER BY id)
        \\  RETURNING 1
        \\)
        \\SELECT id FROM moved
    , .{ gid, @as([]const u8, &m.from.bytes), @as([]const u8, &m.into.bytes), seq, @as([]const u8, &log_id.bytes), m.reason });

    try touched_entities.append(a, &m.from.bytes);
    try touched_entities.append(a, &m.into.bytes);
    try touched_facts.appendSlice(a, moved);
}

fn insertFacts(a: std.mem.Allocator, conn: *pg.Conn, gid: []const u8, seq: i64, commit_ts: i64, facts: []const core.ChangeSet.NewFact, touched: *std.ArrayList([]const u8)) !void {
    if (facts.len == 0) return;

    const n = facts.len;
    const ids = try a.alloc([]const u8, n);
    const subjects = try a.alloc([]const u8, n);
    const relations = try a.alloc([]const u8, n);
    const qualifiers = try a.alloc([]const u8, n);
    const object_ids = try a.alloc(?[]const u8, n);
    const object_values = try a.alloc(?[]const u8, n);
    const texts = try a.alloc([]const u8, n);
    const rationales = try a.alloc(?[]const u8, n);
    const projects = try a.alloc(?[]const u8, n);
    const scopes = try a.alloc([]const u8, n);
    const lowers = try a.alloc(?i64, n);
    const uppers = try a.alloc(?i64, n);
    const end_kinds = try a.alloc(?[]const u8, n);
    const ended_by = try a.alloc(?[]const u8, n);
    const authors = try a.alloc([]const u8, n);
    const confidence = try a.alloc(f32, n);
    const flat = try a.alloc(f32, n * dims);

    for (facts, 0..) |*nf, i| {
        const f = &nf.fact;
        if (nf.emb.len != dims) return error.InvalidEmbedding;
        @memcpy(flat[i * dims ..][0..dims], nf.emb);

        ids[i] = &f.id.bytes;
        subjects[i] = &f.subject_id.bytes;
        relations[i] = f.relation;
        qualifiers[i] = f.qualifier;

        switch (f.object) {
            .entity => |*e| {
                object_ids[i] = &e.bytes;
                object_values[i] = null;
            },
            .value => |v| {
                object_ids[i] = null;
                object_values[i] = v;
            },
        }

        texts[i] = f.text;
        rationales[i] = f.rationale;
        projects[i] = f.project;
        scopes[i] = @tagName(f.scope);
        lowers[i] = f.valid.lower;
        uppers[i] = f.valid.upper;
        end_kinds[i] = if (f.end_kind) |k| @tagName(k) else null;
        ended_by[i] = if (f.ended_by) |*e| &e.bytes else null;
        authors[i] = @tagName(f.author);
        confidence[i] = f.confidence;
    }

    _ = try conn.exec(
        \\INSERT INTO fact (id, graph_id, subject_id, relation, qualifier, object_id, object_value, text,
        \\  rationale, project, scope, valid, known, end_kind, ended_by, author, confidence, emb, created_seq)
        \\SELECT t.id, $1, t.subject_id, t.relation, t.qualifier, t.object_id, t.object_value, t.text,
        \\  t.rationale, t.project, t.scope, tstzrange(t.lo, t.hi), tstzrange($2, NULL), t.end_kind, t.ended_by,
        \\  t.author, t.confidence, ($3::float4[])[(t.i - 1) * 512 + 1 : t.i * 512]::halfvec(512), $4
        \\FROM unnest($5::uuid[], $6::uuid[], $7::text[], $8::text[], $9::uuid[], $10::text[], $11::text[],
        \\  $12::text[], $13::text[], $14::text[], $15::timestamptz[], $16::timestamptz[], $17::text[],
        \\  $18::uuid[], $19::text[], $20::float4[]) WITH ORDINALITY
        \\  AS t(id, subject_id, relation, qualifier, object_id, object_value, text, rationale, project, scope,
        \\       lo, hi, end_kind, ended_by, author, confidence, i)
    , .{
        gid,        commit_ts,     flat,      seq,
        ids,        subjects,      relations, qualifiers,
        object_ids, object_values, texts,     rationales,
        projects,   scopes,        lowers,    uppers,
        end_kinds,  ended_by,      authors,   confidence,
    });
    try touched.appendSlice(a, ids);
}

fn collectIds(a: std.mem.Allocator, conn: *pg.Conn, sql: []const u8, args: anytype) ![]const []const u8 {
    var result = try conn.query(sql, args);
    defer result.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (try result.next()) |row| try out.append(a, try a.dupe(u8, try row.get([]const u8, 0)));
    return out.items;
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}
