const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");
const pg = @import("pg");
const rules = @import("rules.zig");
const resolve = @import("resolve.zig");
const postgres = @import("postgres.zig");
const jobs = @import("jobs.zig");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Id = core.Id;

pub const default_types = [_]core.EntityType{ .person, .project, .organization };
pub const default_limit = 50;
pub const default_cap_usd = 1.0;
pub const batch_size = 8;
pub const schedule_interval_s = 3600;

pub const Options = struct {
    types: []const core.EntityType = &default_types,
    limit: u32 = default_limit,
    cap_usd: f64 = default_cap_usd,
    dry_run: bool = false,
};

pub const Side = struct {
    id: Id,
    name: []const u8,
    norm: []const u8,
    type: core.EntityType,
    facts: i64 = 0,
};

pub const Candidate = struct {
    dup: ?Id = null,
    score: ?f32 = null,
    a: Side,
    b: Side,
    cosine: f32 = 0,
    lexical: f32 = 0,
};

pub const Profile = struct {
    id: Id,
    description: []const u8 = "",
    summary: []const u8 = "",
    aliases: []const []const u8 = &.{},
    facts: []const []const u8 = &.{},
    projects: []const []const u8 = &.{},
};

pub const Overlap = struct {
    a: Id,
    b: Id,
    shared_neighbors: []const []const u8 = &.{},
    shared_projects: []const []const u8 = &.{},
};

pub const Context = struct {
    profiles: ?[]const Profile = null,
    pairs: ?[]const Overlap = null,
};

pub const Action = enum { merge, keep_apart, unsure, too_large, blocked, incompatible, already_merged, changed };

pub const Decision = struct {
    candidate: Candidate,
    action: Action,
    p: ?f64 = null,
    reason: []const u8 = "",
    overlap: Overlap,
    from: ?Side = null,
    into: ?Side = null,
    moved_facts: usize = 0,
};

pub const Report = struct {
    dry_run: bool,
    candidates: usize = 0,
    judged: usize = 0,
    spent_usd: f64 = 0,
    capped: bool = false,
    decisions: []const Decision = &.{},

    pub fn count(r: Report, action: Action) usize {
        var n: usize = 0;
        for (r.decisions) |d| {
            if (d.action == action) n += 1;
        }
        return n;
    }
};

pub const candidates_sql =
    \\WITH live AS (
    \\  SELECT e.id, e.type, e.norm, e.name_emb FROM entity e
    \\  WHERE e.graph_id = $1::uuid AND e.merged_into IS NULL AND e.type = ANY($2::text[])
    \\),
    \\dups AS (
    \\  SELECT d.id AS dup, d.score, COALESCE(a.merged_into, a.id) AS a, COALESCE(b.merged_into, b.id) AS b
    \\  FROM possible_duplicate d JOIN entity a ON a.id = d.entity_a JOIN entity b ON b.id = d.entity_b
    \\  WHERE d.graph_id = $1::uuid AND d.status = 'open'
    \\),
    \\people AS (
    \\  SELECT a.id AS a, b.id AS b FROM live a
    \\  JOIN entity b ON b.graph_id = $1::uuid AND b.type = 'person' AND b.merged_into IS NULL
    \\    AND split_part(b.norm, ' ', 1) = split_part(a.norm, ' ', 1) AND b.id <> a.id
    \\  WHERE a.type = 'person' AND length(split_part(a.norm, ' ', 1)) >= 3
    \\),
    \\lexical AS (
    \\  SELECT a.id AS a, COALESCE(x.merged_into, x.id) AS b FROM live a CROSS JOIN LATERAL (
    \\    SELECT al.entity_id FROM entity_alias al WHERE al.graph_id = $1::uuid AND al.norm % a.norm AND al.entity_id <> a.id
    \\    ORDER BY similarity(al.norm, a.norm) DESC LIMIT 5) t JOIN entity x ON x.id = t.entity_id
    \\  WHERE a.type <> 'person'
    \\),
    \\nearest AS (
    \\  SELECT a.id AS a, k.id AS b FROM live a CROSS JOIN LATERAL (
    \\    SELECT x.id FROM entity x WHERE x.graph_id = $1::uuid AND x.merged_into IS NULL AND x.name_emb IS NOT NULL
    \\      AND x.type = a.type AND x.id <> a.id
    \\    ORDER BY x.name_emb <=> a.name_emb LIMIT 5) k
    \\  WHERE a.type <> 'person' AND a.name_emb IS NOT NULL
    \\),
    \\found AS (
    \\  SELECT DISTINCT least(a, b) AS a, greatest(a, b) AS b FROM (
    \\    SELECT a, b FROM people UNION ALL SELECT a, b FROM lexical UNION ALL SELECT a, b FROM nearest) f
    \\  WHERE a <> b
    \\),
    \\pairs AS (
    \\  SELECT dup, score, a, b FROM dups
    \\  UNION ALL
    \\  SELECT NULL, NULL, f.a, f.b FROM found f
    \\  WHERE NOT EXISTS (SELECT 1 FROM possible_duplicate d WHERE d.graph_id = $1::uuid
    \\      AND ((d.entity_a = f.a AND d.entity_b = f.b) OR (d.entity_a = f.b AND d.entity_b = f.a)))
    \\    AND NOT EXISTS (SELECT 1 FROM must_not_merge m WHERE m.graph_id = $1::uuid
    \\      AND m.entity_a = least(f.a, f.b) AND m.entity_b = greatest(f.a, f.b))
    \\),
    \\sides AS (
    \\  SELECT e.id, e.name, e.norm, e.type, e.merged_into IS NULL AS live, e.name_emb,
    \\    (SELECT count(*) FROM fact f WHERE f.graph_id = $1::uuid AND f.subject_id = e.id)
    \\      + (SELECT count(*) FROM fact f WHERE f.graph_id = $1::uuid AND f.object_id = e.id AND f.subject_id <> e.id) AS facts
    \\  FROM entity e WHERE e.id IN (SELECT a FROM pairs UNION SELECT b FROM pairs)
    \\)
    \\SELECT COALESCE(json_agg(json_build_object(
    \\  'dup', p.dup, 'score', p.score,
    \\  'a', json_build_object('id', a.id, 'name', a.name, 'norm', a.norm, 'type', a.type, 'facts', a.facts),
    \\  'b', json_build_object('id', b.id, 'name', b.name, 'norm', b.norm, 'type', b.type, 'facts', b.facts),
    \\  'cosine', CASE WHEN a.name_emb IS NULL OR b.name_emb IS NULL THEN 0 ELSE 1 - (a.name_emb <=> b.name_emb) END,
    \\  'lexical', similarity(a.norm, b.norm))), '[]'::json)::text
    \\FROM pairs p JOIN sides a ON a.id = p.a JOIN sides b ON b.id = p.b
    \\WHERE (a.type = ANY($2::text[]) OR b.type = ANY($2::text[])) AND (p.dup IS NOT NULL OR (a.live AND b.live))
;

pub const context_sql =
    \\WITH p AS (SELECT * FROM unnest($2::uuid[], $3::uuid[]) AS p(a, b)),
    \\ids AS (SELECT a AS id FROM p UNION SELECT b FROM p),
    \\nb AS (
    \\  SELECT i.id, f.object_id AS n FROM ids i JOIN fact f ON f.graph_id = $1::uuid AND f.subject_id = i.id
    \\    AND f.object_id IS NOT NULL AND upper_inf(f.known)
    \\  UNION SELECT i.id, f.subject_id FROM ids i JOIN fact f ON f.graph_id = $1::uuid AND f.object_id = i.id AND upper_inf(f.known)
    \\),
    \\pr AS (
    \\  SELECT i.id, f.project FROM ids i JOIN fact f ON f.graph_id = $1::uuid AND f.subject_id = i.id AND f.project IS NOT NULL
    \\  UNION SELECT i.id, f.project FROM ids i JOIN fact f ON f.graph_id = $1::uuid AND f.object_id = i.id AND f.project IS NOT NULL
    \\)
    \\SELECT json_build_object(
    \\  'profiles', (SELECT json_agg(json_build_object('id', e.id, 'description', e.description, 'summary', e.summary,
    \\      'aliases', ARRAY(SELECT al.alias FROM entity_alias al WHERE al.entity_id = e.id AND al.norm <> e.norm ORDER BY al.norm LIMIT 4),
    \\      'facts', ARRAY(SELECT f.text FROM fact f WHERE f.graph_id = $1::uuid AND f.subject_id = e.id
    \\        AND upper_inf(f.known) AND upper_inf(f.valid) ORDER BY f.confidence DESC, f.created_seq DESC LIMIT 3),
    \\      'projects', ARRAY(SELECT pr.project FROM pr WHERE pr.id = e.id ORDER BY pr.project LIMIT 3)))
    \\    FROM entity e JOIN ids ON ids.id = e.id),
    \\  'pairs', (SELECT json_agg(json_build_object('a', p.a, 'b', p.b,
    \\      'shared_neighbors', ARRAY(SELECT x.name FROM (SELECT n FROM nb WHERE nb.id = p.a INTERSECT SELECT n FROM nb WHERE nb.id = p.b) s
    \\        JOIN entity x ON x.id = s.n WHERE s.n <> p.a AND s.n <> p.b ORDER BY x.name LIMIT 5),
    \\      'shared_projects', ARRAY(SELECT s.project FROM (SELECT project FROM pr WHERE pr.id = p.a
    \\        INTERSECT SELECT project FROM pr WHERE pr.id = p.b) s ORDER BY s.project LIMIT 3)))
    \\    FROM p)
    \\)::text
;

const spent_sql =
    \\SELECT COALESCE(sum(cost_usd), 0)::float8 FROM llm_call
    \\WHERE graph_id = $1::uuid AND started_at >= $2 AND entry_id IS NULL AND purpose = 'resolve'
;

fn spentSince(conn: *pg.Conn, graph_id: Id, since: core.Micros) !f64 {
    var gbuf: [36]u8 = undefined;
    var row = (try conn.row(spent_sql, .{ graph_id.toString(&gbuf), since })) orelse return 0;
    defer row.deinit() catch {};
    return row.get(f64, 0);
}

const record_sql =
    \\WITH settled AS (
    \\  UPDATE possible_duplicate SET status = $5, reason = $6, decided_at = now()
    \\  WHERE graph_id = $1::uuid AND status = 'open'
    \\    AND ((entity_a = $2::uuid AND entity_b = $3::uuid) OR (entity_a = $3::uuid AND entity_b = $2::uuid))
    \\  RETURNING 1
    \\)
    \\INSERT INTO possible_duplicate (id, graph_id, entity_a, entity_b, score, status, reason, decided_at)
    \\SELECT $7::uuid, $1::uuid, $2::uuid, $3::uuid, $4, $5, $6, now() WHERE NOT EXISTS (SELECT 1 FROM settled)
;

pub fn parseTypes(arena: Allocator, list: []const u8) ![]const core.EntityType {
    var out: std.ArrayList(core.EntityType) = .empty;
    var it = std.mem.tokenizeAny(u8, list, ", ");
    while (it.next()) |name| {
        const t = std.meta.stringToEnum(core.EntityType, name) orelse return error.UnknownEntityType;
        try out.append(arena, t);
    }

    if (out.items.len == 0) return error.UnknownEntityType;
    return out.items;
}

fn rank(c: Candidate) f32 {
    if (c.dup != null) return 2 + (c.score orelse 0);
    const first: f32 = if (c.a.type == .person and rules.sameFirstName(c.a.norm, c.b.norm)) 0.2 else 0;
    return @max(c.cosine, c.lexical) + first;
}

fn byRank(_: void, a: Candidate, b: Candidate) bool {
    return rank(a) > rank(b);
}

pub fn worthAsking(c: Candidate) bool {
    if (c.dup != null) return true;
    if (!rules.mergeCompatible(c.a.type, c.b.type) or rules.distinctMarkers(c.a.norm, c.b.norm)) return false;
    if (c.a.type == .person and c.b.type == .person) return rules.sameFirstName(c.a.norm, c.b.norm);
    return c.lexical >= rules.gray_lexical or c.cosine >= rules.gray_cosine;
}

fn typeNames(arena: Allocator, types: []const core.EntityType) ![]const []const u8 {
    const out = try arena.alloc([]const u8, types.len);
    for (types, out) |t, *n| n.* = @tagName(t);
    return out;
}

pub fn findCandidates(arena: Allocator, conn: *pg.Conn, graph_id: Id, types: []const core.EntityType) ![]Candidate {
    var gbuf: [36]u8 = undefined;
    try conn.begin();
    errdefer conn.rollback() catch {};
    _ = try conn.exec("SET LOCAL hnsw.iterative_scan = relaxed_order", .{});
    _ = try conn.exec("SET LOCAL pg_trgm.similarity_threshold = 0.4", .{});
    const all = try postgres.jsonRow([]Candidate, arena, conn, candidates_sql, .{ graph_id.toString(&gbuf), try typeNames(arena, types) });
    try conn.commit();

    var kept: std.ArrayList(Candidate) = .empty;
    for (all) |c| if (worthAsking(c)) try kept.append(arena, c);
    std.mem.sort(Candidate, kept.items, {}, byRank);
    return kept.items;
}

pub fn loadContext(arena: Allocator, conn: *pg.Conn, graph_id: Id, cands: []const Candidate) !Context {
    if (cands.len == 0) return .{};
    const as = try arena.alloc([]const u8, cands.len);
    const bs = try arena.alloc([]const u8, cands.len);
    for (cands, as, bs) |*c, *a, *b| {
        a.* = &c.a.id.bytes;
        b.* = &c.b.id.bytes;
    }

    var gbuf: [36]u8 = undefined;
    return postgres.jsonRow(Context, arena, conn, context_sql, .{ graph_id.toString(&gbuf), as, bs });
}

fn profileOf(ctx: Context, id: Id) Profile {
    for (ctx.profiles orelse &.{}) |p| if (p.id.eql(id)) return p;
    return .{ .id = id };
}

fn overlapOf(ctx: Context, c: Candidate) Overlap {
    for (ctx.pairs orelse &.{}) |o| if (o.a.eql(c.a.id) and o.b.eql(c.b.id)) return o;
    return .{ .a = c.a.id, .b = c.b.id };
}

fn writeList(w: *Writer, items: []const []const u8, empty: []const u8) Writer.Error!void {
    if (items.len == 0) try w.print(" {s}", .{empty});
    for (items, 0..) |item, i| try w.print("{s} {s}", .{ if (i > 0) "," else "", item });
}

fn writeSide(w: *Writer, tag: []const u8, s: Side, p: Profile) Writer.Error!void {
    try w.print("{s}: \"{s}\" ({t})", .{ tag, s.name, s.type });
    if (p.description.len > 0) try w.print(": {s}", .{p.description});
    if (p.summary.len > 0) try w.print(" Summary: {s}", .{p.summary});
    if (p.aliases.len > 0) {
        try w.writeAll(" Also called");
        for (p.aliases, 0..) |al, i| try w.print("{s} \"{s}\"", .{ if (i > 0) "," else "", al });
        try w.writeAll(".");
    }

    if (p.facts.len > 0) {
        try w.writeAll(" Known facts:");
        for (p.facts) |f| try w.print(" {s}", .{f});
    }

    if (p.projects.len > 0) {
        try w.writeAll(" Projects:");
        try writeList(w, p.projects, "");
        try w.writeAll(".");
    }
    try w.writeAll("\n");
}

pub fn question(arena: Allocator, c: Candidate, ctx: Context) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    writeQuestion(&out.writer, c, ctx) catch return error.OutOfMemory;
    return out.written();
}

fn writeQuestion(w: *Writer, c: Candidate, ctx: Context) Writer.Error!void {
    try w.writeAll("Are A and B the same real-world entity, so that the knowledge graph should merge them?\n");
    try writeSide(w, "A", c.a, profileOf(ctx, c.a.id));
    try writeSide(w, "B", c.b, profileOf(ctx, c.b.id));

    const o = overlapOf(ctx, c);
    try w.writeAll("Both are linked to:");
    try writeList(w, o.shared_neighbors, "nothing in common");
    try w.writeAll(". Shared projects:");
    try writeList(w, o.shared_projects, "none");
    try w.print(".\n{s}", .{resolve.entity_link_rule});
}

pub const Verdict = enum { same, different, unsure };

pub const JudgeResult = struct {
    verdict: Verdict,
    reason: []const u8,
};

pub const judge_system =
    \\You decide whether two entities in a knowledge graph built from coding-agent sessions are the same real-world thing. Answer "same" only when the context shows they are one thing, "different" when it shows they are distinct, and "unsure" otherwise. Give a one-sentence reason. Output one JSON object that matches the schema.
;

const Judged = struct { p: f64, reason: []const u8 = "" };

fn judge(comptime Model: type, arena: Allocator, model: *Model, prompts: []const []const u8) ![]const Judged {
    const out = try arena.alloc(Judged, prompts.len);
    if (model.decisionEnabled()) {
        const qs = try arena.alloc(llm.Question, prompts.len);
        for (prompts, qs) |p, *q| q.* = .{ .yes_no = p };

        const answers = try model.decide(arena, .{ .purpose = .resolve, .questions = qs });
        if (answers.len != prompts.len) return error.WrongAnswerCount;
        for (answers, out) |a, *j| j.* = switch (a) {
            .yes_no => |p| .{ .p = p },
            .choice => return error.WrongAnswerKind,
        };
        return out;
    }

    for (prompts, out) |p, *j| {
        const resp = try model.structured(arena, .{
            .purpose = .resolve,
            .system = judge_system,
            .user = p,
            .schema_name = "entity_match",
            .schema_json = schema.strict(JudgeResult),
        });
        const parsed = try std.json.parseFromSliceLeaky(JudgeResult, arena, resp.json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        const same: f64 = switch (parsed.verdict) {
            .same => 1,
            .different => 0,
            .unsure => 0.5,
        };
        j.* = .{ .p = same, .reason = parsed.reason };
    }
    return out;
}

fn sideFor(c: Candidate, id: Id) Side {
    return if (c.a.id.eql(id)) c.a else c.b;
}

fn containsId(ids: []const Id, id: Id) bool {
    for (ids) |x| if (x.eql(id)) return true;
    return false;
}

fn record(conn: *pg.Conn, io: std.Io, graph_id: Id, c: Candidate, status: []const u8, reason: []const u8, p: f64) !void {
    var bufs: [4][36]u8 = undefined;
    _ = try conn.exec(record_sql, .{
        graph_id.toString(&bufs[0]),  c.a.id.toString(&bufs[1]), c.b.id.toString(&bufs[2]),
        @as(f32, @floatCast(p)),      status,                    reason,
        Id.v7(io).toString(&bufs[3]),
    });
}

fn verdictReason(arena: Allocator, j: Judged) ![]const u8 {
    if (j.reason.len > 0) return j.reason;
    return std.fmt.allocPrint(arena, "consolidation judged p(same) = {d:.2}", .{j.p});
}

fn settleWithoutAsking(conn: *pg.Conn, io: std.Io, graph_id: Id, c: Candidate, dry_run: bool, gone: []const Id) !?Action {
    if (c.a.id.eql(c.b.id)) {
        if (!dry_run) try record(conn, io, graph_id, c, "merged", "already merged", 1);
        return .already_merged;
    }

    if (containsId(gone, c.a.id) or containsId(gone, c.b.id)) return .changed;
    if (!rules.mergeCompatible(c.a.type, c.b.type) or rules.distinctMarkers(c.a.norm, c.b.norm)) {
        if (!dry_run) try record(conn, io, graph_id, c, "rejected", "incompatible types or distinct numbered names", 0);
        return .incompatible;
    }
    return null;
}

pub fn run(comptime Model: type, arena: Allocator, s: *store.Store, model: *Model, graph_id: Id, opts: Options) !Report {
    const started = core.time.now(s.io);
    var report: Report = .{ .dry_run = opts.dry_run };

    const conn = try s.pool.acquire();
    defer conn.release();

    const found = try findCandidates(arena, conn, graph_id, opts.types);
    report.candidates = found.len;
    const chosen = found[0..@min(found.len, opts.limit)];
    const ctx = try loadContext(arena, conn, graph_id, chosen);

    var decisions: std.ArrayList(Decision) = .empty;
    var gone: std.ArrayList(Id) = .empty;
    var start: usize = 0;
    while (start < chosen.len) : (start += batch_size) {
        report.spent_usd = try spentSince(conn, graph_id, started);
        if (report.spent_usd >= opts.cap_usd) {
            report.capped = true;
            break;
        }

        const batch = chosen[start..@min(chosen.len, start + batch_size)];
        var asks: std.ArrayList([]const u8) = .empty;
        var asked: std.ArrayList(usize) = .empty;
        for (batch, 0..) |c, k| {
            if (try settleWithoutAsking(conn, s.io, graph_id, c, opts.dry_run, gone.items)) |action| {
                try decisions.append(arena, .{ .candidate = c, .action = action, .overlap = overlapOf(ctx, c) });
                continue;
            }

            try asks.append(arena, try question(arena, c, ctx));
            try asked.append(arena, k);
        }

        if (asks.items.len == 0) continue;
        const verdicts = try judge(Model, arena, model, asks.items);
        report.judged += verdicts.len;

        for (asked.items, verdicts) |k, j| {
            const c = batch[k];
            var d: Decision = .{ .candidate = c, .action = .unsure, .p = j.p, .overlap = overlapOf(ctx, c), .reason = try verdictReason(arena, j) };

            if (j.p >= rules.consolidate_same) {
                switch (try s.merge(graph_id, c.a.id, c.b.id, d.reason, .{ .dry_run = opts.dry_run })) {
                    .merged => |m| {
                        d.action = .merge;
                        d.from = sideFor(c, m.from);
                        d.into = sideFor(c, m.into);
                        d.moved_facts = m.moved_facts;
                        if (!opts.dry_run) try gone.append(arena, m.from);
                    },
                    .skipped => |why| {
                        d.action = switch (why) {
                            .too_large => .too_large,
                            .blocked => .blocked,
                            .same, .missing => .changed,
                        };
                        if (!opts.dry_run and why == .too_large) try record(conn, s.io, graph_id, c, "too_large", d.reason, j.p);
                        if (!opts.dry_run and why == .blocked) try record(conn, s.io, graph_id, c, "rejected", d.reason, j.p);
                    },
                }
            } else if (j.p <= rules.consolidate_different) {
                d.action = .keep_apart;
                if (!opts.dry_run) try s.keepApart(graph_id, c.a.id, c.b.id, d.reason);
            } else if (!opts.dry_run) try record(conn, s.io, graph_id, c, "unsure", d.reason, j.p);

            try decisions.append(arena, d);
        }
    }

    report.spent_usd = try spentSince(conn, graph_id, started);
    report.decisions = decisions.items;
    return report;
}

pub fn runScheduled(comptime Model: type, arena: Allocator, s: *store.Store, model: *Model, graph_id: Id, pairs: u32) !?Report {
    if (pairs == 0 or !model.decisionEnabled()) return null;
    {
        const conn = try s.pool.acquire();
        defer conn.release();
        if (!try jobs.claimJob(conn, graph_id, "consolidation", schedule_interval_s)) return null;
    }

    return try run(Model, arena, s, model, graph_id, .{ .limit = pairs });
}

fn label(a: Action, dry_run: bool) []const u8 {
    return switch (a) {
        .merge => if (dry_run) "would merge" else "merged",
        .keep_apart => if (dry_run) "would keep apart" else "kept apart",
        .unsure => "unsure",
        .too_large => "too large",
        .blocked => "blocked",
        .incompatible => "incompatible",
        .already_merged => "already merged",
        .changed => "changed this run",
    };
}

pub fn print(r: Report, w: *Writer) Writer.Error!void {
    if (r.dry_run) try w.writeAll("dry run: nothing was written\n");
    try w.print("{d} candidate pairs, {d} judged, ${d:.4} spent{s}\n", .{ r.candidates, r.judged, r.spent_usd, if (r.capped) " (stopped at the spend cap)" else "" });

    for (r.decisions) |d| {
        const c = d.candidate;
        try w.print("\n{s}", .{label(d.action, r.dry_run)});
        if (d.p) |p| try w.print(" p={d:.2}", .{p});
        if (d.from) |f| {
            try w.print(": \"{s}\" ({t}, {d} facts) into \"{s}\" ({d} facts), moving {d} facts\n", .{ f.name, f.type, f.facts, d.into.?.name, d.into.?.facts, d.moved_facts });
        } else try w.print(": \"{s}\" ({t}, {d} facts) and \"{s}\" ({t}, {d} facts)\n", .{ c.a.name, c.a.type, c.a.facts, c.b.name, c.b.type, c.b.facts });

        try w.print("  cosine {d:.2}, lexical {d:.2}", .{ c.cosine, c.lexical });
        if (c.dup != null) try w.writeAll(", open possible duplicate");
        if (d.overlap.shared_neighbors.len > 0) {
            try w.writeAll(", shared neighbors:");
            try writeList(w, d.overlap.shared_neighbors, "");
        }
        if (d.overlap.shared_projects.len > 0) {
            try w.writeAll(", shared projects:");
            try writeList(w, d.overlap.shared_projects, "");
        }
        try w.writeAll("\n");
        if (d.p != null) try w.print("  {s}\n", .{d.reason});
    }

    try w.print("\n{d} {s}, {d} {s}, {d} unsure\n", .{
        r.count(.merge),      if (r.dry_run) "would merge" else "merged",
        r.count(.keep_apart), if (r.dry_run) "would be kept apart" else "kept apart",
        r.count(.unsure),
    });
}

pub const lookup_sql =
    \\SELECT COALESCE(json_agg(json_build_object('id', e.id, 'name', e.name, 'norm', e.norm, 'type', e.type,
    \\  'facts', (SELECT count(*) FROM fact f WHERE f.graph_id = e.graph_id AND f.subject_id = e.id)
    \\    + (SELECT count(*) FROM fact f WHERE f.graph_id = e.graph_id AND f.object_id = e.id AND f.subject_id <> e.id))
    \\  ORDER BY e.name), '[]'::json)::text
    \\FROM entity e
    \\WHERE e.graph_id = $1::uuid AND e.merged_into IS NULL AND (
    \\  e.id::text = $2 OR e.norm = $3
    \\  OR (NOT EXISTS (SELECT 1 FROM entity x WHERE x.graph_id = $1::uuid AND x.merged_into IS NULL AND (x.id::text = $2 OR x.norm = $3))
    \\    AND e.id IN (SELECT COALESCE(x.merged_into, x.id) FROM entity_alias a JOIN entity x ON x.id = a.entity_id
    \\      WHERE a.graph_id = $1::uuid AND a.norm = $3)))
;

pub const Lookup = union(enum) {
    found: Side,
    missing,
    ambiguous: []const Side,
};

pub fn lookup(arena: Allocator, conn: *pg.Conn, graph_id: Id, ref: []const u8) !Lookup {
    var gbuf: [36]u8 = undefined;
    var ibuf: [36]u8 = undefined;
    const id_text: []const u8 = if (Id.parse(ref)) |id| id.toString(&ibuf) else |_| ref;
    const found = try postgres.jsonRow([]const Side, arena, conn, lookup_sql, .{ graph_id.toString(&gbuf), id_text, try core.text.norm(arena, ref) });
    return switch (found.len) {
        0 => .missing,
        1 => .{ .found = found[0] },
        else => .{ .ambiguous = found },
    };
}

pub const ManualOptions = struct {
    force: bool = false,
    dry_run: bool = false,
};

pub fn mergeManual(s: *store.Store, graph_id: Id, from: Side, into: Side, reason: []const u8, opts: ManualOptions) !store.merging.MergeOutcome {
    if (!rules.mergeCompatible(from.type, into.type)) return error.IncompatibleTypes;
    return s.merge(graph_id, from.id, into.id, reason, .{ .orient = false, .force = opts.force, .dry_run = opts.dry_run });
}

pub const undo_lookup_sql =
    \\SELECT COALESCE(json_agg(DISTINCT m.id), '[]'::json)::text FROM merge_log m JOIN entity f ON f.id = m.from_id
    \\WHERE m.graph_id = $1::uuid AND m.undone_seq IS NULL AND f.merged_into = m.into_id
    \\  AND (m.id::text = $2 OR m.from_id::text = $2 OR f.norm = $3)
;

pub fn findMerge(arena: Allocator, conn: *pg.Conn, graph_id: Id, ref: []const u8) !Id {
    var gbuf: [36]u8 = undefined;
    var ibuf: [36]u8 = undefined;
    const id_text: []const u8 = if (Id.parse(ref)) |id| id.toString(&ibuf) else |_| ref;
    const found = try postgres.jsonRow([]const Id, arena, conn, undo_lookup_sql, .{ graph_id.toString(&gbuf), id_text, try core.text.norm(arena, ref) });
    return switch (found.len) {
        0 => error.MergeNotFound,
        1 => found[0],
        else => error.AmbiguousMerge,
    };
}

pub fn entityName(arena: Allocator, conn: *pg.Conn, id: Id) ![]const u8 {
    var buf: [36]u8 = undefined;
    var row = (try conn.row("SELECT name FROM entity WHERE id = $1::uuid", .{id.toString(&buf)})) orelse return "";
    defer row.deinit() catch {};
    return arena.dupe(u8, try row.get([]const u8, 0));
}
