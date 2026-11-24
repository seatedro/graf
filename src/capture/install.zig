const std = @import("std");
const core = @import("core");
const json = @import("install_json.zig");
const profiles = @import("profiles.zig");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;
const Dir = std.Io.Dir;

pub const Options = struct {
    harnesses: []const core.Harness = &.{ .@"claude-code", .codex, .pi, .fx },
    command: []const u8 = "graf",
    dry_run: bool = false,
};

pub const Action = enum { create, update, unchanged, failed };

pub const FileReport = struct {
    harness: core.Harness,
    path: []const u8,
    action: Action,
    changes: []const []const u8 = &.{},
    backup: ?[]const u8 = null,
    failure: ?[]const u8 = null,
};

pub const Report = struct {
    dry_run: bool,
    files: []const FileReport,
    skipped: []const core.Harness,

    pub fn changed(r: Report) bool {
        for (r.files) |f| if (f.action == .create or f.action == .update) return true;
        return false;
    }

    pub fn failed(r: Report) bool {
        for (r.files) |f| if (f.action == .failed) return true;
        return false;
    }
};

pub const hook_timeout_seconds = 2;

const HookEvent = struct { name: []const u8, graf_event: []const u8 };

const hook_events = [_]HookEvent{
    .{ .name = "SessionStart", .graf_event = "session-start" },
    .{ .name = "UserPromptSubmit", .graf_event = "prompt-submit" },
    .{ .name = "Stop", .graf_event = "stop" },
    .{ .name = "SessionEnd", .graf_event = "session-end" },
};

const Edit = union(enum) {
    mcp_json: struct { keys: []const []const u8, stdio_type: bool },
    hooks_json: []const u8,
    codex_toml,
};

const Target = struct { path: []const u8, edit: Edit };

const Result = struct { text: []const u8, changes: []const []const u8 };

pub fn install(arena: Allocator, io: Io, env: *const Environ.Map, opts: Options, out: *std.Io.Writer) !Report {
    const home = env.get("HOME") orelse return error.HomeNotSet;
    var files: std.ArrayList(FileReport) = .empty;
    var skipped: std.ArrayList(core.Harness) = .empty;

    for (opts.harnesses) |harness| {
        const targets = try targetsFor(arena, io, env, home, harness) orelse {
            try skipped.append(arena, harness);
            try out.print("{s}: no local config to install into, skipped\n", .{@tagName(harness)});
            continue;
        };

        for (targets) |target| {
            const report = try apply(arena, io, opts, harness, target);
            try files.append(arena, report);
            try describe(out, opts.dry_run, report, home);
        }
    }

    return .{ .dry_run = opts.dry_run, .files = files.items, .skipped = skipped.items };
}

fn envDir(arena: Allocator, env: *const Environ.Map, name: []const u8, home: []const u8, fallback: []const []const u8) Allocator.Error![]const u8 {
    if (env.get(name)) |v| if (v.len > 0) return v;

    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(arena, home);
    try parts.appendSlice(arena, fallback);
    return std.fs.path.join(arena, parts.items);
}

fn targetsFor(arena: Allocator, io: Io, env: *const Environ.Map, home: []const u8, harness: core.Harness) !?[]const Target {
    const join = std.fs.path.join;
    return switch (harness) {
        .@"claude-code" => blk: {
            var targets: std.ArrayList(Target) = .empty;
            for (try profiles.discover(arena, io, home, env.get(profiles.claude.env), profiles.claude)) |profile| {
                const mcp_path = try join(arena, &.{ if (profile.default) home else profile.dir, ".claude.json" });
                try targets.appendSlice(arena, &.{
                    .{ .path = mcp_path, .edit = .{ .mcp_json = .{ .keys = &.{"mcpServers"}, .stdio_type = true } } },
                    .{ .path = try join(arena, &.{ profile.dir, "settings.json" }), .edit = .{ .hooks_json = "claude-code" } },
                });
            }
            break :blk targets.items;
        },
        .codex => blk: {
            var targets: std.ArrayList(Target) = .empty;
            for (try profiles.discover(arena, io, home, env.get(profiles.codex.env), profiles.codex)) |profile| {
                try targets.appendSlice(arena, &.{
                    .{ .path = try join(arena, &.{ profile.dir, "config.toml" }), .edit = .codex_toml },
                    .{ .path = try join(arena, &.{ profile.dir, "hooks.json" }), .edit = .{ .hooks_json = "codex" } },
                });
            }
            break :blk targets.items;
        },
        .pi => blk: {
            const pi_dir = try envDir(arena, env, "PI_CODING_AGENT_DIR", home, &.{ ".pi", "agent" });
            break :blk try arena.dupe(Target, &.{
                .{ .path = try join(arena, &.{ pi_dir, "mcp.json" }), .edit = .{ .mcp_json = .{ .keys = &.{"mcpServers"}, .stdio_type = false } } },
            });
        },
        .fx => blk: {
            const fx_home = try envDir(arena, env, "FX_HOME", home, &.{".fx"});
            break :blk try arena.dupe(Target, &.{
                .{ .path = try join(arena, &.{ fx_home, "mcp.json" }), .edit = .{ .mcp_json = .{ .keys = &.{ "mcp", "mcpServers" }, .stdio_type = false } } },
            });
        },
        else => null,
    };
}

fn apply(arena: Allocator, io: Io, opts: Options, harness: core.Harness, target: Target) !FileReport {
    var report: FileReport = .{ .harness = harness, .path = target.path, .action = .unchanged };
    const original: ?[]const u8 = Dir.cwd().readFileAlloc(io, target.path, arena, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| {
            report.action = .failed;
            report.failure = @errorName(e);
            return report;
        },
    };

    const result = edit(arena, original orelse "", target.edit, opts.command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => {
            report.action = .failed;
            report.failure = "not valid JSON, left untouched";
            return report;
        },
    };
    if (original != null and std.mem.eql(u8, original.?, result.text)) return report;

    report.action = if (original == null) .create else .update;
    report.changes = result.changes;
    if (original != null) report.backup = try std.mem.concat(arena, u8, &.{ target.path, ".bak" });
    if (opts.dry_run) return report;

    writeFile(io, target.path, original, report.backup, result.text) catch |err| {
        report.action = .failed;
        report.failure = @errorName(err);
    };

    return report;
}

fn writeFile(io: Io, path: []const u8, original: ?[]const u8, backup: ?[]const u8, text: []const u8) !void {
    const cwd = Dir.cwd();
    var permissions: Dir.Permissions = .fromMode(0o600);

    if (original) |old| {
        permissions = (try cwd.statFile(io, path, .{})).permissions;
        if (backup) |bak| {
            if (cwd.access(io, bak, .{})) |_| {} else |_| try cwd.writeFile(io, .{
                .sub_path = bak,
                .data = old,
                .flags = .{ .exclusive = true, .permissions = permissions },
            });
        }
    }

    var atomic = try cwd.createFileAtomic(io, path, .{ .permissions = permissions, .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, text);
    try atomic.replace(io);
}

fn edit(arena: Allocator, original: []const u8, e: Edit, command: []const u8) json.Error!Result {
    var changes: std.ArrayList([]const u8) = .empty;
    const blank = std.mem.trim(u8, original, " \t\r\n").len == 0;
    var text: []const u8 = switch (e) {
        .codex_toml => original,
        else => if (blank) "{}\n" else original,
    };

    switch (e) {
        .mcp_json => |m| text = if (m.stdio_type)
            try ensureMcpServer(arena, text, m.keys, StdioServer{ .command = command }, &changes)
        else
            try ensureMcpServer(arena, text, m.keys, PlainServer{ .command = command }, &changes),
        .hooks_json => |harness| for (hook_events) |event| {
            text = try ensureHook(arena, text, harness, event, command, &changes);
        },
        .codex_toml => text = try ensureCodexToml(arena, text, command, &changes),
    }

    if (e != .codex_toml) _ = try json.root(text);
    return .{ .text = text, .changes = changes.items };
}

const mcp_args: []const []const u8 = &.{"mcp"};
const StdioServer = struct { type: []const u8 = "stdio", command: []const u8, args: []const []const u8 = mcp_args };
const PlainServer = struct { command: []const u8, args: []const []const u8 = mcp_args };

fn ensureMcpServer(arena: Allocator, text: []const u8, keys: []const []const u8, server: anytype, changes: *std.ArrayList([]const u8)) json.Error![]const u8 {
    const doc = try json.root(text);
    if (!json.isObject(text, doc)) return error.InvalidJson;

    var servers: ?json.Member = null;
    for (keys) |key| if (try json.find(arena, text, doc, key)) |m| {
        servers = m;
        break;
    };
    const servers_member = servers orelse {
        try changes.append(arena, try std.fmt.allocPrint(arena, "add {s}.graf", .{keys[0]}));
        return json.insertMember(arena, text, doc, keys[0], .{ .graf = server });
    };
    if (!json.isObject(text, servers_member.value)) return error.InvalidJson;

    const existing = try json.find(arena, text, servers_member.value, "graf") orelse {
        try changes.append(arena, try std.fmt.allocPrint(arena, "add {s}.graf", .{servers_member.key}));
        return json.insertMember(arena, text, servers_member.value, "graf", server);
    };

    if (try serverMatches(arena, text, existing.value, server.command)) return text;
    try changes.append(arena, try std.fmt.allocPrint(arena, "update {s}.graf", .{servers_member.key}));
    return json.replaceValue(arena, text, existing.value, server);
}

fn serverMatches(arena: Allocator, text: []const u8, value: json.Span, command: []const u8) json.Error!bool {
    if (!json.isObject(text, value)) return false;
    const cmd = try json.find(arena, text, value, "command") orelse return false;
    const cmd_text = try json.stringValue(arena, text, cmd.value) orelse return false;
    if (!std.mem.eql(u8, cmd_text, command)) return false;

    const args = try json.find(arena, text, value, "args") orelse return false;
    if (!json.isArray(text, args.value)) return false;
    const items = try json.elements(arena, text, args.value);
    if (items.len != 1) return false;
    const first = try json.stringValue(arena, text, items[0]) orelse return false;
    return std.mem.eql(u8, first, "mcp");
}

const HookHandler = struct { type: []const u8 = "command", command: []const u8, timeout: u32 = hook_timeout_seconds };
const HookGroup = struct { hooks: []const HookHandler };

pub fn hookCommand(arena: Allocator, command: []const u8, harness: []const u8, graf_event: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s} hook {s} {s}", .{ try shellQuote(arena, command), harness, graf_event });
}

fn shellQuote(arena: Allocator, word: []const u8) Allocator.Error![]const u8 {
    for (word) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_-./:+=@%,~", ch) != null)) break;
    } else if (word.len > 0) return word;

    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (word) |ch| {
        if (ch == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, ch);
    }
    try out.append(arena, '\'');
    return out.items;
}

fn ensureHook(arena: Allocator, text: []const u8, harness: []const u8, event: HookEvent, command: []const u8, changes: *std.ArrayList([]const u8)) json.Error![]const u8 {
    const desired = try hookCommand(arena, command, harness, event.graf_event);
    const suffix = try std.fmt.allocPrint(arena, " hook {s} {s}", .{ harness, event.graf_event });
    const group = HookGroup{ .hooks = &.{.{ .command = desired }} };

    const doc = try json.root(text);
    if (!json.isObject(text, doc)) return error.InvalidJson;
    const hooks = try json.find(arena, text, doc, "hooks") orelse {
        try changes.append(arena, try std.fmt.allocPrint(arena, "add hooks.{s}", .{event.name}));
        var map: std.json.ArrayHashMap([]const HookGroup) = .{};
        try map.map.put(arena, event.name, &.{group});
        return json.insertMember(arena, text, doc, "hooks", map);
    };

    if (!json.isObject(text, hooks.value)) return error.InvalidJson;
    const list = try json.find(arena, text, hooks.value, event.name) orelse {
        try changes.append(arena, try std.fmt.allocPrint(arena, "add hooks.{s}", .{event.name}));
        return json.insertMember(arena, text, hooks.value, event.name, [_]HookGroup{group});
    };
    if (!json.isArray(text, list.value)) return error.InvalidJson;

    for (try json.elements(arena, text, list.value)) |g| {
        if (!json.isObject(text, g)) continue;
        const handlers = try json.find(arena, text, g, "hooks") orelse continue;
        if (!json.isArray(text, handlers.value)) continue;
        for (try json.elements(arena, text, handlers.value)) |h| {
            if (!json.isObject(text, h)) continue;
            const cmd = try json.find(arena, text, h, "command") orelse continue;
            const cmd_text = try json.stringValue(arena, text, cmd.value) orelse continue;
            if (std.mem.eql(u8, cmd_text, desired)) return text;
            if (std.mem.endsWith(u8, cmd_text, suffix)) {
                try changes.append(arena, try std.fmt.allocPrint(arena, "update hooks.{s} command", .{event.name}));
                return json.replaceValue(arena, text, cmd.value, desired);
            }
        }
    }

    try changes.append(arena, try std.fmt.allocPrint(arena, "add hooks.{s}", .{event.name}));
    return json.appendElement(arena, text, list.value, group);
}

fn ensureCodexToml(arena: Allocator, text: []const u8, command: []const u8, changes: *std.ArrayList([]const u8)) Allocator.Error![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOfScalar(u8, line, '#')) |hash| line = std.mem.trimEnd(u8, line[0..hash], " \t");
        if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') continue;
        const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
        if (std.mem.eql(u8, name, "mcp_servers.graf") or std.mem.eql(u8, name, "mcp_servers.\"graf\"")) return text;
    }

    try changes.append(arena, "add [mcp_servers.graf]");
    const sep: []const u8 = if (text.len == 0) "" else if (std.mem.endsWith(u8, text, "\n")) "\n" else "\n\n";
    return std.fmt.allocPrint(arena, "{s}{s}[mcp_servers.graf]\ncommand = {f}\nargs = [\"mcp\"]\n", .{ text, sep, std.json.fmt(command, .{}) });
}

fn describe(out: *std.Io.Writer, dry_run: bool, r: FileReport, home: []const u8) !void {
    const shown = if (std.mem.startsWith(u8, r.path, home) and r.path.len > home.len and r.path[home.len] == '/') r.path[home.len..] else r.path;
    const tilde: []const u8 = if (shown.ptr != r.path.ptr) "~" else "";

    const verb: []const u8 = switch (r.action) {
        .create => if (dry_run) "would create" else "created",
        .update => if (dry_run) "would update" else "updated",
        .unchanged => "unchanged",
        .failed => "failed",
    };

    try out.print("{s}: {s} {s}{s}", .{ @tagName(r.harness), verb, tilde, shown });
    if (r.changes.len > 0) {
        try out.writeAll(" (");
        for (r.changes, 0..) |change, i| try out.print("{s}{s}", .{ if (i == 0) "" else ", ", change });
        try out.writeAll(")");
    }

    if (r.failure) |f| try out.print(": {s}", .{f});
    try out.writeByte('\n');
}

const testing = std.testing;

const Home = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    home: []const u8,
    env: Environ.Map,
    out: std.Io.Writer.Allocating,

    fn init(h: *Home) !void {
        h.arena_state = .init(testing.allocator);
        h.tmp = testing.tmpDir(.{});
        h.home = try h.tmp.dir.realPathFileAlloc(testing.io, ".", h.arena_state.allocator());

        h.env = .init(testing.allocator);
        try h.env.put("HOME", h.home);
        h.out = .init(h.arena_state.allocator());
    }

    fn deinit(h: *Home) void {
        h.env.deinit();
        h.tmp.cleanup();
        h.arena_state.deinit();
    }

    fn run(h: *Home, opts: Options) !Report {
        h.out.clearRetainingCapacity();
        return install(h.arena_state.allocator(), testing.io, &h.env, opts, &h.out.writer);
    }

    fn read(h: *Home, sub: []const u8) ![]const u8 {
        return h.tmp.dir.readFileAlloc(testing.io, sub, h.arena_state.allocator(), .limited(1 << 20));
    }

    fn exists(h: *Home, sub: []const u8) bool {
        h.tmp.dir.access(testing.io, sub, .{}) catch return false;
        return true;
    }

    fn write(h: *Home, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |parent| try h.tmp.dir.createDirPath(testing.io, parent);
        try h.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    fn snapshot(h: *Home, subs: []const []const u8) ![]const []const u8 {
        const arena = h.arena_state.allocator();
        const texts = try arena.alloc([]const u8, subs.len);
        for (subs, texts) |sub, *t| t.* = try h.read(sub);
        return texts;
    }
};

const all_files = [_][]const u8{
    ".claude.json",
    ".claude/settings.json",
    ".codex/config.toml",
    ".codex/hooks.json",
    ".pi/agent/mcp.json",
    ".fx/mcp.json",
};

fn expectHooks(arena: Allocator, text: []const u8, harness: []const u8, command: []const u8) !void {
    const Doc = struct { hooks: std.json.ArrayHashMap([]const struct { hooks: []const struct { type: []const u8, command: []const u8, timeout: u32 } }) };
    const doc = try std.json.parseFromSliceLeaky(Doc, arena, text, .{ .ignore_unknown_fields = true });

    for (hook_events) |event| {
        const groups = doc.hooks.map.get(event.name) orelse return error.MissingHookEvent;
        var found = false;
        for (groups) |g| for (g.hooks) |hk| {
            if (std.mem.eql(u8, hk.command, try hookCommand(arena, command, harness, event.graf_event))) {
                try testing.expectEqualStrings("command", hk.type);
                found = true;
            }
        };
        try testing.expect(found);
    }
}

test "fresh install writes every harness config, then a re-run changes nothing" {
    var h: Home = undefined;
    try h.init();
    defer h.deinit();
    const arena = h.arena_state.allocator();

    const first = try h.run(.{});
    try testing.expect(first.changed());
    try testing.expect(!first.failed());
    try testing.expectEqual(@as(usize, all_files.len), first.files.len);
    for (first.files) |f| try testing.expectEqual(Action.create, f.action);

    const Server = struct { type: ?[]const u8 = null, command: []const u8, args: []const []const u8 };
    const claude = try std.json.parseFromSliceLeaky(struct { mcpServers: struct { graf: Server } }, arena, try h.read(".claude.json"), .{});
    try testing.expectEqualStrings("stdio", claude.mcpServers.graf.type.?);
    try testing.expectEqualStrings("graf", claude.mcpServers.graf.command);
    try testing.expectEqualStrings("mcp", claude.mcpServers.graf.args[0]);

    try expectHooks(arena, try h.read(".claude/settings.json"), "claude-code", "graf");
    try expectHooks(arena, try h.read(".codex/hooks.json"), "codex", "graf");
    try testing.expectEqualStrings("[mcp_servers.graf]\ncommand = \"graf\"\nargs = [\"mcp\"]\n", try h.read(".codex/config.toml"));

    const pi = try std.json.parseFromSliceLeaky(struct { mcpServers: struct { graf: Server } }, arena, try h.read(".pi/agent/mcp.json"), .{});
    try testing.expectEqualStrings("graf", pi.mcpServers.graf.command);
    try testing.expect(pi.mcpServers.graf.type == null);

    const fx = try std.json.parseFromSliceLeaky(struct { mcp: struct { graf: Server } }, arena, try h.read(".fx/mcp.json"), .{});
    try testing.expectEqualStrings("mcp", fx.mcp.graf.args[0]);

    for (all_files) |f| try testing.expect(!h.exists(try std.mem.concat(arena, u8, &.{ f, ".bak" })));

    const before = try h.snapshot(&all_files);
    const second = try h.run(.{});
    try testing.expect(!second.changed());
    for (second.files) |f| try testing.expectEqual(Action.unchanged, f.action);

    const after = try h.snapshot(&all_files);
    for (before, after) |b, a| try testing.expectEqualStrings(b, a);
}

test "existing entries are preserved byte-for-byte and backed up once" {
    var h: Home = undefined;
    try h.init();
    defer h.deinit();
    const arena = h.arena_state.allocator();

    const claude_json =
        \\{
        \\    "numStartups": 12,
        \\    "mcpServers": {
        \\        "brackwater-docs": {"type": "http", "url": "https://mcp.example.test/mcp"}
        \\    },
        \\    "projects": {"/work/brackwater": {"allowedTools": []}}
        \\}
        \\
    ;

    const settings_json =
        \\{
        \\  "model": "some-model",
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {
        \\        "matcher": "startup",
        \\        "hooks": [{"type": "command", "command": "echo hi", "timeout": 3}]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const codex_toml = "model = \"some-model\"\n\n[mcp_servers.brackwater]\ncommand = \"brackwater-mcp\"";
    const fx_json = "{\"mcpServers\":{\"brackwater\":{\"command\":\"brackwater-mcp\"}}}";

    try h.write(".claude.json", claude_json);
    try h.write(".claude/settings.json", settings_json);
    try h.write(".codex/config.toml", codex_toml);
    try h.write(".fx/mcp.json", fx_json);

    const report = try h.run(.{ .harnesses = &.{ .@"claude-code", .codex, .fx } });
    try testing.expect(!report.failed());

    const claude = try h.read(".claude.json");
    try testing.expect(std.mem.startsWith(u8, claude,
        \\{
        \\    "numStartups": 12,
        \\    "mcpServers": {
        \\        "brackwater-docs": {"type": "http", "url": "https://mcp.example.test/mcp"},
        \\        "graf": {
        \\            "type": "stdio",
    ));
    try testing.expect(std.mem.endsWith(u8, claude,
        \\    },
        \\    "projects": {"/work/brackwater": {"allowedTools": []}}
        \\}
        \\
    ));
    try testing.expectEqualStrings(claude_json, try h.read(".claude.json.bak"));

    const settings = try h.read(".claude/settings.json");
    try testing.expect(std.mem.indexOf(u8, settings, "{\"type\": \"command\", \"command\": \"echo hi\", \"timeout\": 3}") != null);
    try testing.expect(std.mem.indexOf(u8, settings, "\"matcher\": \"startup\"") != null);
    try expectHooks(arena, settings, "claude-code", "graf");
    try testing.expectEqualStrings(settings_json, try h.read(".claude/settings.json.bak"));

    try testing.expectEqualStrings(codex_toml ++ "\n\n[mcp_servers.graf]\ncommand = \"graf\"\nargs = [\"mcp\"]\n", try h.read(".codex/config.toml"));
    try testing.expectEqualStrings(codex_toml, try h.read(".codex/config.toml.bak"));
    try testing.expect(!h.exists(".codex/hooks.json.bak"));

    try testing.expectEqualStrings("{\"mcpServers\":{\"brackwater\":{\"command\":\"brackwater-mcp\"}, \"graf\": {\"command\":\"graf\",\"args\":[\"mcp\"]}}}", try h.read(".fx/mcp.json"));

    const moved = try h.run(.{ .harnesses = &.{.@"claude-code"}, .command = "/opt/brackwater tools/graf" });
    try testing.expectEqual(Action.update, moved.files[0].action);
    try testing.expectEqual(Action.update, moved.files[1].action);

    try testing.expectEqualStrings(claude_json, try h.read(".claude.json.bak"));
    try expectHooks(arena, try h.read(".claude/settings.json"), "claude-code", "/opt/brackwater tools/graf");
    try testing.expect(std.mem.indexOf(u8, try h.read(".claude/settings.json"), "\"command\": \"'/opt/brackwater tools/graf' hook claude-code stop\"") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, try h.read(".claude/settings.json"), "hook claude-code stop"));

    const again = try h.run(.{ .harnesses = &.{.@"claude-code"}, .command = "/opt/brackwater tools/graf" });
    try testing.expect(!again.changed());
}

test "dry run reports planned edits and writes nothing" {
    var h: Home = undefined;
    try h.init();
    defer h.deinit();

    try h.write(".pi/agent/mcp.json", "{\"mcpServers\": {}}\n");
    const report = try h.run(.{ .dry_run = true });
    try testing.expect(report.changed());
    try testing.expect(report.dry_run);

    for (all_files) |f| {
        if (std.mem.eql(u8, f, ".pi/agent/mcp.json")) continue;
        try testing.expect(!h.exists(f));
    }
    try testing.expectEqualStrings("{\"mcpServers\": {}}\n", try h.read(".pi/agent/mcp.json"));
    try testing.expect(!h.exists(".pi/agent/mcp.json.bak"));

    const text = h.out.written();
    try testing.expect(std.mem.indexOf(u8, text, "claude-code: would create ~/.claude.json (add mcpServers.graf)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pi: would update ~/.pi/agent/mcp.json (add mcpServers.graf)\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "codex: would create ~/.codex/hooks.json (add hooks.SessionStart, add hooks.UserPromptSubmit, add hooks.Stop, add hooks.SessionEnd)\n") != null);
}

test "invalid JSON is left untouched and unsupported harnesses are skipped" {
    var h: Home = undefined;
    try h.init();
    defer h.deinit();

    try h.write(".pi/agent/mcp.json", "{ \"mcpServers\": { // comment\n } }");
    const report = try h.run(.{ .harnesses = &.{ .pi, .cli } });

    try testing.expect(report.failed());
    try testing.expectEqual(Action.failed, report.files[0].action);
    try testing.expectEqual(core.Harness.cli, report.skipped[0]);
    try testing.expectEqualStrings("{ \"mcpServers\": { // comment\n } }", try h.read(".pi/agent/mcp.json"));
}

test "harness home overrides from the environment" {
    var h: Home = undefined;
    try h.init();
    defer h.deinit();

    const arena = h.arena_state.allocator();
    try h.env.put("CODEX_HOME", try std.fs.path.join(arena, &.{ h.home, "alt-codex" }));
    try h.env.put("CLAUDE_CONFIG_DIR", try std.fs.path.join(arena, &.{ h.home, "alt-claude" }));

    _ = try h.run(.{ .harnesses = &.{ .@"claude-code", .codex } });

    try testing.expect(h.exists("alt-codex/config.toml"));
    try testing.expect(h.exists("alt-codex/hooks.json"));
    try testing.expect(h.exists("alt-claude/.claude.json"));
    try testing.expect(h.exists("alt-claude/settings.json"));
    try testing.expect(!h.exists(".claude.json"));
}

test "every claude and codex profile directory is wired in one run" {
    var h: Home = undefined;
    try h.init();
    defer h.deinit();
    const arena = h.arena_state.allocator();

    try h.write(".claude/settings.json", "{}\n");
    try h.write(".claude-work/.claude.json", "{\"numStartups\": 3}\n");
    try h.write(".codex/auth.json", "{}\n");
    try h.write(".codex-alt/sessions/2026/11/24/rollout-x.jsonl", "");
    try h.write(".claude.json.bak", "{\"old\": true}\n");
    try h.write(".claude-backup/settings.json", "{}\n");
    try h.write(".claude-router/config.json", "{}\n");
    try h.write(".codexrc", "");

    const report = try h.run(.{ .harnesses = &.{ .@"claude-code", .codex } });
    try testing.expect(!report.failed());
    try testing.expectEqual(@as(usize, 8), report.files.len);

    const Server = struct { type: ?[]const u8 = null, command: []const u8, args: []const []const u8 };
    const Mcp = struct { mcpServers: struct { graf: Server } };
    for ([_][]const u8{ ".claude.json", ".claude-work/.claude.json" }) |sub| {
        const doc = try std.json.parseFromSliceLeaky(Mcp, arena, try h.read(sub), .{ .ignore_unknown_fields = true });
        try testing.expectEqualStrings("graf", doc.mcpServers.graf.command);
    }
    for ([_][]const u8{ ".claude/settings.json", ".claude-work/settings.json" }) |sub| try expectHooks(arena, try h.read(sub), "claude-code", "graf");
    for ([_][]const u8{ ".codex", ".codex-alt" }) |dir| {
        try expectHooks(arena, try h.read(try std.fs.path.join(arena, &.{ dir, "hooks.json" })), "codex", "graf");
        try testing.expectEqualStrings("[mcp_servers.graf]\ncommand = \"graf\"\nargs = [\"mcp\"]\n", try h.read(try std.fs.path.join(arena, &.{ dir, "config.toml" })));
    }

    try testing.expect(!h.exists(".claude/.claude.json"));
    try testing.expectEqualStrings("{\"old\": true}\n", try h.read(".claude.json.bak"));
    try testing.expectEqualStrings("{}\n", try h.read(".claude-backup/settings.json"));
    try testing.expect(!h.exists(".claude-backup/.claude.json"));
    try testing.expect(!h.exists(".claude-router/settings.json"));
    try testing.expect(!h.exists(".claude-router/.claude.json"));

    const again = try h.run(.{ .harnesses = &.{ .@"claude-code", .codex } });
    try testing.expect(!again.changed());
}

test "an env override outside home joins the discovered profiles" {
    var h: Home = undefined;
    try h.init();
    defer h.deinit();

    const arena = h.arena_state.allocator();
    try h.write(".claude/settings.json", "{}\n");
    try h.write(".codex/config.toml", "");
    try h.env.put("CLAUDE_CONFIG_DIR", try std.fs.path.join(arena, &.{ h.home, "elsewhere", "claude" }));
    try h.env.put("CODEX_HOME", try std.fs.path.join(arena, &.{ h.home, "elsewhere", "codex" }));

    const report = try h.run(.{ .harnesses = &.{ .@"claude-code", .codex } });
    try testing.expectEqual(@as(usize, 8), report.files.len);

    try testing.expect(h.exists("elsewhere/claude/.claude.json"));
    try testing.expect(h.exists("elsewhere/claude/settings.json"));
    try testing.expect(h.exists(".claude.json"));
    try testing.expect(h.exists("elsewhere/codex/hooks.json"));
    try testing.expect(h.exists(".codex/hooks.json"));
}

test {
    _ = json;
}
