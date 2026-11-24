const std = @import("std");
const core = @import("core");
const pg = @import("pg");
const prompt = @import("prompt.zig");
const schema = @import("schema.zig");
const postgres = @import("postgres.zig");

const Allocator = std.mem.Allocator;
const Id = core.Id;

pub const summary_after_changes = 5;
pub const summary_when_facts = 8;
pub const promote_entries = 5;
pub const promote_sources = 2;
pub const promotion_interval_s = 86_400;

pub const due_summaries_sql = std.fmt.comptimePrint(
    \\SELECT COALESCE(json_agg(json_build_object('id', d.id, 'name', d.name, 'type', d.type, 'facts', d.facts)), '[]'::json)::text FROM (
    \\  SELECT e.id, e.name, e.type,
    \\    (SELECT COALESCE(json_agg(f.text ORDER BY f.created_seq DESC), '[]'::json) FROM (
    \\       SELECT text, created_seq FROM fact
    \\       WHERE graph_id = e.graph_id AND (subject_id = e.id OR object_id = e.id) AND upper_inf(known) AND upper_inf(valid)
    \\       ORDER BY created_seq DESC LIMIT 40) f) AS facts
    \\  FROM entity e
    \\  WHERE e.graph_id = $1::uuid AND e.merged_into IS NULL AND (
    \\    e.facts_since_summary >= {d} OR (e.summary = '' AND (
    \\      SELECT count(*) FROM fact f WHERE f.graph_id = e.graph_id AND f.subject_id = e.id AND upper_inf(f.known) AND upper_inf(f.valid)) >= {d}))
    \\  ORDER BY e.facts_since_summary DESC LIMIT $2) d
, .{ summary_after_changes, summary_when_facts });

pub const promote_sql = std.fmt.comptimePrint(
    \\WITH usage AS (
    \\  SELECT f.relation, count(DISTINCT ev.fact_id) AS uses, count(DISTINCT e.id) AS entries, count(DISTINCT e.source_id) AS sources
    \\  FROM fact f JOIN fact_evidence ev ON ev.fact_id = f.id AND ev.kind IN ('stated', 'restated')
    \\  JOIN entry e ON e.id = ev.entry_id
    \\  WHERE f.graph_id = $1::uuid GROUP BY f.relation
    \\)
    \\UPDATE relation r SET uses = u.uses, entries = u.entries, sources = u.sources,
    \\  status = CASE WHEN r.status = 'proposed' AND r.mapped_to IS NULL AND u.entries >= {d} AND u.sources >= {d} THEN 'learned' ELSE r.status END
    \\FROM usage u WHERE r.graph_id = $1::uuid AND r.name = u.relation
, .{ promote_entries, promote_sources });

pub const claim_job_sql =
    \\INSERT INTO ingest_job (graph_id, name, last_run) VALUES ($1::uuid, $2, now())
    \\ON CONFLICT (graph_id, name) DO UPDATE SET last_run = now()
    \\WHERE ingest_job.last_run <= now() - make_interval(secs => $3::int)
    \\RETURNING 1
;

pub fn claimJob(conn: *pg.Conn, graph_id: Id, name: []const u8, interval_s: i32) !bool {
    var gbuf: [36]u8 = undefined;
    var row = (try conn.row(claim_job_sql, .{ graph_id.toString(&gbuf), name, interval_s })) orelse return false;
    row.deinit() catch {};
    return true;
}

pub fn runDailyPromotion(conn: *pg.Conn, graph_id: Id) !bool {
    if (!try claimJob(conn, graph_id, "relation_promotion", promotion_interval_s)) return false;
    var gbuf: [36]u8 = undefined;
    _ = try conn.exec(promote_sql, .{graph_id.toString(&gbuf)});
    return true;
}

pub const DueEntity = struct {
    id: Id,
    name: []const u8,
    type: core.EntityType,
    facts: []const []const u8,
};

pub fn dueSummaries(arena: Allocator, conn: *pg.Conn, graph_id: Id, limit: i32) ![]const DueEntity {
    var gbuf: [36]u8 = undefined;
    return postgres.jsonRow([]const DueEntity, arena, conn, due_summaries_sql, .{ graph_id.toString(&gbuf), limit });
}

pub fn summaryUser(arena: Allocator, e: DueEntity) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("Entity: {s} ({t})\nFacts:\n", .{ e.name, e.type }) catch return error.OutOfMemory;
    for (e.facts) |f| w.print("- {s}\n", .{f}) catch return error.OutOfMemory;
    return out.written();
}

pub fn saveSummary(conn: *pg.Conn, id: Id, summary: []const u8) !void {
    var buf: [36]u8 = undefined;
    _ = try conn.exec("UPDATE entity SET summary = $2, facts_since_summary = 0 WHERE id = $1::uuid", .{ id.toString(&buf), summary });
}

pub fn refreshSummaries(comptime Model: type, arena: Allocator, conn: *pg.Conn, model: *Model, graph_id: Id, limit: i32) !usize {
    const due = try dueSummaries(arena, conn, graph_id, limit);
    var done: usize = 0;
    for (due) |e| {
        const resp = model.structured(arena, .{
            .purpose = .summarize,
            .system = prompt.summary_system,
            .user = try summaryUser(arena, e),
            .schema_name = "entity_summary",
            .schema_json = schema.strict(prompt.SummaryResult),
        }) catch break;
        const parsed = std.json.parseFromSliceLeaky(prompt.SummaryResult, arena, resp.json, .{ .allocate = .alloc_always }) catch continue;
        try saveSummary(conn, e.id, std.mem.trim(u8, parsed.summary, " \n"));
        done += 1;
    }
    return done;
}
