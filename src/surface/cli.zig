const std = @import("std");
const core = @import("core");
const store = @import("store");
const eval = @import("eval");

pub const version = "0.0.0-dev";

const Command = enum { help, version, config, init, serve, mcp, hook, search, entity, remember, forget, doctor, eval };

const usage =
    \\usage: graf [--config PATH] <command> [args...]
    \\
    \\commands:
    \\  init       create or migrate the database
    \\  serve      run the daemon (HTTP, MCP, ingestion, tailers)
    \\  mcp        MCP server over stdio
    \\  hook       harness hook entry point
    \\  search     search memory
    \\  entity     show an entity and its facts
    \\  remember   store a note
    \\  forget     forget a fact
    \\  doctor     check configuration, database and providers
    \\  eval       run the labeled eval suite
    \\  config     print the effective configuration (secrets masked)
    \\  version    print the version
    \\
;

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
            if (cfg.database.url.len == 0) {
                try err.writeAll("graf init: set database.url or GRAF_DATABASE_URL (managed local Postgres is not built yet)\n");
                return 2;
            }
            var s = try store.Store.open(io, init.gpa, cfg.database.url, .{});
            defer s.close();
            const report = try s.migrate();
            try out.print("database ready: applied {d} of {d} migrations\n", .{ report.applied, report.total });
            return 0;
        },
        .eval => {
            const rest = try arena.alloc([]const u8, args.len - i - 1);
            for (rest, args[i + 1 ..]) |*dst, src| dst.* = src;
            return eval.main(arena, io, cfg, init.environ_map, rest, out, err);
        },
        else => {
            try err.print("graf {s}: not implemented yet\n", .{@tagName(command)});
            return 2;
        },
    }
}
