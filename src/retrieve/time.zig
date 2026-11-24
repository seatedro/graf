const std = @import("std");
const core = @import("core");

pub const us_per_day: i64 = 86_400 * std.time.us_per_s;

pub fn now(io: std.Io) core.Micros {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_us));
}

pub const ParseError = error{InvalidTimestamp};

/// Accepts `YYYY-MM-DD`, optionally followed by `THH:MM[:SS[.fraction]]` and `Z` or `±HH:MM`.
/// A missing offset means UTC.
pub fn parseIso(s: []const u8) ParseError!core.Micros {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return error.InvalidTimestamp;
    const year = try int(s[0..4]);
    const month = try int(s[5..7]);
    const day = try int(s[8..10]);
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidTimestamp;
    var t: i64 = daysFromCivil(year, month, day) * us_per_day;
    var i: usize = 10;
    if (i == s.len) return t;
    if (s[i] != 'T' and s[i] != 't' and s[i] != ' ') return error.InvalidTimestamp;
    i += 1;
    if (s.len < i + 5 or s[i + 2] != ':') return error.InvalidTimestamp;
    const hour = try int(s[i .. i + 2]);
    const minute = try int(s[i + 3 .. i + 5]);
    if (hour > 23 or minute > 59) return error.InvalidTimestamp;
    t += (hour * 3600 + minute * 60) * std.time.us_per_s;
    i += 5;
    if (i < s.len and s[i] == ':') {
        if (s.len < i + 3) return error.InvalidTimestamp;
        const second = try int(s[i + 1 .. i + 3]);
        if (second > 60) return error.InvalidTimestamp;
        t += second * std.time.us_per_s;
        i += 3;
        if (i < s.len and (s[i] == '.' or s[i] == ',')) {
            i += 1;
            var scale: i64 = 100_000;
            const start = i;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
                t += @as(i64, s[i] - '0') * scale;
                scale = @divTrunc(scale, 10);
            }
            if (i == start) return error.InvalidTimestamp;
        }
    }
    if (i == s.len) return t;
    if (s[i] == 'Z' or s[i] == 'z') {
        if (i + 1 != s.len) return error.InvalidTimestamp;
        return t;
    }
    if (s[i] != '+' and s[i] != '-') return error.InvalidTimestamp;
    const rest = s[i + 1 ..];
    const offset: i64 = switch (rest.len) {
        5 => if (rest[2] != ':') return error.InvalidTimestamp else (try int(rest[0..2])) * 60 + try int(rest[3..5]),
        4 => (try int(rest[0..2])) * 60 + try int(rest[2..4]),
        2 => (try int(rest[0..2])) * 60,
        else => return error.InvalidTimestamp,
    };
    const signed = if (s[i] == '+') offset else -offset;
    return t - signed * 60 * std.time.us_per_s;
}

/// `YYYY-MM-DD` in UTC.
pub fn formatDate(t: core.Micros, buf: *[10]u8) []const u8 {
    const days = @divFloor(t, us_per_day);
    const c = civilFromDays(days);
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

fn int(s: []const u8) ParseError!i64 {
    for (s) |c| if (!std.ascii.isDigit(c)) return error.InvalidTimestamp;
    return std.fmt.parseInt(i64, s, 10) catch error.InvalidTimestamp;
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z0: i64) struct { year: i64, month: u8, day: u8 } {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(month <= 2), .month = @intCast(month), .day = @intCast(day) };
}

test "iso timestamps parse to utc micros" {
    try std.testing.expectEqual(@as(i64, 0), try parseIso("1970-01-01"));
    try std.testing.expectEqual(@as(i64, 1_795_910_400_000_000), try parseIso("2026-11-29"));
    try std.testing.expectEqual(@as(i64, 1_795_910_400_000_000 + 3_723_500_000), try parseIso("2026-11-29T01:02:03.5Z"));
    try std.testing.expectEqual(try parseIso("2026-11-29T00:00:00Z"), try parseIso("2026-11-28T16:00:00-08:00"));
    try std.testing.expectEqual(try parseIso("2026-11-29T00:00Z"), try parseIso("2026-11-29T05:30+0530"));
    try std.testing.expectError(error.InvalidTimestamp, parseIso("2026-13-01"));
    try std.testing.expectError(error.InvalidTimestamp, parseIso("yesterday"));
    try std.testing.expectError(error.InvalidTimestamp, parseIso("2026-11-29T01"));
}

test "dates format in utc" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("2026-11-29", formatDate(try parseIso("2026-11-29T23:59:59Z"), &buf));
    try std.testing.expectEqualStrings("1969-12-31", formatDate(-1, &buf));
    try std.testing.expectEqualStrings("2000-02-29", formatDate(try parseIso("2000-02-29T12:00:00Z"), &buf));
}
