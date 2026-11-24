const std = @import("std");
const core = @import("core");

const Id = core.Id;
const Micros = core.Micros;
const Fact = core.Fact;
const EntityType = core.EntityType;
const Cardinality = core.types.Cardinality;

pub const merge_cosine: f32 = 0.93;
pub const merge_jaccard: f32 = 0.50;
pub const gray_cosine: f32 = 0.78;
pub const gray_cross_type_cosine: f32 = 0.90;
pub const gray_per_entity: usize = 5;

pub const neighbour_cosine: f32 = 0.72;
pub const neighbours_per_fact: usize = 8;
pub const max_invalidations: usize = 5;
pub const relation_collapse_cosine: f32 = 0.90;

pub fn initialConfidence(by: core.types.FactAuthor) f32 {
    return switch (by) {
        .user => 0.90,
        .tool => 0.80,
        .agent => 0.70,
    };
}

pub fn restate(c: f32) f32 {
    return @min(1.0, c + (1.0 - c) * 0.30);
}

pub fn cosine(a: []const f32, b: []const f32) f32 {
    if (a.len == 0 or a.len != b.len) return 0;
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * y;
        na += @as(f64, x) * x;
        nb += @as(f64, y) * y;
    }
    if (na == 0 or nb == 0) return 0;
    return @floatCast(dot / (@sqrt(na) * @sqrt(nb)));
}

pub fn tokenJaccard(a_norm: []const u8, b_norm: []const u8) f32 {
    var inter: usize = 0;
    var a_count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, a_norm, ' ');
    outer: while (it.next()) |tok| {
        var seen = std.mem.tokenizeScalar(u8, a_norm[0 .. it.index - tok.len], ' ');
        while (seen.next()) |prev| if (std.mem.eql(u8, prev, tok)) continue :outer;
        a_count += 1;
        var bt = std.mem.tokenizeScalar(u8, b_norm, ' ');
        while (bt.next()) |other| if (std.mem.eql(u8, other, tok)) {
            inter += 1;
            break;
        };
    }
    var b_count: usize = 0;
    var bi = std.mem.tokenizeScalar(u8, b_norm, ' ');
    outer: while (bi.next()) |tok| {
        var seen = std.mem.tokenizeScalar(u8, b_norm[0 .. bi.index - tok.len], ' ');
        while (seen.next()) |prev| if (std.mem.eql(u8, prev, tok)) continue :outer;
        b_count += 1;
    }
    const uni = a_count + b_count - inter;
    if (uni == 0) return 0;
    return @as(f32, @floatFromInt(inter)) / @as(f32, @floatFromInt(uni));
}

fn isSoftware(t: EntityType) bool {
    return switch (t) {
        .software, .code => true,
        else => false,
    };
}

pub fn hardBlocked(a: EntityType, b: EntityType) bool {
    const groupish = struct {
        fn f(t: EntityType) bool {
            return t == .organization or t == .project;
        }
    }.f;
    return (a == .person and groupish(b)) or (b == .person and groupish(a));
}

pub fn compatible(a: EntityType, b: EntityType) bool {
    if (a == b) return true;
    if (isSoftware(a) and isSoftware(b)) return true;
    if ((a == .other and b != .person) or (b == .other and a != .person)) return true;
    return false;
}

pub const RelationRule = struct {
    cardinality: Cardinality = .many,
    opposes: ?[]const u8 = null,
};

pub fn ruleFor(name: []const u8, override: ?RelationRule) RelationRule {
    if (core.ontology.find(name)) |p| return .{ .cardinality = p.cardinality, .opposes = p.opposes };
    return override orelse .{};
}

pub const ObjectKey = union(enum) {
    entity: Id,
    value: []const u8,

    pub fn eql(a: ObjectKey, b: ObjectKey) bool {
        return switch (a) {
            .entity => |x| switch (b) {
                .entity => |y| x.eql(y),
                .value => false,
            },
            .value => |x| switch (b) {
                .entity => false,
                .value => |y| std.mem.eql(u8, x, y),
            },
        };
    }
};

pub const Key = struct {
    subject: Id,
    relation: []const u8,
    qualifier: []const u8,
    object: ObjectKey,
    valid: core.Range,
};

pub fn sameCanonicalKey(a: Key, b: Key) bool {
    return a.subject.eql(b.subject) and std.mem.eql(u8, a.relation, b.relation) and
        std.mem.eql(u8, a.qualifier, b.qualifier) and a.object.eql(b.object);
}

pub fn rangesOverlap(a: core.Range, b: core.Range) bool {
    if (a.upper) |au| if (b.lower) |bl| if (au <= bl) return false;
    if (b.upper) |bu| if (a.lower) |al| if (bu <= al) return false;
    return true;
}

pub const ConflictReason = enum { one_per_subject, one_per_subject_qualifier, one_per_object, opposed };

pub fn conflict(new: Key, rule: RelationRule, old: Key) ?ConflictReason {
    if (!rangesOverlap(new.valid, old.valid)) return null;
    const same_pred = std.mem.eql(u8, new.relation, old.relation);
    if (same_pred) switch (rule.cardinality) {
        .many => {},
        .one_per_subject => if (new.subject.eql(old.subject) and !new.object.eql(old.object)) return .one_per_subject,
        .one_per_subject_qualifier => if (new.subject.eql(old.subject) and
            std.mem.eql(u8, new.qualifier, old.qualifier) and !new.object.eql(old.object)) return .one_per_subject_qualifier,
        .one_per_object => if (new.object.eql(old.object) and !new.subject.eql(old.subject)) return .one_per_object,
    };
    if (rule.opposes) |opp| if (std.mem.eql(u8, opp, old.relation) and new.subject.eql(old.subject) and
        std.mem.eql(u8, new.qualifier, old.qualifier) and new.object.eql(old.object)) return .opposed;
    return null;
}

pub const ConflictKind = enum { changed, was_wrong };

pub const Effect = enum {
    none,
    retracted_old,
    ended_old,
    bounded_new,
};

pub fn resolveConflict(old: *Fact, new: *Fact, kind: ConflictKind, commit_time: Micros, new_reference_time: Micros) Effect {
    if (kind == .was_wrong) {
        old.known.upper = commit_time;
        old.end_kind = .retracted;
        old.ended_by = new.id;
        return .retracted_old;
    }
    if (!rangesOverlap(old.valid, new.valid)) return .none;

    const old_lo = old.valid.lower;
    const new_lo = new.valid.lower;
    const starts_after = if (new_lo) |n| (if (old_lo) |o| n > o else true) else false;
    const starts_before = if (old_lo) |o| (if (new_lo) |n| n < o else true) else false;

    if (starts_after) {
        old.valid.upper = minUpper(old.valid.upper, new_lo.?);
        old.end_kind = .changed;
        old.ended_by = new.id;
        return .ended_old;
    }
    if (starts_before) {
        new.valid.upper = minUpper(new.valid.upper, old_lo.?);
        return .bounded_new;
    }
    if (old_lo) |o| if (new_reference_time <= o) {
        old.known.upper = commit_time;
        old.end_kind = .retracted;
        old.ended_by = new.id;
        return .retracted_old;
    };
    old.valid.upper = minUpper(old.valid.upper, new_reference_time);
    old.end_kind = .changed;
    old.ended_by = new.id;
    return .ended_old;
}

fn minUpper(cur: ?Micros, t: Micros) Micros {
    return if (cur) |c| @min(c, t) else t;
}

pub const BlastRadius = struct {
    used: usize = 0,
    dropped: usize = 0,

    pub fn admit(b: *BlastRadius) bool {
        if (b.used < max_invalidations) {
            b.used += 1;
            return true;
        }
        b.dropped += 1;
        return false;
    }
};

pub const KnownRelation = struct {
    name: []const u8,
    emb: []const f32,
};

pub fn collapseRelation(novel_emb: []const f32, known: []const KnownRelation) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_cos: f32 = relation_collapse_cosine;
    for (known) |k| {
        const c = cosine(novel_emb, k.emb);
        if (c >= best_cos) {
            best_cos = c;
            best = k.name;
        }
    }
    return best;
}

pub fn validRelationName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64 or !std.ascii.isLower(s[0])) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return s[s.len - 1] != '_';
}

const testing = std.testing;
const day = 86_400_000_000;

fn id(n: u8) Id {
    return Id.fromParts(n, @splat(n));
}

fn fact(n: u8, lower: ?Micros, upper: ?Micros) Fact {
    return .{
        .id = id(n),
        .graph_id = id(0),
        .subject_id = id(100),
        .relation = "has_oncall",
        .object = .{ .entity = id(n + 50) },
        .text = "",
        .scope = .project,
        .valid = .{ .lower = lower, .upper = upper },
        .known = .{ .lower = 0 },
        .author = .user,
        .confidence = 0.9,
    };
}

test "a later state change ends the old fact at the new start (on-call handoff)" {
    var old = fact(1, 10 * day, null);
    var new = fact(2, 12 * day, null);
    try testing.expectEqual(Effect.ended_old, resolveConflict(&old, &new, .changed, 99 * day, 12 * day));
    try testing.expectEqual(@as(?Micros, 12 * day), old.valid.upper);
    try testing.expectEqual(core.types.EndKind.changed, old.end_kind.?);
    try testing.expect(old.ended_by.?.eql(new.id));
    try testing.expect(old.known.upper == null);
    try testing.expect(new.valid.upper == null);
}

test "was_wrong retracts by closing system time, never valid time" {
    var old = fact(1, 10 * day, null);
    var new = fact(2, 12 * day, null);
    try testing.expectEqual(Effect.retracted_old, resolveConflict(&old, &new, .was_wrong, 13 * day, 12 * day));
    try testing.expectEqual(@as(?Micros, 13 * day), old.known.upper);
    try testing.expect(old.valid.upper == null);
    try testing.expectEqual(core.types.EndKind.retracted, old.end_kind.?);
}

test "historical backfill bounds the new fact and leaves current state alone" {
    var current = fact(1, 20 * day, null);
    var backfill = fact(2, 5 * day, null);
    try testing.expectEqual(Effect.bounded_new, resolveConflict(&current, &backfill, .changed, 30 * day, 30 * day));
    try testing.expect(current.valid.upper == null);
    try testing.expect(current.end_kind == null);
    try testing.expectEqual(@as(?Micros, 20 * day), backfill.valid.upper);

    var dated = fact(3, 5 * day, 12 * day);
    try testing.expectEqual(Effect.none, resolveConflict(&current, &dated, .changed, 30 * day, 30 * day));
    try testing.expectEqual(@as(?Micros, 12 * day), dated.valid.upper);
}

test "an old fact with an unknown start is ended by any dated change" {
    var old = fact(1, null, null);
    var new = fact(2, 3 * day, null);
    try testing.expectEqual(Effect.ended_old, resolveConflict(&old, &new, .changed, 9 * day, 3 * day));
    try testing.expectEqual(@as(?Micros, 3 * day), old.valid.upper);
}

test "same start closes the old fact at the reference time" {
    var old = fact(1, 10 * day, null);
    var new = fact(2, 10 * day, null);
    try testing.expectEqual(Effect.ended_old, resolveConflict(&old, &new, .changed, 20 * day, 11 * day));
    try testing.expectEqual(@as(?Micros, 11 * day), old.valid.upper);

    var old2 = fact(3, 10 * day, null);
    var new2 = fact(4, 10 * day, null);
    try testing.expectEqual(Effect.retracted_old, resolveConflict(&old2, &new2, .changed, 20 * day, 10 * day));
}

test "a fact that already ended before the new one starts is never modified" {
    var ended = fact(1, 1 * day, 4 * day);
    var new = fact(2, 6 * day, null);
    try testing.expectEqual(Effect.none, resolveConflict(&ended, &new, .changed, 9 * day, 6 * day));
    try testing.expectEqual(@as(?Micros, 4 * day), ended.valid.upper);
    try testing.expect(ended.end_kind == null);
}

test "blast radius admits five endings and counts the rest" {
    var b: BlastRadius = .{};
    var admitted: usize = 0;
    for (0..8) |_| {
        if (b.admit()) admitted += 1;
    }
    try testing.expectEqual(@as(usize, 5), admitted);
    try testing.expectEqual(@as(usize, 3), b.dropped);
}

test "restatement raises confidence smoothly toward one" {
    try testing.expectApproxEqAbs(@as(f32, 0.93), restate(0.90), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.79), restate(0.70), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.951), restate(restate(0.90)), 1e-5);
    try testing.expectEqual(@as(f32, 1.0), restate(1.0));
    try testing.expectEqual(@as(f32, 0.90), initialConfidence(.user));
    try testing.expectEqual(@as(f32, 0.80), initialConfidence(.tool));
    try testing.expectEqual(@as(f32, 0.70), initialConfidence(.agent));
}

test "cardinality conflicts" {
    const subj = id(1);
    const base: Key = .{ .subject = subj, .relation = "has_oncall", .qualifier = "", .object = .{ .entity = id(2) }, .valid = .{ .lower = 0 } };
    var other = base;
    other.object = .{ .entity = id(3) };
    const one = ruleFor("has_oncall", null);
    try testing.expectEqual(ConflictReason.one_per_subject, conflict(other, one, base).?);
    try testing.expect(conflict(base, one, base) == null);
    try testing.expect(sameCanonicalKey(base, base));

    var dated = other;
    dated.valid = .{ .lower = -10, .upper = -1 };
    try testing.expect(conflict(dated, one, base) == null);

    const setting: Key = .{ .subject = subj, .relation = "has_setting", .qualifier = "extraction_model", .object = .{ .value = "model a" }, .valid = .{ .lower = 0 } };
    var setting2 = setting;
    setting2.object = .{ .value = "model b" };
    const q = ruleFor("has_setting", null);
    try testing.expectEqual(ConflictReason.one_per_subject_qualifier, conflict(setting2, q, setting).?);
    var other_q = setting2;
    other_q.qualifier = "embed_model";
    try testing.expect(conflict(other_q, q, setting) == null);

    const lacks: Key = .{ .subject = subj, .relation = "lacks_feature", .qualifier = "", .object = .{ .value = "copy" }, .valid = .{ .lower = 0 } };
    var supports = lacks;
    supports.relation = "supports_feature";
    try testing.expectEqual(ConflictReason.opposed, conflict(supports, ruleFor("supports_feature", null), lacks).?);
    var supports_other = supports;
    supports_other.object = .{ .value = "pipelining" };
    try testing.expect(conflict(supports_other, ruleFor("supports_feature", null), lacks) == null);

    const uses: Key = .{ .subject = subj, .relation = "uses", .qualifier = "", .object = .{ .entity = id(7) }, .valid = .{ .lower = 0 } };
    var uses2 = uses;
    uses2.object = .{ .entity = id(8) };
    try testing.expect(conflict(uses2, ruleFor("uses", null), uses) == null);
    try testing.expect(conflict(uses2, ruleFor("owned_by_team", .{ .cardinality = .one_per_object }), blk: {
        var k = uses;
        k.relation = "owned_by_team";
        k.object = .{ .entity = id(8) };
        k.subject = id(9);
        break :blk k;
    }) == null);
}

test "entity type guards" {
    try testing.expect(hardBlocked(.person, .organization));
    try testing.expect(hardBlocked(.project, .person));
    try testing.expect(!hardBlocked(.code, .dataset));
    try testing.expect(compatible(.software, .code));
    try testing.expect(!compatible(.code, .dataset));
    try testing.expect(!compatible(.organization, .code));
    try testing.expect(compatible(.other, .software));
    try testing.expect(!compatible(.other, .person));
}

test "token jaccard and cosine" {
    try testing.expectEqual(@as(f32, 1.0), tokenJaccard("pg zig", "pg zig"));
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), tokenJaccard("brackwater gateway", "brackwater relay"), 1e-6);
    try testing.expectEqual(@as(f32, 0.0), tokenJaccard("", "x"));
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), tokenJaccard("a a b", "a c"), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), cosine(&.{ 1, 2 }, &.{ 2, 4 }), 1e-6);
    try testing.expectEqual(@as(f32, 0.0), cosine(&.{ 1, 0 }, &.{ 0, 1 }));
}

test "relation collapse picks the closest known relation above the threshold" {
    const known = [_]KnownRelation{
        .{ .name = "fixed_by", .emb = &.{ 1, 0, 0 } },
        .{ .name = "uses", .emb = &.{ 0, 1, 0 } },
    };
    try testing.expectEqualStrings("fixed_by", collapseRelation(&.{ 0.98, 0.1, 0.05 }, &known).?);
    try testing.expect(collapseRelation(&.{ 0.7, 0.7, 0 }, &known) == null);
    try testing.expect(validRelationName("resolved_by"));
    try testing.expect(!validRelationName("ResolvedBy"));
    try testing.expect(!validRelationName("bad-name"));
    try testing.expect(!validRelationName("trailing_"));
}
