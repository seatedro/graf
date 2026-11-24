const std = @import("std");
const core = @import("core");
const time = @import("time.zig");

const Allocator = std.mem.Allocator;

pub fn normalize(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var gap = false;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\'' or c == '`') {
            i += 1;
            continue;
        }
        if (c == 0xE2 and i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0x98 or s[i + 2] == 0x99)) {
            i += 3;
            continue;
        }
        if (std.ascii.isAlphanumeric(c) or c >= 0x80) {
            if (gap and out.items.len > 0) try out.append(arena, ' ');
            gap = false;
            try out.append(arena, std.ascii.toLower(c));
        } else gap = true;
        i += 1;
    }
    return out.items;
}

const TypeClass = enum { person, group, software, data, activity, concept, other };

fn typeClass(t: core.EntityType) TypeClass {
    return switch (t) {
        .person => .person,
        .organization => .group,
        .project, .repository, .code, .software, .ai_model, .environment => .software,
        .dataset, .document => .data,
        .decision, .task, .change, .session, .run, .problem, .event => .activity,
        .concept => .concept,
        .other => .other,
    };
}

pub fn typesCompatible(a: core.EntityType, b: core.EntityType) bool {
    const ca = typeClass(a);
    const cb = typeClass(b);
    return ca == cb or ca == .other or cb == .other;
}

const Canon = struct { name: []const u8, inverse: bool };

const relation_equivalents = [_]struct { []const u8, []const u8, bool }{
    .{ "owns", "owned_by", true },
    .{ "maintained_by", "maintains", true },
    .{ "has_part", "part_of", true },
    .{ "contains", "part_of", true },
    .{ "oncall_for", "has_oncall", true },
    .{ "on_call_for", "has_oncall", true },
    .{ "is_oncall_for", "has_oncall", true },
    .{ "has_on_call", "has_oncall", false },
    .{ "oncall", "has_oncall", false },
    .{ "hosted_on", "located_at", false },
    .{ "hosted_at", "located_at", false },
    .{ "runs_on", "located_at", false },
    .{ "deployed_on", "located_at", false },
    .{ "located_in", "located_at", false },
    .{ "lives_in", "located_at", false },
    .{ "depends_on", "uses", false },
    .{ "built_with", "uses", false },
    .{ "written_in", "uses", false },
    .{ "implemented_in", "uses", false },
    .{ "routes_through", "uses", false },
    .{ "routes_via", "uses", false },
    .{ "has_feature", "supports_feature", false },
    .{ "supports", "supports_feature", false },
    .{ "missing_feature", "lacks_feature", false },
    .{ "lacks", "lacks_feature", false },
    .{ "decided_against", "rejected", false },
    .{ "compared_with", "related_to", false },
    .{ "compared_to", "related_to", false },
    .{ "compared_against", "related_to", false },
    .{ "scheduled_on", "scheduled_for", false },
    .{ "scheduled_at", "scheduled_for", false },
};

pub fn canonicalRelation(arena: Allocator, relation: []const u8) Allocator.Error!Canon {
    const norm = try normalize(arena, relation);
    const name = try arena.dupe(u8, norm);
    std.mem.replaceScalar(u8, name, ' ', '_');
    for (relation_equivalents) |e| {
        if (std.mem.eql(u8, e[0], name)) return .{ .name = e[1], .inverse = e[2] };
    }
    return .{ .name = name, .inverse = false };
}

pub fn valueMatch(arena: Allocator, gold: []const u8, got: []const u8) Allocator.Error!u8 {
    const a = try normalize(arena, gold);
    const b = try normalize(arena, got);
    if (a.len == 0 or b.len == 0) return 0;
    if (std.mem.eql(u8, a, b)) return 2;
    if (time.parseLooseDate(gold)) |ta| if (time.parseLooseDate(got)) |tb| if (time.withinOneDay(ta, tb)) return 2;
    const short, const long = if (a.len <= b.len) .{ a, b } else .{ b, a };
    var it = std.mem.tokenizeScalar(u8, short, ' ');
    while (it.next()) |tok| {
        var found = false;
        var lit = std.mem.tokenizeScalar(u8, long, ' ');
        while (lit.next()) |other| found = found or std.mem.eql(u8, tok, other);
        if (!found) return 0;
    }
    return 1;
}

pub fn containsWord(haystack: []const u8, word: []const u8) bool {
    if (word.len == 0) return false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, word)) |at| {
        const before_ok = at == 0 or !std.ascii.isAlphanumeric(haystack[at - 1]);
        const end = at + word.len;
        const after_ok = end == haystack.len or !std.ascii.isAlphanumeric(haystack[end]);
        if (before_ok and after_ok) return true;
        start = at + 1;
    }
    return false;
}

const testing = std.testing;

test "normalizer folds punctuation, case, and apostrophes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("pg zig", try normalize(arena, "pg.zig"));
    try testing.expectEqualStrings("pg zig", try normalize(arena, "  PG-zig "));
    try testing.expectEqualStrings("pg zig", try normalize(arena, "pg_zig"));
    try testing.expectEqualStrings("karlseguins driver", try normalize(arena, "karlseguin's  driver"));
    try testing.expectEqualStrings("karlseguins driver", try normalize(arena, "karlseguin\u{2019}s driver"));
    try testing.expectEqualStrings("brackwater buoy", try normalize(arena, "brackwater-buoy"));
    try testing.expectEqualStrings("brackwater", try normalize(arena, "Brackwater"));
    try testing.expectEqualStrings("brackwater harbor ops", try normalize(arena, "brackwater/harbor-ops"));
    try testing.expectEqualStrings("surge net 2 0 lite", try normalize(arena, "surge-net-2.0-lite"));
    try testing.expectEqualStrings("", try normalize(arena, " -- "));
}

test "relations and values match through the equivalence rules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const owns = try canonicalRelation(arena, "Owns");
    try testing.expectEqualStrings("owned_by", owns.name);
    try testing.expect(owns.inverse);
    try testing.expectEqualStrings("has_setting", (try canonicalRelation(arena, "has-setting")).name);
    try testing.expectEqual(@as(u8, 2), try valueMatch(arena, "COPY", "copy"));
    try testing.expectEqual(@as(u8, 1), try valueMatch(arena, "COPY", "COPY support"));
    try testing.expectEqual(@as(u8, 2), try valueMatch(arena, "2026-12-03", "December 3, 2026"));
    try testing.expectEqual(@as(u8, 0), try valueMatch(arena, "pipelining", "COPY"));
    try testing.expect(containsWord("Quayline uses Go.", "Go"));
    try testing.expect(!containsWord("Google", "Go"));
    try testing.expect(typesCompatible(.software, .software));
    try testing.expect(!typesCompatible(.organization, .software));
    try testing.expect(!typesCompatible(.dataset, .software));
    try testing.expect(typesCompatible(.other, .person));
}
