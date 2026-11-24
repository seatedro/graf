const std = @import("std");
const core = @import("core");
const Io = std.Io;

pub const RouteKey = enum {
    @"openai-responses",
    @"anthropic-messages",
    @"openai-chat",
    embeddings,
    @"typed-decisions",

    pub fn of(route: core.config.Route) RouteKey {
        return switch (route) {
            inline else => |r| @field(RouteKey, @tagName(r)),
        };
    }
};

pub const Priority = enum { interactive, background };

pub const HaltReason = enum { auth, quota };

pub const Options = struct {
    max_inflight: u32 = 8,
    daily_usd: f64 = 100.0,
    monthly_usd: f64 = 1500.0,
    routes: std.EnumArray(RouteKey, RouteLimit) = .initFill(.{}),
    spend_refresh_ms: u64 = 30_000,

    pub fn fromConfig(cfg: *const core.Config) Options {
        var opts: Options = .{
            .max_inflight = @max(cfg.limits.max_inflight, 1),
            .daily_usd = cfg.limits.daily_usd,
            .monthly_usd = cfg.limits.monthly_usd,
        };
        opts.routes.set(.of(cfg.llm.route), .from(cfg.llm.rpm, cfg.llm.input_tpm));
        opts.routes.set(.embeddings, .from(cfg.embed.rpm, cfg.embed.input_tpm));
        opts.routes.set(.@"typed-decisions", .from(cfg.decision.rpm, cfg.decision.input_tpm));
        return opts;
    }
};

pub const RouteLimit = struct {
    rpm: ?u32 = null,
    input_tpm: ?u32 = null,

    fn from(rpm: u32, input_tpm: u32) RouteLimit {
        return .{ .rpm = if (rpm == 0) null else rpm, .input_tpm = if (input_tpm == 0) null else input_tpm };
    }
};

pub const Denied = error{
    RouteHalted,
    SpendCapReached,
};

pub const Admit = union(enum) {
    granted,
    wait_ms: u64,
    wait_release,
    denied: Denied,
};

const Bucket = struct {
    tokens: f64 = 0,
    last_ms: u64 = 0,
    primed: bool = false,

    fn take(b: *Bucket, per_minute: u32, need: f64, now_ms: u64, commit: bool) ?u64 {
        const cap: f64 = @floatFromInt(per_minute);
        if (!b.primed) {
            b.* = .{ .tokens = cap, .last_ms = now_ms, .primed = true };
        } else if (now_ms > b.last_ms) {
            b.tokens = @min(cap, b.tokens + @as(f64, @floatFromInt(now_ms - b.last_ms)) * cap / 60_000.0);
            b.last_ms = now_ms;
        }
        const want = @min(need, cap);
        if (b.tokens >= want) {
            if (commit) b.tokens -= want;
            return null;
        }
        return @intFromFloat(@ceil((want - b.tokens) * 60_000.0 / cap));
    }
};

const RouteState = struct {
    requests: Bucket = .{},
    input: Bucket = .{},
    cooldown_until_ms: u64 = 0,
    halted: ?HaltReason = null,
};

const Spend = struct {
    day_start_us: i64 = 0,
    month_start_us: i64 = 0,
    day_usd: f64 = 0,
    month_usd: f64 = 0,
    refreshed_ms: ?u64 = null,
};

pub const Limiter = struct {
    opts: Options,
    ledger: ?core.LlmLedger,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    inflight: u32 = 0,
    interactive_waiting: u32 = 0,
    routes: std.EnumArray(RouteKey, RouteState) = .initFill(.{}),
    spend: Spend = .{},

    pub fn init(opts: Options, ledger: ?core.LlmLedger) Limiter {
        return .{ .opts = opts, .ledger = ledger };
    }

    pub fn tryAdmit(l: *Limiter, now_ms: u64, route: RouteKey, priority: Priority, input_tokens: u32) Admit {
        const r = l.routes.getPtr(route);
        if (r.halted != null) return .{ .denied = error.RouteHalted };
        if (priority == .background) {
            if (l.spend.day_usd >= l.opts.daily_usd or l.spend.month_usd >= l.opts.monthly_usd)
                return .{ .denied = error.SpendCapReached };
            if (l.interactive_waiting > 0) return .wait_release;
        }
        if (now_ms < r.cooldown_until_ms) return .{ .wait_ms = r.cooldown_until_ms - now_ms };
        if (l.inflight >= l.opts.max_inflight) return .wait_release;
        const limit = l.opts.routes.get(route);
        var wait: u64 = 0;
        if (limit.rpm) |rpm| if (r.requests.take(rpm, 1, now_ms, false)) |w| {
            wait = @max(wait, w);
        };
        if (limit.input_tpm) |tpm| if (r.input.take(tpm, @floatFromInt(input_tokens), now_ms, false)) |w| {
            wait = @max(wait, w);
        };
        if (wait > 0) return .{ .wait_ms = wait };
        if (limit.rpm) |rpm| _ = r.requests.take(rpm, 1, now_ms, true);
        if (limit.input_tpm) |tpm| _ = r.input.take(tpm, @floatFromInt(input_tokens), now_ms, true);
        l.inflight += 1;
        return .granted;
    }

    pub fn acquire(l: *Limiter, io: Io, route: RouteKey, priority: Priority, input_tokens: u32) (Denied || Io.Cancelable)!void {
        l.refreshSpend(io);
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        if (priority == .interactive) l.interactive_waiting += 1;
        defer if (priority == .interactive) {
            l.interactive_waiting -= 1;
            l.cond.broadcast(io);
        };
        while (true) {
            switch (l.tryAdmit(nowMs(io), route, priority, input_tokens)) {
                .granted => return,
                .denied => |err| return err,
                .wait_release => try l.cond.wait(io, &l.mutex),
                .wait_ms => |ms| l.cond.waitTimeout(io, &l.mutex, .{ .duration = .{
                    .raw = .fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i32)))),
                    .clock = .awake,
                } }) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => |e| return e,
                },
            }
        }
    }

    pub fn release(l: *Limiter, io: Io) void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        l.inflight -= 1;
        l.cond.broadcast(io);
    }

    pub fn cooldown(l: *Limiter, io: Io, route: RouteKey, until_ms: u64) void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        const r = l.routes.getPtr(route);
        r.cooldown_until_ms = @max(r.cooldown_until_ms, until_ms);
    }

    pub fn halt(l: *Limiter, io: Io, route: RouteKey, reason: HaltReason) void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        l.routes.getPtr(route).halted = reason;
        l.cond.broadcast(io);
    }

    pub fn resumeRoute(l: *Limiter, io: Io, route: ?RouteKey) void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        if (route) |r| {
            l.routes.getPtr(r).halted = null;
        } else for (&l.routes.values) |*r| {
            r.halted = null;
        }
        l.cond.broadcast(io);
    }

    pub fn haltedReason(l: *Limiter, io: Io, route: RouteKey) ?HaltReason {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        return l.routes.getPtr(route).halted;
    }

    pub fn addSpend(l: *Limiter, io: Io, usd: f64) void {
        if (usd <= 0) return;
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        l.rollSpendPeriods(nowUs(io));
        l.spend.day_usd += usd;
        l.spend.month_usd += usd;
    }

    pub const SpendTotals = struct { day_usd: f64, month_usd: f64 };

    pub fn spent(l: *Limiter, io: Io) SpendTotals {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        return .{ .day_usd = l.spend.day_usd, .month_usd = l.spend.month_usd };
    }

    fn refreshSpend(l: *Limiter, io: Io) void {
        const ledger = l.ledger orelse return l.rollSpendPeriodsLocked(io);
        const now_ms = nowMs(io);
        const now_us = nowUs(io);
        {
            l.mutex.lockUncancelable(io);
            defer l.mutex.unlock(io);
            l.rollSpendPeriods(now_us);
            if (l.spend.refreshed_ms) |at| if (now_ms -| at < l.opts.spend_refresh_ms) return;
        }
        const periods = periodStarts(now_us);
        const day = ledger.spentSince(periods.day) catch return;
        const month = ledger.spentSince(periods.month) catch return;
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        l.spend = .{
            .day_start_us = periods.day,
            .month_start_us = periods.month,
            .day_usd = day,
            .month_usd = month,
            .refreshed_ms = now_ms,
        };
    }

    fn rollSpendPeriodsLocked(l: *Limiter, io: Io) void {
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        l.rollSpendPeriods(nowUs(io));
    }

    fn rollSpendPeriods(l: *Limiter, now_us: i64) void {
        const p = periodStarts(now_us);
        if (p.day != l.spend.day_start_us) {
            l.spend.day_start_us = p.day;
            l.spend.day_usd = 0;
            l.spend.refreshed_ms = null;
        }
        if (p.month != l.spend.month_start_us) {
            l.spend.month_start_us = p.month;
            l.spend.month_usd = 0;
            l.spend.refreshed_ms = null;
        }
    }
};

pub fn periodStarts(now_us: i64) struct { day: i64, month: i64 } {
    const us_per_day: i64 = 86_400 * std.time.us_per_s;
    const day_index = @divFloor(now_us, us_per_day);
    const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(day_index) };
    const into_month = epoch_day.calculateYearDay().calculateMonthDay().day_index;
    return .{ .day = day_index * us_per_day, .month = (day_index - into_month) * us_per_day };
}

pub fn nowMs(io: Io) u64 {
    return @intCast(@max(0, Io.Clock.awake.now(io).toMilliseconds()));
}

fn nowUs(io: Io) i64 {
    return Io.Clock.real.now(io).toMicroseconds();
}

const testing = std.testing;

test "in-flight cap and release" {
    var l = Limiter.init(.{ .max_inflight = 2 }, null);
    try testing.expect(l.tryAdmit(0, .embeddings, .background, 0) == .granted);
    try testing.expect(l.tryAdmit(0, .@"openai-responses", .background, 0) == .granted);
    try testing.expect(l.tryAdmit(0, .embeddings, .background, 0) == .wait_release);
    l.release(testing.io);
    try testing.expect(l.tryAdmit(0, .embeddings, .background, 0) == .granted);
}

test "per-route request and input-token buckets" {
    var opts: Options = .{ .max_inflight = 100 };
    opts.routes.set(.@"openai-responses", .{ .rpm = 2, .input_tpm = 1000 });
    var l = Limiter.init(opts, null);
    try testing.expect(l.tryAdmit(0, .@"openai-responses", .background, 400) == .granted);
    try testing.expect(l.tryAdmit(0, .@"openai-responses", .background, 400) == .granted);
    const a = l.tryAdmit(0, .@"openai-responses", .background, 100);
    try testing.expectEqual(@as(u64, 30_000), a.wait_ms);
    try testing.expect(l.tryAdmit(0, .embeddings, .background, 100) == .granted);
    try testing.expect(l.tryAdmit(30_000, .@"openai-responses", .background, 100) == .granted);
    var m_opts: Options = .{};
    m_opts.routes.set(.embeddings, .{ .input_tpm = 1000 });
    var m = Limiter.init(m_opts, null);
    try testing.expect(m.tryAdmit(0, .embeddings, .background, 5000) == .granted);
    try testing.expectEqual(@as(u64, 60_000), m.tryAdmit(0, .embeddings, .background, 5000).wait_ms);
}

test "a cooldown holds every caller of that route only" {
    var l = Limiter.init(.{}, null);
    l.cooldown(testing.io, .@"anthropic-messages", 5_000);
    try testing.expectEqual(@as(u64, 4_000), l.tryAdmit(1_000, .@"anthropic-messages", .interactive, 0).wait_ms);
    try testing.expect(l.tryAdmit(1_000, .embeddings, .background, 0) == .granted);
    try testing.expect(l.tryAdmit(5_000, .@"anthropic-messages", .background, 0) == .granted);
}

test "interactive callers go first and pass the spend cap" {
    var l = Limiter.init(.{ .daily_usd = 1.0 }, null);
    l.interactive_waiting = 1;
    try testing.expect(l.tryAdmit(0, .embeddings, .background, 0) == .wait_release);
    try testing.expect(l.tryAdmit(0, .embeddings, .interactive, 0) == .granted);
    l.interactive_waiting = 0;
    l.addSpend(testing.io, 1.5);
    try testing.expectEqual(Admit{ .denied = error.SpendCapReached }, l.tryAdmit(0, .embeddings, .background, 0));
    try testing.expect(l.tryAdmit(0, .embeddings, .interactive, 0) == .granted);
}

test "a halted route refuses until resumed" {
    var l = Limiter.init(.{}, null);
    l.halt(testing.io, .@"openai-responses", .auth);
    try testing.expectEqual(Admit{ .denied = error.RouteHalted }, l.tryAdmit(0, .@"openai-responses", .interactive, 0));
    try testing.expectError(error.RouteHalted, l.acquire(testing.io, .@"openai-responses", .background, 0));
    try testing.expectEqual(@as(?HaltReason, .auth), l.haltedReason(testing.io, .@"openai-responses"));
    l.resumeRoute(testing.io, null);
    try l.acquire(testing.io, .@"openai-responses", .background, 0);
    l.release(testing.io);
}

const FakeLedger = struct {
    day: f64,
    month: f64,
    reads: u32 = 0,

    fn ledger(f: *FakeLedger) core.LlmLedger {
        return .{ .ptr = f, .vtable = &.{ .record = record, .spentSince = spentSince } };
    }
    fn record(_: *anyopaque, _: *const core.LlmCall) anyerror!void {}
    fn spentSince(ptr: *anyopaque, since: core.Micros) anyerror!f64 {
        const f: *FakeLedger = @ptrCast(@alignCast(ptr));
        f.reads += 1;
        const p = periodStarts(Io.Clock.real.now(testing.io).toMicroseconds());
        return if (since == p.day) f.day else f.month;
    }
};

test "the monthly cap from the ledger pauses background work" {
    var fake: FakeLedger = .{ .day = 3.0, .month = 1500.0 };
    var l = Limiter.init(.{}, fake.ledger());
    try testing.expectError(error.SpendCapReached, l.acquire(testing.io, .@"openai-responses", .background, 0));
    try testing.expectEqual(@as(f64, 3.0), l.spent(testing.io).day_usd);
    try l.acquire(testing.io, .@"openai-responses", .interactive, 0);
    l.release(testing.io);
    try testing.expectEqual(@as(u32, 2), fake.reads);
}

test "UTC period starts" {
    const t = (classifyDays(2026, 11, 23) * 86_400 + 3_600) * std.time.us_per_s;
    const p = periodStarts(t);
    try testing.expectEqual(classifyDays(2026, 11, 23) * 86_400 * std.time.us_per_s, p.day);
    try testing.expectEqual(classifyDays(2026, 11, 1) * 86_400 * std.time.us_per_s, p.month);
}

fn classifyDays(y: i64, m: i64, d: i64) i64 {
    return @import("classify.zig").daysFromCivil(y, m, d);
}

test "route limits come from each endpoint's config section" {
    var cfg: core.Config = .{};
    cfg.llm.route = .@"anthropic-messages";
    cfg.llm.rpm = 60;
    cfg.llm.input_tpm = 90_000;
    cfg.embed.rpm = 3000;
    cfg.decision.input_tpm = 5000;
    const o = Options.fromConfig(&cfg);
    try testing.expectEqual(RouteLimit{ .rpm = 60, .input_tpm = 90_000 }, o.routes.get(.@"anthropic-messages"));
    try testing.expectEqual(RouteLimit{}, o.routes.get(.@"openai-responses"));
    try testing.expectEqual(RouteLimit{ .rpm = 3000 }, o.routes.get(.embeddings));
    try testing.expectEqual(RouteLimit{ .input_tpm = 5000 }, o.routes.get(.@"typed-decisions"));
}
