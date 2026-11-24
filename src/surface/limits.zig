const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.serve);

pub const open_files_target: posix.rlim_t = 65536;
pub const darwin_open_max: posix.rlim_t = 10240;

pub const SetLimit = *const fn (posix.rlimit_resource, posix.rlimit) posix.SetrlimitError!void;

pub fn raiseOpenFiles() void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const limit = posix.getrlimit(.NOFILE) catch |err| {
        log.warn("cannot read the open file limit: {t}", .{err});
        return;
    };

    const raised = raiseOpenFilesWith(limit, posix.setrlimit) catch |err| {
        log.warn("cannot raise the open file limit above {d}: {t}; file watching falls back to periodic scans when it runs out", .{ limit.cur, err });
        return;
    };

    if (raised > limit.cur) log.info("raised the open file limit from {d} to {d}", .{ limit.cur, raised });
}

pub fn raiseOpenFilesWith(limit: posix.rlimit, set: SetLimit) posix.SetrlimitError!posix.rlim_t {
    const want = @min(limit.max, open_files_target);
    if (limit.cur >= want) return limit.cur;

    set(.NOFILE, .{ .cur = want, .max = limit.max }) catch |err| {
        const fallback = @min(want, darwin_open_max);
        if (fallback == want or fallback <= limit.cur) return err;

        try set(.NOFILE, .{ .cur = fallback, .max = limit.max });
        return fallback;
    };

    return want;
}

const testing = std.testing;

const FakeLimit = struct {
    var ceiling: posix.rlim_t = std.math.maxInt(posix.rlim_t);
    var calls: usize = 0;
    var applied: ?posix.rlimit = null;

    fn reset(c: posix.rlim_t) void {
        ceiling = c;
        calls = 0;
        applied = null;
    }

    fn set(resource: posix.rlimit_resource, limit: posix.rlimit) posix.SetrlimitError!void {
        std.debug.assert(resource == .NOFILE);
        calls += 1;
        if (limit.cur > ceiling) return error.LimitTooBig;
        applied = limit;
    }
};

test "the open file limit rises to the target, capped by the hard limit" {
    const infinity = std.math.maxInt(posix.rlim_t);

    FakeLimit.reset(infinity);
    try testing.expectEqual(open_files_target, try raiseOpenFilesWith(.{ .cur = 256, .max = infinity }, FakeLimit.set));
    try testing.expectEqual(infinity, FakeLimit.applied.?.max);

    FakeLimit.reset(infinity);
    try testing.expectEqual(@as(posix.rlim_t, 4096), try raiseOpenFilesWith(.{ .cur = 1024, .max = 4096 }, FakeLimit.set));
    try testing.expectEqual(@as(posix.rlim_t, 4096), FakeLimit.applied.?.cur);

    FakeLimit.reset(infinity);
    try testing.expectEqual(@as(posix.rlim_t, 1 << 20), try raiseOpenFilesWith(.{ .cur = 1 << 20, .max = infinity }, FakeLimit.set));
    try testing.expectEqual(@as(usize, 0), FakeLimit.calls);
}

test "a kernel that rejects the target falls back to OPEN_MAX, and a refusal is an error" {
    const infinity = std.math.maxInt(posix.rlim_t);

    FakeLimit.reset(darwin_open_max);
    try testing.expectEqual(darwin_open_max, try raiseOpenFilesWith(.{ .cur = 256, .max = infinity }, FakeLimit.set));
    try testing.expectEqual(@as(usize, 2), FakeLimit.calls);
    try testing.expectEqual(infinity, FakeLimit.applied.?.max);

    FakeLimit.reset(128);
    try testing.expectError(error.LimitTooBig, raiseOpenFilesWith(.{ .cur = 256, .max = infinity }, FakeLimit.set));
    try testing.expect(FakeLimit.applied == null);

    FakeLimit.reset(2048);
    try testing.expectError(error.LimitTooBig, raiseOpenFilesWith(.{ .cur = 256, .max = 8192 }, FakeLimit.set));
    try testing.expectEqual(@as(usize, 1), FakeLimit.calls);
}

test "raising the real open file limit never lowers it" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const before = try posix.getrlimit(.NOFILE);
    defer posix.setrlimit(.NOFILE, before) catch {};

    raiseOpenFiles();

    const after = try posix.getrlimit(.NOFILE);
    try testing.expect(after.cur >= before.cur);
    try testing.expectEqual(before.max, after.max);
}
