const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");
const ingest = @import("ingest");
const capture = @import("capture");
const retrieve = @import("retrieve");
const http = @import("http.zig");
const service = @import("service.zig");
const edge = @import("edge.zig");
const limits = @import("limits.zig");
const Upstream = @import("upstream.zig").Upstream;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.serve);

pub const Runtime = struct {
    arena: std.heap.ArenaAllocator,
    postgres: ?store.managed.Server,
    io: Io,
    store: store.Store,
    graph_id: core.Id,
    client: llm.Client,
    backend: retrieve.LlmBackend,
    engine: retrieve.Engine,

    pub const OpenOptions = struct {
        pool_size: u16,
        start_postgres: bool = false,
    };

    pub fn open(rt: *Runtime, gpa: Allocator, io: Io, env: *const std.process.Environ.Map, config: *const core.Config, opts: OpenOptions) !void {
        rt.arena = .init(gpa);
        errdefer rt.arena.deinit();
        rt.io = io;
        rt.postgres = null;
        errdefer if (rt.postgres) |*p| p.stop(io);

        const arena = rt.arena.allocator();
        const url = switch (try store.managed.plan(arena, io, env, config.database.url)) {
            .url => |u| u,
            .managed => |m| if (opts.start_postgres) blk: {
                _ = try store.managed.initCluster(gpa, io, m.toolchain, m.data_dir);
                rt.postgres = try store.managed.Server.start(gpa, io, m.toolchain, m.data_dir, arena);
                break :blk rt.postgres.?.url;
            } else try store.managed.databaseUrl(arena, m.data_dir),
            .docker => try store.managed.docker.start(arena, io),
            .unavailable => return error.DatabaseNotConfigured,
        };

        rt.store = try store.Store.open(io, gpa, url, .{ .pool_size = opts.pool_size });
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
        if (rt.postgres) |*p| p.stop(rt.io);
        rt.arena.deinit();
    }
};

fn flusher(c: *capture.Capture) service.Flusher {
    return .{ .ptr = c, .flushFn = flushCapture };
}

fn flushCapture(ptr: *anyopaque, req: service.FlushRequest) anyerror!bool {
    const c: *capture.Capture = @ptrCast(@alignCast(ptr));
    const harness = req.harness orelse return false;
    const path = req.transcript_path orelse return false;
    return c.flush(harness, path);
}

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

pub fn checkExposure(config: *const core.Config) !void {
    try httpOptions(config, .{ .socket_path = null, .version = "" }).validate();
}

fn httpOptions(config: *const core.Config, opts: Options) http.Options {
    return .{
        .listen = config.serve.listen,
        .socket_path = opts.socket_path,
        .version = opts.version,
        .token = config.serve.token,
        .tailscale_origin = config.serve.tailscale_origin,
        .tailscale_logins = config.serve.tailscale_logins,
    };
}

fn replayHookSpool(cap: *capture.Capture) void {
    const replayed = cap.replaySpool() catch |err| {
        log.warn("replaying spooled hook flushes failed: {s}", .{@errorName(err)});
        return;
    };
    if (replayed > 0) log.info("replayed {d} spooled hook flushes", .{replayed});
}

pub fn run(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, config: *const core.Config, opts: Options) !void {
    try checkExposure(config);
    limits.raiseOpenFiles();

    var rt: Runtime = undefined;
    try rt.open(gpa, io, env, config, .{ .pool_size = @intCast(@max(8, config.ingest.workers + 4)), .start_postgres = true });
    defer rt.close();

    const sink = rt.store.sink(rt.graph_id);
    var cap = try capture.Capture.init(gpa, io, env, config, sink, .{});
    defer cap.deinit();
    replayHookSpool(&cap);

    var capy_source: ?capture.capy.Source = if (config.capyEnabled()) try capture.capy.Source.init(gpa, io, env, config, sink, .{}) else null;
    defer if (capy_source) |*c| c.deinit();

    var svc: service.Service = .{ .gpa = gpa, .io = io, .engine = &rt.engine, .sink = sink, .flusher = flusher(&cap) };
    defer svc.deinit();

    if (opts.socket_path) |p| if (std.fs.path.dirname(p)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    var server: http.Server = .init(gpa, io, svc.handler(), httpOptions(config, opts));
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
    try background.concurrent(io, capture.Capture.run, .{&cap});
    if (capy_source) |*c| try background.concurrent(io, capture.capy.Source.run, .{c});

    log.info("graf serve: graph {s} on {s}{s}{s}", .{ config.graph, config.serve.listen, if (opts.socket_path != null) " and " else "", opts.socket_path orelse "" });
    try server.run();
}

fn announceUpstream(up: *Upstream) Io.Cancelable!void {
    if (try up.health()) {
        log.info("hub {s} is reachable", .{up.base});
    } else log.warn("hub {s} is not reachable yet; captured entries stay spooled until it is", .{up.base});
}

pub fn runEdge(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, config: *const core.Config, opts: Options) !void {
    try checkExposure(config);
    limits.raiseOpenFiles();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state_dir = try capture.state.dir(arena, env) orelse return error.NoStateDir;

    var up = try Upstream.init(gpa, io, config.edge.upstream, config.edge.token, config.edge.timeout_ms);
    defer up.deinit();
    var spool = try edge.Spool.open(gpa, io, try edge.spoolDir(arena, state_dir), .{});
    defer spool.close();

    var cap = try capture.Capture.init(gpa, io, env, config, spool.sink(), .{});
    defer cap.deinit();
    replayHookSpool(&cap);

    var proxy: edge.Edge = .{ .upstream = &up, .spool = &spool, .flusher = flusher(&cap) };

    if (opts.socket_path) |p| if (std.fs.path.dirname(p)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    var server: http.Server = .init(gpa, io, proxy.handler(), httpOptions(config, opts));
    try server.start();
    defer server.deinit();

    var background: Io.Group = .init;
    defer background.cancel(io);
    try background.concurrent(io, capture.Capture.run, .{&cap});
    try background.concurrent(io, edge.Spool.run, .{ &spool, &up });
    try background.concurrent(io, announceUpstream, .{&up});

    log.info("graf serve --edge: pushing to {s}; local {s}{s}{s}", .{ up.base, config.serve.listen, if (opts.socket_path != null) " and " else "", opts.socket_path orelse "" });
    try server.run();
}
