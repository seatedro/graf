const std = @import("std");
const core = @import("core");
const time = @import("time.zig");

pub const rrf_k = 60.0;
pub const weight_vec = 1.0;
pub const weight_lex = 0.8;
pub const weight_graph = 0.7;
pub const rerank_top = 25;
pub const rerank_weight = 0.65;
pub const mmr_lambda = 0.80;

pub const Ranks = struct {
    vec: ?u32 = null,
    lex: ?u32 = null,
    graph: ?u32 = null,
};

pub fn rrf(r: Ranks) f64 {
    var s: f64 = 0;
    if (r.vec) |v| s += weight_vec / (rrf_k + @as(f64, @floatFromInt(v)));
    if (r.lex) |v| s += weight_lex / (rrf_k + @as(f64, @floatFromInt(v)));
    if (r.graph) |v| s += weight_graph / (rrf_k + @as(f64, @floatFromInt(v)));
    return s;
}

pub const ProjectFilter = union(enum) {
    global_only,
    all,
    project: []const u8,

    pub fn from(p: ?[]const u8) ProjectFilter {
        const name = p orelse return .global_only;
        if (std.mem.eql(u8, name, "*")) return .all;
        return .{ .project = name };
    }

    pub fn sqlParam(f: ProjectFilter) ?[]const u8 {
        return switch (f) {
            .global_only => null,
            .all => "*",
            .project => |p| p,
        };
    }
};

pub fn scopeBoost(filter: ProjectFilter, scope: core.types.Scope, project: ?[]const u8) f64 {
    if (scope == .global) return 1.00;
    return switch (filter) {
        .project => |p| if (project != null and std.mem.eql(u8, project.?, p)) 1.20 else 0.80,
        else => 1.00,
    };
}

pub fn recencyFactor(age_days: f64) f64 {
    return 0.85 + 0.15 * @exp(-@max(age_days, 0) / 60.0);
}

pub fn confidenceFactor(confidence: f32) f64 {
    return 0.75 + 0.25 * @as(f64, confidence);
}

pub fn ageDays(as_of: core.Micros, since: ?core.Micros) f64 {
    const s = since orelse return 365.0;
    return @as(f64, @floatFromInt(as_of - s)) / @as(f64, @floatFromInt(time.us_per_day));
}

pub fn cosine(a: []const f32, b: []const f32) f64 {
    if (a.len == 0 or a.len != b.len) return 0;
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * y;
        na += @as(f64, x) * x;
        nb += @as(f64, y) * y;
    }
    if (na == 0 or nb == 0) return 0;
    return dot / (@sqrt(na) * @sqrt(nb));
}

pub const Candidate = struct {
    rrf: f64,
    factors: f64,
    emb: []const f32,
    relevance: ?f64 = null,
    score: f64 = 0,
};

pub fn score(cands: []Candidate, reranked: bool) void {
    var max_rrf: f64 = 0;
    for (cands) |c| max_rrf = @max(max_rrf, c.rrf);
    for (cands) |*c| {
        const base = if (!reranked) c.rrf else blk: {
            const n = if (max_rrf > 0) c.rrf / max_rrf else 0;
            break :blk rerank_weight * (c.relevance orelse 0) + (1 - rerank_weight) * n;
        };
        c.score = base * c.factors;
    }
}

pub fn mmr(arena: std.mem.Allocator, cands: []const Candidate) ![]u32 {
    const n = cands.len;
    const order = try arena.alloc(u32, n);
    if (n == 0) return order;
    var max_score: f64 = 0;
    for (cands) |c| max_score = @max(max_score, c.score);
    const taken = try arena.alloc(bool, n);
    @memset(taken, false);
    const max_sim = try arena.alloc(f64, n);
    @memset(max_sim, 0);
    for (0..n) |step| {
        var best: usize = 0;
        var best_val: f64 = -std.math.inf(f64);
        for (cands, 0..) |c, i| {
            if (taken[i]) continue;
            const rel = if (max_score > 0) c.score / max_score else 0;
            const val = mmr_lambda * rel - (1 - mmr_lambda) * (if (step == 0) 0 else max_sim[i]);
            if (val > best_val) {
                best_val = val;
                best = i;
            }
        }
        taken[best] = true;
        order[step] = @intCast(best);
        for (cands, 0..) |c, i| {
            if (!taken[i]) max_sim[i] = @max(max_sim[i], cosine(c.emb, cands[best].emb));
        }
    }
    return order;
}

pub fn byRrf(arena: std.mem.Allocator, cands: []const Candidate) ![]u32 {
    const idx = try arena.alloc(u32, cands.len);
    for (idx, 0..) |*v, i| v.* = @intCast(i);
    std.sort.pdq(u32, idx, cands, struct {
        fn lt(c: []const Candidate, a: u32, b: u32) bool {
            if (c[a].rrf != c[b].rrf) return c[a].rrf > c[b].rrf;
            return a < b;
        }
    }.lt);
    return idx;
}

test "rrf weights the arms" {
    const v = rrf(.{ .vec = 1 });
    const l = rrf(.{ .lex = 1 });
    const g = rrf(.{ .graph = 1 });
    try std.testing.expect(v > l and l > g);
    try std.testing.expectApproxEqAbs(1.0 / 61.0 + 0.8 / 62.0 + 0.7 / 63.0, rrf(.{ .vec = 1, .lex = 2, .graph = 3 }), 1e-12);
    try std.testing.expectEqual(@as(f64, 0), rrf(.{}));
}

test "scope boost prefers the caller's project" {
    const f = ProjectFilter.from("graf");
    try std.testing.expectEqual(@as(f64, 1.20), scopeBoost(f, .project, "graf"));
    try std.testing.expectEqual(@as(f64, 1.00), scopeBoost(f, .global, null));
    try std.testing.expectEqual(@as(f64, 0.80), scopeBoost(f, .project, "quayline"));
    try std.testing.expectEqual(@as(f64, 1.00), scopeBoost(ProjectFilter.from("*"), .project, "quayline"));
    try std.testing.expect(ProjectFilter.from(null) == .global_only);
}

test "recency and confidence factors stay gentle" {
    try std.testing.expectEqual(@as(f64, 1.0), recencyFactor(0));
    try std.testing.expect(recencyFactor(10_000) >= 0.85 and recencyFactor(10_000) < 0.851);
    try std.testing.expectEqual(@as(f64, 1.0), confidenceFactor(1.0));
    try std.testing.expectApproxEqAbs(0.925, confidenceFactor(0.7), 1e-6);
}

test "rerank blends relevance with normalized rrf" {
    var c = [_]Candidate{
        .{ .rrf = 0.02, .factors = 1, .emb = &.{}, .relevance = 0.1 },
        .{ .rrf = 0.01, .factors = 1, .emb = &.{}, .relevance = 0.9 },
        .{ .rrf = 0.015, .factors = 1, .emb = &.{} },
    };
    score(&c, true);
    try std.testing.expectApproxEqAbs(0.65 * 0.1 + 0.35, c[0].score, 1e-9);
    try std.testing.expectApproxEqAbs(0.65 * 0.9 + 0.35 * 0.5, c[1].score, 1e-9);
    try std.testing.expectApproxEqAbs(0.35 * 0.75, c[2].score, 1e-9);
    score(&c, false);
    try std.testing.expectEqual(@as(f64, 0.02), c[0].score);
}

test "mmr suppresses near-duplicate paraphrases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = [_]Candidate{
        .{ .rrf = 0, .factors = 1, .emb = &.{ 1, 0, 0 }, .score = 1.0 },
        .{ .rrf = 0, .factors = 1, .emb = &.{ 0.999, 0.01, 0 }, .score = 0.95 },
        .{ .rrf = 0, .factors = 1, .emb = &.{ 0, 1, 0 }, .score = 0.80 },
    };
    const order = try mmr(arena_state.allocator(), &c);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 1 }, order);
}
