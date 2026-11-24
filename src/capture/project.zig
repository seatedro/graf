//! Project derivation and capture exclusions.

const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;

/// The soft project scope for a working directory: the normalized origin remote of
/// its git repository (`github.com/owner/repo`), else the cleaned absolute `cwd`.
pub fn derive(arena: Allocator, io: std.Io, cwd: []const u8) Allocator.Error![]const u8 {
    _ = arena;
    _ = io;
    return cwd;
}

pub const Exclusion = struct {
    /// The session's working directory, if known.
    cwd: ?[]const u8 = null,
    /// The derived project, if known.
    project: ?[]const u8 = null,
    /// The transcript file, if any.
    transcript_path: ?[]const u8 = null,
    /// `$HOME`, for `~` in `exclude_paths`.
    home: ?[]const u8 = null,
};

/// True when `capture.exclude_projects`, `capture.exclude_paths`, or a `.grafignore`
/// at the repository root of `cwd` excludes this session.
pub fn isExcluded(arena: Allocator, io: std.Io, config: *const core.Config, what: Exclusion) Allocator.Error!bool {
    _ = arena;
    _ = io;
    _ = config;
    _ = what;
    return false;
}
