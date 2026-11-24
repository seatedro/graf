const std = @import("std");
const core = @import("core");
const api = @import("api.zig");
const service = @import("service.zig");
const Upstream = @import("upstream.zig").Upstream;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const posix = std.posix;

const log = std.log.scoped(.edge);

pub const subdir = "edge";
pub const spool_file = "spool.jsonl";
pub const offset_file = "spool.offset";
pub const cursors_file = "cursors.jsonl";
pub const rejected_file = "rejected.jsonl";

pub fn spoolDir(arena: Allocator, state_dir: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ state_dir, subdir });
}

pub const Spool = struct {
    gpa: Allocator,
    io: Io,
    dir: []const u8,
    keep: std.heap.ArenaAllocator,
    cursors: std.StringHashMapUnmanaged([]const u8) = .empty,
    mutex: Io.Mutex = .init,
    options: Options,

    pub const Options = struct {
        idle: Io.Duration = .fromMilliseconds(500),
        min_backoff_ms: u64 = 1_000,
        max_backoff_ms: u64 = 60_000,
    };

    pub const Drained = struct {
        delivered: usize = 0,
        rejected: usize = 0,
    };

    const CursorLine = struct { key: []const u8, cursor: []const u8 };

    pub fn open(gpa: Allocator, io: Io, spool_dir: []const u8, options: Options) !Spool {
        try Dir.cwd().createDirPath(io, spool_dir);
        var s: Spool = .{ .gpa = gpa, .io = io, .dir = undefined, .keep = .init(gpa), .options = options };
        errdefer s.keep.deinit();
        errdefer s.cursors.deinit(gpa);
        s.dir = try s.keep.allocator().dupe(u8, spool_dir);
        try s.repairTail();
        try s.loadCursors();
        return s;
    }

    pub fn close(s: *Spool) void {
        s.cursors.deinit(s.gpa);
        s.keep.deinit();
        s.* = undefined;
    }

    pub fn sink(s: *Spool) core.EntrySink {
        return .{ .ptr = s, .vtable = &.{ .enqueue = enqueue, .loadCursor = loadCursor } };
    }

    fn path(s: *const Spool, buf: *[std.fs.max_path_bytes]u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ s.dir, name });
    }

    fn enqueue(ptr: *anyopaque, draft: *const core.EntryDraft) anyerror!core.EntrySink.Outcome {
        const s: *Spool = @ptrCast(@alignCast(ptr));
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var redacted = try core.redactDraft(arena, draft.*);
        redacted.cursor = null;
        var line: Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(redacted, .{ .emit_null_optional_fields = false }, &line.writer);
        try line.writer.writeByte('\n');

        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        try s.append(spool_file, line.written(), true);
        if (draft.source) |source| if (draft.cursor) |c| try s.saveCursor(arena, &source, c);
        return .{ .queued = core.Id.v7(s.io) };
    }

    fn loadCursor(ptr: *anyopaque, arena: Allocator, source: *const core.SourceKey) anyerror!?[]const u8 {
        const s: *Spool = @ptrCast(@alignCast(ptr));
        const key = try cursorKey(arena, source);
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        const c = s.cursors.get(key) orelse return null;
        return try arena.dupe(u8, c);
    }

    fn cursorKey(arena: Allocator, source: *const core.SourceKey) ![]const u8 {
        return std.fmt.allocPrint(arena, "{t}:{s}", .{ source.harness, source.external_id });
    }

    fn saveCursor(s: *Spool, arena: Allocator, source: *const core.SourceKey, cursor: []const u8) !void {
        const key = try cursorKey(arena, source);
        if (s.cursors.get(key)) |current| if (std.mem.eql(u8, current, cursor)) return;
        try s.putCursor(key, cursor);
        var line: Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(CursorLine{ .key = key, .cursor = cursor }, .{}, &line.writer);
        try line.writer.writeByte('\n');
        try s.append(cursors_file, line.written(), false);
    }

    fn putCursor(s: *Spool, key: []const u8, cursor: []const u8) !void {
        const keep = s.keep.allocator();
        const entry = try s.cursors.getOrPut(s.gpa, key);
        if (!entry.found_existing) entry.key_ptr.* = try keep.dupe(u8, key);
        entry.value_ptr.* = try keep.dupe(u8, cursor);
    }

    fn loadCursors(s: *Spool) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const file_path = try s.path(&buf, cursors_file);
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const text = Dir.cwd().readFileAlloc(s.io, file_path, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            const parsed = std.json.parseFromSliceLeaky(CursorLine, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
            try s.putCursor(parsed.key, parsed.cursor);
        }

        var compacted: Io.Writer.Allocating = .init(arena);
        var it = s.cursors.iterator();
        while (it.next()) |kv| {
            try std.json.Stringify.value(CursorLine{ .key = kv.key_ptr.*, .cursor = kv.value_ptr.* }, .{}, &compacted.writer);
            try compacted.writer.writeByte('\n');
        }
        try s.replace(cursors_file, compacted.written());
    }

    fn append(s: *Spool, name: []const u8, bytes: []const u8, sync: bool) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const file_path = try s.path(&buf, name);
        const fd = try posix.openat(posix.AT.FDCWD, file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);
        const file: File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer file.close(s.io);
        try file.writeStreamingAll(s.io, bytes);
        if (sync) try file.sync(s.io);
    }

    fn replace(s: *Spool, name: []const u8, bytes: []const u8) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const file_path = try s.path(&buf, name);
        var atomic = try Dir.cwd().createFileAtomic(s.io, file_path, .{ .replace = true, .permissions = @fromBackingInt(0o600) });
        defer atomic.deinit(s.io);
        try atomic.file.writeStreamingAll(s.io, bytes);
        try atomic.replace(s.io);
    }

    fn repairTail(s: *Spool) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const file_path = try s.path(&buf, spool_file);
        const file = Dir.cwd().openFile(s.io, file_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer file.close(s.io);
        const len = try file.length(s.io);
        var end = len;
        var block: [4096]u8 = undefined;
        while (end > 0) {
            const start = end -| block.len;
            const n = try file.readPositionalAll(s.io, block[0..@intCast(end - start)], start);
            if (std.mem.findScalarLast(u8, block[0..n], '\n')) |i| {
                end = start + i + 1;
                break;
            }
            end = start;
        }
        if (end != len) {
            log.warn("dropping {d} bytes of a partly written spool line", .{len - end});
            try file.setLength(s.io, end);
        }
    }

    fn spoolLength(s: *Spool) !u64 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const st = Dir.cwd().statFile(s.io, try s.path(&buf, spool_file), .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => |e| return e,
        };
        return st.size;
    }

    fn readOffset(s: *Spool, length: u64) !u64 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var text_buf: [32]u8 = undefined;
        const text = Dir.cwd().readFile(s.io, try s.path(&buf, offset_file), &text_buf) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => |e| return e,
        };
        const offset = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch return 0;
        return if (offset > length) 0 else offset;
    }

    fn commit(s: *Spool, offset: u64) !void {
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (offset >= try s.spoolLength()) {
            const file = Dir.cwd().openFile(s.io, try s.path(&buf, spool_file), .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => return,
                else => |e| return e,
            };
            defer file.close(s.io);
            try file.setLength(s.io, 0);
            Dir.cwd().deleteFile(s.io, try s.path(&buf, offset_file)) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            return;
        }
        var num: [32]u8 = undefined;
        try s.replace(offset_file, try std.fmt.bufPrint(&num, "{d}\n", .{offset}));
    }

    pub fn pending(s: *Spool) !usize {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const data = (try s.snapshot(arena_state.allocator())).data;
        return std.mem.count(u8, data, "\n");
    }

    const Snapshot = struct { data: []const u8, offset: u64 };

    fn snapshot(s: *Spool, arena: Allocator) !Snapshot {
        try s.mutex.lock(s.io);
        defer s.mutex.unlock(s.io);
        const length = try s.spoolLength();
        if (length == 0) return .{ .data = "", .offset = 0 };
        const offset = try s.readOffset(length);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const file = try Dir.cwd().openFile(s.io, try s.path(&buf, spool_file), .{});
        defer file.close(s.io);
        const data = try arena.alloc(u8, @intCast(length - offset));
        const n = try file.readPositionalAll(s.io, data, offset);
        return .{ .data = data[0..n], .offset = offset };
    }

    pub fn drain(s: *Spool, up: *Upstream) !Drained {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const snap = try s.snapshot(arena_state.allocator());
        var request_arena = std.heap.ArenaAllocator.init(s.gpa);
        defer request_arena.deinit();
        var result: Drained = .{};
        var pos: usize = 0;
        while (std.mem.findScalarPos(u8, snap.data, pos, '\n')) |nl| {
            _ = request_arena.reset(.retain_capacity);
            const line = snap.data[pos..nl];
            if (std.mem.trim(u8, line, " \t\r").len > 0) {
                const reply = up.request(request_arena.allocator(), .POST, "/v1/entries", line) catch |err| {
                    try s.commit(snap.offset + pos);
                    return err;
                };
                if (reply.status >= 200 and reply.status < 300) {
                    result.delivered += 1;
                } else if (permanent(reply.status)) {
                    log.warn("the hub rejected a spooled entry with {d}; kept in {s}", .{ reply.status, rejected_file });
                    {
                        try s.mutex.lock(s.io);
                        defer s.mutex.unlock(s.io);
                        try s.append(rejected_file, snap.data[pos .. nl + 1], true);
                    }
                    result.rejected += 1;
                } else {
                    try s.commit(snap.offset + pos);
                    return error.UpstreamUnavailable;
                }
            }
            pos = nl + 1;
            try s.commit(snap.offset + pos);
        }
        return result;
    }

    fn permanent(status: u16) bool {
        return status == 400 or status == 413 or status == 415 or status == 422;
    }

    pub fn run(s: *Spool, up: *Upstream) Io.Cancelable!void {
        var backoff_ms: u64 = 0;
        while (true) {
            const waiting = s.pending() catch 0;
            var wait = s.options.idle;
            if (waiting > 0) {
                if (s.drain(up)) |drained| {
                    if (backoff_ms > 0 or drained.delivered > 0) log.info("pushed {d} spooled entries to the hub", .{drained.delivered});
                    backoff_ms = 0;
                } else |err| {
                    if (err == error.Canceled) return error.Canceled;
                    backoff_ms = if (backoff_ms == 0) s.options.min_backoff_ms else @min(backoff_ms * 2, s.options.max_backoff_ms);
                    log.info("hub unavailable ({s}); {d} entries spooled, retrying in {d} ms", .{ @errorName(err), waiting, backoff_ms });
                    wait = .fromMilliseconds(@intCast(backoff_ms));
                }
            }
            try s.io.sleep(wait, .awake);
        }
    }
};

pub const Edge = struct {
    upstream: *Upstream,
    spool: *Spool,
    flusher: ?service.Flusher = null,

    pub fn handler(e: *Edge) api.Handler {
        return .{ .ptr = e, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, arena: Allocator, req: api.Request) anyerror!api.Reply {
        const e: *Edge = @ptrCast(@alignCast(ptr));
        switch (req.op) {
            .entries => {
                const draft = std.json.parseFromSliceLeaky(core.EntryDraft, arena, req.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
                    return api.errorReply(arena, 400, "request body must be an entry");
                const outcome = try e.spool.sink().enqueue(&draft);
                return .{ .body = try std.json.Stringify.valueAlloc(arena, .{ .id = outcome.queued, .spooled = true }, .{}) };
            },
            .flush => {
                const f = e.flusher orelse return .{ .status = 202, .body = "{\"accepted\":true,\"flushed\":false}" };
                const in = std.json.parseFromSliceLeaky(service.FlushRequest, arena, req.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
                    return api.errorReply(arena, 400, "invalid flush request");
                const flushed = f.flush(in) catch |err| blk: {
                    log.warn("flush failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                return .{ .status = 202, .body = if (flushed) "{\"accepted\":true,\"flushed\":true}" else "{\"accepted\":true,\"flushed\":false}" };
            },
            else => return e.upstream.handler().handle(arena, req),
        }
    }
};

test {
    _ = @import("edge_test.zig");
}
