const std = @import("std");
const core = @import("core");

fn dateMicros(year: i64, month: u32, day: u32) ?core.Micros {
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    return core.time.daysFromCivil(year, @intCast(month), @intCast(day)) * std.time.us_per_day;
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
    if (core.time.parseRfc3339(trimmed)) |t| return t else |_| {}

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
        return dateMicros(year, m, day);
    }

    if (monthNumber(words[1])) |m| {
        const day = std.fmt.parseInt(u32, words[0], 10) catch return null;
        return dateMicros(year, m, day);
    }

    return null;
}

pub fn withinOneDay(a: core.Micros, b: core.Micros) bool {
    return @abs(a - b) <= std.time.us_per_day;
}

test "loose dates accept the forms extraction produces" {
    const want = try core.time.parseRfc3339("2026-12-03");

    try std.testing.expectEqual(want, parseLooseDate("December 3, 2026").?);
    try std.testing.expectEqual(want, parseLooseDate("3 Dec 2026").?);
    try std.testing.expectEqual(want, parseLooseDate(" 2026-12-03 ").?);
    try std.testing.expect(parseLooseDate("unnest batch inserts") == null);
    try std.testing.expect(withinOneDay(want, want + std.time.us_per_day));
    try std.testing.expect(!withinOneDay(want, want + std.time.us_per_day + 1));
}
