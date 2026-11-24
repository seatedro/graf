const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Kind = struct {
    env: []const u8,
    base: []const u8,
    markers: []const []const u8,
};

pub const claude: Kind = .{
    .env = "CLAUDE_CONFIG_DIR",
    .base = ".claude",
    .markers = &.{ "settings.json", ".claude.json", ".credentials.json", "projects" },
};

pub const codex: Kind = .{
    .env = "CODEX_HOME",
    .base = ".codex",
    .markers = &.{ "config.toml", "auth.json", "sessions" },
};

pub const Profile = struct {
    dir: []const u8,
    default: bool = false,
};

const backup_words = [_][]const u8{ "bak", "backup", "old", "orig", "tmp", "temp" };

pub fn discover(arena: Allocator, io: Io, home: []const u8, override: ?[]const u8, kind: Kind) ![]const Profile {
    var found: std.ArrayList(Profile) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    if (override) |dir| if (dir.len > 0) {
        try add(arena, io, &found, &seen, .{ .dir = try std.fs.path.resolveAlloc(arena, &.{dir}) });
    };

    for (try siblings(arena, io, home, kind)) |name| {
        const dir = try std.fs.path.join(arena, &.{ home, name });
        try add(arena, io, &found, &seen, .{ .dir = dir, .default = std.mem.eql(u8, name, kind.base) });
    }

    if (found.items.len == 0) try found.append(arena, .{ .dir = try std.fs.path.join(arena, &.{ home, kind.base }), .default = true });
    return found.items;
}

fn add(arena: Allocator, io: Io, found: *std.ArrayList(Profile), seen: *std.StringHashMapUnmanaged(void), profile: Profile) !void {
    const key = Io.Dir.cwd().realPathFileAlloc(io, profile.dir, arena) catch profile.dir;
    const entry = try seen.getOrPut(arena, key);
    if (entry.found_existing) return;

    try found.append(arena, profile);
}

fn siblings(arena: Allocator, io: Io, home: []const u8, kind: Kind) ![]const []const u8 {
    var dir = Io.Dir.cwd().openDir(io, home, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!isProfileName(entry.name, kind.base)) continue;
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        const st = dir.statFile(io, entry.name, .{}) catch continue;
        if (st.kind != .directory) continue;
        if (!std.mem.eql(u8, entry.name, kind.base) and !hasMarker(io, dir, entry.name, kind.markers)) continue;

        try names.append(arena, try arena.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn isProfileName(name: []const u8, base: []const u8) bool {
    if (!std.mem.startsWith(u8, name, base)) return false;
    if (std.mem.endsWith(u8, name, "~")) return false;

    var words = std.mem.tokenizeAny(u8, name[base.len..], "-_.");
    while (words.next()) |word| {
        for (backup_words) |b| if (std.ascii.eqlIgnoreCase(word, b)) return false;
    }
    return true;
}

fn hasMarker(io: Io, home: Io.Dir, name: []const u8, markers: []const []const u8) bool {
    var dir = home.openDir(io, name, .{}) catch return false;
    defer dir.close(io);

    for (markers) |marker| {
        dir.access(io, marker, .{}) catch continue;
        return true;
    }
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

test "profile names skip backups and unrelated prefixes" {
    try testing.expect(isProfileName(".claude", ".claude"));
    try testing.expect(isProfileName(".claude-work", ".claude"));
    try testing.expect(isProfileName(".codex_alt", ".codex"));
    try testing.expect(!isProfileName(".claude.bak", ".claude"));
    try testing.expect(!isProfileName(".claude-backup-2026", ".claude"));
    try testing.expect(!isProfileName(".codex.OLD", ".codex"));
    try testing.expect(!isProfileName(".claude-work~", ".claude"));
    try testing.expect(!isProfileName(".config", ".claude"));
}

test "discovery finds marked sibling profiles, the default, and the env override" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "home/.claude");
    try tmp.dir.createDirPath(io, "home/.claude-work/projects");
    try tmp.dir.createDirPath(io, "home/.claude-empty");
    try tmp.dir.createDirPath(io, "home/.claude.bak/projects");
    try tmp.dir.createDirPath(io, "elsewhere/claude");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.claude.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.claude.json.bak", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.claude-empty/notes.txt", .data = "" });
    try tmp.dir.symLink(io, ".claude-work", "home/.claude-link", .{ .is_directory = true });

    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const home = try std.fs.path.join(arena, &.{ base, "home" });
    const override = try std.fs.path.join(arena, &.{ base, "elsewhere", "claude/" });

    const found = try discover(arena, io, home, override, claude);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ base, "elsewhere", "claude" }), found[0].dir);
    try testing.expect(!found[0].default);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, ".claude" }), found[1].dir);
    try testing.expect(found[1].default);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, ".claude-link" }), found[2].dir);
}

test "discovery falls back to the default directory on a fresh home" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".codex-scratch");
    const home = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const found = try discover(arena, io, home, null, codex);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, ".codex" }), found[0].dir);
    try testing.expect(found[0].default);
}
