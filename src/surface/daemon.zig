const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");
const ingest = @import("ingest");
const capture = @import("capture");
const retrieve = @import("retrieve");
const api = @import("api.zig");
const http = @import("http.zig");
const service = @import("service.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.serve);

pub const tail_interval_ms = 30_000;

pub const Runtime = struct {
    store: store.Store,
    graph_id: core.Id,
    client: llm.Client,
    backend: retrieve.LlmBackend,
    engine: retrieve.Engine,

    pub fn open(rt: *Runtime, gpa: Allocator, io: Io, config: *const core.Config, pool_size: u16) !void {
        if (config.database.url.len == 0) return error.DatabaseNotConfigured;
        rt.store = try store.Store.open(io, gpa, config.database.url, .{ .pool_size = pool_size });
        errdefer rt.store.close();
        _ = try rt.store.migrate();
        rt.graph_id = try rt.store.ensureGraph(config.graph);
        rt.client = .init(gpa, io, config, rt.store.ledger());
        rt.client.graph_id = rt.graph_id;
        rt.backend = .{ .client = &rt.client };
        rt.engine = .init(gpa, io, &rt.store, config, rt.graph_id, .{ .embedder = rt.backend.embedder(), .reranker = rt.backend.reranker() });
    }

    pub fn close(rt: *Runtime) void {
        rt.engine.deinit();
        rt.client.deinit();
        rt.store.close();
    }
};

const Tailers = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    list: std.ArrayList(capture.Tailer) = .empty,
    disabled: bool = false,

    fn init(t: *Tailers, arena: Allocator, env: *const std.process.Environ.Map, sink: core.EntrySink) !void {
        const home = env.get("HOME") orelse return;
        for (capture.default_roots) |r| {
            try t.list.append(arena, .{ .harness = r[0], .root = try std.fs.path.join(arena, &.{ home, r[1] }), .sink = sink });
        }
    }

    fn pollAll(t: *Tailers, only: ?core.Harness) void {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        if (t.disabled) return;
        var arena = std.heap.ArenaAllocator.init(t.gpa);
        defer arena.deinit();
        for (t.list.items) |*tailer| {
            if (only) |h| if (h != tailer.harness) continue;
            _ = arena.reset(.retain_capacity);
            tailer.poll(arena.allocator()) catch |err| {
                if (err == error.NotImplemented) {
                    log.warn("transcript capture is not available in this build", .{});
                    t.disabled = true;
                    return;
                }
                log.warn("tailing {s} failed: {s}", .{ @tagName(tailer.harness), @errorName(err) });
            };
        }
    }

    fn loop(t: *Tailers) Io.Cancelable!void {
        while (!t.disabled) {
            t.pollAll(null);
            try t.io.sleep(.fromMilliseconds(tail_interval_ms), .awake);
        }
    }

    fn flusher(t: *Tailers) service.Flusher {
        return .{ .ptr = t, .flushFn = flush };
    }

    fn flush(ptr: *anyopaque, req: service.FlushRequest) anyerror!void {
        const t: *Tailers = @ptrCast(@alignCast(ptr));
        if (t.disabled) return error.CaptureUnavailable;
        t.pollAll(req.harness);
    }
};

fn runWorkers(pipeline: *ingest.Pipeline, stop: *std.atomic.Value(bool)) Io.Cancelable!void {
    pipeline.runWorkers(stop) catch |err| {
        if (err == error.NotImplemented) {
            log.warn("ingestion is not available in this build; entries stay queued", .{});
        } else log.err("ingestion workers stopped: {s}", .{@errorName(err)});
    };
}

fn refreshBriefsOnCommit(rt: *Runtime) Io.Cancelable!void {
    var listener = rt.store.pool.newListener() catch |err| {
        log.warn("cannot listen for commits, briefs refresh on restart only: {s}", .{@errorName(err)});
        return;
    };
    defer listener.deinit();
    listener.listen("graf_commit", .{}) catch |err| {
        log.warn("cannot listen for commits: {s}", .{@errorName(err)});
        return;
    };
    while (listener.next()) |_| {
        try rt.engine.io.checkCancel();
        rt.engine.refreshBriefs() catch |err| log.warn("brief refresh failed: {s}", .{@errorName(err)});
    }
}

pub const Options = struct {
    version: []const u8,
    socket_path: ?[]const u8,
};

pub fn run(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, config: *const core.Config, opts: Options) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rt: Runtime = undefined;
    try rt.open(gpa, io, config, @intCast(@max(8, config.ingest.workers + 4)));
    defer rt.close();

    var tailers: Tailers = .{ .gpa = gpa, .io = io };
    const sink = rt.store.sink(rt.graph_id);
    try tailers.init(arena, env, sink);

    var svc: service.Service = .{ .gpa = gpa, .io = io, .engine = &rt.engine, .sink = sink, .flusher = tailers.flusher(), .remember_harness = .api };
    defer svc.deinit();

    if (opts.socket_path) |p| if (std.fs.path.dirname(p)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    var server: http.Server = .init(gpa, io, svc.handler(), .{
        .listen = config.serve.listen,
        .socket_path = opts.socket_path,
        .token = config.serve.token,
        .version = opts.version,
    });
    try server.start();
    defer server.deinit();

    var stop: std.atomic.Value(bool) = .init(false);
    var pipeline: ingest.Pipeline = .{ .store = &rt.store, .client = &rt.client, .config = config, .graph_id = rt.graph_id };
    var background: Io.Group = .init;
    defer {
        stop.store(true, .release);
        rt.client.cancelAll();
        background.cancel(io);
    }
    try background.concurrent(io, runWorkers, .{ &pipeline, &stop });
    try background.concurrent(io, refreshBriefsOnCommit, .{&rt});
    try background.concurrent(io, Tailers.loop, .{&tailers});

    log.info("graf serve: graph {s} on {s}{s}{s}", .{ config.graph, config.serve.listen, if (opts.socket_path != null) " and " else "", opts.socket_path orelse "" });
    try server.run();
}
