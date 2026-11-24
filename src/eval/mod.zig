//! Eval workstream (spec 7): replays the labeled episode suite through graf, reads
//! the resulting graph and ledger, runs the retrieval queries, and scores the release
//! gates. Fixtures live in `evals/` at the repo root.

const std = @import("std");
const core = @import("core");
const store = @import("store");
const ingest = @import("ingest");
const retrieve = @import("retrieve");

/// One line of `evals/episodes.jsonl`.
pub const EvalEpisode = struct {
    id: []const u8,
    seq: u32,
    harness: core.Harness,
    source_id: []const u8,
    project: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reference_time: []const u8,
    kind: core.types.EpisodeKind,
    asserted_by: core.types.AssertedBy,
    turns: []const core.Turn = &.{},
};

/// v1 release bar (spec 7.3). M1 ships only when every gate passes.
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
    pub const calls_per_episode_max = 2.00;
    pub const cost_per_episode_max_usd = 0.02;
    pub const crash_resume_pass_rate_min = 1.0;
};

pub const Metrics = struct {
    entity_f1: f64 = 0,
    merge_accuracy: f64 = 0,
    cross_type_merges: u32 = 0,
    fact_precision: f64 = 0,
    fact_recall: f64 = 0,
    invalidation_f1: f64 = 0,
    temporal_accuracy: f64 = 0,
    secret_leaks: u32 = 0,
    retrieval_recall_at_5: f64 = 0,
    calls_per_episode: f64 = 0,
    cost_per_episode_usd: f64 = 0,
    crash_resume_pass_rate: f64 = 0,

    pub fn passes(m: Metrics) bool {
        return m.entity_f1 >= gates.entity_f1_min and
            m.merge_accuracy >= gates.merge_accuracy_min and
            m.cross_type_merges <= gates.cross_type_merges_max and
            m.fact_precision >= gates.fact_precision_min and
            m.fact_recall >= gates.fact_recall_min and
            m.invalidation_f1 >= gates.invalidation_f1_min and
            m.temporal_accuracy >= gates.temporal_accuracy_min and
            m.secret_leaks <= gates.secret_leaks_max and
            m.retrieval_recall_at_5 >= gates.retrieval_recall_at_5_min and
            m.calls_per_episode <= gates.calls_per_episode_max and
            m.cost_per_episode_usd <= gates.cost_per_episode_max_usd and
            m.crash_resume_pass_rate >= gates.crash_resume_pass_rate_min;
    }
};

pub const RunOptions = struct {
    /// Directory holding `episodes.jsonl`, `expected.json`.
    suite_dir: []const u8 = "evals",
};

pub fn run(arena: std.mem.Allocator, io: std.Io, config: *const core.Config, opts: RunOptions) !Metrics {
    _ = arena;
    _ = io;
    _ = config;
    _ = opts;
    return core.NotImplemented;
}

test {
    std.testing.refAllDecls(@This());
}

test "an all-zero scorecard fails the gates" {
    try std.testing.expect(!(Metrics{}).passes());
}
