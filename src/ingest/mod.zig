const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");

pub const TimeBasis = enum { explicit, relative, reference };

pub const ExtractResult = struct {
    skip: ?[]const u8,
    entities: []const ExtractedEntity,
    facts: []const ExtractedFact,
    new_predicates: []const ProposedPredicate,
};

pub const ExtractedEntity = struct {
    ref: []const u8,
    name: []const u8,
    type: core.EntityType,
    aliases: []const []const u8,
    description: []const u8,
};

pub const ExtractedFact = struct {
    subject: []const u8,
    predicate: []const u8,
    qualifier: ?[]const u8,
    object: ?[]const u8,
    value: ?[]const u8,
    text: []const u8,
    rationale: ?[]const u8,
    valid_from: ?[]const u8,
    valid_to: ?[]const u8,
    time_basis: TimeBasis,
    scope: core.types.Scope,
    asserted_by: core.types.FactAssertedBy,
    quote: []const u8,
};

pub const ProposedPredicate = struct {
    name: []const u8,
    description: []const u8,
    object_kind: core.types.ObjectKind,
};

pub const rules = @import("rules.zig");
pub const time = @import("time.zig");
pub const extract = @import("extract.zig");
pub const resolve = @import("resolve.zig");
pub const schema = @import("schema.zig");
pub const prompt = @import("prompt.zig");
pub const pipeline = @import("pipeline.zig");
pub const rebase = @import("rebase.zig");
pub const testing = @import("testing.zig");

pub const ConflictKind = rules.ConflictKind;

pub const ResolveResult = struct {
    entity_links: []const EntityLink,
    fact_verdicts: []const FactVerdict,
};

pub const EntityLink = struct {
    ref: []const u8,
    existing: ?[]const u8,
};

pub const FactVerdict = struct {
    fact_index: u32,
    duplicate_of: ?[]const u8,
    contradicts: []const Contradiction,
};

pub const Contradiction = struct {
    fact: []const u8,
    kind: ConflictKind,
    at: ?[]const u8,
};

pub const resolveConflict = rules.resolveConflict;

pub const Outcome = enum { committed, skipped, requeued, split, dead, fenced };

pub const Pipeline = struct {
    store: *store.Store,
    client: *llm.Client,
    config: *const core.Config,
    graph_id: core.Id,

    pub fn process(p: *Pipeline, arena: std.mem.Allocator, lease: store.Lease) !Outcome {
        _ = p;
        _ = arena;
        _ = lease;
        return core.NotImplemented;
    }

    pub fn runWorkers(p: *Pipeline, stop: *std.atomic.Value(bool)) !void {
        _ = p;
        _ = stop;
        return core.NotImplemented;
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("scenarios_test.zig");
    _ = @import("pipeline_test.zig");
}
