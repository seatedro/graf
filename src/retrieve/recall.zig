const std = @import("std");
const core = @import("core");
const time = @import("time.zig");
const render = @import("render.zig");
const mod = @import("mod.zig");
const Hit = mod.Hit;

pub const max_sessions = 256;
const per_source = 6;

const Session = struct {
    arena: std.heap.ArenaAllocator,
    warmed: []const Hit = &.{},
    injected: std.AutoHashMapUnmanaged(core.Id, void) = .empty,
    last_used: core.Micros = 0,
};

pub const RecallCache = struct {
    mutex: std.Io.Mutex = .init,
    sessions: std.StringHashMapUnmanaged(*Session) = .empty,

    pub fn deinit(c: *RecallCache, gpa: std.mem.Allocator) void {
        var it = c.sessions.iterator();
        while (it.next()) |kv| destroy(gpa, kv.key_ptr.*, kv.value_ptr.*);
        c.sessions.deinit(gpa);
    }

    fn destroy(gpa: std.mem.Allocator, k: []const u8, s: *Session) void {
        s.injected.deinit(gpa);
        s.arena.deinit();
        gpa.destroy(s);
        gpa.free(k);
    }

    fn session(c: *RecallCache, gpa: std.mem.Allocator, id: []const u8, now: core.Micros) !*Session {
        const gop = try c.sessions.getOrPut(gpa, id);
        if (!gop.found_existing) {
            errdefer c.sessions.removeByPtr(gop.key_ptr);
            const s = try gpa.create(Session);
            errdefer gpa.destroy(s);
            gop.key_ptr.* = try gpa.dupe(u8, id);
            s.* = .{ .arena = .init(gpa) };
            gop.value_ptr.* = s;
            if (c.sessions.count() > max_sessions) c.evictOldest(gpa, gop.key_ptr.*);
        }
        gop.value_ptr.*.last_used = now;
        return gop.value_ptr.*;
    }

    fn evictOldest(c: *RecallCache, gpa: std.mem.Allocator, keep: []const u8) void {
        var oldest: ?[]const u8 = null;
        var oldest_t: core.Micros = std.math.maxInt(core.Micros);
        var it = c.sessions.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.*.ptr == keep.ptr) continue;
            if (kv.value_ptr.*.last_used < oldest_t) {
                oldest_t = kv.value_ptr.*.last_used;
                oldest = kv.key_ptr.*;
            }
        }
        const k = oldest orelse return;
        const kv = c.sessions.fetchRemove(k).?;
        destroy(gpa, kv.key, kv.value);
    }
};

pub fn warm(e: *mod.Engine, session_id: []const u8, prompt: []const u8, project: ?[]const u8) !void {
    var tmp = std.heap.ArenaAllocator.init(e.gpa);
    defer tmp.deinit();
    const result = try e.search(tmp.allocator(), .{ .query = prompt, .project = project, .max_tokens = mod.recall_tokens });
    const top = result.hits[0..@min(result.hits.len, 12)];

    const c = &e.sessions;
    c.mutex.lockUncancelable(e.io);
    defer c.mutex.unlock(e.io);
    const s = try c.session(e.gpa, session_id, time.now(e.io));
    _ = s.arena.reset(.retain_capacity);
    const a = s.arena.allocator();
    const copy = try a.alloc(Hit, top.len);
    for (top, copy) |h, *d| d.* = try dupeHit(a, h);
    s.warmed = copy;
}

pub fn recall(e: *mod.Engine, arena: std.mem.Allocator, session_id: []const u8, prompt: []const u8, project: ?[]const u8) ![]const u8 {
    const instant = try e.searchInstant(arena, .{ .query = prompt, .project = project, .max_tokens = mod.recall_tokens });

    const c = &e.sessions;
    c.mutex.lockUncancelable(e.io);
    defer c.mutex.unlock(e.io);
    const s = try c.session(e.gpa, session_id, time.now(e.io));

    var out: std.Io.Writer.Allocating = .init(arena);
    var budget: render.Budget = .{ .max_tokens = mod.recall_tokens };
    const header = "graf recall (facts from memory relevant to this prompt):\n";
    _ = budget.take(header.len);
    var picked: std.AutoArrayHashMapUnmanaged(core.Id, void) = .empty;
    for ([_][]const Hit{ instant.hits[0..@min(instant.hits.len, per_source)], s.warmed[0..@min(s.warmed.len, per_source)] }) |hits| {
        for (hits) |*h| {
            if (s.injected.contains(h.fact.id)) continue;
            if (picked.contains(h.fact.id)) continue;
            var line: std.Io.Writer.Allocating = .init(arena);
            try render.writeFactLine(&line.writer, h, false);
            if (!budget.take(line.written().len)) continue;
            if (picked.count() == 0) try out.writer.writeAll(header);
            try out.writer.writeAll(line.written());
            try picked.put(arena, h.fact.id, {});
        }
    }
    for (picked.keys()) |id| try s.injected.put(e.gpa, id, {});
    return out.written();
}

fn dupeHit(a: std.mem.Allocator, h: Hit) !Hit {
    var d = h;
    d.fact.predicate = try a.dupe(u8, h.fact.predicate);
    d.fact.qualifier = try a.dupe(u8, h.fact.qualifier);
    d.fact.text = try a.dupe(u8, h.fact.text);
    d.fact.rationale = if (h.fact.rationale) |r| try a.dupe(u8, r) else null;
    d.fact.project = if (h.fact.project) |p| try a.dupe(u8, p) else null;
    d.fact.object = switch (h.fact.object) {
        .entity => |id| .{ .entity = id },
        .value => |v| .{ .value = try a.dupe(u8, v) },
    };
    d.subject_name = try a.dupe(u8, h.subject_name);
    d.object_name = if (h.object_name) |n| try a.dupe(u8, n) else null;
    return d;
}
