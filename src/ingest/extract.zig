const std = @import("std");
const core = @import("core");
const ingest = @import("mod.zig");
const rules = @import("rules.zig");
const time = @import("time.zig");

const Allocator = std.mem.Allocator;
const ExtractResult = ingest.ExtractResult;
const ExtractedEntity = ingest.ExtractedEntity;
const ExtractedFact = ingest.ExtractedFact;

pub const max_quote_bytes = 200;

pub fn decode(arena: Allocator, json: []const u8) !ExtractResult {
    return std.json.parseFromSliceLeaky(ExtractResult, arena, json, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
}

pub const FactMeta = struct {
    valid: core.Range,
    quote_pos: ?usize,
};

pub const Checked = struct {
    result: ExtractResult,
    meta: []const FactMeta,
    warnings: []const []const u8,
    invalid_facts: usize,
    needs_repair: bool,

    pub fn isEmpty(c: Checked) bool {
        return c.result.skip != null or c.result.facts.len == 0;
    }
};

pub fn bodyText(arena: Allocator, body: core.EntryBody) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (body.text) |txt| try out.appendSlice(arena, txt);
    for (body.turns) |turn| {
        if (out.items.len > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, turn.text);
        for (turn.tool_calls) |tc| {
            try out.append(arena, '\n');
            try out.appendSlice(arena, tc.args_preview);
            try out.append(arena, '\n');
            try out.appendSlice(arena, tc.result_preview);
        }
    }

    return out.items;
}

const Warnings = struct {
    list: std.ArrayList([]const u8) = .empty,
    arena: Allocator,

    fn add(w: *Warnings, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try w.list.append(w.arena, try std.fmt.allocPrint(w.arena, fmt, args));
    }
};

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

pub fn check(arena: Allocator, raw: ExtractResult, body_text: []const u8, reference_time: core.Micros) Allocator.Error!Checked {
    var w: Warnings = .{ .arena = arena };

    var entities: std.ArrayList(ExtractedEntity) = .empty;
    var norms: std.ArrayList([]const u8) = .empty;
    var ref_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (raw.entities) |e_in| {
        var e = e_in;
        e.ref = trimmed(e.ref);
        e.name = trimmed(e.name);
        if (e.ref.len == 0 or e.name.len == 0) {
            try w.add("dropped entity with empty ref or name", .{});
            continue;
        }
        if (ref_map.contains(e.ref)) {
            try w.add("dropped duplicate entity ref {s}", .{e.ref});
            continue;
        }

        const n = try core.text.norm(arena, e.name);
        if (n.len == 0) {
            try w.add("dropped entity {s} whose name has no letters or digits", .{e.ref});
            continue;
        }

        var folded = false;
        for (entities.items, norms.items) |*kept, kept_norm| {
            if (std.mem.eql(u8, kept_norm, n) and rules.compatible(kept.type, e.type)) {
                try ref_map.put(arena, e.ref, kept.ref);
                var aliases: std.ArrayList([]const u8) = .empty;
                try aliases.appendSlice(arena, kept.aliases);
                try aliases.appendSlice(arena, e.aliases);
                if (!std.mem.eql(u8, kept.name, e.name)) try aliases.append(arena, e.name);
                kept.aliases = aliases.items;
                folded = true;
                break;
            }
        }

        if (folded) continue;
        try ref_map.put(arena, e.ref, e.ref);
        try entities.append(arena, e);
        try norms.append(arena, n);
    }

    const Resolver = struct {
        map: *const std.StringHashMapUnmanaged([]const u8),
        ents: []const ExtractedEntity,
        norms: []const []const u8,
        arena: Allocator,

        fn ref(r: @This(), s: []const u8) Allocator.Error!?[]const u8 {
            const tr = trimmed(s);
            if (r.map.get(tr)) |canonical| return canonical;
            const n = try core.text.norm(r.arena, tr);
            for (r.ents, r.norms) |e, en| if (std.mem.eql(u8, en, n)) return e.ref;
            return null;
        }
    };

    const resolver: Resolver = .{ .map = &ref_map, .ents = entities.items, .norms = norms.items, .arena = arena };

    var facts: std.ArrayList(ExtractedFact) = .empty;
    var meta: std.ArrayList(FactMeta) = .empty;
    var invalid: usize = 0;
    for (raw.facts, 0..) |f_in, i| {
        var f = f_in;
        const reason: ?[]const u8 = blk: {
            f.subject = (try resolver.ref(f.subject)) orelse break :blk "unknown subject ref";
            f.relation = trimmed(f.relation);
            if (!rules.validRelationName(f.relation)) break :blk "relation is not snake_case";
            if (f.object != null and f.value != null) break :blk "both object and value are set";
            if (f.object) |o| {
                f.object = (try resolver.ref(o)) orelse break :blk "unknown object ref";
            } else if (f.value) |v| {
                f.value = trimmed(v);
                if (f.value.?.len == 0) break :blk "empty value";
            } else break :blk "neither object nor value is set";
            f.text = trimmed(f.text);
            if (f.text.len == 0) break :blk "empty text";
            f.quote = truncateUtf8(trimmed(f.quote), max_quote_bytes);
            if (f.quote.len == 0) break :blk "empty quote";
            if (f.qualifier) |q| f.qualifier = if (trimmed(q).len == 0) null else trimmed(q);
            break :blk null;
        };

        if (reason) |r| {
            invalid += 1;
            try w.add("dropped fact {d}: {s}", .{ i, r });
            continue;
        }

        const from_explicit = if (f.valid_from) |s| trimmed(s).len > 0 else false;
        var upper = time.parseBound(f.valid_to) catch {
            invalid += 1;
            try w.add("dropped fact {d}: valid_to is not RFC 3339", .{i});
            continue;
        };

        const ended_already = if (upper) |u| u <= reference_time else false;
        const lower: ?core.Micros = if (from_explicit)
            time.parseBound(f.valid_from) catch {
                invalid += 1;
                try w.add("dropped fact {d}: valid_from is not RFC 3339", .{i});
                continue;
            }
        else if (ended_already)
            null
        else
            reference_time;

        if (upper) |u| if (lower) |l| if (u <= l) {
            try w.add("fact {d}: valid_to is not after valid_from; treating it as open", .{i});
            upper = null;
            f.valid_to = null;
        };

        try facts.append(arena, f);
        try meta.append(arena, .{
            .valid = .{ .lower = lower, .upper = upper },
            .quote_pos = std.mem.indexOf(u8, body_text, f.quote),
        });
    }

    const n_facts = facts.items.len;
    const drop = try arena.alloc(bool, n_facts);
    @memset(drop, false);

    for (0..n_facts) |i| {
        for (0..n_facts) |j| {
            if (i == j or drop[j]) continue;
            if (!laterThan(meta.items, j, i)) continue;
            if (try collides(arena, facts.items[j], meta.items[j], facts.items[i], meta.items[i])) {
                drop[i] = true;
                try w.add("fact {d} superseded by a later statement in the same entry", .{i});
                break;
            }
        }
    }

    var kept_facts: std.ArrayList(ExtractedFact) = .empty;
    var kept_meta: std.ArrayList(FactMeta) = .empty;
    for (facts.items, meta.items, drop) |f, m, d| if (!d) {
        try kept_facts.append(arena, f);
        try kept_meta.append(arena, m);
    };

    var rels: std.ArrayList(ingest.ProposedRelation) = .empty;
    outer: for (raw.new_relations) |p_in| {
        var p = p_in;
        p.name = trimmed(p.name);
        if (!rules.validRelationName(p.name)) {
            try w.add("dropped proposed relation that is not snake_case", .{});
            continue;
        }
        for (rels.items) |prev| if (std.mem.eql(u8, prev.name, p.name)) continue :outer;
        try rels.append(arena, p);
    }

    return .{
        .result = .{
            .skip = if (raw.skip) |s| (if (trimmed(s).len == 0) null else s) else null,
            .entities = entities.items,
            .facts = kept_facts.items,
            .new_relations = rels.items,
        },
        .meta = kept_meta.items,
        .warnings = w.list.items,
        .invalid_facts = invalid,
        .needs_repair = raw.facts.len > 0 and invalid * 2 > raw.facts.len,
    };
}

fn laterThan(meta: []const FactMeta, a: usize, b: usize) bool {
    if (meta[a].quote_pos) |pa| if (meta[b].quote_pos) |pb| if (pa != pb) return pa > pb;
    return a > b;
}

const RefObject = union(enum) { ref: []const u8, value: []const u8 };

fn objectOf(arena: Allocator, f: ExtractedFact) Allocator.Error!RefObject {
    if (f.object) |o| return .{ .ref = o };
    return .{ .value = try core.text.norm(arena, f.value.?) };
}

fn sameObject(a: RefObject, b: RefObject) bool {
    return switch (a) {
        .ref => |x| switch (b) {
            .ref => |y| std.mem.eql(u8, x, y),
            .value => false,
        },
        .value => |x| switch (b) {
            .ref => false,
            .value => |y| std.mem.eql(u8, x, y),
        },
    };
}

fn collides(arena: Allocator, later: ExtractedFact, later_meta: FactMeta, earlier: ExtractedFact, earlier_meta: FactMeta) Allocator.Error!bool {
    if (!std.mem.eql(u8, later.subject, earlier.subject)) {
        const rule = rules.ruleFor(later.relation, null);
        if (rule.cardinality != .one_per_object or !std.mem.eql(u8, later.relation, earlier.relation)) return false;
        if (!rules.rangesOverlap(later_meta.valid, earlier_meta.valid)) return false;
        return sameObject(try objectOf(arena, later), try objectOf(arena, earlier));
    }

    const lo = try objectOf(arena, later);
    const eo = try objectOf(arena, earlier);
    const lq = later.qualifier orelse "";
    const eq = earlier.qualifier orelse "";
    const same_relation = std.mem.eql(u8, later.relation, earlier.relation);
    if (same_relation and std.mem.eql(u8, lq, eq) and sameObject(lo, eo)) return true;

    if (!rules.rangesOverlap(later_meta.valid, earlier_meta.valid)) return false;
    const rule = rules.ruleFor(later.relation, null);
    if (same_relation) switch (rule.cardinality) {
        .one_per_subject => return !sameObject(lo, eo),
        .one_per_subject_qualifier => return std.mem.eql(u8, lq, eq) and !sameObject(lo, eo),
        else => {},
    };
    if (rule.opposes) |opp| if (std.mem.eql(u8, opp, earlier.relation) and std.mem.eql(u8, lq, eq) and sameObject(lo, eo)) return true;
    return false;
}

const testing = std.testing;

fn ent(ref: []const u8, name: []const u8, ty: core.EntityType) ExtractedEntity {
    return .{ .ref = ref, .name = name, .type = ty, .aliases = &.{}, .description = "" };
}

fn fct(subject: []const u8, relation: []const u8, object: ?[]const u8, value: ?[]const u8, quote: []const u8) ExtractedFact {
    return .{
        .subject = subject,
        .relation = relation,
        .qualifier = null,
        .object = object,
        .value = value,
        .text = "a fact",
        .rationale = null,
        .valid_from = null,
        .valid_to = null,
        .time_basis = .reference,
        .scope = .project,
        .author = .user,
        .quote = quote,
    };
}

const ref_time = 1_763_658_000_000_000;

test "decode is strict about unknown fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ok = try decode(arena, "{\"skip\":null,\"entities\":[],\"facts\":[],\"new_relations\":[]}");
    try testing.expect(ok.skip == null);
    try testing.expectError(error.UnknownField, decode(arena, "{\"skip\":null,\"entities\":[],\"facts\":[],\"new_relations\":[],\"extra\":1}"));
    try testing.expect(std.meta.isError(decode(arena, "```json\n{}\n```")));
}

test "one bad fact is dropped and the rest survive without repair" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "lantern uses brackwater relay. lantern lacks streaming.";
    const raw: ExtractResult = .{
        .skip = null,
        .entities = &.{ ent("n1", "Lantern", .project), ent("n2", "Brackwater Relay", .software) },
        .facts = &.{
            fct("n1", "uses", "n2", null, "lantern uses brackwater relay"),
            fct("n1", "lacks_feature", null, "streaming", "lantern lacks streaming"),
            fct("n9", "uses", "n2", null, "lantern uses brackwater relay"),
            fct("n1", "Uses", "n2", null, "x"),
            fct("n1", "uses", null, null, "x"),
            fct("Brackwater Relay", "maintains", "n1", null, "lantern uses brackwater relay"),
        },
        .new_relations = &.{},
    };

    const c = try check(arena, raw, body, ref_time);
    try testing.expectEqual(@as(usize, 3), c.result.facts.len);
    try testing.expectEqual(@as(usize, 3), c.invalid_facts);
    try testing.expect(!c.needs_repair);
    try testing.expectEqualStrings("n2", c.result.facts[2].subject);
    try testing.expectEqual(@as(?core.Micros, ref_time), c.meta[0].valid.lower);
    try testing.expectEqual(@as(?usize, 0), c.meta[0].quote_pos);
}

test "more than half invalid asks for a repair" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw: ExtractResult = .{
        .skip = null,
        .entities = &.{ent("n1", "Lantern", .project)},
        .facts = &.{
            fct("n1", "uses", null, "zig", "uses zig"),
            fct("n7", "uses", null, "go", "q"),
            fct("n1", "uses", null, "c", ""),
        },
        .new_relations = &.{},
    };

    const c = try check(arena, raw, "uses zig", ref_time);
    try testing.expect(c.needs_repair);
}

test "self-correction keeps only the later single-valued statement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "Set lantern's http_server to actix... wait no, scratch that. Lantern's http_server is axum.";
    var actix = fct("n1", "has_setting", null, "actix", "Set lantern's http_server to actix");
    actix.qualifier = "http_server";
    var axum = fct("n1", "has_setting", null, "axum", "Lantern's http_server is axum");
    axum.qualifier = "http_server";
    const raw: ExtractResult = .{
        .skip = null,
        .entities = &.{ent("n1", "Lantern", .project)},
        .facts = &.{ axum, actix },
        .new_relations = &.{},
    };

    const c = try check(arena, raw, body, ref_time);
    try testing.expectEqual(@as(usize, 1), c.result.facts.len);
    try testing.expectEqualStrings("axum", c.result.facts[0].value.?);
    try testing.expectEqual(@as(usize, 0), c.invalid_facts);
}

test "self-correction drops an opposed earlier statement and an exact restatement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "the driver lacks COPY. oh wait, it now supports COPY. yes it supports copy";
    const raw: ExtractResult = .{
        .skip = null,
        .entities = &.{ ent("n1", "pg.zig", .software), ent("n2", "pg-zig", .software) },
        .facts = &.{
            fct("n1", "lacks_feature", null, "COPY", "the driver lacks COPY"),
            fct("n2", "supports_feature", null, "COPY", "it now supports COPY"),
            fct("n1", "supports_feature", null, "copy", "yes it supports copy"),
        },
        .new_relations = &.{},
    };

    const c = try check(arena, raw, body, ref_time);
    try testing.expectEqual(@as(usize, 1), c.result.entities.len);
    try testing.expectEqual(@as(usize, 1), c.result.entities[0].aliases.len);
    try testing.expectEqual(@as(usize, 1), c.result.facts.len);
    try testing.expectEqualStrings("yes it supports copy", c.result.facts[0].quote);
}

test "dated statements about different periods do not self-correct" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "Priya was on call Nov 10 to Nov 17, then Hollis took over.";
    var priya = fct("n1", "has_oncall", "n2", null, "Priya was on call Nov 10 to Nov 17");
    priya.valid_from = "2026-11-10";
    priya.valid_to = "2026-11-17";
    var hollis = fct("n1", "has_oncall", "n3", null, "then Hollis took over");
    hollis.valid_from = "2026-11-17T00:00:00Z";
    const raw: ExtractResult = .{
        .skip = null,
        .entities = &.{ ent("n1", "Brackwater Relay", .software), ent("n2", "Priya", .person), ent("n3", "Hollis", .person) },
        .facts = &.{ priya, hollis },
        .new_relations = &.{},
    };

    const c = try check(arena, raw, body, ref_time);
    try testing.expectEqual(@as(usize, 2), c.result.facts.len);
    try testing.expectEqual(try core.time.parseRfc3339("2026-11-17"), c.meta[0].valid.upper.?);
}

test "a stated end with no start is unbounded below and does not supersede the new holder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var takes_over = fct("n1", "has_oncall", "n2", null, "Juno took over at 17:00");
    takes_over.valid_from = "2026-11-20T17:00:00Z";
    var rotated = fct("n1", "has_oncall", "n3", null, "Hollis rotated off");
    rotated.valid_to = "2026-11-20T17:00:00Z";
    var leaving = fct("n1", "owned_by", "n3", null, "Hollis owns it until Friday");
    leaving.valid_to = "2026-11-27T00:00:00Z";
    const raw: ExtractResult = .{
        .skip = null,
        .entities = &.{ ent("n1", "Relay", .software), ent("n2", "Juno", .person), ent("n3", "Hollis", .person) },
        .facts = &.{ takes_over, rotated, leaving },
        .new_relations = &.{},
    };

    const c = try check(arena, raw, "Juno took over at 17:00. Hollis rotated off. Hollis owns it until Friday", try core.time.parseRfc3339("2026-11-20T18:00:00Z"));
    try testing.expectEqual(@as(usize, 3), c.result.facts.len);
    try testing.expect(c.meta[1].valid.lower == null);
    try testing.expectEqual(try core.time.parseRfc3339("2026-11-20T17:00:00Z"), c.meta[1].valid.upper.?);
    try testing.expectEqual(try core.time.parseRfc3339("2026-11-20T18:00:00Z"), c.meta[2].valid.lower.?);
}

test "bad dates drop the fact; an unknown start is unbounded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bad = fct("n1", "prefers", null, "zig", "prefers zig");
    bad.valid_from = "last tuesday";
    var always = fct("n1", "avoids", null, "python sidecars", "avoids python sidecars");
    always.valid_from = "-infinity";
    var backwards = fct("n1", "uses", null, "nix", "uses nix");
    backwards.valid_from = "2026-11-20";
    backwards.valid_to = "2026-11-19";
    const raw: ExtractResult = .{
        .skip = null,
        .entities = &.{ent("n1", "Dana", .person)},
        .facts = &.{ bad, always, backwards },
        .new_relations = &.{},
    };

    const c = try check(arena, raw, "prefers zig avoids python sidecars uses nix", ref_time);
    try testing.expectEqual(@as(usize, 2), c.result.facts.len);
    try testing.expect(c.meta[0].valid.lower == null);
    try testing.expect(c.meta[1].valid.upper == null);
}

test "skip and empty extractions are empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const skip = try check(arena, .{ .skip = "test output only", .entities = &.{}, .facts = &.{}, .new_relations = &.{} }, "", ref_time);
    try testing.expect(skip.isEmpty());

    const empty = try check(arena, .{ .skip = null, .entities = &.{}, .facts = &.{}, .new_relations = &.{} }, "", ref_time);
    try testing.expect(empty.isEmpty());
    try testing.expect(!empty.needs_repair);
}
