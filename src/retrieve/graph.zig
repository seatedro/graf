const std = @import("std");
const core = @import("core");
const db = @import("db.zig");
const Engine = @import("mod.zig").Engine;

pub const Op = enum { overview, neighborhood, search, entity };

pub const Input = struct {
    project: ?[]const u8 = null,
    type: ?[]const u8 = null,
    relation: ?[]const u8 = null,
    min_confidence: ?f32 = null,
    as_of: ?[]const u8 = null,
    include_history: ?bool = null,
    id: ?[]const u8 = null,
    hops: ?u8 = null,
    query: ?[]const u8 = null,
    before: ?[]const u8 = null,
    fact_id: ?[]const u8 = null,
};

const filters = @embedFile("graph/filters.sql");
const seeds = @embedFile("graph/seeds.sql");
const probe = @embedFile("graph/probe.sql");
const first = std.fmt.comptimePrint(@embedFile("graph/first.sql"), .{probe});
const overview_sql = filters ++ seeds ++ first ++ @embedFile("graph/overview.sql");
const neighborhood_sql = filters ++ seeds ++ first ++ std.fmt.comptimePrint(@embedFile("graph/neighborhood.sql"), .{probe});
const search_sql = filters ++ @embedFile("graph/search.sql");
const entity_sql = filters ++ @embedFile("graph/entity.sql");

pub fn run(engine: *Engine, arena: std.mem.Allocator, op: Op, in: Input) ![]const u8 {
    for ([_]?[]const u8{ in.project, in.type, in.relation, in.query }) |opt| {
        if (opt) |s| if (std.mem.trim(u8, s, " \t\n\r").len == 0 or s.len > 256 or std.mem.indexOfScalar(u8, s, 0) != null)
            return error.InvalidGraphInput;
    }
    if (in.min_confidence) |c| if (!std.math.isFinite(c) or c < 0 or c > 1) return error.InvalidGraphInput;
    if (in.hops) |h| if (op != .neighborhood or h < 1 or h > 2) return error.InvalidGraphInput;
    if ((op == .search) != (in.query != null)) return error.InvalidGraphInput;
    if ((op == .entity and in.id == null) or (in.id != null and op != .entity and op != .neighborhood))
        return error.InvalidGraphInput;
    if ((in.before != null and in.fact_id != null) or (op != .entity and (in.before != null or in.fact_id != null)))
        return error.InvalidGraphInput;

    const id = if (in.id) |s| core.Id.parse(s) catch return error.InvalidGraphInput else null;
    const before = if (in.before) |s| core.Id.parse(s) catch return error.InvalidGraphInput else null;
    const fact_id = if (in.fact_id) |s| core.Id.parse(s) catch return error.InvalidGraphInput else null;
    const at: ?core.Micros = if (in.as_of) |s| try core.time.parseIso(s) else null;
    const args = .{ &engine.graph_id.bytes, in.project, in.type, in.relation, in.min_confidence, at, in.include_history orelse false };
    const id_bytes: ?[]const u8 = if (id) |*v| &v.bytes else null;
    const conn = try engine.store.pool.acquire();
    defer conn.release();

    var row = (switch (op) {
        .overview => try db.queryRow(conn, arena, overview_sql, args ++ .{id_bytes}),
        .neighborhood => try db.queryRow(conn, arena, neighborhood_sql, args ++ .{ id_bytes, @as(i32, in.hops orelse 1) }),
        .search => try db.queryRow(conn, arena, search_sql, args ++ .{ in.query.?, try core.text.norm(arena, in.query.?) }),
        .entity => try db.queryRow(conn, arena, entity_sql, args ++ .{
            id_bytes,
            if (before) |*v| @as(?[]const u8, &v.bytes) else null,
            if (fact_id) |*v| @as(?[]const u8, &v.bytes) else null,
        }),
    }) orelse return error.EntityNotFound;
    defer row.deinit() catch {};

    return db.text(arena, &row, 0);
}

test "graph viewer rejects malformed inputs before acquiring a connection" {
    var engine: Engine = undefined;
    const arena = std.testing.allocator;
    try std.testing.expectError(error.InvalidGraphInput, run(&engine, arena, .neighborhood, .{ .hops = 3 }));
    try std.testing.expectError(error.InvalidGraphInput, run(&engine, arena, .entity, .{ .id = "not-an-id" }));
    try std.testing.expectError(error.InvalidGraphInput, run(&engine, arena, .search, .{ .query = " " }));
    try std.testing.expectError(error.InvalidGraphInput, run(&engine, arena, .overview, .{ .min_confidence = 1.1 }));
    try std.testing.expectError(error.InvalidGraphInput, run(&engine, arena, .search, .{ .query = "test", .before = "invalid" }));
    try std.testing.expectError(error.InvalidGraphInput, run(&engine, arena, .entity, .{ .id = "entity", .before = "page", .fact_id = "fact" }));
    try std.testing.expectError(error.InvalidTimestamp, run(&engine, arena, .neighborhood, .{ .as_of = "not-a-date" }));
}
