//! `graf hook <harness> <event>` (spec 4.1, 6.1): the brief on session start, instant
//! recall on prompt submit, and a flush request on stop / session end. Every path
//! exits 0 within its budget and spools to disk when the daemon is down.

const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Event = enum { @"session-start", @"prompt-submit", stop, @"session-end" };

/// Runs one hook invocation. `stdin_json` is what the harness piped in; anything the
/// harness should add to the model's context is written to `out`. Never fails the
/// agent's turn: daemon errors degrade to empty output (and a spool line for flushes).
pub fn run(arena: Allocator, io: std.Io, env: *const Environ.Map, config: *const core.Config, harness: core.Harness, event: Event, stdin_json: []const u8, out: *std.Io.Writer) !void {
    _ = arena;
    _ = io;
    _ = env;
    _ = config;
    _ = harness;
    _ = event;
    _ = stdin_json;
    _ = out;
    return core.NotImplemented;
}
