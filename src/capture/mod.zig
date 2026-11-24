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

pub const default_roots = [_]struct { core.Harness, []const u8 }{
    .{ .@"claude-code", ".claude/projects" },
    .{ .codex, ".codex/sessions" },
    .{ .pi, ".pi/agent/sessions" },
    .{ .fx, ".fx/sessions" },
};

test {
    std.testing.refAllDecls(@This());
}
