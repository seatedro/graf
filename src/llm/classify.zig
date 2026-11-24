const std = @import("std");

pub const ErrorClass = enum {
    network_not_sent,
    timeout,
    network_dropped,
    http_5xx,
    overloaded_529,
    rate_limited_429,
    context_overflow,
    auth_401_403,
    quota_exhausted,
    invalid_request_400,
    invalid_output,
};

pub const DeliveryCertainty = enum { not_sent, possibly_sent };

pub fn fromStatus(status: u16, body: []const u8) ErrorClass {
    return switch (status) {
        401, 403 => .auth_401_403,
        402 => .quota_exhausted,
        408 => .timeout,
        413 => .context_overflow,
        429 => if (namesQuota(body)) .quota_exhausted else .rate_limited_429,
        529 => .overloaded_529,
        500...528, 530...599 => if (status == 503 and containsIgnoreCase(body, "overloaded")) .overloaded_529 else .http_5xx,
        else => if (isContextOverflow(body))
            .context_overflow
        else if (namesQuota(body))
            .quota_exhausted
        else
            .invalid_request_400,
    };
}

pub fn namesQuota(body: []const u8) bool {
    inline for (.{ "insufficient_quota", "credit balance is too low", "billing_hard_limit" }) |needle| {
        if (containsIgnoreCase(body, needle)) return true;
    }
    return false;
}

pub fn isContextOverflow(body: []const u8) bool {
    inline for (.{
        "context_length_exceeded",
        "exceeds the context window",
        "exceeded the context window",
        "maximum context length",
        "maximum prompt length",
        "input is too long",
        "prompt is too long",
        "too many input tokens",
        "request_too_large",
    }) |needle| {
        if (containsIgnoreCase(body, needle)) return true;
    }
    return false;
}

pub fn isConnectivityFailure(err: anyerror) bool {
    return err == error.UnknownHostName or
        err == error.NameServerFailure or
        err == error.TemporaryNameServerFailure or
        err == error.NoAddressReturned or
        err == error.ResolvConfParseFailed or
        err == error.DetectingNetworkConfigurationFailed or
        err == error.AddressUnavailable or
        err == error.ConnectionRefused or
        err == error.ConnectionTimedOut or
        err == error.HostUnreachable or
        err == error.NetworkUnreachable or
        err == error.NetworkDown or
        err == error.TlsInitializationFailed or
        err == error.CertificateBundleLoadFailure;
}

pub const TransportClass = struct { class: ErrorClass, certainty: DeliveryCertainty };

pub fn fromTransport(err: anyerror, sent: bool, timed_out: bool) TransportClass {
    const certainty: DeliveryCertainty = if (sent) .possibly_sent else .not_sent;
    if (timed_out) return .{ .class = .timeout, .certainty = certainty };
    if (!sent or isConnectivityFailure(err)) return .{ .class = .network_not_sent, .certainty = .not_sent };
    return .{ .class = .network_dropped, .certainty = .possibly_sent };
}

pub fn retryAfterMs(value: []const u8, now_unix_ms: i64) ?u32 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len == 0) return null;
    if (std.fmt.parseFloat(f64, v)) |secs| {
        if (!(secs >= 0) or secs > 86_400) return null;
        return @intFromFloat(@ceil(secs * 1000));
    } else |_| {}
    const at = parseHttpDate(v) orelse return null;
    const delta = at * 1000 - now_unix_ms;
    if (delta <= 0) return 0;
    return std.math.cast(u32, delta) orelse null;
}

pub fn retryAfterMsHeader(value: []const u8) ?u32 {
    const ms = std.fmt.parseFloat(f64, std.mem.trim(u8, value, " \t")) catch return null;
    if (!(ms >= 0) or ms > 86_400_000) return null;
    return @intFromFloat(@ceil(ms));
}

fn parseHttpDate(s: []const u8) ?i64 {
    var it = std.mem.tokenizeAny(u8, s, " ,:");
    _ = it.next() orelse return null;
    const day = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const mon_s = it.next() orelse return null;
    const year = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    const hh = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const mm = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const ss = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var month: u8 = 0;
    for (months, 1..) |m, i| {
        if (std.ascii.eqlIgnoreCase(m, mon_s)) month = @intCast(i);
    }
    if (month == 0 or day == 0 or day > 31 or year < 1970 or hh > 23 or mm > 59 or ss > 60) return null;
    return (daysFromCivil(year, month, day) * 86_400) + @as(i64, hh) * 3600 + @as(i64, mm) * 60 + ss;
}

pub fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

test "status classification" {
    try std.testing.expectEqual(ErrorClass.auth_401_403, fromStatus(401, ""));
    try std.testing.expectEqual(ErrorClass.auth_401_403, fromStatus(403, ""));
    try std.testing.expectEqual(ErrorClass.rate_limited_429, fromStatus(429, "{\"error\":{\"type\":\"rate_limit_error\"}}"));
    try std.testing.expectEqual(ErrorClass.quota_exhausted, fromStatus(429, "{\"error\":{\"code\":\"insufficient_quota\"}}"));
    try std.testing.expectEqual(ErrorClass.quota_exhausted, fromStatus(400, "Your credit balance is too low"));
    try std.testing.expectEqual(ErrorClass.overloaded_529, fromStatus(529, ""));
    try std.testing.expectEqual(ErrorClass.overloaded_529, fromStatus(503, "{\"type\":\"overloaded_error\"}"));
    try std.testing.expectEqual(ErrorClass.http_5xx, fromStatus(502, "bad gateway"));
    try std.testing.expectEqual(ErrorClass.context_overflow, fromStatus(400, "{\"error\":{\"code\":\"context_length_exceeded\"}}"));
    try std.testing.expectEqual(ErrorClass.context_overflow, fromStatus(400, "prompt is too long: 250000 tokens > 200000 maximum"));
    try std.testing.expectEqual(ErrorClass.context_overflow, fromStatus(413, ""));
    try std.testing.expectEqual(ErrorClass.invalid_request_400, fromStatus(400, "unknown model"));
    try std.testing.expectEqual(ErrorClass.invalid_request_400, fromStatus(404, "not found"));
    try std.testing.expectEqual(ErrorClass.timeout, fromStatus(408, ""));
}

test "transport classification keeps delivery certainty" {
    try std.testing.expectEqual(TransportClass{ .class = .network_not_sent, .certainty = .not_sent }, fromTransport(error.ConnectionRefused, false, false));
    try std.testing.expectEqual(TransportClass{ .class = .network_dropped, .certainty = .possibly_sent }, fromTransport(error.ReadFailed, true, false));
    try std.testing.expectEqual(TransportClass{ .class = .timeout, .certainty = .possibly_sent }, fromTransport(error.Canceled, true, true));
    try std.testing.expectEqual(TransportClass{ .class = .timeout, .certainty = .not_sent }, fromTransport(error.Canceled, false, true));
}

test "retry-after in seconds, fractions and HTTP dates" {
    try std.testing.expectEqual(@as(?u32, 7000), retryAfterMs("7", 0));
    try std.testing.expectEqual(@as(?u32, 1500), retryAfterMs("1.5", 0));
    try std.testing.expectEqual(@as(?u32, null), retryAfterMs("soon", 0));
    const now: i64 = 784_111_777 * 1000;
    try std.testing.expectEqual(@as(?u32, 0), retryAfterMs("Sun, 06 Nov 1994 08:49:37 GMT", now));
    try std.testing.expectEqual(@as(?u32, 30_000), retryAfterMs("Sun, 06 Nov 1994 08:50:07 GMT", now));
    try std.testing.expectEqual(@as(?u32, 250), retryAfterMsHeader("250"));
}
