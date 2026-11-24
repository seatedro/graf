const std = @import("std");
const core = @import("core");
const db = @import("db.zig");
const mod = @import("mod.zig");
const Hit = mod.Hit;

pub const EntryOutcome = struct {
    status: core.types.EntryStatus,
    stated: []const Hit = &.{},
    restated: []const Hit = &.{},
    ended: []const Hit = &.{},
};

const evidence_sql = "SELECT " ++ db.hit_columns ++ ", ev.kind" ++ db.hit_from ++
    " JOIN fact_evidence ev ON ev.fact_id = f.id WHERE ev.entry_id = $1 AND f.graph_id = $2 AND ev.kind IN ('stated', 'restated') ORDER BY f.id";

const ended_sql = "SELECT " ++ db.hit_columns ++ db.hit_from ++
    " WHERE f.graph_id = $2 AND f.ended_by IN (SELECT fact_id FROM fact_evidence WHERE entry_id = $1 AND kind = 'stated') ORDER BY f.id";

pub fn get(e: *mod.Engine, arena: std.mem.Allocator, entry_id: core.Id) !?EntryOutcome {
    const conn = try e.store.pool.acquire();
    defer conn.release();

    var status_row = (try db.queryRow(conn, arena, "SELECT status FROM entry WHERE id = $1 AND graph_id = $2", .{ &entry_id.bytes, &e.graph_id.bytes })) orelse return null;
    const status = std.meta.stringToEnum(core.types.EntryStatus, try status_row.get([]const u8, 0)) orelse .queued;
    try status_row.deinit();
    if (status != .committed) return .{ .status = status };

    var stated: std.ArrayList(Hit) = .empty;
    var restated: std.ArrayList(Hit) = .empty;
    {
        var result = try db.query(conn, arena, evidence_sql, .{ &entry_id.bytes, &e.graph_id.bytes });
        defer result.deinit();
        while (try result.next()) |row| {
            const hit = try db.readHit(arena, row);
            const list = if (std.mem.eql(u8, try row.get([]const u8, db.hit_column_count), "stated")) &stated else &restated;
            try list.append(arena, hit);
        }
    }

    var ended: std.ArrayList(Hit) = .empty;
    {
        var result = try db.query(conn, arena, ended_sql, .{ &entry_id.bytes, &e.graph_id.bytes });
        defer result.deinit();
        while (try result.next()) |row| try ended.append(arena, try db.readHit(arena, row));
    }

    return .{ .status = status, .stated = stated.items, .restated = restated.items, .ended = ended.items };
}
