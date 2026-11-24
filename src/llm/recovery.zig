const std = @import("std");
const ErrorClass = @import("classify.zig").ErrorClass;

pub const Disposition = enum {
    requeue,
    split,
    pause_route,
    dead,
};

pub const Phase = enum { original, repair };

pub const Policy = struct {
    transient_backoff_ms: []const u32 = &.{ 1000, 2000, 4000 },
    rate_limit_backoff_ms: []const u32 = &.{ 2000, 4000, 8000, 16000 },
    jitter_permille: u16 = 200,
    max_retry_after_ms: u32 = 60_000,
};

pub const State = struct {
    policy: Policy = .{},
    phase: Phase = .original,
    sends: u16 = 0,
    transient: u8 = 0,
    rate_limited: u8 = 0,
    rng: u64,

    pub fn init(seed: u64) State {
        return .{ .rng = seed | 1 };
    }
};

pub const Event = union(enum) {
    start,
    succeeded,
    failed: struct { class: ErrorClass, retry_after_ms: ?u32 = null },
    invalid_output,
};

pub const Action = union(enum) {
    send: struct {
        at_ms: u64,
        phase: Phase,
        cooldown_until_ms: ?u64 = null,
    },
    done,
    give_up: struct { disposition: Disposition, class: ErrorClass },
};

pub fn step(s: *State, event: Event, now_ms: u64) Action {
    switch (event) {
        .start => return sendAt(s, now_ms, null),
        .succeeded => return .done,
        .invalid_output => {
            if (s.phase == .repair) return giveUp(.dead, .invalid_output);
            s.phase = .repair;
            return sendAt(s, now_ms, null);
        },
        .failed => |f| switch (f.class) {
            .network_not_sent, .network_dropped, .timeout, .http_5xx, .overloaded_529 => {
                if (s.transient >= s.policy.transient_backoff_ms.len) return giveUp(.requeue, f.class);
                const base = s.policy.transient_backoff_ms[s.transient];
                s.transient += 1;
                const at = now_ms + base + jitter(s, base);
                return sendAt(s, at, if (f.class == .overloaded_529) at else null);
            },
            .rate_limited_429 => {
                if (s.rate_limited >= s.policy.rate_limit_backoff_ms.len) return giveUp(.requeue, f.class);
                const wait: u64 = f.retry_after_ms orelse s.policy.rate_limit_backoff_ms[s.rate_limited];
                if (wait > s.policy.max_retry_after_ms) return giveUp(.requeue, f.class);
                s.rate_limited += 1;
                return sendAt(s, now_ms + wait, now_ms + wait);
            },
            .context_overflow => return giveUp(.split, f.class),
            .auth_401_403, .quota_exhausted => return giveUp(.pause_route, f.class),
            .invalid_request_400, .invalid_output => return giveUp(.dead, f.class),
        },
    }
}

fn giveUp(d: Disposition, class: ErrorClass) Action {
    return .{ .give_up = .{ .disposition = d, .class = class } };
}

fn sendAt(s: *State, at_ms: u64, cooldown: ?u64) Action {
    s.sends += 1;
    return .{ .send = .{ .at_ms = at_ms, .phase = s.phase, .cooldown_until_ms = cooldown } };
}

fn jitter(s: *State, base: u32) u64 {
    s.rng ^= s.rng << 13;
    s.rng ^= s.rng >> 7;
    s.rng ^= s.rng << 17;
    const span = @as(u64, base) * s.policy.jitter_permille / 1000;
    return if (span == 0) 0 else s.rng % (span + 1);
}

const testing = std.testing;

fn expectSend(a: Action, min_at: u64, max_at: u64, phase: Phase, cooldown: bool) !void {
    try testing.expect(a == .send);
    try testing.expect(a.send.at_ms >= min_at and a.send.at_ms <= max_at);
    try testing.expectEqual(phase, a.send.phase);
    try testing.expectEqual(cooldown, a.send.cooldown_until_ms != null);
}

fn expectGiveUp(a: Action, d: Disposition, class: ErrorClass) !void {
    try testing.expect(a == .give_up);
    try testing.expectEqual(d, a.give_up.disposition);
    try testing.expectEqual(class, a.give_up.class);
}

test "transient classes retry three times with 1, 2, 4 s plus at most 20% jitter, then requeue" {
    const rows = [_]ErrorClass{ .network_not_sent, .network_dropped, .timeout, .http_5xx, .overloaded_529 };
    for (rows) |class| {
        var s = State.init(42);
        try expectSend(step(&s, .start, 0), 0, 0, .original, false);
        const cool = class == .overloaded_529;
        try expectSend(step(&s, .{ .failed = .{ .class = class } }, 100), 1100, 1300, .original, cool);
        try expectSend(step(&s, .{ .failed = .{ .class = class } }, 5000), 7000, 7400, .original, cool);
        try expectSend(step(&s, .{ .failed = .{ .class = class } }, 9000), 13000, 13800, .original, cool);
        try expectGiveUp(step(&s, .{ .failed = .{ .class = class } }, 20000), .requeue, class);
        try testing.expectEqual(@as(u16, 4), s.sends);
    }
}

test "rate limits honour Retry-After, else back off 2, 4, 8, 16 s, always cooling the route" {
    var s = State.init(7);
    _ = step(&s, .start, 0);
    var a = step(&s, .{ .failed = .{ .class = .rate_limited_429, .retry_after_ms = 3500 } }, 1000);
    try expectSend(a, 4500, 4500, .original, true);
    try testing.expectEqual(@as(?u64, 4500), a.send.cooldown_until_ms);
    a = step(&s, .{ .failed = .{ .class = .rate_limited_429 } }, 10_000);
    try expectSend(a, 14_000, 14_000, .original, true);
    try expectSend(step(&s, .{ .failed = .{ .class = .rate_limited_429 } }, 20_000), 28_000, 28_000, .original, true);
    try expectSend(step(&s, .{ .failed = .{ .class = .rate_limited_429 } }, 30_000), 46_000, 46_000, .original, true);
    try expectGiveUp(step(&s, .{ .failed = .{ .class = .rate_limited_429 } }, 50_000), .requeue, .rate_limited_429);
}

test "a Retry-After past the cap requeues instead of holding the worker" {
    var s = State.init(7);
    _ = step(&s, .start, 0);
    try expectGiveUp(step(&s, .{ .failed = .{ .class = .rate_limited_429, .retry_after_ms = 600_000 } }, 0), .requeue, .rate_limited_429);
}

test "context overflow never retries larger: split" {
    var s = State.init(1);
    _ = step(&s, .start, 0);
    try expectGiveUp(step(&s, .{ .failed = .{ .class = .context_overflow } }, 0), .split, .context_overflow);
    try testing.expectEqual(@as(u16, 1), s.sends);
}

test "auth and quota never retry: pause the route" {
    for ([_]ErrorClass{ .auth_401_403, .quota_exhausted }) |class| {
        var s = State.init(1);
        _ = step(&s, .start, 0);
        try expectGiveUp(step(&s, .{ .failed = .{ .class = class } }, 0), .pause_route, class);
    }
}

test "invalid requests never retry: dead" {
    var s = State.init(1);
    _ = step(&s, .start, 0);
    try expectGiveUp(step(&s, .{ .failed = .{ .class = .invalid_request_400 } }, 0), .dead, .invalid_request_400);
}

test "one repair, then dead; transport retries still apply to the repair request" {
    var s = State.init(9);
    _ = step(&s, .start, 0);
    try expectSend(step(&s, .invalid_output, 10), 10, 10, .repair, false);
    try expectSend(step(&s, .{ .failed = .{ .class = .http_5xx } }, 20), 1020, 1220, .repair, false);
    try expectGiveUp(step(&s, .invalid_output, 2000), .dead, .invalid_output);
}

test "success ends the call" {
    var s = State.init(3);
    _ = step(&s, .start, 0);
    try testing.expect(step(&s, .succeeded, 5) == .done);
}

test "jitter is reproducible from the seed" {
    var a = State.init(1234);
    var b = State.init(1234);
    _ = step(&a, .start, 0);
    _ = step(&b, .start, 0);
    try testing.expectEqual(step(&a, .{ .failed = .{ .class = .timeout } }, 0).send.at_ms, step(&b, .{ .failed = .{ .class = .timeout } }, 0).send.at_ms);
}
