const std = @import("std");
const core = @import("core");
const store = @import("mod.zig");

const Store = store.Store;
const Id = core.Id;
const Micros = core.Micros;

pub const refresh_us: Micros = 10 * std.time.us_per_s;

pub const BackfillSpend = struct {
    mutex: std.Io.Mutex = .init,
    graph_id: Id = .nil,
    day_start: Micros = 0,
    usd: f64 = 0,
    refreshed_at: ?Micros = null,

    fn holds(b: *const BackfillSpend, graph_id: Id, day_start: Micros) bool {
        return b.graph_id.eql(graph_id) and b.day_start == day_start;
    }

    fn roll(b: *BackfillSpend, graph_id: Id, day_start: Micros) void {
        if (b.holds(graph_id, day_start)) return;
        b.graph_id = graph_id;
        b.day_start = day_start;
        b.usd = 0;
        b.refreshed_at = null;
    }
};

pub fn dayStart(t: Micros) Micros {
    return @divFloor(t, std.time.us_per_day) * std.time.us_per_day;
}

pub fn spent(s: *Store, graph_id: Id, now: Micros) !f64 {
    const b = &s.backfill_spend;
    const day = dayStart(now);

    {
        b.mutex.lockUncancelable(s.io);
        defer b.mutex.unlock(s.io);
        b.roll(graph_id, day);
        if (b.refreshed_at) |at| if (now - at < refresh_us) return b.usd;
        b.refreshed_at = now;
    }

    const usd = sumSince(s, graph_id, day) catch |err| {
        b.mutex.lockUncancelable(s.io);
        defer b.mutex.unlock(s.io);
        if (b.holds(graph_id, day)) b.refreshed_at = null;
        return err;
    };

    b.mutex.lockUncancelable(s.io);
    defer b.mutex.unlock(s.io);
    if (b.holds(graph_id, day)) b.usd = usd;
    return usd;
}

pub fn add(s: *Store, graph_id: Id, usd: f64, started_at: Micros) void {
    const b = &s.backfill_spend;
    b.mutex.lockUncancelable(s.io);
    defer b.mutex.unlock(s.io);
    if (b.holds(graph_id, dayStart(started_at))) b.usd += usd;
}

fn sumSince(s: *Store, graph_id: Id, since: Micros) !f64 {
    var row = (try s.pool.row(
        \\SELECT COALESCE(sum(c.cost_usd), 0)::float8
        \\FROM llm_call c JOIN entry b ON b.id = c.entry_id
        \\WHERE c.graph_id = $1 AND c.started_at >= $2 AND b.backfill
    , .{ @as([]const u8, &graph_id.bytes), since })).?;
    defer row.deinit() catch {};
    return row.get(f64, 0);
}
