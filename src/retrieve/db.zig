const std = @import("std");
const core = @import("core");
const pg = @import("pg");

pub const log = std.log.scoped(.retrieve);

pub fn lowerBound(comptime col: []const u8) []const u8 {
    return "CASE WHEN lower_inf(" ++ col ++ ") OR NOT isfinite(lower(" ++ col ++ ")) THEN NULL ELSE lower(" ++ col ++ ") END";
}

pub fn upperBound(comptime col: []const u8) []const u8 {
    return "CASE WHEN upper_inf(" ++ col ++ ") OR NOT isfinite(upper(" ++ col ++ ")) THEN NULL ELSE upper(" ++ col ++ ") END";
}

pub const hit_columns =
    "f.id, f.graph_id, f.subject_id, f.relation, f.qualifier, f.object_id, f.object_value, f.text, f.rationale, f.project, f.scope, " ++
    lowerBound("f.valid") ++ ", " ++ upperBound("f.valid") ++ ", " ++ lowerBound("f.known") ++ ", " ++ upperBound("f.known") ++ ", " ++
    "f.end_kind, f.ended_by, f.author, f.confidence, se.name, se.type, oe.name, " ++
    "(SELECT s.harness FROM fact_evidence fp JOIN entry ep ON ep.id = fp.entry_id JOIN source s ON s.id = ep.source_id " ++
    "WHERE fp.fact_id = f.id ORDER BY (fp.kind = 'stated') DESC, ep.reference_time LIMIT 1)";

pub const hit_column_count = 23;

pub const hit_from = " FROM fact f JOIN entity se ON se.id = f.subject_id LEFT JOIN entity oe ON oe.id = f.object_id";

pub const Hit = struct {
    fact: core.Fact,
    subject_name: []const u8,
    subject_type: core.EntityType,
    object_name: ?[]const u8 = null,
    harness: ?core.Harness = null,
    score: f64 = 0,
};

pub fn readHit(arena: std.mem.Allocator, row: anytype) !Hit {
    const object_id = try optId(row, 5);
    const object_value = try optText(arena, row, 6);
    const end_kind = try optText(arena, row, 15);
    const harness = try optText(arena, row, 22);

    return .{
        .fact = .{
            .id = try id(row, 0),
            .graph_id = try id(row, 1),
            .subject_id = try id(row, 2),
            .relation = try text(arena, row, 3),
            .qualifier = try text(arena, row, 4),
            .object = if (object_id) |o| .{ .entity = o } else .{ .value = object_value orelse "" },
            .text = try text(arena, row, 7),
            .rationale = try optText(arena, row, 8),
            .project = try optText(arena, row, 9),
            .scope = std.meta.stringToEnum(core.types.Scope, try row.get([]const u8, 10)) orelse .project,
            .valid = .{ .lower = try row.get(?i64, 11), .upper = try row.get(?i64, 12) },
            .known = .{ .lower = try row.get(?i64, 13), .upper = try row.get(?i64, 14) },
            .end_kind = if (end_kind) |k| std.meta.stringToEnum(core.types.EndKind, k) else null,
            .ended_by = try optId(row, 16),
            .author = std.meta.stringToEnum(core.types.FactAuthor, try row.get([]const u8, 17)) orelse .agent,
            .confidence = try row.get(f32, 18),
        },
        .subject_name = try text(arena, row, 19),
        .subject_type = entityType(try row.get([]const u8, 20)),
        .object_name = try optText(arena, row, 21),
        .harness = if (harness) |h| std.meta.stringToEnum(core.Harness, h) else null,
    };
}

pub fn entityType(s: []const u8) core.EntityType {
    return std.meta.stringToEnum(core.EntityType, s) orelse .other;
}

pub fn id(row: anytype, col: usize) !core.Id {
    const b = try row.get([]const u8, col);
    if (b.len != 16) return error.InvalidId;
    return .{ .bytes = b[0..16].* };
}

pub fn optId(row: anytype, col: usize) !?core.Id {
    const b = (try row.get(?[]const u8, col)) orelse return null;
    if (b.len != 16) return error.InvalidId;
    return .{ .bytes = b[0..16].* };
}

pub fn text(arena: std.mem.Allocator, row: anytype, col: usize) ![]const u8 {
    return arena.dupe(u8, try row.get([]const u8, col));
}

pub fn optText(arena: std.mem.Allocator, row: anytype, col: usize) !?[]const u8 {
    const s = (try row.get(?[]const u8, col)) orelse return null;
    return try arena.dupe(u8, s);
}

pub fn floats(arena: std.mem.Allocator, row: anytype, col: usize) ![]const f32 {
    const it = try row.get(pg.Iterator(f32), col);
    if (it.is_null) return &.{};
    const out = try arena.alloc(f32, it.len());
    it.fill(out);
    return out;
}

pub fn query(conn: *pg.Conn, arena: std.mem.Allocator, sql: []const u8, args: anytype) !*pg.Result {
    return conn.queryOpts(sql, args, .{ .allocator = arena }) catch |err| {
        logError(conn, err, sql);
        return err;
    };
}

pub fn exec(conn: *pg.Conn, sql: []const u8, args: anytype) !?i64 {
    return conn.exec(sql, args) catch |err| {
        logError(conn, err, sql);
        return err;
    };
}

pub fn queryRow(conn: *pg.Conn, arena: std.mem.Allocator, sql: []const u8, args: anytype) !?pg.QueryRow {
    return conn.rowOpts(sql, args, .{ .allocator = arena }) catch |err| {
        logError(conn, err, sql);
        return err;
    };
}

pub fn logError(conn: *pg.Conn, err: anyerror, what: []const u8) void {
    if (err != error.PG) return;
    if (conn.err) |pge| log.err("{s}: {s}", .{ pge.message, what[0..@min(what.len, 120)] });
}
