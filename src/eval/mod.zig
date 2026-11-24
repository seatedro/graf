const std = @import("std");
const core = @import("core");

pub const time = @import("time.zig");
pub const fixtures = @import("fixtures.zig");
pub const score = @import("score.zig");
pub const pgload = @import("pgload.zig");
pub const runner = @import("runner.zig");
pub const cli = @import("cli.zig");

pub const Suite = fixtures.Suite;
pub const GraphState = score.GraphState;
pub const Report = score.Report;
pub const RunOptions = runner.RunOptions;
pub const run = runner.run;
pub const loadGraphState = pgload.loadGraphState;
pub const main = cli.main;

pub const EvalEntry = struct {
    id: []const u8,
    seq: u32,
    harness: core.Harness,
    source_id: []const u8,
    project: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reference_time: []const u8,
    kind: core.types.EntryKind,
    author: core.types.Author,
    turns: []const core.Turn = &.{},
};

pub const gates = struct {
    pub const entity_f1_min = 0.85;
    pub const merge_accuracy_min = 0.90;
    pub const cross_type_merges_max = 0;
    pub const fact_precision_min = 0.85;
    pub const fact_recall_min = 0.80;
    pub const invalidation_f1_min = 0.85;
    pub const temporal_accuracy_min = 0.90;
    pub const secret_leaks_max = 0;
    pub const retrieval_recall_at_5_min = 0.85;
    pub const calls_per_entry_max = 2.00;
    pub const cost_per_entry_max_usd = 0.02;
    pub const crash_resume_pass_rate_min = 1.0;
};

pub const Metrics = struct {
    entity_f1: ?f64 = null,
    merge_accuracy: ?f64 = null,
    cross_type_merges: ?u32 = null,
    fact_precision: ?f64 = null,
    fact_recall: ?f64 = null,
    invalidation_f1: ?f64 = null,
    temporal_accuracy: ?f64 = null,
    secret_leaks: ?u32 = null,
    retrieval_recall_at_5: ?f64 = null,
    calls_per_entry: ?f64 = null,
    cost_per_entry_usd: ?f64 = null,
    crash_resume_pass_rate: ?f64 = null,

    pub fn gateList(m: Metrics) [12]Gate {
        return .{
            .{ .metric = "entity_f1", .value = m.entity_f1, .bound = .at_least, .limit = gates.entity_f1_min, .unit = .ratio },
            .{ .metric = "merge_accuracy", .value = m.merge_accuracy, .bound = .at_least, .limit = gates.merge_accuracy_min, .unit = .ratio },
            .{ .metric = "cross_type_merges", .value = count(m.cross_type_merges), .bound = .at_most, .limit = gates.cross_type_merges_max, .unit = .count },
            .{ .metric = "fact_precision", .value = m.fact_precision, .bound = .at_least, .limit = gates.fact_precision_min, .unit = .ratio },
            .{ .metric = "fact_recall", .value = m.fact_recall, .bound = .at_least, .limit = gates.fact_recall_min, .unit = .ratio },
            .{ .metric = "invalidation_f1", .value = m.invalidation_f1, .bound = .at_least, .limit = gates.invalidation_f1_min, .unit = .ratio },
            .{ .metric = "temporal_accuracy", .value = m.temporal_accuracy, .bound = .at_least, .limit = gates.temporal_accuracy_min, .unit = .ratio },
            .{ .metric = "secret_leaks", .value = count(m.secret_leaks), .bound = .at_most, .limit = gates.secret_leaks_max, .unit = .count },
            .{ .metric = "retrieval_recall_at_5", .value = m.retrieval_recall_at_5, .bound = .at_least, .limit = gates.retrieval_recall_at_5_min, .unit = .ratio },
            .{ .metric = "calls_per_entry", .value = m.calls_per_entry, .bound = .at_most, .limit = gates.calls_per_entry_max, .unit = .calls },
            .{ .metric = "cost_per_entry_usd", .value = m.cost_per_entry_usd, .bound = .at_most, .limit = gates.cost_per_entry_max_usd, .unit = .usd },
            .{ .metric = "crash_resume_pass_rate", .value = m.crash_resume_pass_rate, .bound = .at_least, .limit = gates.crash_resume_pass_rate_min, .unit = .ratio },
        };
    }

    pub fn passes(m: Metrics) bool {
        for (m.gateList()) |g| if (g.status() != .pass) return false;
        return true;
    }

    fn count(v: ?u32) ?f64 {
        return if (v) |n| @floatFromInt(n) else null;
    }
};

pub const Gate = struct {
    metric: []const u8,
    value: ?f64,
    bound: Bound,
    limit: f64,
    unit: Unit,

    pub const Bound = enum { at_least, at_most };
    pub const Unit = enum { ratio, count, calls, usd };
    pub const Status = enum { pass, fail, unmeasured };

    pub fn status(g: Gate) Status {
        const v = g.value orelse return .unmeasured;
        if (std.math.isNan(v)) return .fail;
        const ok = switch (g.bound) {
            .at_least => v >= g.limit,
            .at_most => v <= g.limit,
        };
        return if (ok) .pass else .fail;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "an unmeasured scorecard fails the gates" {
    try std.testing.expect(!(Metrics{}).passes());
}

test "every gate must be measured and within bounds to pass" {
    var m: Metrics = .{
        .entity_f1 = 0.9,
        .merge_accuracy = 1,
        .cross_type_merges = 0,
        .fact_precision = 0.9,
        .fact_recall = 0.85,
        .invalidation_f1 = 1,
        .temporal_accuracy = 1,
        .secret_leaks = 0,
        .retrieval_recall_at_5 = 0.9,
        .calls_per_entry = 2.0,
        .cost_per_entry_usd = 0.02,
        .crash_resume_pass_rate = 1,
    };
    try std.testing.expect(m.passes());
    m.crash_resume_pass_rate = null;
    try std.testing.expect(!m.passes());
    m.crash_resume_pass_rate = 1;
    m.secret_leaks = 1;
    try std.testing.expect(!m.passes());
}
