//! Capture workstream (spec 4.1): transcript tailers for each local harness, the
//! normalizer (tool-aware retention, thinking stripped), the deterministic redactor,
//! the segmenter that seals turns into episodes, exclusions, and `graf hook`.
//!
//! Capture depends only on `core`: it emits `core.EpisodeDraft`s into a
//! `core.EpisodeSink`, so every piece is testable without Postgres.

const std = @import("std");
const core = @import("core");

/// Where each harness writes its session logs, relative to `$HOME` (spec 1.1).
pub const default_roots = [_]struct { core.Harness, []const u8 }{
    .{ .@"claude-code", ".claude/projects" },
    .{ .codex, ".codex/sessions" },
    .{ .pi, ".pi/agent/sessions" },
    .{ .fx, ".fx/sessions" },
};

/// Parses one JSONL line from a harness transcript into zero or one normalized turn.
/// Returns null for lines that carry no conversational content.
pub fn parseLine(harness: core.Harness, arena: std.mem.Allocator, line: []const u8) !?core.Turn {
    _ = harness;
    _ = arena;
    _ = line;
    return core.NotImplemented;
}

/// Replaces secrets with `[REDACTED:<kind>]` before anything is stored or sent to a
/// model (spec 4.1). Must never let a secret through: the eval gate is zero leaks.
pub fn redact(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    _ = arena;
    _ = text;
    return core.NotImplemented;
}

/// Accumulates turns per source and seals a window into an episode on the token,
/// idle, hook, or gap triggers (spec 4.1).
pub const Segmenter = struct {
    pub const Trigger = enum { tokens, idle, hook, gap };

    pub fn push(s: *Segmenter, arena: std.mem.Allocator, turn: core.Turn) !?core.EpisodeDraft {
        _ = s;
        _ = arena;
        _ = turn;
        return core.NotImplemented;
    }

    pub fn flush(s: *Segmenter, arena: std.mem.Allocator, trigger: Trigger) !?core.EpisodeDraft {
        _ = s;
        _ = arena;
        _ = trigger;
        return core.NotImplemented;
    }
};

/// A tailer follows one harness's session directory and feeds a sink.
pub const Tailer = struct {
    harness: core.Harness,
    root: []const u8,
    sink: core.EpisodeSink,

    /// Scans for new bytes in every session file, resuming from stored cursors.
    pub fn poll(t: *Tailer, arena: std.mem.Allocator) !void {
        _ = t;
        _ = arena;
        return core.NotImplemented;
    }
};

/// `graf hook <harness> <event>`: must exit 0 within its latency budget, spooling to
/// disk if the daemon is down (spec 4.1, 6.1).
pub const hooks = struct {
    pub const Event = enum { @"session-start", @"prompt-submit", stop, @"session-end" };

    pub fn run(arena: std.mem.Allocator, io: std.Io, config: *const core.Config, harness: core.Harness, event: Event, stdin_json: []const u8, out: *std.Io.Writer) !void {
        _ = arena;
        _ = io;
        _ = config;
        _ = harness;
        _ = event;
        _ = stdin_json;
        _ = out;
        return core.NotImplemented;
    }
};

test {
    std.testing.refAllDecls(@This());
}
