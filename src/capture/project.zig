const std = @import("std");
const core = @import("core");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

const max_git_file_bytes = 1 << 20;

pub fn derive(arena: Allocator, io: std.Io, cwd: []const u8) Allocator.Error![]const u8 {
    const clean = try std.fs.path.resolveAlloc(arena, &.{cwd});
    const root = try gitRoot(arena, io, clean) orelse return clean;
    const config_path = try gitConfigPath(arena, io, root) orelse return clean;

    const text = Dir.cwd().readFileAlloc(io, config_path, arena, .limited(max_git_file_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return clean,
    };

    const url = try remoteUrl(arena, text) orelse return clean;
    return try normalizeRemote(arena, url) orelse clean;
}

pub fn gitRoot(arena: Allocator, io: std.Io, cwd: []const u8) Allocator.Error!?[]const u8 {
    var current: []const u8 = try std.fs.path.resolveAlloc(arena, &.{cwd});
    while (true) {
        const dot_git = try std.fs.path.join(arena, &.{ current, ".git" });
        if (Dir.cwd().statFile(io, dot_git, .{})) |st| {
            if (st.kind == .directory or st.kind == .file) return current;
        } else |_| {}
        current = std.fs.path.dirname(current) orelse return null;
    }
}

fn gitConfigPath(arena: Allocator, io: std.Io, root: []const u8) Allocator.Error!?[]const u8 {
    const dot_git = try std.fs.path.join(arena, &.{ root, ".git" });
    const st = Dir.cwd().statFile(io, dot_git, .{}) catch return null;
    if (st.kind == .directory) return try std.fs.path.join(arena, &.{ dot_git, "config" });

    const pointer = (try readSmall(arena, io, dot_git)) orelse return null;
    const trimmed = std.mem.trim(u8, pointer, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;
    const target = std.mem.trim(u8, trimmed["gitdir:".len..], " \t");
    const gitdir = try std.fs.path.resolveAlloc(arena, &.{ root, target });

    const commondir_file = try std.fs.path.join(arena, &.{ gitdir, "commondir" });
    if (try readSmall(arena, io, commondir_file)) |common| {
        const common_dir = try std.fs.path.resolveAlloc(arena, &.{ gitdir, std.mem.trim(u8, common, " \t\r\n") });
        return try std.fs.path.join(arena, &.{ common_dir, "config" });
    }
    return try std.fs.path.join(arena, &.{ gitdir, "config" });
}

fn readSmall(arena: Allocator, io: std.Io, path: []const u8) Allocator.Error!?[]const u8 {
    return Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

pub fn remoteUrl(arena: Allocator, config_text: []const u8) Allocator.Error!?[]const u8 {
    var first: ?[]const u8 = null;
    var section_remote: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, config_text, '\n');

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            section_remote = parseRemoteHeader(line);
            continue;
        }

        const remote = section_remote orelse continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..eq], " \t"), "url")) continue;
        const value = try configValue(arena, line[eq + 1 ..]);
        if (value.len == 0) continue;
        if (std.mem.eql(u8, remote, "origin")) return value;
        if (first == null) first = value;
    }

    return first;
}

fn parseRemoteHeader(line: []const u8) ?[]const u8 {
    const close = std.mem.lastIndexOfScalar(u8, line, ']') orelse return null;
    const inner = std.mem.trim(u8, line[1..close], " \t");
    const space = std.mem.indexOfAny(u8, inner, " \t") orelse return null;
    if (!std.ascii.eqlIgnoreCase(inner[0..space], "remote")) return null;
    const sub = std.mem.trim(u8, inner[space..], " \t");
    if (sub.len < 2 or sub[0] != '"' or sub[sub.len - 1] != '"') return null;
    return sub[1 .. sub.len - 1];
}

fn configValue(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_quotes = false;
    var i: usize = 0;
    const text = std.mem.trim(u8, raw, " \t");

    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (c) {
            '"' => in_quotes = !in_quotes,
            '\\' => if (i + 1 < text.len) {
                i += 1;
                try out.append(arena, switch (text[i]) {
                    'n' => '\n',
                    't' => '\t',
                    else => text[i],
                });
            },
            '#', ';' => if (in_quotes) try out.append(arena, c) else break,
            else => try out.append(arena, c),
        }
    }

    return std.mem.trim(u8, out.items, " \t");
}

pub fn normalizeRemote(arena: Allocator, url_in: []const u8) Allocator.Error!?[]const u8 {
    const url = std.mem.trim(u8, url_in, " \t\r\n");
    var host: []const u8 = undefined;
    var path: []const u8 = undefined;

    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        if (std.ascii.eqlIgnoreCase(url[0..scheme_end], "file")) return null;
        const rest = url[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        var authority = rest[0..slash];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
        host = stripPort(authority);
        path = rest[slash..];
    } else {
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
        if (std.mem.indexOfScalar(u8, url[0..colon], '/') != null) return null;
        var authority = url[0..colon];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
        host = authority;
        path = url[colon + 1 ..];
    }

    if (std.mem.indexOfAny(u8, path, "?#")) |cut| path = path[0..cut];
    path = std.mem.trim(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    path = std.mem.trimEnd(u8, path, "/");
    if (host.len == 0 or path.len == 0) return null;

    const lower = try std.ascii.allocLowerString(arena, host);
    return try std.fmt.allocPrint(arena, "{s}/{s}", .{ lower, path });
}

fn stripPort(authority: []const u8) []const u8 {
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return authority;
        return authority[0 .. close + 1];
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return authority;
    return authority[0..colon];
}

pub const Exclusion = struct {
    cwd: ?[]const u8 = null,
    project: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

pub fn isExcluded(arena: Allocator, io: std.Io, config: *const core.Config, what: Exclusion) Allocator.Error!bool {
    const patterns = config.capture.exclude_projects;
    if (patterns.len > 0) {
        const project = what.project orelse if (what.cwd) |cwd| try derive(arena, io, cwd) else null;
        if (project) |p| for (patterns) |pattern| {
            if (globMatch(pattern, p)) return true;
        };
    }

    for (config.capture.exclude_paths) |entry| {
        const base = try expandPath(arena, entry, what.home) orelse continue;
        if (what.cwd) |cwd| if (isWithin(try std.fs.path.resolveAlloc(arena, &.{cwd}), base)) return true;
        if (what.transcript_path) |tp| if (isWithin(try std.fs.path.resolveAlloc(arena, &.{tp}), base)) return true;
    }

    if (what.cwd) |cwd| if (try gitRoot(arena, io, cwd)) |root| {
        const marker = try std.fs.path.join(arena, &.{ root, ".grafignore" });
        if (Dir.cwd().access(io, marker, .{})) |_| return true else |_| {}
    };
    return false;
}

pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var resume_at: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            resume_at = t;
        } else if (p < pattern.len and pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (star) |s| {
            p = s + 1;
            resume_at += 1;
            t = resume_at;
        } else return false;
    }

    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn expandPath(arena: Allocator, entry: []const u8, home: ?[]const u8) Allocator.Error!?[]const u8 {
    if (entry.len == 0) return null;
    var path = entry;
    if (std.mem.eql(u8, entry, "~") or std.mem.startsWith(u8, entry, "~/")) {
        const h = home orelse return null;
        path = try std.mem.concat(arena, u8, &.{ h, entry[1..] });
    }

    if (!std.fs.path.isAbsolute(path)) return null;
    return try std.fs.path.resolveAlloc(arena, &.{path});
}

fn isWithin(path: []const u8, base: []const u8) bool {
    if (std.mem.eql(u8, base, "/")) return true;
    if (!std.mem.startsWith(u8, path, base)) return false;
    return path.len == base.len or path[base.len] == '/';
}

const testing = std.testing;

test "normalizeRemote handles scp, https, ssh with port, and credentials" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_][2][]const u8{
        .{ "git@github.com:brackwater/widgets.git", "github.com/brackwater/widgets" },
        .{ "https://github.com/brackwater/widgets", "github.com/brackwater/widgets" },
        .{ "https://github.com/brackwater/widgets.git", "github.com/brackwater/widgets" },
        .{ "https://GitHub.com/brackwater/widgets/", "github.com/brackwater/widgets" },
        .{ "ssh://git@git.example.test:2222/brackwater/widgets.git", "git.example.test/brackwater/widgets" },
        .{ "https://user:tok-123@git.example.test/brackwater/widgets", "git.example.test/brackwater/widgets" },
        .{ "https://git.example.test:8443/group/sub/widgets.git/", "git.example.test/group/sub/widgets" },
        .{ "git.example.test:brackwater/widgets", "git.example.test/brackwater/widgets" },
    };

    for (cases) |c| {
        const got = (try normalizeRemote(arena, c[0])) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(c[1], got);
        try testing.expect(std.mem.indexOf(u8, got, "tok-123") == null);
    }

    try testing.expect((try normalizeRemote(arena, "/srv/repos/widgets.git")) == null);
    try testing.expect((try normalizeRemote(arena, "file:///srv/repos/widgets.git")) == null);
}

test "remoteUrl prefers origin, else the first remote" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const with_origin =
        \\[core]
        \\    bare = false
        \\[remote "upstream"]
        \\    url = https://git.example.test/upstream/widgets.git
        \\[remote "origin"]
        \\    url = "git@git.example.test:brackwater/widgets.git" ; comment
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
    ;
    try testing.expectEqualStrings("git@git.example.test:brackwater/widgets.git", (try remoteUrl(arena, with_origin)).?);

    const without_origin =
        \\[remote "fork"]
        \\    URL = https://git.example.test/fork/widgets
        \\[remote "other"]
        \\    url = https://git.example.test/other/widgets
        \\
    ;
    try testing.expectEqualStrings("https://git.example.test/fork/widgets", (try remoteUrl(arena, without_origin)).?);
    try testing.expect((try remoteUrl(arena, "[core]\n\tbare = false\n")) == null);
}

test "globMatch" {
    try testing.expect(globMatch("github.com/brackwater/*", "github.com/brackwater/widgets"));
    try testing.expect(globMatch("github.com/brackwater/widgets", "github.com/brackwater/widgets"));
    try testing.expect(!globMatch("github.com/brackwater/widgets", "github.com/brackwater/widgets2"));
    try testing.expect(!globMatch("github.com/brackwater/*", "github.com/other/widgets"));
    try testing.expect(globMatch("*/secret-*", "git.example.test/secret-plans"));
    try testing.expect(globMatch("*", "anything"));
}

const Fixture = struct {
    arena: Allocator,
    root: []const u8,
    dir: Dir,

    fn write(f: Fixture, sub_path: []const u8, data: []const u8) !void {
        const io = testing.io;
        if (std.fs.path.dirname(sub_path)) |parent| try f.dir.createDirPath(io, parent);
        try f.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }

    fn path(f: Fixture, sub_path: []const u8) ![]const u8 {
        return std.fs.path.join(f.arena, &.{ f.root, sub_path });
    }
};

test "derive walks to the git root, follows worktrees, falls back to cwd" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f: Fixture = .{ .arena = arena, .root = try tmp.dir.realPathFileAlloc(io, ".", arena), .dir = tmp.dir };

    try f.write("main/.git/config", "[remote \"origin\"]\n\turl = https://bot:secret@Git.Example.Test/brackwater/widgets.git\n");
    try f.write("main/src/deep/file.txt", "");
    try testing.expectEqualStrings("git.example.test/brackwater/widgets", try derive(arena, io, try f.path("main/src/deep")));
    try testing.expectEqualStrings(try f.path("main"), (try gitRoot(arena, io, try f.path("main/src/deep"))).?);

    try f.write("main/.git/worktrees/feature/commondir", "../..\n");
    try f.write("wt/.git", try std.fmt.allocPrint(arena, "gitdir: {s}\n", .{try f.path("main/.git/worktrees/feature")}));
    try f.write("wt/pkg/x.txt", "");
    try testing.expectEqualStrings("git.example.test/brackwater/widgets", try derive(arena, io, try f.path("wt/pkg")));

    try f.write("sub/.git", "gitdir: ../main/.git/modules/sub\n");
    try f.write("main/.git/modules/sub/config", "[remote \"up\"]\n\turl = git@git.example.test:brackwater/sub.git\n");
    try testing.expectEqualStrings("git.example.test/brackwater/sub", try derive(arena, io, try f.path("sub")));

    try f.write("plain/.git/config", "[core]\n\tbare = false\n");
    try f.write("plain/a/b.txt", "");
    try testing.expectEqualStrings(try f.path("plain/a"), try derive(arena, io, try f.path("plain/a/./")));
}

test "isExcluded: projects, paths component-wise, tilde, grafignore" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f: Fixture = .{ .arena = arena, .root = try tmp.dir.realPathFileAlloc(io, ".", arena), .dir = tmp.dir };

    try f.write("home/work/a/b/x.txt", "");
    try f.write("home/work/a/bc/x.txt", "");
    try f.write("repo/.git/config", "[remote \"origin\"]\n\turl = git@github.com:brackwater/private.git\n");
    try f.write("repo/lib/x.txt", "");

    var cfg: core.Config = .{};
    cfg.capture.exclude_projects = &.{"github.com/brackwater/*"};
    cfg.capture.exclude_paths = &.{"~/work/a/b"};
    const home = try f.path("home");

    try testing.expect(try isExcluded(arena, io, &cfg, .{ .project = "github.com/brackwater/widgets" }));
    try testing.expect(!try isExcluded(arena, io, &cfg, .{ .project = "github.com/other/widgets" }));
    try testing.expect(try isExcluded(arena, io, &cfg, .{ .cwd = try f.path("repo/lib"), .home = home }));

    try testing.expect(try isExcluded(arena, io, &cfg, .{ .cwd = try f.path("home/work/a/b"), .home = home }));
    try testing.expect(try isExcluded(arena, io, &cfg, .{ .cwd = try f.path("home/work/a/b/deeper"), .home = home }));
    try testing.expect(!try isExcluded(arena, io, &cfg, .{ .cwd = try f.path("home/work/a/bc"), .home = home }));
    try testing.expect(try isExcluded(arena, io, &cfg, .{ .cwd = try f.path("home"), .transcript_path = try f.path("home/work/a/b/s.jsonl"), .home = home }));
    try testing.expect(!try isExcluded(arena, io, &cfg, .{ .cwd = try f.path("home/work/a/b") }));

    cfg.capture.exclude_projects = &.{};
    cfg.capture.exclude_paths = &.{};

    try f.write("open/.git/config", "");
    try f.write("open/src/x.txt", "");
    try testing.expect(!try isExcluded(arena, io, &cfg, .{ .cwd = try f.path("open/src") }));
    try f.write("open/.grafignore", "");
    try testing.expect(try isExcluded(arena, io, &cfg, .{ .cwd = try f.path("open/src") }));
}
