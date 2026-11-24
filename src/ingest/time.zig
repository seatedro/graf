const std = @import("std");
const core = @import("core");

const Micros = core.Micros;

pub fn parseBound(s: ?[]const u8) core.time.ParseError!?Micros {
    const v = s orelse return null;
    const t = std.mem.trim(u8, v, " \t");
    if (t.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(t, "-infinity") or std.ascii.eqlIgnoreCase(t, "infinity")) return null;
    return try core.time.parseRfc3339(t);
}

const weekdays = [_][]const u8{ "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" };

pub fn weekday(t: Micros) []const u8 {
    const days = @divFloor(t, std.time.us_per_day);
    return weekdays[@intCast(@mod(days, 7))];
}

pub fn format(t: Micros, buf: *[20]u8) []const u8 {
    const days = @divFloor(t, std.time.us_per_day);
    const rem = @mod(t, std.time.us_per_day);
    const c = core.time.civilFromDays(days);
    const secs: u32 = @intCast(@divFloor(rem, std.time.us_per_s));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(c.year)), c.month, c.day, secs / 3600, (secs / 60) % 60, secs % 60,
    }) catch unreachable;
}

test "timestamps format back to rfc3339 with their weekday" {
    const t = try core.time.parseRfc3339("2026-11-20T17:00:00Z");
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("2026-11-20T17:00:00Z", format(t, &buf));
    try std.testing.expectEqualStrings("Friday", weekday(t));
}

test "open bounds parse to null" {
    try std.testing.expectEqual(@as(?Micros, null), try parseBound("-infinity"));
    try std.testing.expectEqual(@as(?Micros, null), try parseBound(null));
    try std.testing.expectEqual(@as(?Micros, null), try parseBound(" "));
    try std.testing.expectEqual(try core.time.parseRfc3339("2026-11-17"), (try parseBound(" 2026-11-17 ")).?);
    try std.testing.expectError(error.InvalidTimestamp, parseBound("next tuesday"));
}
