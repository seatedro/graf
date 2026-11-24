const std = @import("std");
const core = @import("core");
const time = @import("time.zig");
const mod = @import("mod.zig");
const Hit = mod.Hit;
const Writer = std.Io.Writer;

pub fn estimateTokens(bytes: usize) u32 {
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(bytes)) / 3.8));
}

pub const Budget = struct {
    max_tokens: u32,
    bytes: usize = 0,

    pub fn fits(b: Budget, more: usize) bool {
        const t = @as(f64, @floatFromInt(estimateTokens(b.bytes + more))) * 1.1;
        return t <= @as(f64, @floatFromInt(b.max_tokens));
    }

    pub fn take(b: *Budget, more: usize) bool {
        if (!b.fits(more)) return false;
        b.bytes += more;
        return true;
    }
};

pub fn writeFactLine(w: *Writer, hit: *const Hit, with_range: bool) Writer.Error!void {
    const f = hit.fact;
    try w.writeAll("- [");
    if (f.known.upper) |t| {
        try w.print("{s} {f}", .{ if (f.end_kind) |k| @tagName(k) else "retracted", time.Date{ .t = t } });
    } else if (f.valid.upper) |t| {
        if (with_range) {
            if (f.valid.lower) |lo| try w.print("{f} -> {f}", .{ time.Date{ .t = lo }, time.Date{ .t = t } }) else try w.print("until {f}", .{time.Date{ .t = t }});
            if (f.end_kind) |k| try w.print(" ({s})", .{@tagName(k)});
        } else {
            try w.print("ended {f}", .{time.Date{ .t = t }});
            if (f.end_kind) |k| try w.print(" ({s})", .{@tagName(k)});
        }
    } else if (f.valid.lower) |t| {
        try w.print("current since {f}", .{time.Date{ .t = t }});
    } else {
        try w.writeAll("current");
    }
    try w.print(" | conf {d:.2} | {s}] {s}", .{ f.confidence, if (hit.harness) |h| @tagName(h) else @tagName(f.author), f.text });
    if (f.rationale) |why| if (why.len > 0) try w.print(" (why: {s})", .{why});
    try w.writeByte('\n');
}

fn writeEntityHeader(w: *Writer, e: *const core.Entity) Writer.Error!void {
    try w.print("\n### {s} ({s})", .{ e.name, @tagName(e.type) });
    const about = if (e.summary.len > 0) e.summary else e.description;
    if (about.len > 0) try w.print(" — {s}", .{clip(about, 160)});
    try w.writeByte('\n');
}

pub fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn lineLen(comptime f: anytype, args: anytype) usize {
    var counter: Writer.Discarding = .init(&.{});
    @call(.auto, f, .{&counter.writer} ++ args) catch unreachable;
    return @intCast(counter.fullCount());
}

fn subjectEntity(entities: []const core.Entity, hit: *const Hit) core.Entity {
    for (entities) |e| if (e.id.eql(hit.fact.subject_id)) return e;
    return .{ .id = hit.fact.subject_id, .graph_id = hit.fact.graph_id, .name = hit.subject_name, .norm = "", .type = hit.subject_type };
}

pub fn render(result: *const mod.SearchResult, params: mod.SearchParams, out: *Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const max_tokens = @min(@max(params.max_tokens, 100), mod.max_tokens_limit);
    const scope = if (params.project) |p| (if (std.mem.eql(u8, p, "*")) "all projects" else p) else "global";

    var budget: Budget = .{ .max_tokens = max_tokens };
    _ = budget.take(64 + params.query.len + scope.len);

    const Group = struct { subject: core.Id, hits: std.ArrayList(*const Hit) };
    var groups: std.ArrayList(Group) = .empty;
    for (result.hits) |*hit| {
        var group: ?*Group = null;
        for (groups.items) |*g| if (g.subject.eql(hit.fact.subject_id)) {
            group = g;
        };
        var cost = lineLen(writeFactLine, .{ hit, params.include_history });
        if (group == null) {
            cost += lineLen(writeEntityHeader, .{&subjectEntity(result.entities, hit)});
        }
        if (!budget.take(cost)) continue;
        if (group == null) {
            try groups.append(arena, .{ .subject = hit.fact.subject_id, .hits = .empty });
            group = &groups.items[groups.items.len - 1];
        }
        try group.?.hits.append(arena, hit);
    }

    var index: Writer.Allocating = .init(arena);
    var seen: std.AutoHashMapUnmanaged(core.Id, void) = .empty;
    for (groups.items) |g| try seen.put(arena, g.subject, {});
    var first = true;
    for (groups.items) |g| for (g.hits.items) |h| if (h.object_name) |name| switch (h.fact.object) {
        .entity => |oid| if (!(try seen.getOrPut(arena, oid)).found_existing) {
            try index.writer.print("{s}{s}", .{ if (first) "\nAlso mentioned: " else ", ", name });
            first = false;
        },
        .value => {},
    };
    if (!first) try index.writer.writeByte('\n');
    const index_text = if (budget.take(index.written().len)) index.written() else "";

    var as_of_buf: [10]u8 = undefined;
    try out.print("## Memory for \"{s}\" (project: {s}, as_of: {s}, {d}/{d} tok)\n", .{
        params.query, scope, time.formatDate(result.as_of, &as_of_buf), estimateTokens(budget.bytes), max_tokens,
    });
    if (groups.items.len == 0) {
        try out.writeAll("\nNo matching memories.\n");
        return;
    }
    for (groups.items) |g| {
        try writeEntityHeader(out, &subjectEntity(result.entities, g.hits.items[0]));
        for (g.hits.items) |h| try writeFactLine(out, h, params.include_history);
    }
    try out.writeAll(index_text);
}

pub fn renderEntity(result: *const mod.EntityResult, params: mod.EntityParams, out: *Writer) !void {
    const max_tokens = @min(@max(params.max_tokens, 100), mod.max_tokens_limit);
    var budget: Budget = .{ .max_tokens = max_tokens };
    var body: Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    const w = &body.writer;
    const e = result.entity;

    if (e.aliases.len > 0) {
        try w.writeAll("Aliases: ");
        for (e.aliases, 0..) |a, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", a });
        try w.writeByte('\n');
    }
    if (e.entity.description.len > 0) try w.print("{s}\n", .{e.entity.description});
    if (e.entity.summary.len > 0) try w.print("Summary: {s}\n", .{e.entity.summary});
    if (result.alternatives.len > 0) {
        try w.writeAll("Other entities with this name: ");
        for (result.alternatives, 0..) |a, i| try w.print("{s}{s} ({s}, id {f})", .{ if (i == 0) "" else "; ", a.name, @tagName(a.type), a.id });
        try w.writeByte('\n');
    }
    _ = budget.take(64 + e.entity.name.len + body.written().len);

    var facts: Writer.Allocating = .init(std.heap.page_allocator);
    defer facts.deinit();
    for (result.facts) |*h| {
        const n = lineLen(writeFactLine, .{ h, true });
        if (budget.take(n)) try writeFactLine(&facts.writer, h, true);
    }
    if (facts.written().len > 0) {
        try w.writeAll("\n### Facts\n");
        try w.writeAll(facts.written());
        _ = budget.take(10);
    }

    var neighbors: Writer.Allocating = .init(std.heap.page_allocator);
    defer neighbors.deinit();
    for (result.neighbors) |*n| {
        const about = if (n.entity.summary.len > 0) n.entity.summary else n.entity.description;
        var line: Writer.Allocating = .init(std.heap.page_allocator);
        defer line.deinit();
        try line.writer.print("- {s} ({s})", .{ n.entity.name, @tagName(n.entity.type) });
        if (about.len > 0) try line.writer.print(" — {s}", .{clip(about, 160)});
        try line.writer.writeByte('\n');
        if (!budget.take(line.written().len)) continue;
        try neighbors.writer.writeAll(line.written());
        for (n.facts) |*h| {
            const cost = 2 + lineLen(writeFactLine, .{ h, true });
            if (!budget.take(cost)) continue;
            try neighbors.writer.writeAll("  ");
            try writeFactLine(&neighbors.writer, h, true);
        }
    }
    if (neighbors.written().len > 0) {
        try w.writeAll("\n### Neighbors\n");
        try w.writeAll(neighbors.written());
    }

    var as_of_buf: [10]u8 = undefined;
    try out.print("## {s} ({s}) (id: {f}, as_of: {s}, {d}/{d} tok)\n", .{
        e.entity.name, @tagName(e.entity.type), e.entity.id, time.formatDate(result.as_of, &as_of_buf), estimateTokens(budget.bytes), max_tokens,
    });
    try out.writeAll(body.written());
}

fn testHit(subject: core.Id, subject_name: []const u8, fact_text: []const u8, lower: ?core.Micros, upper: ?core.Micros) Hit {
    return .{
        .fact = .{
            .id = core.Id.fromParts(1, @splat(@truncate(fact_text.len))),
            .graph_id = core.Id.nil,
            .subject_id = subject,
            .relation = "uses",
            .object = .{ .value = "x" },
            .text = fact_text,
            .scope = .project,
            .valid = .{ .lower = lower, .upper = upper },
            .known = .{ .lower = lower },
            .end_kind = if (upper != null) .changed else null,
            .author = .user,
            .confidence = 0.9,
        },
        .subject_name = subject_name,
        .subject_type = .software,
        .harness = .@"claude-code",
    };
}

test "render groups by subject and tags each line" {
    const day = std.time.us_per_day;
    const t0 = try time.parseIso("2026-11-22");
    const pgzig = core.Id.fromParts(1, @splat(1));
    const graf = core.Id.fromParts(1, @splat(2));
    const hits = [_]Hit{
        testHit(pgzig, "pg.zig", "pg.zig lacks COPY and pipelining.", t0, null),
        testHit(graf, "graf", "graf uses Postgres 17 with pgvector and pg.zig.", t0 + day, null),
        testHit(pgzig, "pg.zig", "pg.zig works with pgvector HNSW via float4[] casts.", t0, null),
        testHit(graf, "graf", "graf considered SQLite before choosing Postgres.", null, t0 + day),
    };
    const entities = [_]core.Entity{
        .{ .id = pgzig, .graph_id = core.Id.nil, .name = "pg.zig", .norm = "pg zig", .type = .software, .description = "Zig Postgres driver" },
        .{ .id = graf, .graph_id = core.Id.nil, .name = "graf", .norm = "graf", .type = .project },
    };
    const result: mod.SearchResult = .{ .hits = &hits, .entities = &entities, .reranked = false, .as_of = t0 + day };
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&result, .{ .query = "pg.zig copy support", .project = "graf" }, &out.writer);
    const s = out.written();
    try std.testing.expect(std.mem.startsWith(u8, s, "## Memory for \"pg.zig copy support\" (project: graf, as_of: 2026-11-23, "));
    const expected_body =
        \\
        \\### pg.zig (software) — Zig Postgres driver
        \\- [current since 2026-11-22 | conf 0.90 | claude-code] pg.zig lacks COPY and pipelining.
        \\- [current since 2026-11-22 | conf 0.90 | claude-code] pg.zig works with pgvector HNSW via float4[] casts.
        \\
        \\### graf (project)
        \\- [current since 2026-11-23 | conf 0.90 | claude-code] graf uses Postgres 17 with pgvector and pg.zig.
        \\- [ended 2026-11-23 (changed) | conf 0.90 | claude-code] graf considered SQLite before choosing Postgres.
        \\
    ;
    try std.testing.expect(std.mem.endsWith(u8, s, expected_body));
}

test "render stays inside the token budget" {
    const subject = core.Id.fromParts(1, @splat(3));
    var hits: [200]Hit = undefined;
    for (&hits) |*h| h.* = testHit(subject, "graf", "graf records a fairly long fact sentence so that the budget fills up quickly.", 0, null);
    const result: mod.SearchResult = .{ .hits = &hits, .entities = &.{}, .reranked = false };
    for ([_]u32{ 100, 400, 1500, 4000 }) |max| {
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try render(&result, .{ .query = "q", .max_tokens = max }, &out.writer);
        const est = @as(f64, @floatFromInt(estimateTokens(out.written().len))) * 1.1;
        try std.testing.expect(est <= @as(f64, @floatFromInt(max)));
        if (max >= 400) try std.testing.expect(est >= @as(f64, @floatFromInt(max)) * 0.8);
    }
}

test "render reports an empty result" {
    const result: mod.SearchResult = .{ .hits = &.{}, .entities = &.{}, .reranked = false };
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&result, .{ .query = "nothing" }, &out.writer);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "No matching memories.\n"));
}
