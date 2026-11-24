//! Ingestion: the worker pool and per-episode state machine.
//! Claim -> continuity context -> extraction call -> validate and persist -> batch
//! embed -> one batched prefetch CTE -> deterministic resolution -> optional resolution call
//! -> bi-temporal invalidation -> staged change set -> fenced commit with rebase.
//!
//! The extraction and resolution result types below are the model-facing contracts. Their
//! JSON Schemas come from `llm.jsonSchema`, so changing a field here changes the
//! prompt contract.

const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");

pub const TimeBasis = enum { explicit, relative, reference };

/// Output of the extraction call.
pub const ExtractResult = struct {
    /// Reason the episode holds no durable knowledge, or null.
    skip: ?[]const u8,
    entities: []const ExtractedEntity,
    facts: []const ExtractedFact,
    new_predicates: []const ProposedPredicate,
};

pub const ExtractedEntity = struct {
    /// Local reference, `n1`..`nk`.
    ref: []const u8,
    name: []const u8,
    type: core.EntityType,
    aliases: []const []const u8,
    description: []const u8,
};

pub const ExtractedFact = struct {
    /// Entity ref of the subject.
    subject: []const u8,
    predicate: []const u8,
    qualifier: ?[]const u8,
    /// Entity ref of the object; exactly one of `object` and `value` is set.
    object: ?[]const u8,
    value: ?[]const u8,
    text: []const u8,
    rationale: ?[]const u8,
    /// RFC 3339.
    valid_from: ?[]const u8,
    valid_to: ?[]const u8,
    time_basis: TimeBasis,
    scope: core.types.Scope,
    asserted_by: core.types.FactAssertedBy,
    /// Verbatim excerpt, at most 200 characters.
    quote: []const u8,
};

pub const ProposedPredicate = struct {
    name: []const u8,
    description: []const u8,
    object_kind: core.types.ObjectKind,
};

pub const ConflictKind = enum { changed, was_wrong };

/// Output of the resolution call. Existing items are addressed by prefetch ids
/// (`E1..E40`, `F1..F80`); new facts by their index in `ExtractResult.facts`.
pub const ResolveResult = struct {
    entity_links: []const EntityLink,
    fact_verdicts: []const FactVerdict,
};

pub const EntityLink = struct {
    ref: []const u8,
    /// Prefetch id of the existing entity this one is, or null for a new entity.
    existing: ?[]const u8,
};

pub const FactVerdict = struct {
    fact_index: u32,
    /// Prefetch id of an existing fact this one restates, or null.
    duplicate_of: ?[]const u8,
    contradicts: []const Contradiction,
};

pub const Contradiction = struct {
    fact: []const u8,
    kind: ConflictKind,
    at: ?[]const u8,
};

/// Pure bi-temporal invalidation for one conflicting pair.
pub fn resolveConflict(old: *core.Fact, new: *core.Fact, kind: ConflictKind, commit_time: core.Micros, new_reference_time: core.Micros) !void {
    _ = old;
    _ = new;
    _ = kind;
    _ = commit_time;
    _ = new_reference_time;
    return core.NotImplemented;
}

pub const Outcome = enum { committed, skipped, requeued, split, dead, fenced };

pub const Pipeline = struct {
    store: *store.Store,
    client: *llm.Client,
    config: *const core.Config,
    graph_id: core.Id,

    /// Drives one claimed episode as far as it can go.
    pub fn process(p: *Pipeline, arena: std.mem.Allocator, lease: store.Lease) !Outcome {
        _ = p;
        _ = arena;
        _ = lease;
        return core.NotImplemented;
    }

    /// Runs `ingest.workers` blocking workers until `stop` is set.
    pub fn runWorkers(p: *Pipeline, stop: *std.atomic.Value(bool)) !void {
        _ = p;
        _ = stop;
        return core.NotImplemented;
    }
};

test {
    std.testing.refAllDecls(@This());
}
