//! Shared vocabulary for every module: the domain types (episodes, entities, facts,
//! change sets), the core ontology, configuration, and the small interfaces that let
//! modules talk without importing each other.
//!
//! Adding a declaration here is fine in any PR. Changing or removing an existing one
//! needs its own PR first (see AGENTS.md).

const std = @import("std");

pub const types = @import("types.zig");
pub const ontology = @import("ontology.zig");
pub const config = @import("config.zig");
pub const toml = @import("toml.zig");

pub const Id = types.Id;
pub const Micros = types.Micros;
pub const Range = types.Range;
pub const Harness = types.Harness;
pub const Turn = types.Turn;
pub const ToolCall = types.ToolCall;
pub const SourceKey = types.SourceKey;
pub const EpisodeBody = types.EpisodeBody;
pub const EpisodeDraft = types.EpisodeDraft;
pub const Episode = types.Episode;
pub const Entity = types.Entity;
pub const EntityType = types.EntityType;
pub const Fact = types.Fact;
pub const Predicate = types.Predicate;
pub const ChangeSet = types.ChangeSet;
pub const LlmCall = types.LlmCall;
pub const EpisodeSink = types.EpisodeSink;
pub const LlmLedger = types.LlmLedger;
pub const Config = config.Config;

/// Returned by public interfaces that are declared but not built yet.
pub const NotImplemented = error.NotImplemented;

test {
    std.testing.refAllDecls(@This());
}
