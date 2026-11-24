//! Retrieval: hybrid search (HNSW + tsvector + alias/1-hop in one
//! SQL round trip, fused with RRF), optional decision-model rerank with a
//! deterministic fallback, MMR, the token-budgeted renderer, `memory_entity`, the
//! session-start brief, and background-warmed per-prompt recall.

const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");

pub const SearchParams = struct {
    query: []const u8,
    /// Caller's project; "*" searches every project; null means global facts only.
    project: ?[]const u8 = null,
    as_of: ?core.Micros = null,
    known_at: ?core.Micros = null,
    include_history: bool = false,
    harness: ?core.Harness = null,
    max_tokens: u32 = 1500,
};

pub const EntityParams = struct {
    name_or_id: []const u8,
    depth: u2 = 1,
    as_of: ?core.Micros = null,
    include_history: bool = false,
    include_retracted: bool = false,
    max_tokens: u32 = 1500,
};

pub const Hit = struct {
    fact: core.Fact,
    subject_name: []const u8,
    object_name: ?[]const u8 = null,
    harness: ?core.Harness = null,
    score: f64,
};

pub const SearchResult = struct {
    hits: []const Hit,
    entities: []const core.Entity,
    /// Whether the decision-model rerank ran (false means deterministic fallback).
    reranked: bool,
};

pub const Engine = struct {
    store: *store.Store,
    client: *llm.Client,
    config: *const core.Config,
    graph_id: core.Id,

    pub fn search(e: *Engine, arena: std.mem.Allocator, params: SearchParams) !SearchResult {
        _ = e;
        _ = arena;
        _ = params;
        return core.NotImplemented;
    }

    pub fn entity(e: *Engine, arena: std.mem.Allocator, params: EntityParams) !SearchResult {
        _ = e;
        _ = arena;
        _ = params;
        return core.NotImplemented;
    }

    /// Session-start brief for a project, at most 800 tokens, no model calls.
    pub fn brief(e: *Engine, arena: std.mem.Allocator, project: ?[]const u8) ![]const u8 {
        _ = e;
        _ = arena;
        _ = project;
        return core.NotImplemented;
    }
};

/// Renders results as compact Markdown within `max_tokens`.
pub fn render(result: *const SearchResult, params: SearchParams, out: *std.Io.Writer) !void {
    _ = result;
    _ = params;
    _ = out;
    return core.NotImplemented;
}

test {
    std.testing.refAllDecls(@This());
}
