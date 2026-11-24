const std = @import("std");
const Micros = @import("types.zig").Micros;

pub const ParseError = error{InvalidTimestamp};

pub fn now(io: std.Io) Micros {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_us));
}

pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) @as(i64, month) - 3 else @as(i64, month) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: u8, day: u8 };

pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
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

pub fn parseRfc3339(s_in: []const u8) ParseError!Micros {
    const s = std.mem.trim(u8, s_in, " \t");
    var t = try date(s);
    if (s.len == 10) return t;
    if (!isTimeSeparator(s[10]) or s.len < 19 or s[13] != ':' or s[16] != ':') return error.InvalidTimestamp;
    t += try clock(s[11..13], s[14..16], s[17..19]);
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        t += try fraction(s, &i);
    }
    if (i == s.len) return error.InvalidTimestamp;
    switch (s[i]) {
        'Z', 'z' => if (i + 1 != s.len) return error.InvalidTimestamp,
        '+', '-' => {
            if (s.len != i + 6 or s[i + 3] != ':') return error.InvalidTimestamp;
            t = try applyOffset(t, s[i], s[i + 1 .. i + 3], s[i + 4 .. i + 6]);
        },
        else => return error.InvalidTimestamp,
    }
    return t;
}

pub fn parseIso(s: []const u8) ParseError!Micros {
    var t = try date(s);
    if (s.len == 10) return t;
    if (!isTimeSeparator(s[10]) or s.len < 16 or s[13] != ':') return error.InvalidTimestamp;
    t += try clock(s[11..13], s[14..16], "00");
    var i: usize = 16;
    if (i < s.len and s[i] == ':') {
        if (s.len < i + 3) return error.InvalidTimestamp;
        t += try clock("00", "00", s[i + 1 .. i + 3]);
        i += 3;
        if (i < s.len and (s[i] == '.' or s[i] == ',')) {
            i += 1;
            t += try fraction(s, &i);
        }
    }
    if (i == s.len) return t;
    switch (s[i]) {
        'Z', 'z' => return if (i + 1 == s.len) t else error.InvalidTimestamp,
        '+', '-' => {
            const rest = s[i + 1 ..];
            return switch (rest.len) {
                5 => if (rest[2] != ':') error.InvalidTimestamp else applyOffset(t, s[i], rest[0..2], rest[3..5]),
                4 => applyOffset(t, s[i], rest[0..2], rest[2..4]),
                2 => applyOffset(t, s[i], rest[0..2], "00"),
                else => error.InvalidTimestamp,
            };
        },
        else => return error.InvalidTimestamp,
    }
}

fn isTimeSeparator(c: u8) bool {
    return c == 'T' or c == 't' or c == ' ';
}

fn number(s: []const u8) ParseError!u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidTimestamp;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn daysInMonth(year: i64, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        else => 0,
    };
}

fn date(s: []const u8) ParseError!Micros {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return error.InvalidTimestamp;
    const year = try number(s[0..4]);
    const month = try number(s[5..7]);
    const day = try number(s[8..10]);
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, @intCast(month))) return error.InvalidTimestamp;
    return daysFromCivil(year, @intCast(month), @intCast(day)) * std.time.us_per_day;
}

fn clock(hh: []const u8, mm: []const u8, ss: []const u8) ParseError!Micros {
    const hour = try number(hh);
    const minute = try number(mm);
    const second = try number(ss);
    if (hour > 23 or minute > 59 or second > 60) return error.InvalidTimestamp;
    return (@as(i64, hour) * 3600 + @as(i64, minute) * 60 + @min(second, 59)) * std.time.us_per_s;
}

fn fraction(s: []const u8, i: *usize) ParseError!Micros {
    const start = i.*;
    var frac: i64 = 0;
    var places: u8 = 0;
    while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) {
        if (places < 6) {
            frac = frac * 10 + (s[i.*] - '0');
            places += 1;
        }
    }
    if (i.* == start) return error.InvalidTimestamp;
    while (places < 6) : (places += 1) frac *= 10;
    return frac;
}

fn applyOffset(t: Micros, sign: u8, hh: []const u8, mm: []const u8) ParseError!Micros {
    const hours = try number(hh);
    const minutes = try number(mm);
    if (hours > 23 or minutes > 59) return error.InvalidTimestamp;
    const offset = (@as(i64, hours) * 3600 + @as(i64, minutes) * 60) * std.time.us_per_s;
    return if (sign == '+') t - offset else t + offset;
}

const testing = std.testing;

test "civil dates round trip through day numbers" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    try testing.expectEqual(Civil{ .year = 2000, .month = 2, .day = 29 }, civilFromDays(daysFromCivil(2000, 2, 29)));
    try testing.expectEqual(Civil{ .year = 2026, .month = 11, .day = 20 }, civilFromDays(daysFromCivil(2026, 11, 20)));
}

test "rfc3339 timestamps parse to utc micros" {
    try testing.expectEqual(@as(Micros, 0), try parseRfc3339("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(Micros, 1_795_194_000_000_000), try parseRfc3339("2026-11-20T17:00:00Z"));
    try testing.expectEqual(try parseRfc3339("2026-11-20T17:00:00Z"), try parseRfc3339("2026-11-20T19:00:00+02:00"));
    try testing.expectEqual(try parseRfc3339("2026-11-20T17:00:00Z"), try parseRfc3339("2026-11-20T18:00:00+01:00"));
    try testing.expectEqual(@as(Micros, 500_000), try parseRfc3339("1970-01-01T00:00:00.5Z"));
    try testing.expectEqual(try parseRfc3339("2026-12-03T00:00:00Z"), try parseRfc3339("2026-12-03"));
    try testing.expectEqual(try parseRfc3339("2026-12-03"), try parseRfc3339(" 2026-12-03 "));
}

test "rfc3339 rejects malformed input" {
    for ([_][]const u8{ "", "yesterday", "next tuesday", "2026-13-01", "2026-02-30", "2026-11-20 17:00", "2026-11-20T25:00:00Z", "2026-11-20T17:00:00", "2026-11-20T17:00:00+0100" }) |s| {
        try testing.expectError(error.InvalidTimestamp, parseRfc3339(s));
    }
}

test "iso timestamps parse to utc micros" {
    try testing.expectEqual(@as(Micros, 0), try parseIso("1970-01-01"));
    try testing.expectEqual(@as(Micros, 0), try parseIso("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(Micros, 1_795_910_400_000_000), try parseIso("2026-11-29"));
    try testing.expectEqual(@as(Micros, 1_795_910_400_000_000 + 3_723_500_000), try parseIso("2026-11-29T01:02:03.5Z"));
    try testing.expectEqual(@as(Micros, 1_763_658_000_123_000), try parseIso("2025-11-20T17:00:00.123Z"));
    try testing.expectEqual(@as(Micros, 1_763_658_000_000_000), try parseIso("2025-11-20T19:00:00+02:00"));
    try testing.expectEqual(@as(Micros, 1_763_658_000_000_000), try parseIso("2025-11-20T17:00:00"));
    try testing.expectEqual(try parseIso("2026-11-29T00:00:00Z"), try parseIso("2026-11-28T16:00:00-08:00"));
    try testing.expectEqual(try parseIso("2026-11-29T00:00Z"), try parseIso("2026-11-29T05:30+0530"));
    try testing.expectEqual(try parseIso("2026-11-29T00:00Z"), try parseIso("2026-11-29T02:00+02"));
    for ([_][]const u8{ "yesterday", "2026-13-01", "2026-02-30", "2026-11-29T01", "2026-11-29T01:02:03.Z", "2026-11-29T01:02+2" }) |s| {
        try testing.expectError(error.InvalidTimestamp, parseIso(s));
    }
}
