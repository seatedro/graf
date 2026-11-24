const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.capture);

pub const max_watch_fds = 4096;

pub fn watchBudget(soft_limit: u64) usize {
    return @intCast(@min(soft_limit / 2, max_watch_fds));
}

pub const Changes = struct {
    paths: std.ArrayList([]const u8) = .empty,
    rescan: bool = false,
};

pub const Watcher = switch (builtin.os.tag) {
    .linux => Inotify,
    .macos, .ios, .freebsd, .netbsd, .openbsd, .dragonfly => Kqueue,
    else => Polling,
};

pub const Polling = struct {
    pub fn init(gpa: Allocator) Polling {
        _ = gpa;
        return .{};
    }

    pub fn deinit(w: *Polling) void {
        w.* = undefined;
    }

    pub fn active(w: *const Polling) bool {
        _ = w;
        return false;
    }

    pub fn watchTree(w: *Polling, io: Io, root: []const u8) !void {
        _ = .{ w, io, root };
    }

    pub fn watchFile(w: *Polling, path: []const u8) !void {
        _ = .{ w, path };
    }

    pub fn poll(w: *Polling, io: Io, arena: Allocator, changes: *Changes) !void {
        _ = .{ w, io, arena, changes };
    }
};

const Inotify = struct {
    const linux = std.os.linux;
    const mask: u32 = linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.CREATE | linux.IN.MOVED_TO | linux.IN.DELETE_SELF | linux.IN.ONLYDIR;

    gpa: Allocator,
    fd: i32,
    dirs: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,
    exhausted: bool = false,

    pub fn init(gpa: Allocator) Inotify {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            log.warn("cannot start inotify ({t}); transcripts are picked up by periodic scans", .{err});
            return .{ .gpa = gpa, .fd = -1 };
        }

        return .{ .gpa = gpa, .fd = @intCast(rc) };
    }

    pub fn deinit(w: *Inotify) void {
        if (w.fd >= 0) _ = linux.close(w.fd);
        var it = w.dirs.valueIterator();
        while (it.next()) |path| w.gpa.free(path.*);
        w.dirs.deinit(w.gpa);
        w.* = undefined;
    }

    pub fn active(w: *const Inotify) bool {
        return w.fd >= 0;
    }

    pub fn watchTree(w: *Inotify, io: Io, root: []const u8) !void {
        if (w.fd < 0) return;
        if (!try w.addDir(root)) return;

        var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var walker = try dir.walk(w.gpa);
        defer walker.deinit();

        while (walker.next(io) catch null) |entry| {
            if (w.exhausted) return;
            if (entry.kind != .directory) continue;
            const full = try std.fs.path.join(w.gpa, &.{ root, entry.path });
            defer w.gpa.free(full);
            _ = try w.addDir(full);
        }
    }

    pub fn watchFile(w: *Inotify, path: []const u8) !void {
        _ = .{ w, path };
    }

    fn addDir(w: *Inotify, path: []const u8) !bool {
        const z = try w.gpa.dupeSentinel(u8, path, 0);
        defer w.gpa.free(z);
        const rc = linux.inotify_add_watch(w.fd, z, mask);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOSPC, .NOMEM => {
                if (!w.exhausted) log.warn("inotify watch limit reached at {d} directories; the rest are picked up by periodic scans", .{w.dirs.count()});
                w.exhausted = true;
                return false;
            },
            else => return false,
        }

        const wd: i32 = @intCast(rc);
        const gop = try w.dirs.getOrPut(w.gpa, wd);
        if (gop.found_existing) {
            if (std.mem.eql(u8, gop.value_ptr.*, path)) return true;
            w.gpa.free(gop.value_ptr.*);
        }

        gop.value_ptr.* = try w.gpa.dupe(u8, path);
        return true;
    }

    pub fn poll(w: *Inotify, io: Io, arena: Allocator, changes: *Changes) !void {
        if (w.fd < 0) return;

        var buf: [16 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(w.fd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return,
            }
            if (rc == 0) return;

            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= rc) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                off += @sizeOf(linux.inotify_event) + ev.len;

                if (ev.mask & linux.IN.Q_OVERFLOW != 0) {
                    changes.rescan = true;
                    continue;
                }

                if (ev.mask & linux.IN.IGNORED != 0) {
                    if (w.dirs.fetchRemove(ev.wd)) |kv| w.gpa.free(kv.value);
                    w.exhausted = false;
                    continue;
                }

                const dir = w.dirs.get(ev.wd) orelse continue;
                const name = ev.getName() orelse continue;
                const full = try std.fs.path.join(arena, &.{ dir, name });
                if (ev.mask & linux.IN.ISDIR != 0) {
                    try w.watchTree(io, full);
                    changes.rescan = true;
                    continue;
                }
                try changes.paths.append(arena, full);
            }
        }
    }
};

const Kqueue = struct {
    const c = std.c;
    const max_files = 512;

    gpa: Allocator,
    kq: c_int,
    watched: std.StringHashMapUnmanaged(Entry) = .empty,
    by_fd: std.AutoHashMapUnmanaged(c_int, []const u8) = .empty,
    files: usize = 0,
    budget: usize,
    warned: bool = false,

    const Entry = struct { fd: c_int, dir: bool };

    pub fn init(gpa: Allocator) Kqueue {
        const soft: u64 = if (std.posix.getrlimit(.NOFILE)) |l| l.cur else |_| 256;
        const kq = c.kqueue();
        if (kq < 0) log.warn("cannot start kqueue ({t}); transcripts are picked up by periodic scans", .{c.errno(kq)});

        return .{ .gpa = gpa, .kq = kq, .budget = watchBudget(soft) };
    }

    pub fn deinit(w: *Kqueue) void {
        var it = w.watched.iterator();
        while (it.next()) |e| {
            _ = c.close(e.value_ptr.fd);
            w.gpa.free(e.key_ptr.*);
        }

        w.watched.deinit(w.gpa);
        w.by_fd.deinit(w.gpa);
        if (w.kq >= 0) _ = c.close(w.kq);
        w.* = undefined;
    }

    pub fn active(w: *const Kqueue) bool {
        return w.kq >= 0;
    }

    pub fn watchTree(w: *Kqueue, io: Io, root: []const u8) !void {
        if (w.kq < 0) return;
        if (!try w.add(root, true)) return;

        var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var walker = try dir.walk(w.gpa);
        defer walker.deinit();

        while (walker.next(io) catch null) |entry| {
            if (w.full()) return;
            if (entry.kind != .directory) continue;
            const full_path = try std.fs.path.join(w.gpa, &.{ root, entry.path });
            defer w.gpa.free(full_path);
            _ = try w.add(full_path, true);
        }
    }

    fn full(w: *const Kqueue) bool {
        return w.watched.count() >= w.budget;
    }

    fn warnFull(w: *Kqueue) void {
        if (w.warned) return;
        w.warned = true;
        log.warn("watching {d} paths, the open file budget; changes elsewhere are picked up by periodic scans", .{w.watched.count()});
    }

    pub fn watchFile(w: *Kqueue, path: []const u8) !void {
        if (w.kq < 0 or w.files >= max_files) return;
        if (try w.add(path, false)) w.files += 1;
    }

    fn add(w: *Kqueue, path: []const u8, dir: bool) !bool {
        if (w.watched.contains(path)) return false;
        if (w.full()) {
            w.warnFull();
            return false;
        }

        const z = try w.gpa.dupeSentinel(u8, path, 0);
        defer w.gpa.free(z);
        const fd = c.open(z, .{ .EVTONLY = true, .CLOEXEC = true });
        if (fd < 0) {
            switch (c.errno(fd)) {
                .MFILE, .NFILE => {
                    w.budget = w.watched.count();
                    w.warnFull();
                },
                else => {},
            }
            return false;
        }

        const change: c.Kevent = .{
            .ident = @intCast(fd),
            .filter = c.EVFILT.VNODE,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR,
            .fflags = c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.DELETE | c.NOTE.RENAME,
            .data = 0,
            .udata = 0,
        };

        var none: [0]c.Kevent = .{};
        if (c.kevent(w.kq, @ptrCast(&change), 1, &none, 0, null) < 0) {
            _ = c.close(fd);
            return false;
        }

        const owned = try w.gpa.dupe(u8, path);
        try w.watched.put(w.gpa, owned, .{ .fd = fd, .dir = dir });
        try w.by_fd.put(w.gpa, fd, owned);
        return true;
    }

    fn remove(w: *Kqueue, fd: c_int) void {
        const kv = w.by_fd.fetchRemove(fd) orelse return;
        if (w.watched.fetchRemove(kv.value)) |e| {
            if (!e.value.dir) w.files -= 1;
        }
        _ = c.close(fd);
        w.gpa.free(kv.value);
    }

    pub fn poll(w: *Kqueue, io: Io, arena: Allocator, changes: *Changes) !void {
        _ = io;
        if (w.kq < 0) return;

        var events: [64]c.Kevent = undefined;
        const zero: c.timespec = .{ .sec = 0, .nsec = 0 };

        while (true) {
            const n = c.kevent(w.kq, &events, 0, &events, events.len, &zero);
            if (n <= 0) return;
            for (events[0..@intCast(n)]) |ev| {
                const fd: c_int = @intCast(ev.ident);
                const path = w.by_fd.get(fd) orelse continue;
                const entry = w.watched.get(path) orelse continue;

                if (entry.dir) {
                    changes.rescan = true;
                } else {
                    try changes.paths.append(arena, try arena.dupe(u8, path));
                }

                if (ev.fflags & (c.NOTE.DELETE | c.NOTE.RENAME) != 0) w.remove(fd);
            }

            if (n < events.len) return;
        }
    }
};

test "inotify reports appends to files in watched trees" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var w: Watcher = .init(std.testing.allocator);
    defer w.deinit();
    try w.watchTree(io, root);
    try std.testing.expect(w.active());

    try tmp.dir.createDirPath(io, "proj");
    var changes: Changes = .{};
    try w.poll(io, arena, &changes);
    try std.testing.expect(changes.rescan);

    try tmp.dir.writeFile(io, .{ .sub_path = "proj/s.jsonl", .data = "{}\n" });
    changes = .{};
    try w.poll(io, arena, &changes);

    const want = try std.fs.path.join(arena, &.{ root, "proj", "s.jsonl" });
    var found = false;
    for (changes.paths.items) |p| found = found or std.mem.eql(u8, p, want);
    try std.testing.expect(found);
}

test "the watch budget leaves half the open file limit for everything else" {
    try std.testing.expectEqual(@as(usize, 128), watchBudget(256));
    try std.testing.expectEqual(@as(usize, 0), watchBudget(0));
    try std.testing.expectEqual(@as(usize, max_watch_fds), watchBudget(65536));
    try std.testing.expectEqual(@as(usize, max_watch_fds), watchBudget(std.math.maxInt(u64)));
}

test "a watcher started without free descriptors degrades to scanning instead of failing" {
    if (Watcher == Polling) return error.SkipZigTest;

    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj/a");
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const before = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{ .cur = 0, .max = before.max });
    var w: Watcher = .init(std.testing.allocator);
    try std.posix.setrlimit(.NOFILE, before);
    defer w.deinit();

    try std.testing.expect(!w.active());
    try w.watchTree(io, root);
    try w.watchFile(root);

    var changes: Changes = .{};
    try w.poll(io, arena, &changes);
    try std.testing.expect(!changes.rescan);
    try std.testing.expectEqual(@as(usize, 0), changes.paths.items.len);
}

test "kqueue stops opening descriptors at its budget" {
    if (Watcher != Kqueue) return error.SkipZigTest;

    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a/1", "a/2", "b/1", "b/2", "c/1" }) |sub| try tmp.dir.createDirPath(io, sub);
    try tmp.dir.writeFile(io, .{ .sub_path = "a/1/s.jsonl", .data = "{}\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);

    var w: Kqueue = .init(std.testing.allocator);
    defer w.deinit();
    w.budget = 4;

    try w.watchTree(io, root);
    try std.testing.expect(w.active());
    try std.testing.expectEqual(@as(usize, 4), w.watched.count());

    try w.watchFile(try std.fs.path.join(arena, &.{ root, "a", "1", "s.jsonl" }));
    try std.testing.expectEqual(@as(usize, 4), w.watched.count());
    try std.testing.expectEqual(@as(usize, 0), w.files);
}
