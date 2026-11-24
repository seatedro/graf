const std = @import("std");
const core = @import("core");
const time = @import("time.zig");
const EvalEntry = @import("mod.zig").EvalEntry;

pub const TimeBasis = enum { explicit, relative, reference };

pub const GoldEntity = struct {
    id: []const u8,
    name: []const u8,
    type: core.EntityType,
    aliases: []const []const u8 = &.{},
    first_seen: ?[]const u8 = null,
};

pub const ExpectedMerge = struct {
    entry: []const u8,
    mention: []const u8,
    must_resolve_to: []const u8,
    rule: []const u8 = "",
};

pub const MustNotMerge = struct {
    entry: []const u8,
    entity_a: []const u8,
    entity_b: []const u8,
    reason: []const u8 = "",
};

pub const GoldFact = struct {
    id: []const u8,
    subject: []const u8,
    relation: []const u8,
    qualifier: ?[]const u8 = null,
    object: ?[]const u8 = null,
    object_value: ?[]const u8 = null,
    scope: ?core.types.Scope = null,
    valid_from: ?[]const u8 = null,
    valid_to: ?[]const u8 = null,
    time_basis: ?TimeBasis = null,
};

pub const GoldInvalidation = struct {
    fact_id: []const u8,
    end_kind: core.types.EndKind,
    valid_to: ?[]const u8 = null,
    mechanism: []const u8 = "",
};

pub const GoldEntry = struct {
    skip: bool = false,
    reason: ?[]const u8 = null,
    facts_added: []const GoldFact = &.{},
    restated: []const []const u8 = &.{},
    invalidations: []const GoldInvalidation = &.{},
    must_not_contain_facts: []const []const u8 = &.{},
    must_remain_active: []const []const u8 = &.{},
    forbidden_substrings_anywhere: []const []const u8 = &.{},
    note: ?[]const u8 = null,
};

pub const RetrievalQuery = struct {
    id: []const u8,
    query: []const u8,
    project: ?[]const u8 = null,
    as_of: ?[]const u8 = null,
    must_include: []const []const u8 = &.{},
    must_exclude: []const []const u8 = &.{},
    must_exclude_substrings: []const []const u8 = &.{},
    note: ?[]const u8 = null,
};

pub const Expected = struct {
    suite_version: []const u8,
    description: []const u8 = "",
    canonical_entities: []const GoldEntity,
    expected_merges: []const ExpectedMerge = &.{},
    must_not_merge: []const MustNotMerge = &.{},
    entries: std.json.ArrayHashMap(GoldEntry),
    retrieval_queries: []const RetrievalQuery = &.{},
};

pub const FactRef = struct {
    fact: GoldFact,
    entry: []const u8,
    valid_from: ?core.Micros,
    valid_to: ?core.Micros,
};

pub const Suite = struct {
    entries: []const EvalEntry,
    expected: Expected,
    facts: []const FactRef,

    pub fn entities(s: *const Suite) []const GoldEntity {
        return s.expected.canonical_entities;
    }

    pub fn entityIndex(s: *const Suite, id: []const u8) ?usize {
        for (s.expected.canonical_entities, 0..) |e, i| if (std.mem.eql(u8, e.id, id)) return i;
        return null;
    }

    pub fn factIndex(s: *const Suite, id: []const u8) ?usize {
        for (s.facts, 0..) |f, i| if (std.mem.eql(u8, f.fact.id, id)) return i;
        return null;
    }

    pub fn entryIndex(s: *const Suite, id: []const u8) ?usize {
        for (s.entries, 0..) |e, i| if (std.mem.eql(u8, e.id, id)) return i;
        return null;
    }

    pub fn gold(s: *const Suite, entry_id: []const u8) ?GoldEntry {
        return s.expected.entries.map.get(entry_id);
    }

    pub fn isSkip(s: *const Suite, entry_id: []const u8) bool {
        const g = s.gold(entry_id) orelse return false;
        return g.skip;
    }

    pub fn query(s: *const Suite, id: []const u8) ?RetrievalQuery {
        for (s.expected.retrieval_queries) |q| if (std.mem.eql(u8, q.id, id)) return q;
        return null;
    }
};

pub fn parseEntries(arena: std.mem.Allocator, jsonl: []const u8) ![]const EvalEntry {
    var list: std.ArrayList(EvalEntry) = .empty;
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try list.append(arena, try std.json.parseFromSliceLeaky(EvalEntry, arena, line, .{ .allocate = .alloc_always }));
    }
    return list.items;
}

pub fn parseSuite(arena: std.mem.Allocator, entries_jsonl: []const u8, expected_json: []const u8) !Suite {
    const entries = try parseEntries(arena, entries_jsonl);
    const expected = try std.json.parseFromSliceLeaky(Expected, arena, expected_json, .{ .allocate = .alloc_always });
    var facts: std.ArrayList(FactRef) = .empty;
    for (expected.entries.map.keys(), expected.entries.map.values()) |ep, g| {
        for (g.facts_added) |f| try facts.append(arena, .{
            .fact = f,
            .entry = ep,
            .valid_from = if (f.valid_from) |v| time.parseRfc3339(v) catch null else null,
            .valid_to = if (f.valid_to) |v| time.parseRfc3339(v) catch null else null,
        });
    }
    return .{ .entries = entries, .expected = expected, .facts = facts.items };
}

pub fn loadSuite(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !Suite {
    const cwd = std.Io.Dir.cwd();
    const entries_path = try std.fs.path.join(arena, &.{ dir, "entries.jsonl" });
    const expected_path = try std.fs.path.join(arena, &.{ dir, "expected.json" });
    const entries = try cwd.readFileAlloc(io, entries_path, arena, .limited(16 << 20));
    const expected = try cwd.readFileAlloc(io, expected_path, arena, .limited(16 << 20));
    return parseSuite(arena, entries, expected);
}

pub const Pattern = struct {
    subject: usize,
    relation: []const u8,
    object: []const u8,
};

pub fn parsePattern(arena: std.mem.Allocator, suite: *const Suite, text: []const u8) !?Pattern {
    const normalize = @import("score.zig").normalize;
    const norm = try normalize(arena, text);
    var best: ?struct { entity: usize, len: usize } = null;
    for (suite.entities(), 0..) |e, i| {
        var names: std.ArrayList([]const u8) = .empty;
        try names.append(arena, e.name);
        try names.appendSlice(arena, e.aliases);
        for (names.items) |name| {
            const n = try normalize(arena, name);
            if (n.len == 0 or n.len >= norm.len) continue;
            if (!std.mem.startsWith(u8, norm, n) or norm[n.len] != ' ') continue;
            if (best == null or n.len > best.?.len) best = .{ .entity = i, .len = n.len };
        }
    }
    const b = best orelse return null;
    const rest = norm[b.len + 1 ..];
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return .{ .subject = b.entity, .relation = rest[0..space], .object = rest[space + 1 ..] };
}

pub fn validate(arena: std.mem.Allocator, suite: *const Suite) ![]const []const u8 {
    var problems: std.ArrayList([]const u8) = .empty;
    const p = struct {
        fn add(a: std.mem.Allocator, list: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) !void {
            try list.append(a, try std.fmt.allocPrint(a, fmt, args));
        }
    }.add;

    for (suite.entries, 0..) |ep, i| {
        for (suite.entries[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, ep.id)) try p(arena, &problems, "entry {s}: duplicate id", .{ep.id});
            if (prev.harness == ep.harness and std.mem.eql(u8, prev.source_id, ep.source_id) and prev.seq >= ep.seq)
                try p(arena, &problems, "entry {s}: seq {d} does not follow {s} in source {s}", .{ ep.id, ep.seq, prev.id, ep.source_id });
        }
        _ = time.parseRfc3339(ep.reference_time) catch try p(arena, &problems, "entry {s}: bad reference_time {s}", .{ ep.id, ep.reference_time });
        if (ep.turns.len == 0) try p(arena, &problems, "entry {s}: no turns", .{ep.id});
        if (suite.gold(ep.id) == null) try p(arena, &problems, "entry {s}: no gold labels", .{ep.id});
    }
    for (suite.expected.entries.map.keys()) |id| {
        if (suite.entryIndex(id) == null) try p(arena, &problems, "gold entry {s}: not in entries.jsonl", .{id});
    }
    for (suite.entities(), 0..) |e, i| {
        for (suite.entities()[0..i]) |prev| if (std.mem.eql(u8, prev.id, e.id)) try p(arena, &problems, "entity {s}: duplicate id", .{e.id});
    }
    for (suite.facts, 0..) |f, i| {
        for (suite.facts[0..i]) |prev| if (std.mem.eql(u8, prev.fact.id, f.fact.id)) try p(arena, &problems, "fact {s}: duplicate id", .{f.fact.id});
        if (suite.entityIndex(f.fact.subject) == null) try p(arena, &problems, "fact {s}: unknown subject {s}", .{ f.fact.id, f.fact.subject });
        if ((f.fact.object == null) == (f.fact.object_value == null)) try p(arena, &problems, "fact {s}: needs exactly one of object and object_value", .{f.fact.id});
        if (f.fact.object) |o| if (suite.entityIndex(o) == null) try p(arena, &problems, "fact {s}: unknown object {s}", .{ f.fact.id, o });
        if (f.fact.valid_from != null and f.valid_from == null) try p(arena, &problems, "fact {s}: bad valid_from", .{f.fact.id});
        if (f.fact.valid_to != null and f.valid_to == null) try p(arena, &problems, "fact {s}: bad valid_to", .{f.fact.id});
    }
    for (suite.expected.expected_merges) |m| {
        if (suite.entityIndex(m.must_resolve_to) == null) try p(arena, &problems, "merge {s}: unknown entity {s}", .{ m.mention, m.must_resolve_to });
        if (suite.entryIndex(m.entry) == null) try p(arena, &problems, "merge {s}: unknown entry {s}", .{ m.mention, m.entry });
    }
    for (suite.expected.must_not_merge) |m| {
        for ([_][]const u8{ m.entity_a, m.entity_b }) |id| {
            if (suite.entityIndex(id) == null) try p(arena, &problems, "must_not_merge: unknown entity {s}", .{id});
        }
    }
    for (suite.expected.entries.map.keys(), suite.expected.entries.map.values()) |ep, g| {
        if (g.skip and g.facts_added.len > 0) try p(arena, &problems, "entry {s}: skip entry lists facts", .{ep});
        for (g.restated) |id| if (suite.factIndex(id) == null) try p(arena, &problems, "entry {s}: restates unknown fact {s}", .{ ep, id });
        for (g.must_remain_active) |id| if (suite.factIndex(id) == null) try p(arena, &problems, "entry {s}: must_remain_active names unknown fact {s}", .{ ep, id });
        for (g.invalidations) |inv| {
            if (suite.factIndex(inv.fact_id) == null) try p(arena, &problems, "entry {s}: invalidates unknown fact {s}", .{ ep, inv.fact_id });
            if (inv.valid_to) |v| _ = time.parseRfc3339(v) catch try p(arena, &problems, "entry {s}: bad invalidation valid_to {s}", .{ ep, v });
        }
        for (g.must_not_contain_facts) |text| {
            if (try parsePattern(arena, suite, text) == null) try p(arena, &problems, "entry {s}: cannot parse must_not_contain_facts entry '{s}'", .{ ep, text });
        }
    }
    for (suite.expected.retrieval_queries) |q| {
        for (q.must_include) |id| if (suite.factIndex(id) == null) try p(arena, &problems, "query {s}: must_include names unknown fact {s}", .{ q.id, id });
        for (q.must_exclude) |id| if (suite.factIndex(id) == null) try p(arena, &problems, "query {s}: must_exclude names unknown fact {s}", .{ q.id, id });
        if (q.as_of) |v| _ = time.parseRfc3339(v) catch try p(arena, &problems, "query {s}: bad as_of {s}", .{ q.id, v });
    }
    return problems.items;
}

pub fn shippedSuiteDir(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var dir: []const u8 = "evals";
    for (0..6) |_| {
        const probe = try std.fs.path.join(arena, &.{ dir, "expected.json" });
        if (std.Io.Dir.cwd().access(io, probe, .{})) |_| return dir else |_| {}
        dir = try std.fs.path.join(arena, &.{ "..", dir });
    }
    return error.FileNotFound;
}

pub fn loadShippedSuite(arena: std.mem.Allocator, io: std.Io) !Suite {
    return loadSuite(arena, io, try shippedSuiteDir(arena, io));
}

test "the shipped suite loads and is referentially intact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suite = try loadShippedSuite(arena, std.testing.io);
    try std.testing.expectEqual(@as(usize, 20), suite.entries.len);
    try std.testing.expectEqual(@as(usize, 22), suite.entities().len);
    try std.testing.expectEqual(@as(usize, 10), suite.expected.retrieval_queries.len);
    try std.testing.expectEqual(@as(usize, 20), suite.expected.entries.map.count());
    try std.testing.expectEqual(@as(usize, 28), suite.facts.len);
    try std.testing.expectEqual(@as(usize, 4), suite.expected.expected_merges.len);
    try std.testing.expectEqual(@as(usize, 3), suite.expected.must_not_merge.len);
    const problems = try validate(arena, &suite);
    for (problems) |msg| std.debug.print("suite problem: {s}\n", .{msg});
    try std.testing.expectEqual(@as(usize, 0), problems.len);
    try std.testing.expect(suite.isSkip("e04") and suite.isSkip("e14") and !suite.isSkip("e01"));
    try std.testing.expectEqual(core.Harness.@"claude-code", suite.entries[0].harness);
    try std.testing.expectEqual(core.types.EntryKind.note, suite.entries[11].kind);
}

test "validation reports dangling references" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suite = try parseSuite(arena,
        \\{"id":"e01","seq":1,"harness":"cli","source_id":"s","reference_time":"2026-11-18T18:00:00Z","kind":"note","author":"user","turns":[{"role":"user","text":"x"}]}
        \\{"id":"e02","seq":1,"harness":"cli","source_id":"s","reference_time":"later","kind":"note","author":"user","turns":[{"role":"user","text":"y"}]}
    ,
        \\{"suite_version":"t","canonical_entities":[{"id":"a","name":"A","type":"software"}],
        \\ "entries":{"e01":{"facts_added":[{"id":"f1","subject":"a","relation":"uses","object":"b"}],"restated":["nope"],"must_not_contain_facts":["Nobody uses this"]}},
        \\ "retrieval_queries":[{"id":"q","query":"?","must_include":["f9"]}]}
    );
    const problems = try validate(arena, &suite);
    const want = [_][]const u8{ "does not follow", "bad reference_time", "e02: no gold labels", "unknown object b", "restates unknown fact nope", "cannot parse", "unknown fact f9" };
    for (want) |w| {
        var found = false;
        for (problems) |msg| found = found or std.mem.indexOf(u8, msg, w) != null;
        if (!found) std.debug.print("missing problem containing '{s}'\n", .{w});
        try std.testing.expect(found);
    }
}

test "must_not_contain patterns resolve their subject" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suite = try loadShippedSuite(arena, std.testing.io);
    const pat = (try parsePattern(arena, &suite, "graf uses Apache AGE")).?;
    try std.testing.expectEqualStrings("ent_graf", suite.entities()[pat.subject].id);
    try std.testing.expectEqualStrings("uses", pat.relation);
    try std.testing.expectEqualStrings("apache age", pat.object);
}
