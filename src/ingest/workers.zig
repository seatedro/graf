const std = @import("std");
const core = @import("core");
const store = @import("store");
const pg = @import("pg");
const ingest = @import("mod.zig");
const pipeline = @import("pipeline.zig");
const postgres = @import("postgres.zig");
const jobs = @import("jobs.zig");

const log = std.log.scoped(.ingest);

pub const leader_lock_sql = "SELECT pg_try_advisory_lock(hashtextextended('graf:ingest-leader', 0))";
pub const idle_poll_ms = 2_000;
pub const leader_retry_ms = 5_000;
pub const housekeeping_ms = 60_000;
pub const summaries_per_pass = 5;
pub const arena_retain_bytes = 1 << 20;

const Shared = struct {
    p: *ingest.Pipeline,
    stop: *std.atomic.Value(bool),
    wake: std.atomic.Value(u32) = .init(0),
};

fn sleepUnless(io: std.Io, shared: *Shared, total_ms: i64) void {
    var waited: i64 = 0;
    while (waited < total_ms) : (waited += 100) {
        if (shared.stop.load(.acquire)) return;
        if (shared.wake.load(.acquire) > 0) {
            _ = shared.wake.fetchSub(1, .acq_rel);
            return;
        }
        io.sleep(.fromMilliseconds(100), .awake) catch return;
    }
}

pub fn tryLead(conn: *pg.Conn) !bool {
    var row = (try conn.row(leader_lock_sql, .{})) orelse return false;
    defer row.deinit() catch {};
    return row.get(bool, 0);
}

pub fn run(p: *ingest.Pipeline, stop: *std.atomic.Value(bool)) !void {
    const io = p.client.io;
    const gpa = p.store.allocator;
    const opts = p.store.pool._opts;

    var leader = try pg.Conn.open(io, gpa, opts.connect);
    defer leader.deinit();
    try leader.auth(opts.auth);

    var shared: Shared = .{ .p = p, .stop = stop };
    while (!try tryLead(&leader)) {
        if (stop.load(.acquire)) return;
        sleepUnless(io, &shared, leader_retry_ms);
        if (stop.load(.acquire)) return;
    }
    log.info("this process leads ingestion", .{});
    return lead(p, stop);
}

pub fn lead(p: *ingest.Pipeline, stop: *std.atomic.Value(bool)) !void {
    const io = p.client.io;
    const gpa = p.store.allocator;
    var shared: Shared = .{ .p = p, .stop = stop };

    var listener = try p.store.pool.newListener();
    defer listener.deinit();
    try listener.listen("graf_queue", .{});
    const listen_thread = try std.Thread.spawn(.{}, listen, .{ &listener, &shared });

    const n = @max(p.config.ingest.workers, 1);
    const threads = try gpa.alloc(std.Thread, n);
    defer gpa.free(threads);
    var started: usize = 0;
    defer {
        stop.store(true, .release);
        for (threads[0..started]) |t| t.join();
        listener.stop() catch {};
        listen_thread.join();
    }

    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, worker, .{ &shared, i });
        started += 1;
    }

    while (!stop.load(.acquire)) io.sleep(.fromMilliseconds(200), .awake) catch break;
}

fn listen(listener: *pg.Listener, shared: *Shared) void {
    while (listener.next()) |_| {
        _ = shared.wake.fetchAdd(1, .acq_rel);
    }
}

fn worker(shared: *Shared, index: usize) void {
    const p = shared.p;
    const io = p.client.io;
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "graf-worker-{d}", .{index}) catch "graf-worker";

    var backend: postgres.PgBackend = .{ .store = p.store, .graph_id = p.graph_id, .io = io, .worker = name, .backfill_daily_usd = p.config.limits.backfill_daily_usd };
    var model: postgres.ClientModel = .{ .client = p.client };
    var driver: pipeline.Driver(postgres.PgBackend, postgres.ClientModel) = .{
        .backend = &backend,
        .model = &model,
        .config = p.config,
        .graph_id = p.graph_id,
        .io = io,
    };

    var arena_state = std.heap.ArenaAllocator.init(p.store.allocator);
    defer arena_state.deinit();
    var last_housekeeping: core.Micros = 0;

    while (!shared.stop.load(.acquire)) {
        recycle(&arena_state);
        const arena = arena_state.allocator();
        const lease = backend.claim(arena) catch |err| {
            log.err("claim failed: {t}", .{err});
            sleepUnless(io, shared, idle_poll_ms);
            continue;
        };

        if (lease) |l| {
            const outcome = driver.process(arena, l) catch |err| {
                log.err("entry {f} failed: {t}", .{ l.entry_id, err });
                continue;
            };
            log.debug("entry {f}: {t}", .{ l.entry_id, outcome });
            continue;
        }

        if (index == 0) {
            const now = core.time.now(io);
            if (now - last_housekeeping >= housekeeping_ms * 1000) {
                last_housekeeping = now;
                housekeeping(arena, p, &model) catch |err| log.warn("housekeeping failed: {t}", .{err});
            }
        }

        sleepUnless(io, shared, idle_poll_ms);
    }
}

pub fn recycle(arena_state: *std.heap.ArenaAllocator) void {
    _ = arena_state.reset(.{ .retain_with_limit = arena_retain_bytes });
}

fn housekeeping(arena: std.mem.Allocator, p: *ingest.Pipeline, model: *postgres.ClientModel) !void {
    const conn = try p.store.pool.acquire();
    defer conn.release();
    _ = try jobs.runDailyPromotion(conn, p.graph_id);
    _ = try jobs.refreshSummaries(postgres.ClientModel, arena, conn, model, p.graph_id, summaries_per_pass);
}
