const std = @import("std");
const core = @import("core");

pub fn formatDate(t: core.Micros, buf: *[10]u8) []const u8 {
    const days = @divFloor(t, std.time.us_per_day);
    const c = core.time.civilFromDays(days);
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(c.year)), c.month, c.day }) catch unreachable;
    return buf;
}

pub const Date = struct {
    t: core.Micros,

    pub fn format(d: Date, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [10]u8 = undefined;
        try w.writeAll(formatDate(d.t, &buf));
    }
};

test "dates format in utc" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("2026-11-29", formatDate(try core.time.parseIso("2026-11-29T23:59:59Z"), &buf));
    try std.testing.expectEqualStrings("1969-12-31", formatDate(-1, &buf));
    try std.testing.expectEqualStrings("2000-02-29", formatDate(try core.time.parseIso("2000-02-29T12:00:00Z"), &buf));
}
