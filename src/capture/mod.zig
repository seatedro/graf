const std = @import("std");
const core = @import("core");

pub const default_roots = [_]struct { core.Harness, []const u8 }{
    .{ .@"claude-code", ".claude/projects" },
    .{ .codex, ".codex/sessions" },
    .{ .pi, ".pi/agent/sessions" },
    .{ .fx, ".fx/sessions" },
};

pub fn parseLine(harness: core.Harness, arena: std.mem.Allocator, line: []const u8) !?core.Turn {
    _ = harness;
    _ = arena;
    _ = line;
    return core.NotImplemented;
}

pub fn redact(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    _ = arena;
    _ = text;
    return core.NotImplemented;
}

pub const Segmenter = struct {
    pub const Trigger = enum { tokens, idle, hook, gap };

    pub fn push(s: *Segmenter, arena: std.mem.Allocator, turn: core.Turn) !?core.EntryDraft {
        _ = s;
        _ = arena;
        _ = turn;
        return core.NotImplemented;
    }

    pub fn flush(s: *Segmenter, arena: std.mem.Allocator, trigger: Trigger) !?core.EntryDraft {
        _ = s;
        _ = arena;
        _ = trigger;
        return core.NotImplemented;
    }
};

pub const Tailer = struct {
    harness: core.Harness,
    root: []const u8,
    sink: core.EntrySink,

    pub fn poll(t: *Tailer, arena: std.mem.Allocator) !void {
        _ = t;
        _ = arena;
        return core.NotImplemented;
    }
};

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
