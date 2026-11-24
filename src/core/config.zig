const std = @import("std");
const toml = @import("toml.zig");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Route = enum { @"openai-responses", @"anthropic-messages", @"openai-chat" };

pub const DecisionWire = enum { generic, stateful };

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
    edge: Edge = .{},
    sources: Sources = .{},
    eval: Eval = .{},

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
        rpm: u32 = 0,
        input_tpm: u32 = 0,
        rates: []const []const u8 = &.{},
    };

    pub const Embed = struct {
        base_url: []const u8 = "",
        api_key: []const u8 = "",
        model: []const u8 = "text-embedding-3-large",
        dimensions: u32 = 512,
        cost_header: []const u8 = "",
        rpm: u32 = 0,
        input_tpm: u32 = 0,
    };

    pub const Decision = struct {
        base_url: []const u8 = "",
        api_key: []const u8 = "",
        path: []const u8 = "",
        model: []const u8 = "",
        wire: DecisionWire = .generic,
        cost_header: []const u8 = "",
        dup_threshold: f64 = 0.70,
        contradict_threshold: f64 = 0.80,
        rerank_timeout_ms: u32 = 400,
        rpm: u32 = 0,
        input_tpm: u32 = 0,
    };

    pub const Limits = struct {
        daily_usd: f64 = 100.0,
        monthly_usd: f64 = 1500.0,
        backfill_daily_usd: f64 = 25.0,
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

    pub const Edge = struct {
        upstream: []const u8 = "",
        token: []const u8 = "",
        timeout_ms: u32 = 10_000,
    };

    pub const Sources = struct {
        capy: Capy = .{},

        pub const Capy = struct {
            enabled: bool = false,
            base_url: []const u8 = "https://api.capy.ai/api/v1",
            api_key: []const u8 = "",
            projects: []const []const u8 = &.{},
            exclude_projects: []const []const u8 = &.{},
            exclude_threads: []const []const u8 = &.{},
            statuses: []const []const u8 = &.{},
            discover_every_s: u32 = 60,
            max_streams: u32 = 16,
        };
    };

    pub const Eval = struct {
        judge_model: []const u8 = "",
        judge_route: []const u8 = "",
        judge_base_url: []const u8 = "",
        judge_api_key: []const u8 = "",
    };

    pub fn decisionEnabled(c: *const Config) bool {
        return c.decision.base_url.len > 0;
    }

    pub fn capyEnabled(c: *const Config) bool {
        return c.sources.capy.enabled and c.sources.capy.api_key.len > 0;
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
    .{ "GRAF_SERVE_TOKEN", "serve", "token" },
    .{ "GRAF_UPSTREAM_URL", "edge", "upstream" },
    .{ "GRAF_UPSTREAM_TOKEN", "edge", "token" },
    .{ "GRAF_DECISION_MODEL", "decision", "model" },
    .{ "GRAF_EVAL_JUDGE_MODEL", "eval", "judge_model" },
    .{ "GRAF_EVAL_JUDGE_ROUTE", "eval", "judge_route" },
    .{ "GRAF_EVAL_JUDGE_BASE_URL", "eval", "judge_base_url" },
    .{ "GRAF_EVAL_JUDGE_API_KEY", "eval", "judge_api_key" },
    .{ "GRAF_CAPY_API_KEY", "sources.capy", "api_key" },
    .{ "GRAF_CAPY_BASE_URL", "sources.capy", "base_url" },
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
    try validateRates(&cfg, diag);
    return .{ .config = cfg, .path = path, .file_found = found };
}

pub fn parse(arena: Allocator, src: []const u8, diag: *toml.Diagnostic) toml.Error!Config {
    var cfg: Config = .{};
    try toml.parseInto(Config, arena, src, &cfg, diag);
    resolveInheritance(&cfg);
    try validateRates(&cfg, diag);
    return cfg;
}

pub const Rate = struct {
    model: []const u8,
    input_per_mtok: f64,
    output_per_mtok: f64,
    cache_read_per_mtok: f64 = 0,
    cache_write_per_mtok: f64 = 0,
};

pub fn parseRate(text: []const u8) error{InvalidRate}!Rate {
    var it = std.mem.tokenizeAny(u8, text, " \t");
    var rate: Rate = .{ .model = it.next() orelse return error.InvalidRate, .input_per_mtok = -1, .output_per_mtok = -1 };

    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse return error.InvalidRate;
        const usd = std.fmt.parseFloat(f64, pair[eq + 1 ..]) catch return error.InvalidRate;
        if (!(usd >= 0) or !std.math.isFinite(usd)) return error.InvalidRate;

        const key = pair[0..eq];
        if (std.mem.eql(u8, key, "input")) {
            rate.input_per_mtok = usd;
        } else if (std.mem.eql(u8, key, "output")) {
            rate.output_per_mtok = usd;
        } else if (std.mem.eql(u8, key, "cache_read")) {
            rate.cache_read_per_mtok = usd;
        } else if (std.mem.eql(u8, key, "cache_write")) {
            rate.cache_write_per_mtok = usd;
        } else return error.InvalidRate;
    }

    if (rate.input_per_mtok < 0 or rate.output_per_mtok < 0) return error.InvalidRate;
    return rate;
}

fn validateRates(cfg: *const Config, diag: *toml.Diagnostic) error{InvalidConfig}!void {
    for (cfg.llm.rates) |text| {
        _ = parseRate(text) catch {
            diag.* = .{ .message = "llm.rates entries look like \"<model> input=<usd> output=<usd> [cache_read=<usd>] [cache_write=<usd>]\", in USD per million tokens" };
            return error.InvalidConfig;
        };
    }
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
            } else if (comptime std.mem.indexOfScalar(u8, ev[1], '.')) |dot| {
                @field(@field(@field(cfg, ev[1][0..dot]), ev[1][dot + 1 ..]), ev[2]) = value;
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
    if (cfg.decision.cost_header.len == 0) cfg.decision.cost_header = cfg.llm.cost_header;
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
    return std.mem.endsWith(u8, name, "api_key") or std.mem.eql(u8, name, "token");
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
        \\exclude_projects = ["github.com/brackwater/secret"]
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
    try env.put("GRAF_EVAL_JUDGE_MODEL", "judge-model");
    try env.put("GRAF_EVAL_JUDGE_API_KEY", "jk-456");

    applyEnv(&cfg, &env);
    resolveInheritance(&cfg);

    try std.testing.expectEqualStrings("personal", cfg.graph);
    try std.testing.expectEqual(Route.@"anthropic-messages", cfg.llm.route);
    try std.testing.expectEqualStrings("k-123", cfg.llm.api_key);
    try std.testing.expectEqualStrings("k-123", cfg.embed.api_key);
    try std.testing.expectEqualStrings("https://llm.example.test/v1", cfg.embed.base_url);
    try std.testing.expectEqualStrings("x-cost-usd", cfg.embed.cost_header);
    try std.testing.expectEqual(@as(f64, 25), cfg.limits.daily_usd);
    try std.testing.expectEqualStrings("github.com/brackwater/secret", cfg.capture.exclude_projects[0]);
    try std.testing.expectEqualStrings("judge-model", cfg.eval.judge_model);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeMasked(&cfg, &out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "k-123") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jk-456") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "judge_api_key = \"<set>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ":pw@") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "postgres://graf:***@db.example.test:5432/graf") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[llm]") != null);
}

test "capy source section parses, takes env overrides and masks its key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: toml.Diagnostic = .{};
    var cfg = try parse(arena,
        \\[sources.capy]
        \\enabled = true
        \\projects = ["proj-a", "WID"]
        \\exclude_threads = ["jam_secret"]
        \\discover_every_s = 30
        \\
    , &diag);

    try std.testing.expect(cfg.sources.capy.enabled);
    try std.testing.expect(!cfg.capyEnabled());
    try std.testing.expectEqual(@as(u32, 30), cfg.sources.capy.discover_every_s);
    try std.testing.expectEqualStrings("WID", cfg.sources.capy.projects[1]);
    try std.testing.expectEqualStrings("https://api.capy.ai/api/v1", cfg.sources.capy.base_url);

    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GRAF_CAPY_API_KEY", "capy_k-789");
    try env.put("GRAF_CAPY_BASE_URL", "http://127.0.0.1:9/api/v1");

    applyEnv(&cfg, &env);

    try std.testing.expect(cfg.capyEnabled());
    try std.testing.expectEqualStrings("http://127.0.0.1:9/api/v1", cfg.sources.capy.base_url);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeMasked(&cfg, &out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "capy_k-789") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[sources.capy]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "api_key = \"<set>\"") != null);
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

test "per-route limits and the rate table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var diag: toml.Diagnostic = .{};
    const cfg = try parse(arena_state.allocator(),
        \\[llm]
        \\rpm = 500
        \\input_tpm = 200000
        \\rates = ["model-a input=1.25 output=10 cache_read=0.125", "model-b input=0.02 output=0"]
        \\[embed]
        \\rpm = 3000
        \\[decision]
        \\input_tpm = 50000
        \\
    , &diag);

    try std.testing.expectEqual(@as(u32, 500), cfg.llm.rpm);
    try std.testing.expectEqual(@as(u32, 200_000), cfg.llm.input_tpm);
    try std.testing.expectEqual(@as(u32, 3000), cfg.embed.rpm);
    try std.testing.expectEqual(@as(u32, 0), cfg.embed.input_tpm);
    try std.testing.expectEqual(@as(u32, 50_000), cfg.decision.input_tpm);

    const a = try parseRate(cfg.llm.rates[0]);
    try std.testing.expectEqualStrings("model-a", a.model);
    try std.testing.expectEqual(@as(f64, 10), a.output_per_mtok);
    try std.testing.expectEqual(@as(f64, 0.125), a.cache_read_per_mtok);
    try std.testing.expectEqual(@as(f64, 0), (try parseRate(cfg.llm.rates[1])).cache_write_per_mtok);

    try std.testing.expectError(error.InvalidRate, parseRate("model-c input=1"));
    try std.testing.expectError(error.InvalidRate, parseRate("model-c input=1 output=x"));
    try std.testing.expectError(error.InvalidRate, parseRate("model-c input=1 output=2 cached=1"));
    try std.testing.expectError(error.InvalidConfig, parse(arena_state.allocator(), "[llm]\nrates = [\"model-c input=-1 output=2\"]\n", &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "llm.rates") != null);
}

test "hub and edge settings come from the file and the environment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: toml.Diagnostic = .{};
    var cfg = try parse(arena, "[edge]\nupstream = \"https://hub.example.ts.net\"\ntimeout_ms = 2500\n", &diag);

    try std.testing.expectEqualStrings("https://hub.example.ts.net", cfg.edge.upstream);
    try std.testing.expectEqual(@as(u32, 2500), cfg.edge.timeout_ms);
    try std.testing.expectEqual(@as(u32, 10_000), (Config{}).edge.timeout_ms);

    var env = Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GRAF_SERVE_TOKEN", "serve-secret");
    try env.put("GRAF_UPSTREAM_URL", "https://other.example.ts.net");
    try env.put("GRAF_UPSTREAM_TOKEN", "edge-secret");

    applyEnv(&cfg, &env);
    try std.testing.expectEqualStrings("serve-secret", cfg.serve.token);
    try std.testing.expectEqualStrings("https://other.example.ts.net", cfg.edge.upstream);
    try std.testing.expectEqualStrings("edge-secret", cfg.edge.token);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeMasked(&cfg, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[edge]") != null);
}

test "decision wire format and cost header inheritance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var diag: toml.Diagnostic = .{};
    const cfg = try parse(arena_state.allocator(),
        \\[llm]
        \\cost_header = "x-cost-usd"
        \\[decision]
        \\base_url = "https://decide.example.test"
        \\wire = "stateful"
        \\
    , &diag);

    try std.testing.expectEqual(DecisionWire.stateful, cfg.decision.wire);
    try std.testing.expectEqualStrings("x-cost-usd", cfg.decision.cost_header);

    const defaults = try parse(arena_state.allocator(), "", &diag);
    try std.testing.expectEqual(DecisionWire.generic, defaults.decision.wire);
    try std.testing.expectError(error.InvalidConfig, parse(arena_state.allocator(), "[decision]\nwire = \"other\"\n", &diag));
}
