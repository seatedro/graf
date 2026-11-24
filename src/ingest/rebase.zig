const std = @import("std");
const core = @import("core");
const rules = @import("rules.zig");
const resolve = @import("resolve.zig");

const Allocator = std.mem.Allocator;
const Id = core.Id;
const ChangeSet = core.ChangeSet;

pub const TouchedEntity = struct {
    id: Id,
    name: []const u8,
    norm: []const u8,
    type: core.EntityType,
    merged_into: ?Id = null,
    aliases: []const []const u8 = &.{},
    emb: []const f32 = &.{},
};

pub const TouchedFact = struct {
    fact: resolve.CandidateFact,
    active: bool,
};

pub const Touched = struct {
    entities: []const TouchedEntity = &.{},
    facts: []const TouchedFact = &.{},
};

pub const PossibleDuplicate = struct { a: Id, b: Id, score: f32 };

pub const Rebased = struct {
    possible_duplicates: []const PossibleDuplicate,
};

const Remap = struct {
    from: std.ArrayList(Id) = .empty,
    to: std.ArrayList(Id) = .empty,

    fn put(r: *Remap, arena: Allocator, from: Id, to: Id) !void {
        try r.from.append(arena, from);
        try r.to.append(arena, to);
    }

    fn get(r: Remap, id: Id) Id {
        var cur = id;
        var hops: usize = 0;
        while (hops < 8) : (hops += 1) {
            const next = for (r.from.items, r.to.items) |f, t| {
                if (f.eql(cur)) break t;
            } else return cur;
            cur = next;
        }
        return cur;
    }
};

fn hasNorm(list: []const []const u8, n: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

pub fn apply(arena: Allocator, cs: *ChangeSet, touched: Touched, commit_time: core.Micros, reference_time: core.Micros) !Rebased {
    var remap: Remap = .{};
    var dups: std.ArrayList(PossibleDuplicate) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    try warnings.appendSlice(arena, cs.warnings);
    var new_aliases: std.ArrayList(ChangeSet.Alias) = .empty;
    try new_aliases.appendSlice(arena, cs.new_aliases);

    for (touched.entities) |t| if (t.merged_into) |into| try remap.put(arena, t.id, into);

    var kept_entities: std.ArrayList(ChangeSet.NewEntity) = .empty;
    for (cs.new_entities) |ne| {
        var norms: std.ArrayList([]const u8) = .empty;
        try norms.append(arena, ne.norm);
        for (ne.aliases) |a| try norms.append(arena, try core.text.norm(arena, a));

        var match: ?Id = null;
        for (touched.entities) |t| {
            if (t.merged_into != null or !rules.compatible(ne.type, t.type)) continue;
            var hit = hasNorm(norms.items, t.norm);
            for (t.aliases) |a| hit = hit or hasNorm(norms.items, a);
            if (hit) {
                match = t.id;
                break;
            }
        }
        if (match == null) for (touched.entities) |t| {
            if (t.merged_into != null or t.type != ne.type) continue;
            if (rules.cosine(ne.name_emb, t.emb) >= rules.merge_cosine and rules.tokenJaccard(ne.norm, t.norm) >= rules.merge_jaccard) {
                match = t.id;
                break;
            }
        };
        if (match) |id| {
            try remap.put(arena, ne.id, id);
            for (norms.items, 0..) |n, k| {
                if (n.len == 0) continue;
                const raw = if (k == 0) ne.name else ne.aliases[k - 1];
                try new_aliases.append(arena, .{ .entity_id = id, .alias = raw, .norm = n });
            }
            try warnings.append(arena, try std.fmt.allocPrint(arena, "rebase: {s} resolved to an entity committed concurrently", .{ne.name}));
            continue;
        }
        for (touched.entities) |t| {
            if (t.merged_into != null or rules.hardBlocked(ne.type, t.type) or !rules.compatible(ne.type, t.type)) continue;
            const c = rules.cosine(ne.name_emb, t.emb);
            if (c >= rules.gray_cosine) try dups.append(arena, .{ .a = ne.id, .b = t.id, .score = c });
        }
        try kept_entities.append(arena, ne);
    }
    cs.new_entities = kept_entities.items;

    var aliases_out: std.ArrayList(ChangeSet.Alias) = .empty;
    for (new_aliases.items) |a| {
        var x = a;
        x.entity_id = remap.get(a.entity_id);
        var dup = false;
        for (aliases_out.items) |y| if (y.entity_id.eql(x.entity_id) and std.mem.eql(u8, y.norm, x.norm)) {
            dup = true;
        };
        if (!dup) try aliases_out.append(arena, x);
    }
    cs.new_aliases = aliases_out.items;

    var mentions: std.ArrayList(Id) = .empty;
    for (cs.mentions) |m| {
        const id = remap.get(m);
        var dup = false;
        for (mentions.items) |x| if (x.eql(id)) {
            dup = true;
        };
        if (!dup) try mentions.append(arena, id);
    }
    cs.mentions = mentions.items;

    var merges: std.ArrayList(ChangeSet.Merge) = .empty;
    for (cs.merges) |m| {
        const from = remap.get(m.from);
        const into = remap.get(m.into);
        if (!from.eql(into)) try merges.append(arena, .{ .from = from, .into = into, .reason = m.reason });
    }
    cs.merges = merges.items;

    const ended = struct {
        fn f(t: Touched, id: Id) bool {
            for (t.facts) |x| if (x.fact.id.eql(id)) return !x.active;
            return false;
        }
    }.f;

    var restatements: std.ArrayList(ChangeSet.Restatement) = .empty;
    for (cs.restatements) |r| {
        if (ended(touched, r.fact_id)) {
            try warnings.append(arena, "rebase: dropped a restatement of a fact that ended concurrently");
            continue;
        }
        try restatements.append(arena, r);
    }
    var invalidations: std.ArrayList(ChangeSet.Invalidation) = .empty;
    for (cs.invalidations) |inv| if (!ended(touched, inv.fact_id)) try invalidations.append(arena, inv);
    var retractions: std.ArrayList(ChangeSet.Retraction) = .empty;
    for (cs.retractions) |r| if (!ended(touched, r.fact_id)) try retractions.append(arena, r);
    var evidence: std.ArrayList(ChangeSet.Evidence) = .empty;
    for (cs.evidence) |p| if (!ended(touched, p.fact_id)) try evidence.append(arena, p);

    var blast: rules.BlastRadius = .{ .used = invalidations.items.len + retractions.items.len };
    var new_facts: std.ArrayList(ChangeSet.NewFact) = .empty;
    var active = try arena.alloc(bool, touched.facts.len);
    for (touched.facts, 0..) |t, i| active[i] = t.active;

    for (cs.new_facts) |nf_in| {
        var nf = nf_in;
        nf.fact.subject_id = remap.get(nf.fact.subject_id);
        switch (nf.fact.object) {
            .entity => |o| nf.fact.object = .{ .entity = remap.get(o) },
            .value => {},
        }
        const key: rules.Key = .{
            .subject = nf.fact.subject_id,
            .relation = nf.fact.relation,
            .qualifier = nf.fact.qualifier,
            .object = switch (nf.fact.object) {
                .entity => |o| .{ .entity = o },
                .value => |v| .{ .value = try core.text.norm(arena, v) },
            },
            .valid = nf.fact.valid,
        };
        const rule = rules.ruleFor(nf.fact.relation, null);

        var restated: ?resolve.CandidateFact = null;
        for (touched.facts, 0..) |t, i| {
            if (!active[i]) continue;
            if (rules.sameCanonicalKey(key, try factKey(arena, t.fact))) {
                restated = t.fact;
                break;
            }
        }
        if (restated) |old| {
            var quote: ?[]const u8 = null;
            var kept: std.ArrayList(ChangeSet.Evidence) = .empty;
            for (evidence.items) |p| {
                if (p.fact_id.eql(nf.fact.id)) {
                    if (p.kind == .stated) quote = p.quote;
                    continue;
                }
                try kept.append(arena, p);
            }
            evidence = kept;
            for (invalidations.items) |*inv| if (inv.ended_by) |e| if (e.eql(nf.fact.id)) {
                inv.ended_by = old.id;
            };
            for (retractions.items) |*r| if (r.ended_by) |e| if (e.eql(nf.fact.id)) {
                r.ended_by = old.id;
            };
            var already = false;
            for (restatements.items) |r| if (r.fact_id.eql(old.id)) {
                already = true;
            };
            if (!already) {
                try restatements.append(arena, .{ .fact_id = old.id, .confidence = rules.restate(old.confidence) });
                try evidence.append(arena, .{ .fact_id = old.id, .kind = .restated, .quote = quote });
            }
            continue;
        }

        for (touched.facts, 0..) |t, i| {
            if (!active[i]) continue;
            if (rules.conflict(key, rule, try factKey(arena, t.fact)) == null) continue;
            var old = oldFact(t.fact, nf.fact.graph_id);
            var trial_new = nf.fact;
            switch (rules.resolveConflict(&old, &trial_new, .changed, commit_time, reference_time)) {
                .none => {},
                .bounded_new => nf.fact = trial_new,
                .ended_old => if (blast.admit()) {
                    active[i] = false;
                    try invalidations.append(arena, .{ .fact_id = old.id, .valid_upper = old.valid.upper.?, .ended_by = nf.fact.id });
                    try evidence.append(arena, .{ .fact_id = old.id, .kind = .contradicted });
                },
                .retracted_old => if (blast.admit()) {
                    active[i] = false;
                    try retractions.append(arena, .{ .fact_id = old.id, .end_kind = .retracted, .ended_by = nf.fact.id });
                    try evidence.append(arena, .{ .fact_id = old.id, .kind = .retracted });
                },
            }
        }
        try new_facts.append(arena, nf);
    }
    if (blast.dropped > 0) try warnings.append(arena, try std.fmt.allocPrint(arena, "rebase: skipped {d} endings over the per-entry cap", .{blast.dropped}));

    cs.new_facts = new_facts.items;
    cs.restatements = restatements.items;
    cs.invalidations = invalidations.items;
    cs.retractions = retractions.items;
    cs.evidence = evidence.items;
    cs.warnings = warnings.items;
    return .{ .possible_duplicates = dups.items };
}

fn factKey(arena: Allocator, c: resolve.CandidateFact) !rules.Key {
    return .{
        .subject = c.subject_id,
        .relation = c.relation,
        .qualifier = c.qualifier,
        .object = if (c.object_id) |o| .{ .entity = o } else .{ .value = try core.text.norm(arena, c.object_value orelse "") },
        .valid = .{ .lower = c.valid_lower, .upper = c.valid_upper },
    };
}

fn oldFact(c: resolve.CandidateFact, graph_id: Id) core.Fact {
    return .{
        .id = c.id,
        .graph_id = graph_id,
        .subject_id = c.subject_id,
        .relation = c.relation,
        .qualifier = c.qualifier,
        .object = if (c.object_id) |o| .{ .entity = o } else .{ .value = c.object_value orelse "" },
        .text = c.text,
        .scope = .project,
        .valid = .{ .lower = c.valid_lower, .upper = c.valid_upper },
        .known = .{},
        .author = .agent,
        .confidence = c.confidence,
    };
}

const testing = std.testing;

fn testId(n: u8) Id {
    return Id.fromParts(@as(u48, n) << 8, @splat(n));
}

test "rebase folds a concurrently created entity and restates a concurrently committed fact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mine = testId(1);
    const theirs = testId(2);
    const subject = testId(3);
    const my_fact = testId(10);
    const their_fact = testId(11);
    var cs: ChangeSet = .{
        .base_seq = 4,
        .new_entities = &.{.{ .id = mine, .name = "Relay", .norm = "relay", .type = .software, .name_emb = &.{ 1, 0 } }},
        .new_facts = &.{.{ .fact = .{
            .id = my_fact,
            .graph_id = testId(0),
            .subject_id = subject,
            .relation = "depends_on",
            .object = .{ .entity = mine },
            .text = "x",
            .scope = .project,
            .valid = .{ .lower = 100 },
            .known = .{ .lower = 100 },
            .author = .user,
            .confidence = 0.9,
        }, .emb = &.{} }},
        .evidence = &.{.{ .fact_id = my_fact, .kind = .stated, .quote = "q" }},
        .mentions = &.{ mine, subject },
    };
    const out = try apply(arena, &cs, .{
        .entities = &.{.{ .id = theirs, .name = "relay", .norm = "relay", .type = .software }},
        .facts = &.{.{ .active = true, .fact = .{ .item = 0, .id = their_fact, .subject_id = subject, .relation = "depends_on", .object_id = theirs, .text = "y", .valid_lower = 50, .confidence = 0.7 } }},
    }, 200, 100);
    try testing.expectEqual(@as(usize, 0), out.possible_duplicates.len);
    try testing.expectEqual(@as(usize, 0), cs.new_entities.len);
    try testing.expectEqual(@as(usize, 0), cs.new_facts.len);
    try testing.expectEqual(@as(usize, 1), cs.restatements.len);
    try testing.expect(cs.restatements[0].fact_id.eql(their_fact));
    try testing.expectApproxEqAbs(@as(f32, 0.79), cs.restatements[0].confidence, 1e-6);
    try testing.expect(cs.mentions[0].eql(theirs));
    try testing.expectEqual(@as(usize, 1), cs.evidence.len);
    try testing.expectEqual(core.types.EvidenceKind.restated, cs.evidence[0].kind);
}

test "rebase ends a concurrently committed single-valued fact and drops work on facts that ended" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const subject = testId(3);
    const my_fact = testId(10);
    const their_fact = testId(11);
    const gone = testId(12);
    var cs: ChangeSet = .{
        .base_seq = 4,
        .new_facts = &.{.{ .fact = .{
            .id = my_fact,
            .graph_id = testId(0),
            .subject_id = subject,
            .relation = "has_status",
            .object = .{ .value = "frozen" },
            .text = "x",
            .scope = .project,
            .valid = .{ .lower = 300 },
            .known = .{ .lower = 300 },
            .author = .user,
            .confidence = 0.9,
        }, .emb = &.{} }},
        .restatements = &.{.{ .fact_id = gone, .confidence = 0.95 }},
        .evidence = &.{ .{ .fact_id = my_fact, .kind = .stated }, .{ .fact_id = gone, .kind = .restated } },
    };
    _ = try apply(arena, &cs, .{
        .facts = &.{
            .{ .active = true, .fact = .{ .item = 0, .id = their_fact, .subject_id = subject, .relation = "has_status", .object_value = "open", .text = "y", .valid_lower = 200, .confidence = 0.9 } },
            .{ .active = false, .fact = .{ .item = 0, .id = gone, .subject_id = subject, .relation = "uses", .object_value = "z", .text = "z", .valid_lower = 10, .valid_upper = 20, .confidence = 0.9 } },
        },
    }, 400, 300);
    try testing.expectEqual(@as(usize, 1), cs.new_facts.len);
    try testing.expectEqual(@as(usize, 1), cs.invalidations.len);
    try testing.expect(cs.invalidations[0].fact_id.eql(their_fact));
    try testing.expectEqual(@as(core.Micros, 300), cs.invalidations[0].valid_upper);
    try testing.expectEqual(@as(usize, 0), cs.restatements.len);
    for (cs.evidence) |p| try testing.expect(!p.fact_id.eql(gone));
}

test "rebase follows concurrent merges and records gray-band duplicates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const merged_away = testId(5);
    const survivor = testId(6);
    const mine = testId(7);
    const lookalike = testId(8);
    var cs: ChangeSet = .{
        .base_seq = 1,
        .new_entities = &.{.{ .id = mine, .name = "relay gateway", .norm = "relay gateway", .type = .software, .name_emb = &.{ 1, 0.5 } }},
        .new_aliases = &.{.{ .entity_id = merged_away, .alias = "rly", .norm = "rly" }},
        .mentions = &.{ merged_away, mine },
    };
    const out = try apply(arena, &cs, .{ .entities = &.{
        .{ .id = merged_away, .name = "rly", .norm = "rly", .type = .software, .merged_into = survivor },
        .{ .id = lookalike, .name = "relay proxy", .norm = "relay proxy", .type = .software, .emb = &.{ 1, 0.4 } },
    } }, 10, 5);
    try testing.expect(cs.mentions[0].eql(survivor));
    try testing.expect(cs.new_aliases[0].entity_id.eql(survivor));
    try testing.expectEqual(@as(usize, 1), cs.new_entities.len);
    try testing.expectEqual(@as(usize, 1), out.possible_duplicates.len);
    try testing.expect(out.possible_duplicates[0].b.eql(lookalike));
}
