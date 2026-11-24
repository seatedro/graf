//! Capture: transcript tailers for each local harness, the dialect parsers and the
//! normalizer (tool-aware retention, thinking stripped), the deterministic
//! redactor, the segmenter that seals turns into episodes, exclusions, and
//! `graf hook` / `graf install`.
//!
//! Capture depends only on `core`: it emits `core.EpisodeDraft`s into a
//! `core.EpisodeSink`, so every piece is testable without Postgres.

const std = @import("std");
const core = @import("core");

pub const redactor = @import("redact.zig");
pub const normalize = @import("normalize.zig");
pub const dialect = @import("dialect.zig");
pub const state = @import("state.zig");
pub const project = @import("project.zig");
pub const hooks = @import("hooks.zig");
pub const install = @import("install.zig");

pub const redact = redactor.redact;

/// Where each harness writes its session logs, relative to `$HOME`.
pub const default_roots = [_]struct { core.Harness, []const u8 }{
    .{ .@"claude-code", ".claude/projects" },
    .{ .codex, ".codex/sessions" },
    .{ .pi, ".pi/agent/sessions" },
    .{ .fx, ".fx/sessions" },
};

test {
    std.testing.refAllDecls(@This());
}
