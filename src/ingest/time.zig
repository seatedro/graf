const std = @import("std");
const core = @import("core");

pub const Micros = core.Micros;

pub const us_per_s: i64 = 1_000_000;
pub const us_per_day: i64 = 86_400 * us_per_s;

pub fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) @as(i64, m) - 3 else @as(i64, m) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: u8, day: u8 };

pub fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = if (m <= 2) y + 1 else y, .month = m, .day = d };
}

fn daysInMonth(y: i64, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 29 else 28,
        else => 0,
    };
}

fn digits(s: []const u8, comptime n: usize) ?u32 {
    if (s.len < n) return null;
    var v: u32 = 0;
    for (s[0..n]) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

pub const ParseError = error{InvalidTimestamp};

pub fn parse(s_in: []const u8) ParseError!Micros {
    const s = std.mem.trim(u8, s_in, " \t");
    const year = digits(s, 4) orelse return error.InvalidTimestamp;
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return error.InvalidTimestamp;
    const month: u8 = @intCast(digits(s[5..], 2) orelse return error.InvalidTimestamp);
    const day: u8 = @intCast(digits(s[8..], 2) orelse return error.InvalidTimestamp);
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return error.InvalidTimestamp;
    var t = daysFromCivil(year, month, day) * us_per_day;
    if (s.len == 10) return t;

    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return error.InvalidTimestamp;
    if (s.len < 19 or s[13] != ':' or s[16] != ':') return error.InvalidTimestamp;
    const hh = digits(s[11..], 2) orelse return error.InvalidTimestamp;
    const mm = digits(s[14..], 2) orelse return error.InvalidTimestamp;
    const ss = digits(s[17..], 2) orelse return error.InvalidTimestamp;
    if (hh > 23 or mm > 59 or ss > 60) return error.InvalidTimestamp;
    t += (@as(i64, hh) * 3600 + @as(i64, mm) * 60 + @min(ss, 59)) * us_per_s;

    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var frac: i64 = 0;
        var places: u8 = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            if (places < 6) {
                frac = frac * 10 + (s[i] - '0');
                places += 1;
            }
        }
        if (places == 0) return error.InvalidTimestamp;
        while (places < 6) : (places += 1) frac *= 10;
        t += frac;
    }
    if (i == s.len) return error.InvalidTimestamp;
    switch (s[i]) {
        'Z', 'z' => {
            if (i + 1 != s.len) return error.InvalidTimestamp;
        },
        '+', '-' => {
            if (s.len != i + 6 or s[i + 3] != ':') return error.InvalidTimestamp;
            const oh = digits(s[i + 1 ..], 2) orelse return error.InvalidTimestamp;
            const om = digits(s[i + 4 ..], 2) orelse return error.InvalidTimestamp;
            if (oh > 23 or om > 59) return error.InvalidTimestamp;
            const off = (@as(i64, oh) * 3600 + @as(i64, om) * 60) * us_per_s;
            t = if (s[i] == '+') t - off else t + off;
        },
        else => return error.InvalidTimestamp,
    }
    return t;
}

pub fn parseBound(s: ?[]const u8) ParseError!?Micros {
    const v = s orelse return null;
    const t = std.mem.trim(u8, v, " \t");
    if (t.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(t, "-infinity") or std.ascii.eqlIgnoreCase(t, "infinity")) return null;
    return try parse(t);
}

const weekdays = [_][]const u8{ "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" };

pub fn weekday(t: Micros) []const u8 {
    const days = @divFloor(t, us_per_day);
    return weekdays[@intCast(@mod(days, 7))];
}

pub fn format(t: Micros, buf: *[20]u8) []const u8 {
    const days = @divFloor(t, us_per_day);
    const rem = @mod(t, us_per_day);
    const c = civilFromDays(days);
    const secs: u32 = @intCast(@divFloor(rem, us_per_s));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(c.year)), c.month, c.day, secs / 3600, (secs / 60) % 60, secs % 60,
    }) catch unreachable;
}

test "rfc3339 parse and format round trip" {
    const t = try parse("2026-11-20T17:00:00Z");
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("2026-11-20T17:00:00Z", format(t, &buf));
    try std.testing.expectEqual(t, try parse("2026-11-20T18:00:00+01:00"));
    try std.testing.expectEqual(t + 500_000, try parse("2026-11-20T17:00:00.5Z"));
    try std.testing.expectEqual(try parse("2026-12-03T00:00:00Z"), try parse("2026-12-03"));
    try std.testing.expectEqualStrings("Friday", weekday(t));
    try std.testing.expectEqual(@as(Micros, 0), try parse("1970-01-01T00:00:00Z"));
}

test "rfc3339 rejects malformed input" {
    for ([_][]const u8{ "", "2026-13-01", "2026-02-30", "2026-11-20T25:00:00Z", "2026-11-20T17:00:00", "next tuesday", "2026-11-20T17:00:00+0100" }) |s| {
        try std.testing.expectError(error.InvalidTimestamp, parse(s));
    }
    try std.testing.expectEqual(@as(?Micros, null), try parseBound("-infinity"));
    try std.testing.expectEqual(@as(?Micros, null), try parseBound(null));
}
