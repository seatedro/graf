const std = @import("std");
const pg = @import("pg");

pub const Migration = struct {
    version: u32,
    name: []const u8,
    sql: []const u8,
};

pub const all = [_]Migration{
    .{ .version = 1, .name = "init", .sql = @embedFile("migrations/0001_init.sql") },
    .{ .version = 2, .name = "lease_token", .sql = @embedFile("migrations/0002_lease_token.sql") },
    .{ .version = 200, .name = "project_brief", .sql = @embedFile("migrations/0200_project_brief.sql") },
};

pub const Report = struct {
    applied: u32,
    total: u32,
};

pub fn run(allocator: std.mem.Allocator, pool: *pg.Pool) !Report {
    const conn = try pool.acquire();
    defer conn.release();

    try exec(conn, "SET client_min_messages TO warning");
    try exec(conn, "SELECT pg_advisory_lock(hashtextextended('graf:migrate', 0))");
    defer exec(conn, "SELECT pg_advisory_unlock(hashtextextended('graf:migrate', 0))") catch {};
    try exec(conn,
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  version    int PRIMARY KEY,
        \\  name       text NOT NULL,
        \\  applied_at timestamptz NOT NULL DEFAULT now()
        \\)
    );

    var applied: u32 = 0;
    for (all) |m| {
        var row = (try conn.row("SELECT 1 FROM schema_migrations WHERE version = $1", .{@as(i32, @intCast(m.version))})) orelse {
            const script = try std.fmt.allocPrint(
                allocator,
                "{s};\nINSERT INTO schema_migrations (version, name) VALUES ({d}, '{s}');",
                .{ m.sql, m.version, m.name },
            );
            defer allocator.free(script);
            exec(conn, script) catch |err| {
                std.log.err("migration {d}_{s} failed", .{ m.version, m.name });
                return err;
            };
            applied += 1;
            continue;
        };
        try row.deinit();
    }
    return .{ .applied = applied, .total = all.len };
}

fn exec(conn: *pg.Conn, sql: []const u8) !void {
    conn.execIgnoringState(sql) catch |err| {
        if (err == error.PG) if (conn.err) |pge| std.log.err("postgres: {s}", .{pge.message});
        return err;
    };
}

test "migration versions are unique and sorted" {
    var last: u32 = 0;
    for (all) |m| {
        try std.testing.expect(m.version > last);
        last = m.version;
    }
}
