const std = @import("std");
const core = @import("core");
const store = @import("store");
const capture = @import("capture");
const eval = @import("eval");
const api = @import("api.zig");
const client = @import("client.zig");
const daemon = @import("daemon.zig");
const mcp = @import("mcp.zig");
const service = @import("service.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const version = "0.0.0-dev";

const Command = enum { help, version, config, init, serve, mcp, hook, search, entity, remember, forget, doctor, eval };

const usage =
    \\usage: graf [--config PATH] <command> [args...]
    \\
    \\commands:
    \\  init                         create or migrate the database
    \\  serve                        run the daemon (HTTP, MCP, ingestion, tailers)
    \\  mcp                          MCP server over stdio (starts the daemon if needed)
    \\  hook <harness> <event>       harness hook entry point
    \\  search <query...>            search memory
    \\      [--project P | --all] [--as-of T] [--known-at T] [--history] [--harness H] [--max-tokens N] [--json]
    \\  entity <name-or-id>          show an entity and its facts
    \\      [--depth 1|2] [--as-of T] [--history] [--retracted] [--max-tokens N] [--json]
    \\  remember <text...>           store a note
    \\      [--project P | --global] [--valid-from T] [--no-wait] [--json]
    \\  forget <fact-id> | --query Q forget a fact [--reason R] [--json]
    \\  doctor                       check configuration, database and providers
    \\  eval                         run the labeled eval suite
    \\  config                       print the effective configuration (secrets masked)
    \\  version                      print the version
    \\
;

const value_flags = [_][]const u8{ "--project", "--as-of", "--known-at", "--harness", "--max-tokens", "--depth", "--valid-from", "--query", "--reason", "--suite" };

const Args = struct {
    positional: []const []const u8,
    rest: []const []const u8,

    fn parse(arena: Allocator, rest: []const []const u8) !Args {
        var pos: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const a = rest[i];
            if (std.mem.startsWith(u8, a, "--")) {
                for (value_flags) |f| if (std.mem.eql(u8, f, a)) {
                    if (i + 1 >= rest.len) return error.MissingFlagValue;
                    i += 1;
                };
                continue;
            }
            try pos.append(arena, a);
        }
        return .{ .positional = pos.items, .rest = rest };
    }

    fn value(a: Args, name: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i + 1 < a.rest.len) : (i += 1) if (std.mem.eql(u8, a.rest[i], name)) return a.rest[i + 1];
        return null;
    }

    fn has(a: Args, name: []const u8) bool {
        for (a.rest) |r| if (std.mem.eql(u8, r, name)) return true;
        return false;
    }

    fn int(a: Args, name: []const u8) !?u32 {
        const v = a.value(name) orelse return null;
        return std.fmt.parseInt(u32, v, 10) catch error.InvalidNumber;
    }

    fn joined(a: Args, arena: Allocator) ![]const u8 {
        return std.mem.join(arena, " ", a.positional);
    }
};

pub fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};
    var err_buf: [1024]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(io, &err_buf);
    const err = &err_writer.interface;
    defer err.flush() catch {};

    var config_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len and std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
            i += 1;
            config_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--help")) {
            try out.writeAll(usage);
            return 0;
        } else {
            try err.print("graf: unknown flag '{s}'\n", .{args[i]});
            return 2;
        }
    }
    if (i >= args.len) {
        try err.writeAll(usage);
        return 2;
    }
    const command = std.meta.stringToEnum(Command, args[i]) orelse {
        try err.print("graf: unknown command '{s}'\n\n{s}", .{ args[i], usage });
        return 2;
    };
    const rest = args[i + 1 ..];

    switch (command) {
        .help => {
            try out.writeAll(usage);
            return 0;
        },
        .version => {
            try out.print("graf {s}\n", .{version});
            return 0;
        },
        else => {},
    }

    var diag: core.toml.Diagnostic = .{};
    const loaded = core.config.load(arena, io, init.environ_map, .{ .path = config_path, .diag = &diag }) catch |e| switch (e) {
        error.InvalidConfig => {
            try err.print("graf: {s}:{d}: {s}\n", .{ config_path orelse "config", diag.line, diag.message });
            return 2;
        },
        error.ConfigNotFound => {
            try err.print("graf: config file not found: {s}\n", .{config_path orelse init.environ_map.get(core.config.config_path_env).?});
            return 2;
        },
        else => |other| return other,
    };
    const cfg = &loaded.config;

    switch (command) {
        .help, .version => unreachable,
        .config => {
            try out.print("# file: {s} ({s})\n", .{ loaded.path orelse "(none)", if (loaded.file_found) "loaded" else "not found, using defaults" });
            try core.config.writeMasked(cfg, out);
            return 0;
        },
        .init => {
            var rt: daemon.Runtime = undefined;
            rt.open(init.gpa, io, cfg, 2) catch |e| return fail(err, "init", e);
            defer rt.close();
            try out.print("database ready; graph '{s}' is {f}\n", .{ cfg.graph, rt.graph_id });
            return 0;
        },
        .serve => {
            daemon.run(init.gpa, io, init.environ_map, cfg, .{ .version = version, .socket_path = try api.socketPath(arena, init.environ_map, cfg) }) catch |e| return fail(err, "serve", e);
            return 0;
        },
        .mcp => return runMcp(init, cfg, config_path, err),
        .hook => return runHook(init, cfg, rest, out, err),
        .doctor => return doctor(arena, init, cfg, loaded, out),
        .eval => {
            const suite = (try Args.parse(arena, rest)).value("--suite") orelse "evals";
            const metrics = eval.run(arena, io, cfg, .{ .suite_dir = suite }) catch |e| return fail(err, "eval", e);
            try std.json.Stringify.value(metrics, .{ .whitespace = .indent_2 }, out);
            try out.writeByte('\n');
            return if (metrics.passes()) 0 else 1;
        },
        .search, .entity, .remember, .forget => {
            const parsed = Args.parse(arena, rest) catch {
                try err.print("graf {s}: a flag is missing its value\n", .{@tagName(command)});
                return 2;
            };
            const req = buildRequest(arena, command, parsed) catch |e| {
                try err.print("graf {s}: {s}\n\n{s}", .{ @tagName(command), usageError(e), usage });
                return 2;
            };
            var rt: daemon.Runtime = undefined;
            rt.open(init.gpa, io, cfg, 2) catch |e| return fail(err, @tagName(command), e);
            defer rt.close();
            var svc: service.Service = .{ .gpa = init.gpa, .io = io, .engine = &rt.engine, .sink = rt.store.sink(rt.graph_id), .remember_harness = .cli };
            defer svc.deinit();
            const reply = svc.handler().handle(arena, req) catch |e| return fail(err, @tagName(command), e);
            return printReply(arena, reply, parsed.has("--json"), out, err);
        },
    }
}

fn buildRequest(arena: Allocator, command: Command, a: Args) !api.Request {
    const opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    return switch (command) {
        .search => .{ .op = .search, .body = try std.json.Stringify.valueAlloc(arena, .{
            .query = if (a.positional.len == 0) return error.MissingQuery else try a.joined(arena),
            .project = if (a.has("--all")) "*" else a.value("--project"),
            .as_of = a.value("--as-of"),
            .known_at = a.value("--known-at"),
            .include_history = a.has("--history"),
            .harness = a.value("--harness"),
            .max_tokens = try a.int("--max-tokens"),
        }, opts) },
        .entity => .{ .op = .entity, .body = try std.json.Stringify.valueAlloc(arena, .{
            .name_or_id = if (a.positional.len == 0) return error.MissingName else try a.joined(arena),
            .depth = try a.int("--depth"),
            .as_of = a.value("--as-of"),
            .include_history = a.has("--history"),
            .include_retracted = a.has("--retracted"),
            .max_tokens = try a.int("--max-tokens"),
        }, opts) },
        .remember => .{ .op = .remember, .body = try std.json.Stringify.valueAlloc(arena, .{
            .text = if (a.positional.len == 0) return error.MissingText else try a.joined(arena),
            .project = a.value("--project"),
            .scope = if (a.has("--global")) "global" else "project",
            .valid_from = a.value("--valid-from"),
            .wait = !a.has("--no-wait"),
        }, opts) },
        .forget => .{ .op = .forget, .body = try std.json.Stringify.valueAlloc(arena, .{
            .fact_id = if (a.positional.len > 0) a.positional[0] else null,
            .query = a.value("--query"),
            .reason = a.value("--reason"),
        }, opts) },
        else => unreachable,
    };
}

fn usageError(e: anyerror) []const u8 {
    return switch (e) {
        error.MissingQuery => "missing query",
        error.MissingName => "missing entity name or id",
        error.MissingText => "missing text",
        error.InvalidNumber => "expected a number",
        else => @errorName(e),
    };
}

fn printReply(arena: Allocator, reply: api.Reply, json: bool, out: *Writer, err: *Writer) !u8 {
    if (json) {
        try out.print("{s}\n", .{reply.body});
        return if (reply.status >= 400) 1 else 0;
    }
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, reply.body, .{}) catch {
        try out.print("{s}\n", .{reply.body});
        return if (reply.status >= 400) 1 else 0;
    };
    if (reply.status >= 400) {
        const msg = if (value == .object) if (value.object.get("error")) |e| (if (e == .string) e.string else reply.body) else reply.body else reply.body;
        try err.print("graf: {s}\n", .{msg});
        return 1;
    }
    if (value == .object) if (value.object.get("text")) |t| if (t == .string) {
        try out.writeAll(t.string);
        if (!std.mem.endsWith(u8, t.string, "\n")) try out.writeByte('\n');
        return 0;
    };
    try out.print("{s}\n", .{reply.body});
    return 0;
}

fn fail(err: *Writer, what: []const u8, e: anyerror) !u8 {
    const hint: []const u8 = switch (e) {
        error.DatabaseNotConfigured => "set database.url in the config file or GRAF_DATABASE_URL",
        error.ConnectionRefused => "cannot reach Postgres; is it running? (graf doctor)",
        error.NotImplemented => "not available in this build yet",
        else => "",
    };
    try err.print("graf {s}: {s}{s}{s}\n", .{ what, @errorName(e), if (hint.len > 0) ": " else "", hint });
    return 1;
}

fn runMcp(init: std.process.Init, cfg: *const core.Config, config_path: ?[]const u8, err: *Writer) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    const socket = try api.socketPath(arena, env, cfg) orelse {
        try err.writeAll("graf mcp: cannot place the daemon socket; set serve.socket or HOME\n");
        return 1;
    };
    var c = client.Client.init(io, .{ .unix = socket }, cfg.serve.token);
    const exe = try std.process.executablePathAlloc(io, arena);
    const extra: []const []const u8 = if (config_path) |p| try arena.dupe([]const u8, &.{ "--config", p }) else &.{};
    client.ensureDaemonWith(arena, io, env, &c, exe, .{ .args = extra }) catch |e| {
        try err.print("graf mcp: daemon unavailable ({s}); tool calls will fail until it starts\n", .{@errorName(e)});
        try err.flush();
    };

    var handler = c.handler();
    var defaults: service.DefaultProject = undefined;
    if (env.get("GRAF_PROJECT")) |p| if (p.len > 0) {
        defaults = .{ .inner = handler, .project = p };
        handler = defaults.handler();
    };

    var in_buf: [64 * 1024]u8 = undefined;
    var in_reader = std.Io.File.stdin().reader(io, &in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    try mcp.serveStdio(init.gpa, handler, version, &in_reader.interface, &out_writer.interface);
    return 0;
}

fn runHook(init: std.process.Init, cfg: *const core.Config, rest: []const []const u8, out: *Writer, err: *Writer) !u8 {
    if (rest.len < 2) {
        try err.writeAll("usage: graf hook <harness> <event>\n");
        return 0;
    }
    const harness = std.meta.stringToEnum(core.Harness, rest[0]) orelse return 0;
    const event = std.meta.stringToEnum(capture.hooks.Event, rest[1]) orelse return 0;
    var in_buf: [16 * 1024]u8 = undefined;
    var in_reader = std.Io.File.stdin().reader(init.io, &in_buf);
    const stdin_json = in_reader.interface.allocRemaining(init.arena.allocator(), .limited(1 << 20)) catch "";
    capture.hooks.run(init.arena.allocator(), init.io, cfg, harness, event, stdin_json, out) catch |e| {
        try err.print("graf hook: {s}\n", .{@errorName(e)});
    };
    return 0;
}

fn doctor(arena: Allocator, init: std.process.Init, cfg: *const core.Config, loaded: core.config.Loaded, out: *Writer) !u8 {
    const io = init.io;
    var failures: u32 = 0;
    const Check = struct {
        fn line(w: *Writer, ok: enum { ok, warn, fail }, comptime fmt: []const u8, args: anytype) !void {
            try w.print("[{s}] " ++ fmt ++ "\n", .{@tagName(ok)} ++ args);
        }
    };

    try Check.line(out, .ok, "config: {s} ({s})", .{ loaded.path orelse "(none)", if (loaded.file_found) "loaded" else "defaults" });

    if (cfg.database.url.len == 0) {
        try Check.line(out, .fail, "database: no database.url or GRAF_DATABASE_URL", .{});
        failures += 1;
    } else if (store.Store.open(io, init.gpa, cfg.database.url, .{ .pool_size = 1 })) |opened| {
        var s = opened;
        defer s.close();
        try Check.line(out, .ok, "database: connected to {f}", .{core.config.MaskedUrl{ .url = cfg.database.url }});
        failures += try doctorDatabase(arena, &s, cfg, out);
    } else |e| {
        try Check.line(out, .fail, "database: cannot connect ({s})", .{@errorName(e)});
        failures += 1;
    }

    if (cfg.llm.model.len == 0) {
        try Check.line(out, .fail, "model: llm.model is not set; ingestion cannot run", .{});
        failures += 1;
    } else try Check.line(out, .ok, "model: {s} via {s} at {s}", .{ cfg.llm.model, @tagName(cfg.llm.route), cfg.llm.base_url });
    if (cfg.llm.api_key.len == 0) try Check.line(out, .warn, "model: no API key set (GRAF_LLM_API_KEY)", .{});
    try Check.line(out, .ok, "embeddings: {s}, {d} dimensions", .{ cfg.embed.model, cfg.embed.dimensions });
    if (cfg.decisionEnabled())
        try Check.line(out, .ok, "rerank: decision backend configured, {d} ms budget", .{cfg.decision.rerank_timeout_ms})
    else
        try Check.line(out, .warn, "rerank: no decision backend; search uses the deterministic order", .{});

    if (try api.socketPath(arena, init.environ_map, cfg)) |sock| {
        var c = client.Client.init(io, .{ .unix = sock }, cfg.serve.token);
        if (c.health() catch false)
            try Check.line(out, .ok, "daemon: running at {s}", .{sock})
        else
            try Check.line(out, .warn, "daemon: not running (graf serve, or any graf mcp starts it)", .{});
    }
    return if (failures > 0) 1 else 0;
}

fn doctorDatabase(arena: Allocator, s: *store.Store, cfg: *const core.Config, out: *Writer) !u32 {
    var failures: u32 = 0;
    const ext = s.pool.row("SELECT count(*) FILTER (WHERE extname = 'vector'), count(*) FILTER (WHERE extname = 'pg_trgm') FROM pg_extension", .{}) catch null;
    if (ext) |r| {
        var row = r;
        defer row.deinit() catch {};
        const vector = try row.get(i64, 0);
        const trgm = try row.get(i64, 1);
        if (vector == 0 or trgm == 0) {
            try out.print("[warn] extensions: vector {s}, pg_trgm {s} (graf init creates them)\n", .{ if (vector > 0) "installed" else "missing", if (trgm > 0) "installed" else "missing" });
        } else try out.writeAll("[ok] extensions: vector and pg_trgm installed\n");
    }
    const applied: i64 = blk: {
        var row = (s.pool.row("SELECT count(*) FROM schema_migrations", .{}) catch break :blk 0) orelse break :blk 0;
        defer row.deinit() catch {};
        break :blk try row.get(i64, 0);
    };
    const total = store.migrations.all.len;
    if (applied < total) {
        try out.print("[warn] schema: {d} of {d} migrations applied (run graf init)\n", .{ applied, total });
        return failures;
    }
    try out.print("[ok] schema: {d} migrations applied\n", .{applied});
    var row = (s.pool.row(
        "SELECT g.id, (SELECT count(*) FROM entry e WHERE e.graph_id = g.id AND e.status IN ('queued', 'extracting', 'extracted', 'staged', 'committing')), (SELECT count(*) FROM entry e WHERE e.graph_id = g.id AND e.status = 'dead'), (SELECT count(*) FROM fact f WHERE f.graph_id = g.id AND upper_inf(f.known) AND upper_inf(f.valid)) FROM graph g WHERE g.name = $1",
        .{cfg.graph},
    ) catch null) orelse {
        try out.print("[warn] graph '{s}': not created yet (graf init)\n", .{cfg.graph});
        return failures;
    };
    defer row.deinit() catch {};
    const dead = try row.get(i64, 2);
    try out.print("[{s}] graph '{s}': {d} current facts, {d} entries pending, {d} dead\n", .{ if (dead > 0) "warn" else "ok", cfg.graph, try row.get(i64, 3), try row.get(i64, 1), dead });
    _ = arena;
    if (dead > 0) failures += 0;
    return failures;
}
