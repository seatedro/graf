const std = @import("std");
const core = @import("core");
const mod = @import("mod.zig");
const fixtures = @import("fixtures.zig");
const match = @import("match.zig");
const time = @import("time.zig");

const Allocator = std.mem.Allocator;
const Suite = fixtures.Suite;
const EndKind = core.types.EndKind;

pub const Entity = struct {
    key: []const u8,
    name: []const u8,
    type: core.EntityType,
    aliases: []const []const u8 = &.{},
    merged_into: ?[]const u8 = null,
};

pub const Evidence = struct {
    entry: []const u8,
    kind: core.types.EvidenceKind,
};

pub const Object = union(enum) {
    entity: []const u8,
    value: []const u8,
};

pub const Fact = struct {
    key: []const u8,
    subject: []const u8,
    relation: []const u8,
    qualifier: []const u8 = "",
    object: Object,
    text: []const u8 = "",
    valid: core.Range = .{},
    known: core.Range = .{},
    end_kind: ?EndKind = null,
    evidence: []const Evidence = &.{},
};

pub const Entry = struct {
    eval_id: []const u8,
    status: core.types.EntryStatus,
};

pub const LlmCall = struct {
    entry: ?[]const u8 = null,
    purpose: core.types.LlmPurpose,
    cost_usd: f64 = 0,
};

pub const ScannedText = struct {
    location: []const u8,
    text: []const u8,
};

pub const Hit = struct {
    fact: []const u8,
    text: []const u8 = "",
};

pub const QueryResult = struct {
    query: []const u8,
    hits: []const Hit = &.{},
};

pub const Judgment = struct {
    fact: []const u8,
    supported: bool,
    durable: bool,
    reason: []const u8 = "",
};

pub const Residual = struct {
    fact: []const u8,
    entry: ?[]const u8,
    text: []const u8,
    subject: []const u8,
    relation: []const u8,
    qualifier: []const u8,
    object: []const u8,
    judgment: ?Judgment = null,
};

pub const CrashResume = struct {
    trials: u32,
    passed: u32,
};

pub const GraphState = struct {
    entities: []const Entity = &.{},
    facts: []const Fact = &.{},
    entries: []const Entry = &.{},
    llm_calls: []const LlmCall = &.{},
    scanned: ?[]const ScannedText = null,
    retrieval: ?[]const QueryResult = null,
    crash_resume: ?CrashResume = null,
    judgments: ?[]const Judgment = null,
    judge_calls: []const LlmCall = &.{},
};

pub const Detail = struct {
    suite_entries: u32 = 0,
    terminal_entries: u32 = 0,
    entity_tp: u32 = 0,
    entity_fp: u32 = 0,
    entity_fn: u32 = 0,
    unlabeled_entities: u32 = 0,
    merge_pairs: u32 = 0,
    merges_correct: u32 = 0,
    gold_facts: u32 = 0,
    facts_extracted: u32 = 0,
    facts_matched: u32 = 0,
    duplicate_facts: u32 = 0,
    residual_facts: u32 = 0,
    residual_faithful: u32 = 0,
    residual_unsupported: u32 = 0,
    residual_transient: u32 = 0,
    residual_unjudged: u32 = 0,
    gold_fact_items: u32 = 0,
    gold_fact_items_found: u32 = 0,
    invalidation_tp: u32 = 0,
    invalidation_fp: u32 = 0,
    invalidation_fn: u32 = 0,
    temporal_items: u32 = 0,
    temporal_correct: u32 = 0,
    retrieval_expected: u32 = 0,
    retrieval_found: u32 = 0,
    retrieval_exclusion_violations: ?u32 = null,
    extraction_calls: u32 = 0,
    resolution_calls: u32 = 0,
    repair_calls: u32 = 0,
    embedding_calls: u32 = 0,
    total_cost_usd: f64 = 0,
    judge_calls: u32 = 0,
    judge_cost_usd: f64 = 0,
};

pub const Report = struct {
    graph: ?[]const u8 = null,
    judge: ?[]const u8 = null,
    metrics: mod.Metrics,
    detail: Detail,
    residuals: []const Residual = &.{},
    findings: []const []const u8,
};

fn ratio(num: u32, den: u32) f64 {
    if (den == 0) return 0;
    return @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
}

fn f1(tp: u32, fp: u32, fn_: u32) f64 {
    const den = 2 * tp + fp + fn_;
    if (den == 0) return 1;
    return @as(f64, @floatFromInt(2 * tp)) / @as(f64, @floatFromInt(den));
}

fn isTerminal(s: core.types.EntryStatus) bool {
    return switch (s) {
        .committed, .skipped, .dead, .split => true,
        else => false,
    };
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

const Scorer = struct {
    arena: Allocator,
    suite: *const Suite,
    state: *const GraphState,
    findings: std.ArrayList([]const u8) = .empty,
    detail: Detail = .{},
    metrics: mod.Metrics = .{},

    entity_index: std.StringHashMapUnmanaged(usize) = .empty,
    fact_index: std.StringHashMapUnmanaged(usize) = .empty,
    gold_names: []const []const []const u8 = &.{},
    entity_names: []const []const []const u8 = &.{},
    survivor: []usize = &.{},
    label: []?usize = &.{},
    gold_set: [][]bool = &.{},
    fact_gold: []?usize = &.{},
    fact_entry: []?[]const u8 = &.{},
    forgiven: []bool = &.{},
    trap: []bool = &.{},
    residual: []bool = &.{},
    claimed: []?usize = &.{},
    patterns: []const fixtures.Pattern = &.{},

    fn note(sc: *Scorer, comptime fmt: []const u8, args: anytype) !void {
        try sc.findings.append(sc.arena, try std.fmt.allocPrint(sc.arena, fmt, args));
    }

    fn goldEntity(sc: *Scorer, g: usize) fixtures.GoldEntity {
        return sc.suite.entities()[g];
    }

    fn prepareEntities(sc: *Scorer) !void {
        const a = sc.arena;
        const golds = sc.suite.entities();
        const gold_names = try a.alloc([]const []const u8, golds.len);
        for (golds, 0..) |g, i| {
            const names = try a.alloc([]const u8, g.aliases.len + 1);
            names[0] = try match.normalize(a, g.name);
            for (g.aliases, 1..) |alias, j| names[j] = try match.normalize(a, alias);
            gold_names[i] = names;
        }
        sc.gold_names = gold_names;

        const ents = sc.state.entities;
        const entity_names = try a.alloc([]const []const u8, ents.len);
        for (ents, 0..) |e, i| {
            try sc.entity_index.put(a, e.key, i);
            const names = try a.alloc([]const u8, e.aliases.len + 1);
            names[0] = try match.normalize(a, e.name);
            for (e.aliases, 1..) |alias, j| names[j] = try match.normalize(a, alias);
            entity_names[i] = names;
        }
        sc.entity_names = entity_names;

        sc.survivor = try a.alloc(usize, ents.len);
        for (ents, 0..) |_, i| sc.survivor[i] = sc.resolve(i);

        sc.label = try a.alloc(?usize, ents.len);
        sc.gold_set = try a.alloc([]bool, ents.len);
        const typed = try a.alloc(?usize, ents.len);
        for (ents, 0..) |e, i| {
            typed[i] = sc.typedLabel(i, e.type);
            sc.label[i] = null;
            sc.gold_set[i] = try a.alloc(bool, golds.len);
            @memset(sc.gold_set[i], false);
        }
        for (ents, 0..) |_, i| {
            const s = sc.survivor[i];
            for (golds, 0..) |_, g| {
                if (sc.nameHit(i, g)) sc.gold_set[s][g] = true;
            }
        }
        for (ents, 0..) |_, i| {
            const s = sc.survivor[i];
            if (s == i) {
                if (typed[i]) |g| sc.label[s] = g;
            }
        }
        for (ents, 0..) |_, i| {
            const s = sc.survivor[i];
            if (sc.label[s] == null) sc.label[s] = typed[i];
        }
    }

    fn resolve(sc: *Scorer, start: usize) usize {
        var cur = start;
        var steps: usize = 0;
        while (steps <= sc.state.entities.len) : (steps += 1) {
            const next_key = sc.state.entities[cur].merged_into orelse return cur;
            const next = sc.entity_index.get(next_key) orelse return cur;
            if (next == cur) return cur;
            cur = next;
        }
        return cur;
    }

    fn typedLabel(sc: *Scorer, i: usize, t: core.EntityType) ?usize {
        for (sc.entity_names[i]) |n| {
            for (sc.suite.entities(), 0..) |g, gi| {
                if (match.typesCompatible(t, g.type) and std.mem.eql(u8, sc.gold_names[gi][0], n)) return gi;
            }
            for (sc.suite.entities(), 0..) |g, gi| {
                if (!match.typesCompatible(t, g.type)) continue;
                for (sc.gold_names[gi][1..]) |alias| if (std.mem.eql(u8, alias, n)) return gi;
            }
        }
        return null;
    }

    fn nameHit(sc: *Scorer, i: usize, g: usize) bool {
        for (sc.entity_names[i]) |n| {
            for (sc.gold_names[g]) |gn| if (std.mem.eql(u8, gn, n)) return true;
        }
        return false;
    }

    fn entityLabel(sc: *Scorer, key: []const u8) ?usize {
        const i = sc.entity_index.get(key) orelse return null;
        return sc.label[sc.survivor[i]];
    }

    fn isSurvivor(sc: *Scorer, i: usize) bool {
        return sc.survivor[i] == i;
    }

    fn scoreEntities(sc: *Scorer) !void {
        const golds = sc.suite.entities();
        const matched = try sc.arena.alloc(u32, golds.len);
        @memset(matched, 0);
        var fp: u32 = 0;
        for (sc.state.entities, 0..) |e, i| {
            if (!sc.isSurvivor(i)) continue;
            if (sc.label[i]) |g| {
                matched[g] += 1;
                if (matched[g] > 1) {
                    fp += 1;
                    try sc.note("entity: '{s}' is an unmerged duplicate of {s}", .{ e.name, golds[g].id });
                }
                continue;
            }
            var collides = false;
            for (sc.gold_set[i]) |hit| collides = collides or hit;
            if (collides) {
                fp += 1;
                try sc.note("entity: '{s}' ({s}) matches a gold name but not its type", .{ e.name, @tagName(e.type) });
            } else sc.detail.unlabeled_entities += 1;
        }
        var tp: u32 = 0;
        for (matched, 0..) |m, g| {
            if (m > 0) tp += 1 else try sc.note("entity: no surviving entity for {s} ('{s}')", .{ golds[g].id, golds[g].name });
        }
        const fn_: u32 = @intCast(golds.len - tp);
        sc.detail.entity_tp = tp;
        sc.detail.entity_fp = fp;
        sc.detail.entity_fn = fn_;
        sc.metrics.entity_f1 = f1(tp, fp, fn_);
    }

    fn survivorsLabeled(sc: *Scorer, g: usize) struct { count: u32, first: ?usize } {
        var count: u32 = 0;
        var first: ?usize = null;
        for (sc.state.entities, 0..) |_, i| {
            if (!sc.isSurvivor(i) or sc.label[i] != g) continue;
            count += 1;
            if (first == null) first = i;
        }
        return .{ .count = count, .first = first };
    }

    fn scoreMerges(sc: *Scorer) !void {
        const golds = sc.suite.entities();
        var correct: u32 = 0;
        var pairs: u32 = 0;
        for (sc.suite.expected.expected_merges) |m| {
            pairs += 1;
            const g = sc.suite.entityIndex(m.must_resolve_to).?;
            const found = sc.survivorsLabeled(g);
            if (found.count != 1) {
                try sc.note("merge: {s} '{s}' -> {s}: {d} surviving entities, want 1", .{ m.entry, m.mention, m.must_resolve_to, found.count });
                continue;
            }
            const target = found.first.?;
            const mention = try match.normalize(sc.arena, m.mention);
            var ok = true;
            for (sc.state.entities, 0..) |e, i| {
                if (!contains(sc.entity_names[i], mention)) continue;
                if (sc.survivor[i] != target) {
                    ok = false;
                    try sc.note("merge: {s} '{s}' landed in '{s}', not in {s}", .{ m.entry, m.mention, e.name, m.must_resolve_to });
                }
            }
            if (ok) correct += 1;
        }
        var cross: u32 = 0;
        for (sc.state.entities, 0..) |e, i| {
            if (!sc.isSurvivor(i)) continue;
            var first_type: ?core.EntityType = null;
            var mixed = false;
            for (sc.gold_set[i], 0..) |hit, g| {
                if (!hit) continue;
                if (first_type) |t| mixed = mixed or t != golds[g].type else first_type = golds[g].type;
            }
            if (mixed) {
                cross += 1;
                try sc.note("merge: '{s}' merges gold entities of different types", .{e.name});
            }
        }
        for (sc.suite.expected.must_not_merge) |m| {
            pairs += 1;
            const ga = sc.suite.entityIndex(m.entity_a).?;
            const gb = sc.suite.entityIndex(m.entity_b).?;
            var merged = false;
            for (sc.state.entities, 0..) |_, i| {
                if (sc.isSurvivor(i) and sc.gold_set[i][ga] and sc.gold_set[i][gb]) merged = true;
            }
            const present = sc.survivorsLabeled(ga).count > 0 and sc.survivorsLabeled(gb).count > 0;
            if (merged) {
                try sc.note("merge: {s} and {s} must not merge", .{ m.entity_a, m.entity_b });
            } else if (!present) {
                try sc.note("merge: {s} and {s} are not both present as distinct entities", .{ m.entity_a, m.entity_b });
            } else correct += 1;
        }
        sc.detail.merge_pairs = pairs;
        sc.detail.merges_correct = correct;
        sc.metrics.merge_accuracy = ratio(correct, pairs);
        sc.metrics.cross_type_merges = cross;
    }

    fn objectNames(sc: *Scorer, key: []const u8) []const []const u8 {
        const i = sc.entity_index.get(key) orelse return &.{};
        return sc.entity_names[i];
    }

    fn matchStrength(sc: *Scorer, d: Fact, gi: usize) !u8 {
        const g = sc.suite.facts[gi].fact;
        const cp = try match.canonicalRelation(sc.arena, d.relation);
        const gp = try match.canonicalRelation(sc.arena, g.relation);
        if (!std.mem.eql(u8, cp.name, gp.name)) return 0;
        var subject = d.subject;
        var object = d.object;
        if (cp.inverse) {
            const o = switch (d.object) {
                .entity => |k| k,
                .value => return 0,
            };
            subject = o;
            object = .{ .entity = d.subject };
        }
        if (sc.entityLabel(subject) != sc.suite.entityIndex(g.subject)) return 0;
        if (g.qualifier) |q| {
            if (!std.mem.eql(u8, try match.normalize(sc.arena, q), try match.normalize(sc.arena, d.qualifier))) return 0;
        }
        if (g.object) |go| {
            const want = sc.suite.entityIndex(go) orelse return 0;
            switch (object) {
                .entity => |k| return if (sc.entityLabel(k) == want) 2 else 0,
                .value => |v| {
                    const nv = try match.normalize(sc.arena, v);
                    return if (contains(sc.gold_names[want], nv)) 1 else 0;
                },
            }
        }
        const gv = g.object_value orelse return 0;
        switch (object) {
            .value => |v| return match.valueMatch(sc.arena, gv, v),
            .entity => |k| {
                for (sc.objectNames(k)) |n| if (try match.valueMatch(sc.arena, gv, n) > 0) return 1;
                return 0;
            },
        }
    }

    fn prefers(sc: *Scorer, gi: usize, entry: ?[]const u8) bool {
        const ep = entry orelse return false;
        const ref = sc.suite.facts[gi];
        if (std.mem.eql(u8, ref.entry, ep)) return true;
        const gold = sc.suite.gold(ep) orelse return false;
        return contains(gold.restated, ref.fact.id);
    }

    fn statingEntry(d: Fact) ?[]const u8 {
        for (d.evidence) |p| if (p.kind == .stated) return p.entry;
        if (d.evidence.len > 0) return d.evidence[0].entry;
        return null;
    }

    fn retracted(d: Fact) bool {
        if (d.end_kind) |k| return k == .retracted or k == .forgotten;
        return d.known.upper != null;
    }

    fn ended(d: Fact) ?EndKind {
        if (d.end_kind) |k| return k;
        if (d.known.upper != null) return .retracted;
        if (d.valid.upper != null) return .changed;
        return null;
    }

    fn patternHit(sc: *Scorer, d: Fact) !?usize {
        const cp = try match.canonicalRelation(sc.arena, d.relation);
        if (cp.inverse) return null;
        for (sc.patterns, 0..) |p, pi| {
            const pp = try match.canonicalRelation(sc.arena, p.relation);
            if (!std.mem.eql(u8, cp.name, pp.name)) continue;
            if (sc.entityLabel(d.subject) != p.subject) continue;
            const hit = switch (d.object) {
                .value => |v| try match.valueMatch(sc.arena, p.object, v) > 0,
                .entity => |k| blk: {
                    for (sc.objectNames(k)) |n| if (try match.valueMatch(sc.arena, p.object, n) > 0) break :blk true;
                    break :blk false;
                },
            };
            if (hit) return pi;
        }
        return null;
    }

    fn entryOrder(sc: *Scorer, entry: ?[]const u8) usize {
        const ep = entry orelse return std.math.maxInt(usize);
        return sc.suite.entryIndex(ep) orelse std.math.maxInt(usize);
    }

    fn prepareFacts(sc: *Scorer) !void {
        const a = sc.arena;
        const facts = sc.state.facts;
        var patterns: std.ArrayList(fixtures.Pattern) = .empty;
        for (sc.suite.expected.entries.map.values()) |g| {
            for (g.must_not_contain_facts) |text| {
                if (try fixtures.parsePattern(a, sc.suite, text)) |p| try patterns.append(a, p);
            }
        }
        sc.patterns = patterns.items;
        sc.fact_gold = try a.alloc(?usize, facts.len);
        sc.fact_entry = try a.alloc(?[]const u8, facts.len);
        sc.forgiven = try a.alloc(bool, facts.len);
        sc.trap = try a.alloc(bool, facts.len);
        sc.residual = try a.alloc(bool, facts.len);
        for (facts, 0..) |d, i| {
            try sc.fact_index.put(a, d.key, i);
            sc.fact_entry[i] = statingEntry(d);
            const forbidden = try sc.patternHit(d) != null;
            sc.forgiven[i] = retracted(d) and forbidden;
            var best: ?usize = null;
            var best_strength: u8 = 0;
            var best_pref = false;
            for (sc.suite.facts, 0..) |_, gi| {
                const strength = try sc.matchStrength(d, gi);
                if (strength == 0) continue;
                const pref = sc.prefers(gi, sc.fact_entry[i]);
                if (strength > best_strength or (strength == best_strength and pref and !best_pref)) {
                    best = gi;
                    best_strength = strength;
                    best_pref = pref;
                }
            }
            sc.fact_gold[i] = best;
            sc.trap[i] = !sc.forgiven[i] and (sc.fromSkipEntry(i) or (best == null and forbidden));
            sc.residual[i] = !sc.forgiven[i] and !sc.trap[i] and best == null and !retracted(d);
        }

        const order = try a.alloc(usize, facts.len);
        for (order, 0..) |*o, i| o.* = i;
        const Ctx = struct {
            sc: *Scorer,
            fn lessThan(ctx: @This(), l: usize, r: usize) bool {
                const ol = ctx.sc.entryOrder(ctx.sc.fact_entry[l]);
                const or_ = ctx.sc.entryOrder(ctx.sc.fact_entry[r]);
                return if (ol != or_) ol < or_ else l < r;
            }
        };
        std.sort.block(usize, order, Ctx{ .sc = sc }, Ctx.lessThan);
        sc.claimed = try a.alloc(?usize, sc.suite.facts.len);
        @memset(sc.claimed, null);
        for (order) |i| {
            if (sc.forgiven[i] or sc.fromSkipEntry(i)) continue;
            const g = sc.fact_gold[i] orelse continue;
            if (sc.claimed[g] == null) sc.claimed[g] = i;
        }
    }

    fn fromSkipEntry(sc: *Scorer, i: usize) bool {
        const ep = sc.fact_entry[i] orelse return false;
        return sc.suite.isSkip(ep);
    }

    fn scoreFacts(sc: *Scorer) !void {
        var traps: u32 = 0;
        for (sc.state.facts, 0..) |d, i| {
            if (sc.forgiven[i]) continue;
            sc.detail.facts_extracted += 1;
            const ep = sc.fact_entry[i] orelse "?";
            if (sc.trap[i]) {
                traps += 1;
                if (sc.fromSkipEntry(i)) {
                    try sc.note("fact: skip entry {s} produced '{s}'", .{ ep, d.text });
                } else try sc.note("fact: {s} wrote forbidden fact '{s}' and left it active", .{ ep, d.text });
                continue;
            }
            if (sc.residual[i]) {
                sc.detail.residual_facts += 1;
                continue;
            }
            const g = sc.fact_gold[i] orelse continue;
            if (sc.claimed[g] != i) {
                sc.detail.duplicate_facts += 1;
                try sc.note("fact: {s} duplicated {s} as a new row", .{ ep, sc.suite.facts[g].fact.id });
                continue;
            }
            sc.detail.facts_matched += 1;
        }
        var items: u32 = 0;
        var found: u32 = 0;
        for (sc.suite.facts, 0..) |ref, g| {
            items += 1;
            if (sc.claimed[g] != null) found += 1 else try sc.note("fact: missing {s} from {s}", .{ ref.fact.id, ref.entry });
        }
        for (sc.suite.expected.entries.map.keys(), sc.suite.expected.entries.map.values()) |ep, gold| {
            for (gold.restated) |id| {
                items += 1;
                const g = sc.suite.factIndex(id).?;
                var ok = false;
                for (sc.state.facts, 0..) |d, i| {
                    if (sc.fact_gold[i] != g) continue;
                    for (d.evidence) |p| ok = ok or std.mem.eql(u8, p.entry, ep);
                }
                if (ok) found += 1 else try sc.note("fact: {s} did not restate {s}", .{ ep, id });
            }
        }
        sc.detail.gold_facts = @intCast(sc.suite.facts.len);
        sc.detail.gold_fact_items = items;
        sc.detail.gold_fact_items_found = found;
        sc.metrics.fact_recall = ratio(found, items);
        sc.metrics.trap_facts = traps;
        sc.metrics.labeled_precision = ratio(sc.detail.facts_matched, sc.detail.facts_matched + sc.detail.duplicate_facts + traps);
        sc.metrics.fact_density = ratio(sc.detail.facts_extracted, sc.detail.gold_facts);
    }

    fn residuals(sc: *Scorer) ![]Residual {
        var list: std.ArrayList(Residual) = .empty;
        for (sc.state.facts, 0..) |d, i| {
            if (!sc.residual[i]) continue;
            try list.append(sc.arena, .{
                .fact = d.key,
                .entry = sc.fact_entry[i],
                .text = d.text,
                .subject = sc.entityName(d.subject),
                .relation = d.relation,
                .qualifier = d.qualifier,
                .object = switch (d.object) {
                    .entity => |k| sc.entityName(k),
                    .value => |v| v,
                },
            });
        }
        return list.items;
    }

    fn entityName(sc: *Scorer, key: []const u8) []const u8 {
        const i = sc.entity_index.get(key) orelse return key;
        return sc.state.entities[i].name;
    }

    fn scoreResiduals(sc: *Scorer) ![]const Residual {
        const list = try sc.residuals();
        if (list.len == 0) {
            sc.metrics.residual_faithfulness = 1;
            return list;
        }
        const judgments = sc.state.judgments orelse {
            try sc.note("judge: {d} residual facts were not judged; residual faithfulness is unmeasured", .{list.len});
            return list;
        };
        for (list) |*r| {
            for (judgments) |j| {
                if (std.mem.eql(u8, j.fact, r.fact)) {
                    r.judgment = j;
                    break;
                }
            }
            const ep = r.entry orelse "?";
            const j = r.judgment orelse {
                sc.detail.residual_unjudged += 1;
                try sc.note("judge: no verdict for {s} residual '{s}'", .{ ep, r.text });
                continue;
            };
            if (j.supported and j.durable) {
                sc.detail.residual_faithful += 1;
                continue;
            }
            if (!j.supported) sc.detail.residual_unsupported += 1;
            if (!j.durable) sc.detail.residual_transient += 1;
            const why = if (!j.supported and !j.durable) "unsupported and transient" else if (!j.supported) "unsupported" else "transient";
            try sc.note("judge: {s} residual '{s}' is {s}: {s}", .{ ep, r.text, why, j.reason });
        }
        sc.metrics.residual_faithfulness = ratio(sc.detail.residual_faithful, @intCast(list.len));
        return list;
    }

    const GoldInvalidation = struct { entry: []const u8, fact: usize, kind: EndKind, valid_to: ?core.Micros };

    fn goldInvalidations(sc: *Scorer) ![]const GoldInvalidation {
        var list: std.ArrayList(GoldInvalidation) = .empty;
        for (sc.suite.expected.entries.map.keys(), sc.suite.expected.entries.map.values()) |ep, gold| {
            for (gold.invalidations) |inv| try list.append(sc.arena, .{
                .entry = ep,
                .fact = sc.suite.factIndex(inv.fact_id).?,
                .kind = inv.end_kind,
                .valid_to = if (inv.valid_to) |v| core.time.parseRfc3339(v) catch null else null,
            });
        }
        return list.items;
    }

    fn mustRemainActive(sc: *Scorer, g: usize) bool {
        for (sc.suite.expected.entries.map.values()) |gold| {
            if (contains(gold.must_remain_active, sc.suite.facts[g].fact.id)) return true;
        }
        return false;
    }

    fn scoreInvalidations(sc: *Scorer) !void {
        const golds = try sc.goldInvalidations();
        const hit = try sc.arena.alloc(bool, golds.len);
        @memset(hit, false);
        var fp: u32 = 0;
        for (sc.state.facts, 0..) |d, i| {
            const kind = ended(d) orelse continue;
            if (sc.forgiven[i]) continue;
            const g = sc.fact_gold[i];
            if (g) |gi| {
                if (sc.suite.facts[gi].valid_to != null and kind == .changed) continue;
                var matched = false;
                for (golds, 0..) |inv, k| {
                    if (inv.fact != gi) continue;
                    if (inv.kind == kind) {
                        hit[k] = true;
                        matched = true;
                    } else try sc.note("invalidation: {s} ended as {s}, want {s}", .{ sc.suite.facts[gi].fact.id, @tagName(kind), @tagName(inv.kind) });
                }
                if (matched) continue;
                fp += 1;
                if (sc.mustRemainActive(gi)) {
                    try sc.note("invalidation: {s} must remain active but ended ({s})", .{ sc.suite.facts[gi].fact.id, @tagName(kind) });
                } else try sc.note("invalidation: {s} ended ({s}) without a gold invalidation", .{ sc.suite.facts[gi].fact.id, @tagName(kind) });
                continue;
            }
            fp += 1;
            try sc.note("invalidation: unlabeled fact '{s}' ended ({s})", .{ d.text, @tagName(kind) });
        }
        var tp: u32 = 0;
        for (golds, hit) |inv, h| {
            if (h) tp += 1 else try sc.note("invalidation: {s} should end {s} {s}", .{ inv.entry, sc.suite.facts[inv.fact].fact.id, @tagName(inv.kind) });
        }
        const fn_: u32 = @intCast(golds.len - tp);
        sc.detail.invalidation_tp = tp;
        sc.detail.invalidation_fp = fp;
        sc.detail.invalidation_fn = fn_;
        sc.metrics.invalidation_f1 = f1(tp, fp, fn_);
    }

    const Bound = enum { lower, upper };

    fn boundCorrect(sc: *Scorer, g: usize, bound: Bound, want: core.Micros) bool {
        for (sc.state.facts, 0..) |d, i| {
            if (sc.fact_gold[i] != g or sc.forgiven[i]) continue;
            const got = switch (bound) {
                .lower => d.valid.lower,
                .upper => d.valid.upper,
            } orelse continue;
            if (time.withinOneDay(got, want)) return true;
        }
        return false;
    }

    fn temporalItem(sc: *Scorer, g: usize, bound: Bound, want: ?core.Micros) !void {
        const w = want orelse return;
        sc.detail.temporal_items += 1;
        if (sc.boundCorrect(g, bound, w)) {
            sc.detail.temporal_correct += 1;
        } else try sc.note("temporal: {s} valid {s} is missing or more than a day from gold", .{ sc.suite.facts[g].fact.id, if (bound == .lower) "from" else "to" });
    }

    fn scoreTemporal(sc: *Scorer) !void {
        for (sc.suite.facts, 0..) |ref, g| {
            if (ref.fact.time_basis == null and ref.fact.valid_to == null) continue;
            try sc.temporalItem(g, .lower, ref.valid_from);
            try sc.temporalItem(g, .upper, ref.valid_to);
        }
        for (try sc.goldInvalidations()) |inv| try sc.temporalItem(inv.fact, .upper, inv.valid_to);
        sc.metrics.temporal_accuracy = ratio(sc.detail.temporal_correct, sc.detail.temporal_items);
    }

    fn scoreSecrets(sc: *Scorer) !void {
        const texts = sc.state.scanned orelse return;
        var seen: std.ArrayList([]const u8) = .empty;
        var leaks: u32 = 0;
        for (sc.suite.expected.entries.map.values()) |gold| {
            for (gold.forbidden_substrings_anywhere) |needle| {
                if (contains(seen.items, needle)) continue;
                try seen.append(sc.arena, needle);
                for (texts) |t| {
                    if (std.mem.indexOf(u8, t.text, needle) == null) continue;
                    leaks += 1;
                    try sc.note("secret: a forbidden substring of length {d} appears in {s}", .{ needle.len, t.location });
                    break;
                }
            }
        }
        sc.metrics.secret_leaks = leaks;
    }

    fn scoreRetrieval(sc: *Scorer) !void {
        const results = sc.state.retrieval orelse return;
        var expected: u32 = 0;
        var found: u32 = 0;
        var violations: u32 = 0;
        for (sc.suite.expected.retrieval_queries) |q| {
            var hits: []const Hit = &.{};
            for (results) |r| {
                if (std.mem.eql(u8, r.query, q.id)) hits = r.hits;
            }
            const top = hits[0..@min(hits.len, 5)];
            for (q.must_include) |id| {
                expected += 1;
                const g = sc.suite.factIndex(id).?;
                if (sc.anyHitIs(top, g)) found += 1 else try sc.note("retrieval: {s} missing {s} from the top 5", .{ q.id, id });
            }
            for (q.must_exclude) |id| {
                const g = sc.suite.factIndex(id).?;
                if (sc.anyHitIs(top, g)) {
                    violations += 1;
                    try sc.note("retrieval: {s} returned excluded {s}", .{ q.id, id });
                }
            }
            for (q.must_exclude_substrings) |word| {
                for (top) |h| {
                    if (!match.containsWord(sc.hitText(h), word)) continue;
                    violations += 1;
                    try sc.note("retrieval: {s} returned text containing '{s}'", .{ q.id, word });
                    break;
                }
            }
        }
        sc.detail.retrieval_expected = expected;
        sc.detail.retrieval_found = found;
        sc.detail.retrieval_exclusion_violations = violations;
        sc.metrics.retrieval_recall_at_5 = ratio(found, expected);
    }

    fn anyHitIs(sc: *Scorer, hits: []const Hit, g: usize) bool {
        for (hits) |h| {
            const i = sc.fact_index.get(h.fact) orelse continue;
            if (sc.fact_gold[i] == g) return true;
        }
        return false;
    }

    fn hitText(sc: *Scorer, h: Hit) []const u8 {
        if (h.text.len > 0) return h.text;
        const i = sc.fact_index.get(h.fact) orelse return "";
        return sc.state.facts[i].text;
    }

    fn scoreLedger(sc: *Scorer, all_terminal: bool) void {
        for (sc.state.llm_calls) |c| {
            switch (c.purpose) {
                .extract => sc.detail.extraction_calls += 1,
                .resolve => sc.detail.resolution_calls += 1,
                .repair => sc.detail.repair_calls += 1,
                .embed_entry, .embed_batch => sc.detail.embedding_calls += 1,
                .rerank, .summarize, .embed_query, .judge => {},
            }
            switch (c.purpose) {
                .rerank, .embed_query, .judge => {},
                else => sc.detail.total_cost_usd += c.cost_usd,
            }
        }
        for (sc.state.judge_calls) |c| {
            sc.detail.judge_calls += 1;
            sc.detail.judge_cost_usd += c.cost_usd;
        }
        if (!all_terminal) return;
        const n: f64 = @floatFromInt(sc.suite.entries.len);
        const calls: f64 = @floatFromInt(sc.detail.extraction_calls + sc.detail.resolution_calls + sc.detail.repair_calls);
        sc.metrics.calls_per_entry = calls / n;
        sc.metrics.cost_per_entry_usd = sc.detail.total_cost_usd / n;
    }
};

pub fn scoreState(arena: Allocator, suite: *const Suite, state: *const GraphState) !Report {
    var sc: Scorer = .{ .arena = arena, .suite = suite, .state = state };
    sc.detail.suite_entries = @intCast(suite.entries.len);
    for (suite.entries) |ep| {
        for (state.entries) |se| {
            if (std.mem.eql(u8, se.eval_id, ep.id) and isTerminal(se.status)) {
                sc.detail.terminal_entries += 1;
                break;
            }
        }
    }
    const ingested = sc.detail.terminal_entries > 0;
    const all_terminal = sc.detail.terminal_entries == suite.entries.len;

    try sc.prepareEntities();
    try sc.prepareFacts();
    var residual_list: []const Residual = &.{};
    if (ingested) {
        try sc.scoreEntities();
        try sc.scoreMerges();
        try sc.scoreFacts();
        residual_list = try sc.scoreResiduals();
        try sc.scoreInvalidations();
        try sc.scoreTemporal();
    } else try sc.note("ingestion: no suite entry reached a terminal status; graph metrics are unmeasured", .{});
    if (!all_terminal and ingested) try sc.note("ingestion: {d} of {d} entries reached a terminal status; call and cost metrics are unmeasured", .{ sc.detail.terminal_entries, suite.entries.len });
    try sc.scoreSecrets();
    try sc.scoreRetrieval();
    sc.scoreLedger(all_terminal);
    if (state.crash_resume) |cr| {
        if (cr.trials > 0) sc.metrics.crash_resume_pass_rate = ratio(cr.passed, cr.trials);
    }
    return .{ .metrics = sc.metrics, .detail = sc.detail, .residuals = residual_list, .findings = sc.findings.items };
}

pub fn residualFacts(arena: Allocator, suite: *const Suite, state: *const GraphState) ![]const Residual {
    var sc: Scorer = .{ .arena = arena, .suite = suite, .state = state };
    try sc.prepareEntities();
    try sc.prepareFacts();
    return sc.residuals();
}

pub fn goldState(arena: Allocator, suite: *const Suite) !GraphState {
    var entities: std.ArrayList(Entity) = .empty;
    for (suite.entities()) |g| try entities.append(arena, .{ .key = g.id, .name = g.name, .type = g.type, .aliases = g.aliases });

    var facts: std.ArrayList(Fact) = .empty;
    for (suite.facts) |ref| {
        var evidence: std.ArrayList(Evidence) = .empty;
        try evidence.append(arena, .{ .entry = ref.entry, .kind = .stated });
        var valid: core.Range = .{ .lower = ref.valid_from, .upper = ref.valid_to };
        var end_kind: ?EndKind = if (ref.valid_to != null) .changed else null;
        for (suite.expected.entries.map.keys(), suite.expected.entries.map.values()) |ep, gold| {
            if (contains(gold.restated, ref.fact.id)) try evidence.append(arena, .{ .entry = ep, .kind = .restated });
            for (gold.invalidations) |inv| {
                if (!std.mem.eql(u8, inv.fact_id, ref.fact.id)) continue;
                valid.upper = if (inv.valid_to) |v| try core.time.parseRfc3339(v) else null;
                end_kind = inv.end_kind;
            }
        }
        const object: Object = if (ref.fact.object) |o| .{ .entity = o } else .{ .value = ref.fact.object_value.? };
        try facts.append(arena, .{
            .key = ref.fact.id,
            .subject = ref.fact.subject,
            .relation = ref.fact.relation,
            .qualifier = ref.fact.qualifier orelse "",
            .object = object,
            .text = ref.fact.id,
            .valid = valid,
            .known = .{ .lower = ref.valid_from },
            .end_kind = end_kind,
            .evidence = evidence.items,
        });
    }

    var entries: std.ArrayList(Entry) = .empty;
    var calls: std.ArrayList(LlmCall) = .empty;
    var scanned: std.ArrayList(ScannedText) = .empty;
    for (suite.entries) |ep| {
        const skip = suite.isSkip(ep.id);
        try entries.append(arena, .{ .eval_id = ep.id, .status = if (skip) .skipped else .committed });
        try calls.append(arena, .{ .entry = ep.id, .purpose = .extract, .cost_usd = 0.004 });
        if (!skip) {
            try calls.append(arena, .{ .entry = ep.id, .purpose = .resolve, .cost_usd = 0.002 });
            try calls.append(arena, .{ .entry = ep.id, .purpose = .embed_batch, .cost_usd = 0.0001 });
        }
        for (ep.turns) |turn| try scanned.append(arena, .{ .location = ep.id, .text = try redactForbidden(arena, suite, turn.text) });
    }

    var results: std.ArrayList(QueryResult) = .empty;
    for (suite.expected.retrieval_queries) |q| {
        var hits: std.ArrayList(Hit) = .empty;
        for (q.must_include) |id| try hits.append(arena, .{ .fact = id });
        try results.append(arena, .{ .query = q.id, .hits = hits.items });
    }

    return .{
        .entities = entities.items,
        .facts = facts.items,
        .entries = entries.items,
        .llm_calls = calls.items,
        .scanned = scanned.items,
        .retrieval = results.items,
        .crash_resume = .{ .trials = 1, .passed = 1 },
    };
}

fn redactForbidden(arena: Allocator, suite: *const Suite, text: []const u8) ![]const u8 {
    var out = text;
    for (suite.expected.entries.map.values()) |gold| {
        for (gold.forbidden_substrings_anywhere) |needle| {
            out = try std.mem.replaceOwned(u8, arena, out, needle, "[REDACTED]");
        }
    }
    return out;
}

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    suite: Suite,
    state: GraphState,

    fn init() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(f);
        f.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer f.arena_state.deinit();
        const arena = f.arena_state.allocator();
        f.suite = try fixtures.loadShippedSuite(arena, testing.io);
        f.state = try goldState(arena, &f.suite);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
        testing.allocator.destroy(f);
    }

    fn alloc(f: *Fixture) Allocator {
        return f.arena_state.allocator();
    }

    fn score(f: *Fixture) !Report {
        return scoreState(f.alloc(), &f.suite, &f.state);
    }

    fn fact(f: *Fixture, id: []const u8) *Fact {
        for (f.state.facts, 0..) |d, i| if (std.mem.eql(u8, d.key, id)) return @constCast(&f.state.facts[i]);
        unreachable;
    }

    fn entity(f: *Fixture, id: []const u8) *Entity {
        for (f.state.entities, 0..) |e, i| if (std.mem.eql(u8, e.key, id)) return @constCast(&f.state.entities[i]);
        unreachable;
    }

    fn addEntity(f: *Fixture, e: Entity) !void {
        f.state.entities = try std.mem.concat(f.alloc(), Entity, &.{ f.state.entities, &.{e} });
    }

    fn addFact(f: *Fixture, d: Fact) !void {
        f.state.facts = try std.mem.concat(f.alloc(), Fact, &.{ f.state.facts, &.{d} });
    }

    fn hasFinding(report: Report, needle: []const u8) bool {
        for (report.findings) |msg| if (std.mem.indexOf(u8, msg, needle) != null) return true;
        return false;
    }
};

fn expectGate(report: Report, metric: []const u8, want: mod.Gate.Status) !void {
    for (report.metrics.gateList()) |g| {
        if (!std.mem.eql(u8, g.metric, metric)) continue;
        if (g.status() != want) std.debug.print("{s}: got {s} ({?d}), want {s}\n", .{ metric, @tagName(g.status()), g.value, @tagName(want) });
        try testing.expectEqual(want, g.status());
        return;
    }
    return error.UnknownMetric;
}

test "the gold state passes every gate" {
    const f = try Fixture.init();
    defer f.deinit();
    const report = try f.score();
    for (report.findings) |msg| std.debug.print("finding: {s}\n", .{msg});
    try testing.expectEqual(@as(usize, 0), report.findings.len);
    try testing.expect(report.metrics.passes());
    try testing.expectEqual(@as(f64, 1), report.metrics.entity_f1.?);
    try testing.expectEqual(@as(f64, 1), report.metrics.residual_faithfulness.?);
    try testing.expectEqual(@as(f64, 1), report.metrics.fact_density.?);
    try testing.expectEqual(@as(u32, 0), report.metrics.trap_facts.?);
    try testing.expectEqual(@as(f64, 1), report.metrics.labeled_precision.?);
    try testing.expectEqual(@as(u32, 31), report.detail.gold_facts);
    try testing.expectEqual(@as(f64, 1), report.metrics.fact_recall.?);
    try testing.expectEqual(@as(u32, 34), report.detail.gold_fact_items);
    try testing.expectEqual(@as(u32, 7), report.detail.temporal_items);
    try testing.expectEqual(@as(u32, 7), report.detail.merge_pairs);
    try testing.expectEqual(@as(u32, 13), report.detail.retrieval_expected);
    try testing.expectApproxEqAbs(@as(f64, 1.9), report.metrics.calls_per_entry.?, 1e-9);
}

test "a state with nothing ingested is unmeasured, not passing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suite = try fixtures.loadShippedSuite(arena, testing.io);
    const report = try scoreState(arena, &suite, &.{});
    for (report.metrics.gateList()) |g| try testing.expectEqual(mod.Gate.Status.unmeasured, g.status());
    try testing.expect(!report.metrics.passes());
}

test "an unmerged duplicate entity costs entity precision and the expected merge" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.addEntity(.{ .key = "dup", .name = "pg-zig", .type = .software });
    const report = try f.score();
    try testing.expectEqual(@as(u32, 1), report.detail.entity_fp);
    try testing.expectEqual(@as(u32, 5), report.detail.merges_correct);
    try expectGate(report, "merge_accuracy", .fail);
    try testing.expect(Fixture.hasFinding(report, "unmerged duplicate of ent_pgzig"));

    f.entity("dup").merged_into = "ent_pgzig";
    const fixed = try f.score();
    try testing.expectEqual(@as(u32, 0), fixed.detail.entity_fp);
    try testing.expectEqual(@as(u32, 7), fixed.detail.merges_correct);
}

test "merging an organization with its tool is a cross-type merge" {
    const f = try Fixture.init();
    defer f.deinit();
    f.entity("ent_buoy").merged_into = "ent_brackwater";
    const report = try f.score();
    try testing.expectEqual(@as(u32, 1), report.metrics.cross_type_merges.?);
    try expectGate(report, "cross_type_merges", .fail);
    try testing.expect(Fixture.hasFinding(report, "ent_brackwater and ent_buoy must not merge"));
    try testing.expect(!report.metrics.passes());
}

test "an alias that swallows a different-type gold entity is a cross-type merge" {
    const f = try Fixture.init();
    defer f.deinit();
    f.entity("ent_brackwater").aliases = &.{"brackwater-buoy"};
    const report = try f.score();
    try testing.expectEqual(@as(u32, 1), report.metrics.cross_type_merges.?);
}

test "retracting a fact that changed fails invalidation" {
    const f = try Fixture.init();
    defer f.deinit();
    const hollis = f.fact("f_mooring_oncall_hollis");
    hollis.end_kind = .retracted;
    hollis.known.upper = hollis.valid.upper;
    const report = try f.score();
    try testing.expectEqual(@as(u32, 2), report.detail.invalidation_tp);
    try testing.expectEqual(@as(u32, 1), report.detail.invalidation_fp);
    try testing.expectEqual(@as(u32, 1), report.detail.invalidation_fn);
    try expectGate(report, "invalidation_f1", .fail);
    try testing.expect(Fixture.hasFinding(report, "ended as retracted, want changed"));
}

test "a historical backfill that clobbers current state fails" {
    const f = try Fixture.init();
    defer f.deinit();
    const juno = f.fact("f_mooring_oncall_juno");
    juno.valid.upper = try core.time.parseRfc3339("2026-11-21T20:00:00Z");
    juno.end_kind = .changed;
    const tamsin = f.fact("f_mooring_oncall_tamsin");
    tamsin.valid.upper = null;
    tamsin.end_kind = null;
    const report = try f.score();
    try testing.expect(Fixture.hasFinding(report, "f_mooring_oncall_juno must remain active"));
    try testing.expectEqual(@as(u32, 1), report.detail.invalidation_fp);
    try expectGate(report, "temporal_accuracy", .fail);
    try testing.expect(!report.metrics.passes());
}

test "a leaked secret fails the secret gate" {
    const f = try Fixture.init();
    defer f.deinit();
    const leaked = [_]ScannedText{.{ .location = "fact.text", .text = "key is mr_live_7Qk2Vx9Lp4Rt8Wz3Hn6Jb1Ys5Dc0FgAe" }};
    f.state.scanned = try std.mem.concat(f.alloc(), ScannedText, &.{ f.state.scanned.?, &leaked });
    const report = try f.score();
    try testing.expectEqual(@as(u32, 2), report.metrics.secret_leaks.?);
    try expectGate(report, "secret_leaks", .fail);
    for (report.findings) |msg| try testing.expect(std.mem.indexOf(u8, msg, "7Qk2Vx9Lp4Rt8Wz3") == null);
}

test "facts from a skip entry are trap facts" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.addEntity(.{ .key = "neo", .name = "Neo4j", .type = .software });
    try f.addFact(.{
        .key = "bad",
        .subject = "ent_brinelog",
        .relation = "uses",
        .object = .{ .entity = "neo" },
        .text = "brinelog uses Neo4j",
        .evidence = &.{.{ .entry = "e14", .kind = .stated }},
    });
    const report = try f.score();
    try testing.expectEqual(@as(u32, 1), report.metrics.trap_facts.?);
    try testing.expectEqual(@as(u32, 0), report.detail.residual_facts);
    try testing.expect(Fixture.hasFinding(report, "skip entry e14 produced"));
    try expectGate(report, "trap_facts", .fail);
}

test "a refuted claim is forgiven only when it is retracted" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.addEntity(.{ .key = "go", .name = "Go", .type = .software });
    try f.addFact(.{
        .key = "go-fact",
        .subject = "ent_quayline",
        .relation = "uses",
        .object = .{ .entity = "go" },
        .text = "Quayline uses Go",
        .end_kind = .retracted,
        .known = .{ .lower = 1, .upper = 2 },
        .evidence = &.{.{ .entry = "e07", .kind = .stated }},
    });
    const forgiven = try f.score();
    try testing.expectEqual(@as(u32, 0), forgiven.metrics.trap_facts.?);
    try testing.expectEqual(@as(u32, 0), forgiven.detail.residual_facts);
    try testing.expectEqual(@as(u32, 0), forgiven.detail.invalidation_fp);

    const go = f.fact("go-fact");
    go.end_kind = null;
    go.known.upper = null;
    const active = try f.score();
    try testing.expectEqual(@as(u32, 1), active.metrics.trap_facts.?);
    try testing.expectEqual(@as(u32, 0), active.detail.residual_facts);
    try testing.expect(Fixture.hasFinding(active, "forbidden fact 'Quayline uses Go'"));
}

test "a restatement that inserts a second row is a duplicate" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.addFact(.{
        .key = "again",
        .subject = "ent_brinelog",
        .relation = "depends_on",
        .object = .{ .entity = "ent_postgres" },
        .text = "brinelog depends on Postgres",
        .evidence = &.{.{ .entry = "e15", .kind = .stated }},
    });
    const report = try f.score();
    try testing.expectEqual(@as(u32, 1), report.detail.duplicate_facts);
    try testing.expect(Fixture.hasFinding(report, "duplicated f_brinelog_uses_pg"));
    try testing.expectApproxEqAbs(@as(f64, 31.0 / 32.0), report.metrics.labeled_precision.?, 1e-9);
    try expectGate(report, "labeled_precision", .pass);
    for (0..5) |n| try f.addFact(.{
        .key = try std.fmt.allocPrint(f.alloc(), "again-{d}", .{n}),
        .subject = "ent_brinelog",
        .relation = "uses",
        .object = .{ .entity = "ent_postgres" },
        .evidence = &.{.{ .entry = "e15", .kind = .stated }},
    });
    try expectGate(try f.score(), "labeled_precision", .fail);
}

test "a valid_from three days off fails temporal grounding" {
    const f = try Fixture.init();
    defer f.deinit();
    const juno = f.fact("f_mooring_oncall_juno");
    juno.valid.lower = juno.valid.lower.? + 3 * std.time.us_per_day;
    const report = try f.score();
    try testing.expectEqual(@as(u32, 6), report.detail.temporal_correct);
    try expectGate(report, "temporal_accuracy", .fail);
}

test "retrieval misses and excluded hits are counted" {
    const f = try Fixture.init();
    defer f.deinit();
    const results = @constCast(f.state.retrieval.?);
    results[0].hits = &.{ .{ .fact = "f_mooring_oncall_hollis" }, .{ .fact = "f_mooring_oncall_tamsin" } };
    results[5].hits = &.{ .{ .fact = "f_quayline_uses_elixir" }, .{ .fact = "f_quayline_uses_bandit", .text = "Quayline uses Bandit, not Cowboy" } };
    const report = try f.score();
    try testing.expectEqual(@as(u32, 12), report.detail.retrieval_found);
    try testing.expectEqual(@as(u32, 3), report.detail.retrieval_exclusion_violations.?);
    try expectGate(report, "retrieval_recall_at_5", .pass);
    f.state.retrieval = null;
    try expectGate(try f.score(), "retrieval_recall_at_5", .unmeasured);
}

test "calls and cost are unmeasured until every entry finishes" {
    const f = try Fixture.init();
    defer f.deinit();
    @constCast(f.state.entries)[3].status = .queued;
    const report = try f.score();
    try expectGate(report, "calls_per_entry", .unmeasured);
    try expectGate(report, "cost_per_entry_usd", .unmeasured);
    try expectGate(report, "entity_f1", .pass);
}

fn addUnlabeled(f: *Fixture, key: []const u8, text: []const u8) !void {
    try f.addFact(.{
        .key = key,
        .subject = "ent_brinelog",
        .relation = "kept_separate_from",
        .object = .{ .entity = "ent_quayline" },
        .text = text,
        .evidence = &.{.{ .entry = "e01", .kind = .stated }},
    });
}

test "an unlabeled fact is a residual that only the judge can score" {
    const f = try Fixture.init();
    defer f.deinit();
    try addUnlabeled(f, "separate", "brinelog is kept separate from Quayline");

    const residuals = try residualFacts(f.alloc(), &f.suite, &f.state);
    try testing.expectEqual(@as(usize, 1), residuals.len);
    try testing.expectEqualStrings("e01", residuals[0].entry.?);
    try testing.expectEqualStrings("brinelog", residuals[0].subject);
    try testing.expectEqualStrings("Quayline", residuals[0].object);

    const unjudged = try f.score();
    try testing.expectEqual(@as(u32, 1), unjudged.detail.residual_facts);
    try testing.expectEqual(@as(u32, 0), unjudged.metrics.trap_facts.?);
    try expectGate(unjudged, "residual_faithfulness", .unmeasured);
    try testing.expect(!unjudged.metrics.passes());

    f.state.judgments = &.{.{ .fact = "separate", .supported = true, .durable = true, .reason = "the user says to keep it separate" }};
    const faithful = try f.score();
    try testing.expectEqual(@as(f64, 1), faithful.metrics.residual_faithfulness.?);
    try testing.expect(faithful.metrics.passes());
    try testing.expect(faithful.residuals[0].judgment != null);

    f.state.judgments = &.{.{ .fact = "separate", .supported = true, .durable = false, .reason = "one-off remark" }};
    const transient = try f.score();
    try testing.expectEqual(@as(f64, 0), transient.metrics.residual_faithfulness.?);
    try testing.expectEqual(@as(u32, 1), transient.detail.residual_transient);
    try testing.expect(Fixture.hasFinding(transient, "is transient: one-off remark"));
    try expectGate(transient, "residual_faithfulness", .fail);

    f.state.judgments = &.{};
    const missing = try f.score();
    try testing.expectEqual(@as(u32, 1), missing.detail.residual_unjudged);
    try expectGate(missing, "residual_faithfulness", .fail);
}

test "a retracted unlabeled fact is neither a residual nor a trap" {
    const f = try Fixture.init();
    defer f.deinit();
    try addUnlabeled(f, "withdrawn", "brinelog is kept separate from Quayline");
    const d = f.fact("withdrawn");
    d.end_kind = .retracted;
    d.known = .{ .lower = 1, .upper = 2 };
    const report = try f.score();
    try testing.expectEqual(@as(u32, 0), report.detail.residual_facts);
    try testing.expectEqual(@as(u32, 0), report.metrics.trap_facts.?);
    try testing.expectEqual(@as(u32, 32), report.detail.facts_extracted);
}

test "shredding an entry into many facts breaks the density cap" {
    const f = try Fixture.init();
    defer f.deinit();
    var judgments: std.ArrayList(Judgment) = .empty;
    for (0..24) |n| {
        const key = try std.fmt.allocPrint(f.alloc(), "micro-{d}", .{n});
        try addUnlabeled(f, key, "brinelog is kept separate from Quayline");
        try judgments.append(f.alloc(), .{ .fact = key, .supported = true, .durable = true });
    }
    f.state.judgments = judgments.items;
    const report = try f.score();
    try testing.expectEqual(@as(f64, 1), report.metrics.residual_faithfulness.?);
    try testing.expectApproxEqAbs(@as(f64, 55.0 / 31.0), report.metrics.fact_density.?, 1e-9);
    try expectGate(report, "fact_density", .fail);
}

test "judge calls stay out of the ingestion call and cost gates" {
    const f = try Fixture.init();
    defer f.deinit();
    const judge_calls = [_]LlmCall{ .{ .purpose = .judge, .cost_usd = 0.5 }, .{ .purpose = .repair, .cost_usd = 0.25 } };
    f.state.judge_calls = &judge_calls;
    f.state.llm_calls = try std.mem.concat(f.alloc(), LlmCall, &.{ f.state.llm_calls, &.{.{ .purpose = .judge, .cost_usd = 1 }} });
    const report = try f.score();
    try testing.expectApproxEqAbs(@as(f64, 1.9), report.metrics.calls_per_entry.?, 1e-9);
    try expectGate(report, "cost_per_entry_usd", .pass);
    try testing.expectEqual(@as(u32, 2), report.detail.judge_calls);
    try testing.expectApproxEqAbs(@as(f64, 0.75), report.detail.judge_cost_usd, 1e-9);
}
