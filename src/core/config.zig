const std = @import("std");
const toml = @import("toml.zig");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Route = enum { @"openai-responses", @"anthropic-messages", @"openai-chat" };

pub const Config = struct {
    graph: []const u8 = "default",
    database: Database = .{},
    llm: Llm = .{},
    embed: Embed = .{},
    decision: Decision = .{},
    limits: Limits = .{},
    ingest: Ingest = .{},
    serve: Serve = .{},
    capture: Capture = .{},

    pub const Database = struct {
        url: []const u8 = "",
    };

    pub const Llm = struct {
        base_url: []const u8 = "https://api.openai.com/v1",
        api_key: []const u8 = "",
        route: Route = .@"openai-responses",
        model: []const u8 = "",
        cost_header: []const u8 = "",
        timeout_ms: u32 = 120_000,
        stream: bool = false,
    };

    pub const Embed = struct {
        base_url: []const u8 = "",
        api_key: []const u8 = "",
        model: []const u8 = "text-embedding-3-large",
        dimensions: u32 = 512,
        cost_header: []const u8 = "",
    };

    pub const Decision = struct {
        base_url: []const u8 = "",
        api_key: []const u8 = "",
        path: []const u8 = "",
        model: []const u8 = "",
        dup_threshold: f64 = 0.70,
        contradict_threshold: f64 = 0.80,
        rerank_timeout_ms: u32 = 400,
    };

    pub const Limits = struct {
        daily_usd: f64 = 100.0,
        monthly_usd: f64 = 1500.0,
        max_inflight: u32 = 8,
    };

    pub const Ingest = struct {
        workers: u32 = 4,
    };

    pub const Serve = struct {
        listen: []const u8 = "127.0.0.1:7420",
        socket: []const u8 = "",
        token: []const u8 = "",
    };

    pub const Capture = struct {
        exclude_projects: []const []const u8 = &.{},
        exclude_paths: []const []const u8 = &.{},
    };

    pub fn decisionEnabled(c: *const Config) bool {
        return c.decision.base_url.len > 0;
    }
};

pub const env_vars = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "GRAF_GRAPH", "", "graph" },
    .{ "GRAF_DATABASE_URL", "database", "url" },
    .{ "GRAF_LLM_BASE_URL", "llm", "base_url" },
    .{ "GRAF_LLM_API_KEY", "llm", "api_key" },
    .{ "GRAF_LLM_MODEL", "llm", "model" },
    .{ "GRAF_EMBED_BASE_URL", "embed", "base_url" },
    .{ "GRAF_EMBED_API_KEY", "embed", "api_key" },
    .{ "GRAF_EMBED_MODEL", "embed", "model" },
    .{ "GRAF_DECISION_BASE_URL", "decision", "base_url" },
    .{ "GRAF_DECISION_API_KEY", "decision", "api_key" },
};

pub const config_path_env = "GRAF_CONFIG";

pub const LoadOptions = struct {
    path: ?[]const u8 = null,
    diag: ?*toml.Diagnostic = null,
};

pub const Loaded = struct {
    config: Config,
    path: ?[]const u8,
    file_found: bool,
};

pub const LoadError = error{ InvalidConfig, ConfigNotFound, OutOfMemory } || std.Io.Dir.ReadFileAllocError;

pub fn load(arena: Allocator, io: std.Io, env: *const Environ.Map, opts: LoadOptions) LoadError!Loaded {
    var local_diag: toml.Diagnostic = .{};
    const diag = opts.diag orelse &local_diag;
    const explicit = opts.path orelse env.get(config_path_env);
    const path = explicit orelse try defaultPath(arena, env);

    var cfg: Config = .{};
    var found = false;
    if (path) |p| {
        if (std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(1 << 20))) |src| {
            found = true;
            try toml.parseInto(Config, arena, src, &cfg, diag);
        } else |err| switch (err) {
            error.FileNotFound => if (explicit != null) return error.ConfigNotFound,
            else => |e| return e,
        }
    }
    applyEnv(&cfg, env);
    resolveInheritance(&cfg);
    return .{ .config = cfg, .path = path, .file_found = found };
}

pub fn parse(arena: Allocator, src: []const u8, diag: *toml.Diagnostic) toml.Error!Config {
    var cfg: Config = .{};
    try toml.parseInto(Config, arena, src, &cfg, diag);
    resolveInheritance(&cfg);
    return cfg;
}

pub fn defaultPath(arena: Allocator, env: *const Environ.Map) Allocator.Error!?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| if (xdg.len > 0) return try std.fs.path.join(arena, &.{ xdg, "graf", "config.toml" });
    if (env.get("HOME")) |home| if (home.len > 0) return try std.fs.path.join(arena, &.{ home, ".config", "graf", "config.toml" });
    return null;
}

pub fn applyEnv(cfg: *Config, env: *const Environ.Map) void {
    inline for (env_vars) |ev| {
        if (env.get(ev[0])) |value| if (value.len > 0) {
            if (comptime ev[1].len == 0) {
                @field(cfg, ev[2]) = value;
            } else {
                @field(@field(cfg, ev[1]), ev[2]) = value;
            }
        };
    }
}

fn resolveInheritance(cfg: *Config) void {
    if (cfg.embed.base_url.len == 0) cfg.embed.base_url = cfg.llm.base_url;
    if (cfg.embed.api_key.len == 0) cfg.embed.api_key = cfg.llm.api_key;
    if (cfg.embed.cost_header.len == 0) cfg.embed.cost_header = cfg.llm.cost_header;
}

pub fn writeMasked(cfg: *const Config, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeTable(Config, cfg, "", w);
}

fn writeTable(comptime S: type, value: *const S, comptime prefix: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const info = @typeInfo(S).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (@typeInfo(F) != .@"struct") try writeField(F, name, @field(value, name), w);
    }
    inline for (info.field_names, info.field_types) |name, F| {
        if (@typeInfo(F) == .@"struct") {
            try w.print("\n[{s}{s}]\n", .{ prefix, name });
            try writeTable(F, &@field(value, name), prefix ++ name ++ ".", w);
        }
    }
}

fn writeField(comptime T: type, comptime name: []const u8, value: T, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (comptime isSecret(name)) {
        return w.print("{s} = \"{s}\"\n", .{ name, if (value.len == 0) "" else "<set>" });
    }
    if (T == []const u8) {
        if (comptime std.mem.eql(u8, name, "url")) return w.print("{s} = \"{f}\"\n", .{ name, MaskedUrl{ .url = value } });
        return w.print("{s} = \"{s}\"\n", .{ name, value });
    }
    if (T == []const []const u8) {
        try w.print("{s} = [", .{name});
        for (value, 0..) |item, i| try w.print("{s}\"{s}\"", .{ if (i == 0) "" else ", ", item });
        return w.writeAll("]\n");
    }
    switch (@typeInfo(T)) {
        .@"enum" => try w.print("{s} = \"{s}\"\n", .{ name, @tagName(value) }),
        else => try w.print("{s} = {any}\n", .{ name, value }),
    }
}

fn isSecret(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "api_key") or std.mem.eql(u8, name, "token");
}

pub const MaskedUrl = struct {
    url: []const u8,

    pub fn format(m: MaskedUrl, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const scheme_end = (std.mem.indexOf(u8, m.url, "://") orelse return w.writeAll(m.url)) + 3;
        const at = std.mem.indexOfScalarPos(u8, m.url, scheme_end, '@') orelse return w.writeAll(m.url);
        const colon = std.mem.indexOfScalarPos(u8, m.url[0..at], scheme_end, ':') orelse return w.writeAll(m.url);
        try w.print("{s}:***{s}", .{ m.url[0..colon], m.url[at..] });
    }
};

test "defaults match the spec" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: toml.Diagnostic = .{};
    const cfg = try parse(arena_state.allocator(), "", &diag);
    try std.testing.expectEqual(@as(f64, 100.0), cfg.limits.daily_usd);
    try std.testing.expectEqual(@as(u32, 512), cfg.embed.dimensions);
    try std.testing.expectEqual(Route.@"openai-responses", cfg.llm.route);
    try std.testing.expectEqualStrings(cfg.llm.base_url, cfg.embed.base_url);
    try std.testing.expect(!cfg.decisionEnabled());
}

test "file values, then env overrides, then inheritance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\graph = "personal"
        \\[llm]
        \\base_url = "https://llm.example.test/v1"
        \\route = "anthropic-messages"
        \\model = "some-model"
        \\cost_header = "x-cost-usd"
        \\[limits]
        \\daily_usd = 25
        \\[capture]
        \\exclude_projects = ["github.com/acme/secret"]
        \\
    ;
    var diag: toml.Diagnostic = .{};
    var cfg: Config = .{};
    try toml.parseInto(Config, arena, src, &cfg, &diag);

    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GRAF_LLM_API_KEY", "k-123");
    try env.put("GRAF_DATABASE_URL", "postgres://graf:pw@db.example.test:5432/graf");
    try env.put("GRAF_GRAPH", "");
    applyEnv(&cfg, &env);
    resolveInheritance(&cfg);

    try std.testing.expectEqualStrings("personal", cfg.graph);
    try std.testing.expectEqual(Route.@"anthropic-messages", cfg.llm.route);
    try std.testing.expectEqualStrings("k-123", cfg.llm.api_key);
    try std.testing.expectEqualStrings("k-123", cfg.embed.api_key);
    try std.testing.expectEqualStrings("https://llm.example.test/v1", cfg.embed.base_url);
    try std.testing.expectEqualStrings("x-cost-usd", cfg.embed.cost_header);
    try std.testing.expectEqual(@as(f64, 25), cfg.limits.daily_usd);
    try std.testing.expectEqualStrings("github.com/acme/secret", cfg.capture.exclude_projects[0]);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeMasked(&cfg, &out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "k-123") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, ":pw@") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "postgres://graf:***@db.example.test:5432/graf") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[llm]") != null);
}

test "load reads the file named by GRAF_CONFIG and reports a missing explicit file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = "[ingest]\nworkers = 2\n" });
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const file_path = try std.fs.path.join(arena, &.{ dir_path, "config.toml" });

    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GRAF_CONFIG", file_path);
    const loaded = try load(arena, io, &env, .{});
    try std.testing.expect(loaded.file_found);
    try std.testing.expectEqual(@as(u32, 2), loaded.config.ingest.workers);

    const missing = try std.fs.path.join(arena, &.{ dir_path, "nope.toml" });
    try std.testing.expectError(error.ConfigNotFound, load(arena, io, &env, .{ .path = missing }));

    var empty_env = Environ.Map.init(std.testing.allocator);
    defer empty_env.deinit();
    try empty_env.put("HOME", dir_path);
    const defaults = try load(arena, io, &empty_env, .{});
    try std.testing.expect(!defaults.file_found);
}
