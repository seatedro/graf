const std = @import("std");
const core = @import("core");
const db = @import("db.zig");
const time = @import("time.zig");
const render = @import("render.zig");
const mod = @import("mod.zig");
const Hit = mod.Hit;
const Writer = std.Io.Writer;

pub const BriefCache = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(c: *BriefCache, gpa: std.mem.Allocator) void {
        var it = c.entries.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        c.entries.deinit(gpa);
    }

    fn put(c: *BriefCache, gpa: std.mem.Allocator, io: std.Io, key: []const u8, body: []const u8) !void {
        const owned = try gpa.dupe(u8, body);
        errdefer gpa.free(owned);
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const gop = try c.entries.getOrPut(gpa, key);
        if (gop.found_existing) {
            gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = gpa.dupe(u8, key) catch |err| {
                c.entries.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = owned;
    }
};

const section_tokens = .{ .prefs = 200, .project = 400, .recent = 200 };

const base_where = "f.graph_id = $1 AND upper_inf(f.known) AND f.confidence >= 0.70";
const from = " FROM fact f JOIN entity se ON se.id = f.subject_id LEFT JOIN entity oe ON oe.id = f.object_id WHERE ";

const prefs_sql = "SELECT " ++ db.hit_columns ++ from ++ base_where ++
    " AND f.valid @> now() AND f.scope = 'global' AND f.relation IN ('prefers', 'avoids') AND f.confidence >= 0.75" ++
    " ORDER BY f.confidence DESC, lower(f.valid) DESC NULLS LAST, f.id LIMIT 20";

const recent_sql = "SELECT " ++ db.hit_columns ++ from ++ base_where ++
    " AND (f.scope = 'global' OR f.project = $2::text) AND (" ++
    "(f.relation IN ('chose', 'rejected', 'has_status') AND f.valid @> now() AND lower(f.known) >= now() - interval '14 days')" ++
    " OR (f.end_kind = 'changed' AND upper(f.valid) <= now() AND upper(f.valid) >= now() - interval '14 days'))" ++
    " ORDER BY greatest(lower(f.known), upper(f.valid)) DESC, f.id LIMIT 20";

const project_sql = "SELECT " ++ db.hit_columns ++ ", se.summary" ++ from ++ base_where ++
    " AND f.valid @> now() AND f.project = $2::text AND f.scope = 'project'" ++
    " ORDER BY f.confidence * (0.85 + 0.15 * exp(-extract(epoch FROM now() - coalesce(" ++ db.lowerBound("f.valid") ++
    ", lower(f.known))) / 86400.0 / 60.0)) DESC, f.id LIMIT 40";

fn cacheKey(project: ?[]const u8) []const u8 {
    return project orelse "";
}

pub fn get(e: *mod.Engine, arena: std.mem.Allocator, project: ?[]const u8) ![]const u8 {
    {
        e.briefs.mutex.lockUncancelable(e.io);
        defer e.briefs.mutex.unlock(e.io);
        if (e.briefs.entries.get(cacheKey(project))) |body| return arena.dupe(u8, body);
    }
    const stored = try load(e, arena, project);
    const body = stored orelse try buildAndStore(e, arena, project);
    try e.briefs.put(e.gpa, e.io, cacheKey(project), body);
    return body;
}

pub fn refreshAll(e: *mod.Engine) !void {
    var arena_state = std.heap.ArenaAllocator.init(e.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var keys: std.ArrayList([]const u8) = .empty;
    {
        e.briefs.mutex.lockUncancelable(e.io);
        defer e.briefs.mutex.unlock(e.io);
        var it = e.briefs.entries.keyIterator();
        while (it.next()) |k| try keys.append(arena, try arena.dupe(u8, k.*));
    }
    for (keys.items) |k| {
        const project: ?[]const u8 = if (k.len == 0) null else k;
        const body = try buildAndStore(e, arena, project);
        try e.briefs.put(e.gpa, e.io, k, body);
    }
}

fn load(e: *mod.Engine, arena: std.mem.Allocator, project: ?[]const u8) !?[]const u8 {
    const conn = try e.store.pool.acquire();
    defer conn.release();
    var row = (try db.queryRow(conn, arena,
        \\SELECT body FROM project_brief b WHERE b.graph_id = $1 AND b.project = $2
        \\  AND b.built_at >= coalesce((SELECT max(committed_at) FROM commit_log c WHERE c.graph_id = $1), '-infinity')
    , .{ &e.graph_id.bytes, cacheKey(project) })) orelse return null;
    defer row.deinit() catch {};
    return try db.text(arena, &row, 0);
}

fn buildAndStore(e: *mod.Engine, arena: std.mem.Allocator, project: ?[]const u8) ![]const u8 {
    const body = try build(e, arena, project);
    const conn = try e.store.pool.acquire();
    defer conn.release();
    _ = try db.exec(conn,
        \\INSERT INTO project_brief (graph_id, project, body, built_at) VALUES ($1, $2, $3, now())
        \\ON CONFLICT (graph_id, project) DO UPDATE SET body = excluded.body, built_at = excluded.built_at
    , .{ &e.graph_id.bytes, cacheKey(project), body });
    return body;
}

fn query(conn: anytype, arena: std.mem.Allocator, sql: []const u8, args: anytype, with_summary: bool, summaries: ?*std.AutoHashMapUnmanaged(core.Id, []const u8)) ![]Hit {
    var out: std.ArrayList(Hit) = .empty;
    var result = try db.query(conn, arena, sql, args);
    defer result.deinit();
    while (try result.next()) |row| {
        const hit = try db.readHit(arena, row);
        try out.append(arena, hit);
        if (with_summary) {
            const s = try db.text(arena, row, db.hit_column_count);
            if (s.len > 0) try summaries.?.put(arena, hit.fact.subject_id, s);
        }
    }
    return out.items;
}

/// Deterministic brief: standing preferences, active project facts with entity summaries,
/// then decisions and changes from the last 14 days. Empty when there is nothing to say.
pub fn build(e: *mod.Engine, arena: std.mem.Allocator, project: ?[]const u8) ![]const u8 {
    var summaries: std.AutoHashMapUnmanaged(core.Id, []const u8) = .empty;
    var prefs: []Hit = &.{};
    var recent: []Hit = &.{};
    var facts: []Hit = &.{};
    {
        const conn = try e.store.pool.acquire();
        defer conn.release();
        prefs = try query(conn, arena, prefs_sql, .{&e.graph_id.bytes}, false, null);
        recent = try query(conn, arena, recent_sql, .{ &e.graph_id.bytes, project }, false, null);
        if (project) |p| facts = try query(conn, arena, project_sql, .{ &e.graph_id.bytes, p }, true, &summaries);
    }

    var shown: std.AutoHashMapUnmanaged(core.Id, void) = .empty;
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;

    var prefs_out: Writer.Allocating = .init(arena);
    {
        var b: render.Budget = .{ .max_tokens = section_tokens.prefs };
        _ = b.take(26);
        for (prefs) |*h| {
            var line: Writer.Allocating = .init(arena);
            try writeLine(&line.writer, h, false);
            if (b.take(line.written().len)) {
                try prefs_out.writer.writeAll(line.written());
                try shown.put(arena, h.fact.id, {});
            }
        }
    }

    var recent_out: Writer.Allocating = .init(arena);
    {
        var b: render.Budget = .{ .max_tokens = section_tokens.recent };
        _ = b.take(44);
        for (recent) |*h| {
            if (shown.contains(h.fact.id)) continue;
            var line: Writer.Allocating = .init(arena);
            try writeLine(&line.writer, h, true);
            if (b.take(line.written().len)) {
                try recent_out.writer.writeAll(line.written());
                try shown.put(arena, h.fact.id, {});
            }
        }
    }

    var project_out: Writer.Allocating = .init(arena);
    {
        var b: render.Budget = .{ .max_tokens = section_tokens.project };
        _ = b.take(20 + if (project) |p| p.len else 0);
        var summarized: std.AutoHashMapUnmanaged(core.Id, void) = .empty;
        for (facts) |*h| {
            if (shown.contains(h.fact.id)) continue;
            var line: Writer.Allocating = .init(arena);
            if (summaries.get(h.fact.subject_id)) |s| if (!summarized.contains(h.fact.subject_id)) {
                try line.writer.print("- **{s}** ({s}): {s}\n", .{ h.subject_name, @tagName(h.subject_type), render.clip(s, 240) });
            };
            const with_summary = line.written().len;
            try writeLine(&line.writer, h, false);
            if (b.take(line.written().len)) {
                try project_out.writer.writeAll(line.written());
                if (with_summary > 0) try summarized.put(arena, h.fact.subject_id, {});
            } else if (with_summary > 0 and b.take(with_summary)) {
                try project_out.writer.writeAll(line.written()[0..with_summary]);
                try summarized.put(arena, h.fact.subject_id, {});
            }
        }
    }

    if (prefs_out.written().len + project_out.written().len + recent_out.written().len == 0) return "";
    var date_buf: [10]u8 = undefined;
    try w.print("## graf memory brief (project: {s}, {s})\n", .{ project orelse "none", time.formatDate(time.now(e.io), &date_buf) });
    if (prefs_out.written().len > 0) try w.print("\n### Standing preferences\n{s}", .{prefs_out.written()});
    if (project_out.written().len > 0) try w.print("\n### Project {s}\n{s}", .{ project.?, project_out.written() });
    if (recent_out.written().len > 0) try w.print("\n### Last 14 days: decisions and changes\n{s}", .{recent_out.written()});
    return out.written();
}

fn writeLine(w: *Writer, h: *const Hit, dated: bool) Writer.Error!void {
    const f = h.fact;
    try w.writeAll("- [");
    if (dated) {
        if (f.valid.upper) |t| {
            try w.print("{f} ended", .{time.Date{ .t = t }});
            if (f.end_kind) |k| try w.print(" ({s})", .{@tagName(k)});
        } else {
            try w.print("{f} {s}", .{ time.Date{ .t = f.known.lower orelse 0 }, f.relation });
        }
    } else if (f.valid.lower) |t| {
        try w.print("since {f}", .{time.Date{ .t = t }});
    } else {
        try w.writeAll("current");
    }
    try w.print(" | conf {d:.2}] {s}", .{ f.confidence, f.text });
    if (f.rationale) |why| if (why.len > 0) try w.print(" (why: {s})", .{why});
    try w.writeByte('\n');
}
