//! Capture's local state directory (`$XDG_STATE_HOME/graf`, else
//! `~/.local/state/graf`): the hook spool, the pause flag, and the capture epoch.

const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

/// `$XDG_STATE_HOME/graf`, else `$HOME/.local/state/graf`. Null when neither is set.
pub fn dir(arena: Allocator, env: *const Environ.Map) Allocator.Error!?[]const u8 {
    _ = arena;
    _ = env;
    return null;
}

/// True while `graf pause` is in effect (a `paused` file in the state directory).
pub fn isPaused(io: std.Io, state_dir: []const u8) bool {
    _ = io;
    _ = state_dir;
    return false;
}

/// `graf pause` / `graf resume`: creates or removes the pause flag.
pub fn setPaused(io: std.Io, state_dir: []const u8, paused: bool) !void {
    _ = io;
    _ = state_dir;
    _ = paused;
    return core.NotImplemented;
}

/// The capture epoch: turns older than this are never ingested unless a backfill asks
/// for them. Read from `<state_dir>/capture-since`; created with `now` on first use.
pub fn captureSince(io: std.Io, state_dir: []const u8, now: core.Micros) !core.Micros {
    _ = io;
    _ = state_dir;
    return now;
}
