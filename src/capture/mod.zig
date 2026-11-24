const std = @import("std");
const core = @import("core");

pub const redactor = @import("redact.zig");
pub const normalize = @import("normalize.zig");
pub const dialect = @import("dialect.zig");
pub const segment = @import("segment.zig");
pub const cursor = @import("cursor.zig");
pub const tailer = @import("tailer.zig");
pub const Tailer = tailer.Tailer;
pub const watch = @import("watch.zig");
pub const service = @import("service.zig");
pub const Capture = service.Capture;
pub const state = @import("state.zig");
pub const project = @import("project.zig");
pub const hooks = @import("hooks.zig");
pub const install = @import("install.zig");

pub const redact = redactor.redact;

pub const default_roots = service.default_roots;

test {
    std.testing.refAllDecls(@This());
}
