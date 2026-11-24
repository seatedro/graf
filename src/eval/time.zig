const std = @import("std");
const core = @import("core");

pub const us_per_day: i64 = 86_400 * std.time.us_per_s;

pub const Error = error{InvalidTimestamp};

pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn digits(s: []const u8, start: usize, len: usize) Error!u32 {
    if (start + len > s.len) return error.InvalidTimestamp;
    var v: u32 = 0;
    for (s[start .. start + len]) |c| {
        if (c < '0' or c > '9') return error.InvalidTimestamp;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn dateMicros(year: i64, month: u32, day: u32) Error!core.Micros {
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidTimestamp;
    return daysFromCivil(year, @intCast(month), @intCast(day)) * us_per_day;
}

pub fn parseRfc3339(s: []const u8) Error!core.Micros {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return error.InvalidTimestamp;
    const date = try dateMicros(try digits(s, 0, 4), try digits(s, 5, 2), try digits(s, 8, 2));
    if (s.len == 10) return date;
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return error.InvalidTimestamp;
    if (s.len < 19 or s[13] != ':' or s[16] != ':') return error.InvalidTimestamp;
    const hour = try digits(s, 11, 2);
    const minute = try digits(s, 14, 2);
    const second = try digits(s, 17, 2);
    if (hour > 23 or minute > 59 or second > 60) return error.InvalidTimestamp;
    var t: core.Micros = date + (@as(i64, hour) * 3600 + @as(i64, minute) * 60 + second) * std.time.us_per_s;
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var frac: i64 = 0;
        var scale: i64 = 100_000;
        const start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            frac += @as(i64, s[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
        if (i == start) return error.InvalidTimestamp;
        t += frac;
    }
    if (i >= s.len) return error.InvalidTimestamp;
    switch (s[i]) {
        'Z', 'z' => if (i + 1 != s.len) return error.InvalidTimestamp,
        '+', '-' => {
            if (i + 6 != s.len or s[i + 3] != ':') return error.InvalidTimestamp;
            const off = (@as(i64, try digits(s, i + 1, 2)) * 60 + try digits(s, i + 4, 2)) * 60 * std.time.us_per_s;
            t = if (s[i] == '+') t - off else t + off;
        },
        else => return error.InvalidTimestamp,
    }
    return t;
}

const month_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };

fn monthNumber(word: []const u8) ?u32 {
    if (word.len < 3) return null;
    for (month_names, 1..) |m, n| {
        if (std.ascii.eqlIgnoreCase(word[0..3], m)) return @intCast(n);
    }
    return null;
}

pub fn parseLooseDate(s: []const u8) ?core.Micros {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (parseRfc3339(trimmed)) |t| return t else |_| {}
    var words: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " ,");
    while (it.next()) |w| {
        if (n == 3) return null;
        words[n] = w;
        n += 1;
    }
    if (n != 3) return null;
    const year = std.fmt.parseInt(i64, words[2], 10) catch return null;
    if (monthNumber(words[0])) |m| {
        const day = std.fmt.parseInt(u32, words[1], 10) catch return null;
        return dateMicros(year, m, day) catch null;
    }
    if (monthNumber(words[1])) |m| {
        const day = std.fmt.parseInt(u32, words[0], 10) catch return null;
        return dateMicros(year, m, day) catch null;
    }
    return null;
}

pub fn withinOneDay(a: core.Micros, b: core.Micros) bool {
    return @abs(a - b) <= us_per_day;
}

test "rfc3339 parsing" {
    try std.testing.expectEqual(@as(core.Micros, 0), try parseRfc3339("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(core.Micros, 1_795_194_000_000_000), try parseRfc3339("2026-11-20T17:00:00Z"));
    try std.testing.expectEqual(try parseRfc3339("2026-11-20T17:00:00Z"), try parseRfc3339("2026-11-20T19:00:00+02:00"));
    try std.testing.expectEqual(@as(core.Micros, 500_000), try parseRfc3339("1970-01-01T00:00:00.5Z"));
    try std.testing.expectEqual(try parseRfc3339("2026-12-03T00:00:00Z"), try parseRfc3339("2026-12-03"));
    try std.testing.expectError(error.InvalidTimestamp, parseRfc3339("2026-11-20 17:00"));
    try std.testing.expectError(error.InvalidTimestamp, parseRfc3339("yesterday"));
}

test "loose dates accept the forms extraction produces" {
    const want = try parseRfc3339("2026-12-03");
    try std.testing.expectEqual(want, parseLooseDate("December 3, 2026").?);
    try std.testing.expectEqual(want, parseLooseDate("3 Dec 2026").?);
    try std.testing.expectEqual(want, parseLooseDate(" 2026-12-03 ").?);
    try std.testing.expect(parseLooseDate("unnest batch inserts") == null);
    try std.testing.expect(withinOneDay(want, want + us_per_day));
    try std.testing.expect(!withinOneDay(want, want + us_per_day + 1));
}
