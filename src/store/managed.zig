const std = @import("std");
const pg = @import("pg");

pub const database = "graf";
pub const user = "graf";

pub const Toolchain = struct {
    bin_dir: []const u8,

    pub fn tool(tc: Toolchain, arena: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fs.path.join(arena, &.{ tc.bin_dir, name });
    }
};

const well_known_bins = [_][]const u8{
    "/opt/homebrew/opt/postgresql@17/bin",
    "/usr/local/opt/postgresql@17/bin",
    "/usr/lib/postgresql/17/bin",
    "/usr/pgsql-17/bin",
};

pub fn findToolchain(arena: std.mem.Allocator, io: std.Io, path_env: ?[]const u8) !?Toolchain {
    var candidates: std.ArrayList([]const u8) = .empty;
    if (path_env) |p| {
        var it = std.mem.tokenizeScalar(u8, p, std.fs.path.delimiter);
        while (it.next()) |dir| try candidates.append(arena, dir);
    }
    try candidates.appendSlice(arena, &well_known_bins);

    for (candidates.items) |dir| {
        const tc: Toolchain = .{ .bin_dir = dir };
        if (!try hasServerBinaries(arena, io, tc)) continue;
        if (try vectorControl(arena, io, tc) != null) return tc;
    }

    return null;
}

fn hasServerBinaries(arena: std.mem.Allocator, io: std.Io, tc: Toolchain) !bool {
    for ([_][]const u8{ "initdb", "pg_ctl", "postgres" }) |name| {
        std.Io.Dir.accessAbsolute(io, try tc.tool(arena, name), .{ .execute = true }) catch return false;
    }
    return true;
}

pub fn vectorControl(arena: std.mem.Allocator, io: std.Io, tc: Toolchain) !?[]const u8 {
    const prefix = std.fs.path.dirname(tc.bin_dir) orelse return null;
    const major = std.fs.path.basename(prefix);
    const shares = [_][]const u8{
        try std.fs.path.join(arena, &.{ prefix, "share", "postgresql", "extension" }),
        try std.fs.path.join(arena, &.{ prefix, "share", "postgresql@17", "extension" }),
        try std.fs.path.join(arena, &.{ prefix, "share", "extension" }),
        try std.fs.path.join(arena, &.{ "/usr/share/postgresql", major, "extension" }),
    };

    for (shares) |dir| {
        const control = try std.fs.path.join(arena, &.{ dir, "vector.control" });
        std.Io.Dir.accessAbsolute(io, control, .{}) catch continue;
        return control;
    }
    return null;
}

pub fn defaultDataDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| if (xdg.len != 0) return std.fs.path.join(arena, &.{ xdg, "graf", "pg" });
    const home = env.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(arena, &.{ home, ".local", "share", "graf", "pg" });
}

pub fn databaseUrl(arena: std.mem.Allocator, data_dir: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("postgres://{s}@localhost/{s}?host=", .{ user, database });

    for (data_dir) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.writer.writeByte(c);
        } else {
            try out.writer.print("%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice();
}

pub fn initCluster(gpa: std.mem.Allocator, io: std.Io, tc: Toolchain, data_dir: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const version_file = try std.fs.path.join(arena, &.{ data_dir, "PG_VERSION" });
    if (std.Io.Dir.accessAbsolute(io, version_file, .{})) |_| return false else |_| {}

    if (std.fs.path.dirname(data_dir)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try runTool(arena, io, &.{ try tc.tool(arena, "initdb"), "-D", data_dir, "-U", user, "--auth=trust", "--encoding=UTF8", "--no-locale" });

    const conf_path = try std.fs.path.join(arena, &.{ data_dir, "postgresql.conf" });
    const conf = try std.Io.Dir.cwd().readFileAlloc(io, conf_path, arena, .limited(1 << 20));
    const extra = try std.fmt.allocPrint(arena, "{s}\nlisten_addresses = ''\nunix_socket_directories = '{s}'\n", .{ conf, data_dir });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = conf_path, .data = extra });
    return true;
}

fn runTool(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(arena, io, .{ .argv = argv });
    if (!result.term.success()) {
        std.log.err("{s} failed: {s}", .{ argv[0], result.stderr });
        return error.PostgresToolFailed;
    }
}

pub const Server = struct {
    child: ?std.process.Child,
    url: []const u8,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, tc: Toolchain, data_dir: []const u8, url_arena: std.mem.Allocator) !Server {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const url = try databaseUrl(url_arena, data_dir);

        const status = try std.process.run(arena, io, .{ .argv = &.{ try tc.tool(arena, "pg_ctl"), "status", "-D", data_dir } });
        var child: ?std.process.Child = null;
        if (!status.term.success()) {
            child = try std.process.spawn(io, .{
                .argv = &.{ try tc.tool(arena, "postgres"), "-D", data_dir },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
        }
        errdefer if (child) |*c| stopChild(io, c);

        const conn_opts: pg.Conn.Opts = .{ .host = try socketPath(arena, data_dir, null) };
        try waitReady(gpa, io, conn_opts);
        try ensureDatabase(gpa, io, conn_opts);
        return .{ .child = child, .url = url };
    }

    pub fn stop(srv: *Server, io: std.Io) void {
        if (srv.child) |*c| stopChild(io, c);
        srv.child = null;
    }
};

fn stopChild(io: std.Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    std.posix.kill(pid, .INT) catch {
        child.kill(io);
        return;
    };
    _ = child.wait(io) catch {};
}

pub fn socketPath(arena: std.mem.Allocator, dir: []const u8, port: ?u16) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/.s.PGSQL.{d}", .{ std.mem.trimEnd(u8, dir, "/"), port orelse 5432 });
}

const maintenance_auth: pg.Conn.AuthOpts = .{ .username = user, .database = "postgres", .timeout = 5_000 };

fn waitReady(gpa: std.mem.Allocator, io: std.Io, conn_opts: pg.Conn.Opts) !void {
    var attempt: usize = 0;
    while (attempt < 300) : (attempt += 1) {
        if (pg.Conn.openAndAuth(io, gpa, conn_opts, maintenance_auth)) |c| {
            var conn = c;
            conn.deinit();
            return;
        } else |_| {}
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    return error.PostgresNotReady;
}

fn ensureDatabase(gpa: std.mem.Allocator, io: std.Io, conn_opts: pg.Conn.Opts) !void {
    var conn = try pg.Conn.openAndAuth(io, gpa, conn_opts, maintenance_auth);
    defer conn.deinit();

    const exists = blk: {
        var row = try conn.row("SELECT 1 FROM pg_database WHERE datname = $1", .{database}) orelse break :blk false;
        try row.deinit();
        break :blk true;
    };

    if (!exists) _ = try conn.exec("CREATE DATABASE " ++ database, .{});
}

pub const docker = struct {
    pub const image = "pgvector/pgvector:pg17";
    pub const container = "graf-postgres";
    pub const volume = "graf-pg";
    pub const port = 54331;
    pub const url = std.fmt.comptimePrint("postgres://{s}:{s}@127.0.0.1:{d}/{s}", .{ user, user, port, database });

    pub fn available(arena: std.mem.Allocator, io: std.Io) bool {
        const result = std.process.run(arena, io, .{ .argv = &.{ "docker", "version", "--format", "{{.Server.Version}}" } }) catch return false;
        return result.term.success();
    }

    pub fn start(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
        const inspect = try std.process.run(arena, io, .{ .argv = &.{ "docker", "inspect", "--format", "{{.State.Running}}", container } });
        if (inspect.term.success()) {
            if (!std.mem.startsWith(u8, inspect.stdout, "true")) try runTool(arena, io, &.{ "docker", "start", container });
        } else {
            const publish = std.fmt.comptimePrint("127.0.0.1:{d}:5432", .{port});
            try runTool(arena, io, &.{
                "docker",                 "run",                                 "-d",
                "--name",                 container,                             "--restart",
                "unless-stopped",         "-p",                                  publish,
                "-v",                     volume ++ ":/var/lib/postgresql/data", "-e",
                "POSTGRES_USER=" ++ user, "-e",                                  "POSTGRES_PASSWORD=" ++ user,
                "-e",                     "POSTGRES_DB=" ++ database,            image,
            });
        }
        return url;
    }
};

pub const Plan = union(enum) {
    url: []const u8,
    managed: struct { toolchain: Toolchain, data_dir: []const u8 },
    docker,
    unavailable,
};

pub fn plan(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, explicit_url: ?[]const u8) !Plan {
    if (explicit_url) |u| if (u.len != 0) return .{ .url = u };
    if (try findToolchain(arena, io, env.get("PATH"))) |tc| {
        return .{ .managed = .{ .toolchain = tc, .data_dir = try defaultDataDir(arena, env) } };
    }
    if (docker.available(arena, io)) return .docker;
    return .unavailable;
}

test "database url encodes the socket directory" {
    const url = try databaseUrl(std.testing.allocator, "/home/u/.local/share/graf/pg");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("postgres://graf@localhost/graf?host=%2Fhome%2Fu%2F.local%2Fshare%2Fgraf%2Fpg", url);
}

test "data dir follows XDG_DATA_HOME, then HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());

    try env.put("HOME", "/home/u");
    try std.testing.expectEqualStrings("/home/u/.local/share/graf/pg", try defaultDataDir(arena.allocator(), &env));
    try env.put("XDG_DATA_HOME", "/data");
    try std.testing.expectEqualStrings("/data/graf/pg", try defaultDataDir(arena.allocator(), &env));
}

test "an explicit url wins over every other plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    const p = try plan(arena.allocator(), std.testing.io, &env, "postgres://x@h/db");
    try std.testing.expectEqualStrings("postgres://x@h/db", p.url);
}

test "managed cluster initializes socket-only, starts, serves pgvector and stops" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tc = try findToolchain(arena, io, std.testing.environ.getPosix("PATH")) orelse return error.SkipZigTest;
    var rand: [6]u8 = undefined;
    io.random(&rand);
    const data_dir = try std.fmt.allocPrint(arena, "/tmp/graf-managed-{x}", .{rand});
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    try std.testing.expect(try initCluster(gpa, io, tc, data_dir));
    try std.testing.expect(!try initCluster(gpa, io, tc, data_dir));

    var srv = try Server.start(gpa, io, tc, data_dir, arena);
    defer srv.stop(io);

    const store = @import("mod.zig");
    var s = try store.Store.open(io, gpa, srv.url, .{ .pool_size = 1 });
    defer s.close();
    _ = try s.migrate();

    var row = (try s.pool.row("SELECT current_setting('listen_addresses'), extversion FROM pg_extension WHERE extname = 'vector'", .{})).?;
    defer row.deinit() catch {};
    try std.testing.expectEqualStrings("", try row.get([]const u8, 0));
}
