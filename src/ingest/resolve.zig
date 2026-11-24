const std = @import("std");
const core = @import("core");
const ingest = @import("mod.zig");
const rules = @import("rules.zig");
const extract = @import("extract.zig");
const time = @import("time.zig");

const Allocator = std.mem.Allocator;
const Id = core.Id;
const Micros = core.Micros;
const ChangeSet = core.ChangeSet;

pub const CandidateEntity = struct {
    item: u32,
    id: Id,
    name: []const u8,
    norm: []const u8,
    type: core.EntityType,
    alias_match: bool = false,
    cosine: f32 = 0,
};

pub const CandidateFact = struct {
    item: u32,
    id: Id,
    subject_id: Id,
    predicate: []const u8,
    qualifier: []const u8 = "",
    object_id: ?Id = null,
    object_value: ?[]const u8 = null,
    text: []const u8,
    valid_lower: ?Micros = null,
    valid_upper: ?Micros = null,
    confidence: f32,
    cosine: f32 = 0,
};

pub const PredicateRow = struct {
    name: []const u8,
    cardinality: core.types.Cardinality = .many,
    opposes: ?[]const u8 = null,
    status: core.types.PredicateStatus = .proposed,
    mapped_to: ?[]const u8 = null,
    description: []const u8 = "",
    emb: []const f32 = &.{},
};

pub const BlockedPair = struct { a: Id, b: Id };

pub const Prefetch = struct {
    base_seq: i64 = 0,
    entities: []const CandidateEntity = &.{},
    facts: []const CandidateFact = &.{},
    blocked: []const BlockedPair = &.{},
    predicates: []const PredicateRow = &.{},

    fn isBlocked(p: Prefetch, a: Id, b: Id) bool {
        for (p.blocked) |pair| {
            if ((pair.a.eql(a) and pair.b.eql(b)) or (pair.a.eql(b) and pair.b.eql(a))) return true;
        }
        return false;
    }

    fn predicate(p: Prefetch, name: []const u8) ?PredicateRow {
        for (p.predicates) |row| if (std.mem.eql(u8, row.name, name)) return row;
        return null;
    }
};

pub const EpisodeInfo = struct {
    id: Id,
    graph_id: Id,
    reference_time: Micros,
    project: ?[]const u8 = null,
};

pub const Vectors = struct {
    entities: []const []const f32,
    facts: []const []const f32,
    predicates: []const []const f32 = &.{},
};

pub const Thresholds = struct {
    duplicate: f64 = 0.70,
    contradiction: f64 = 0.80,
};

pub const max_entity_labels = 40;
pub const max_fact_labels = 80;

pub const EntityDecision = union(enum) {
    existing: Id,
    ask,
    new,
};

pub const EntityPlan = struct {
    decision: EntityDecision,
    gray: []const Id = &.{},
    absorb: []const Id = &.{},
};

pub const FactPlan = struct {
    candidates: []const Id = &.{},
};

pub const Plan = struct {
    entities: []const EntityPlan,
    facts: []const FactPlan,
    entity_labels: []const Id,
    fact_labels: []const Id,

    pub fn needsResolution(p: Plan) bool {
        for (p.entities) |e| if (e.decision == .ask) return true;
        for (p.facts) |f| if (f.candidates.len > 0) return true;
        return false;
    }

    pub fn entityLabel(p: Plan, id: Id) ?usize {
        for (p.entity_labels, 0..) |l, i| if (l.eql(id)) return i;
        return null;
    }

    pub fn factLabel(p: Plan, id: Id) ?usize {
        for (p.fact_labels, 0..) |l, i| if (l.eql(id)) return i;
        return null;
    }

    pub fn lookupEntityLabel(p: Plan, label: []const u8) ?Id {
        return lookupLabel(p.entity_labels, 'E', label);
    }

    pub fn lookupFactLabel(p: Plan, label: []const u8) ?Id {
        return lookupLabel(p.fact_labels, 'F', label);
    }
};

fn lookupLabel(labels: []const Id, prefix: u8, label: []const u8) ?Id {
    const l = std.mem.trim(u8, label, " ");
    if (l.len < 2 or std.ascii.toUpper(l[0]) != prefix) return null;
    const n = std.fmt.parseInt(usize, l[1..], 10) catch return null;
    if (n == 0 or n > labels.len) return null;
    return labels[n - 1];
}

fn containsId(ids: []const Id, id: Id) bool {
    for (ids) |x| if (x.eql(id)) return true;
    return false;
}

fn appendUnique(arena: Allocator, list: *std.ArrayList(Id), id: Id) Allocator.Error!void {
    if (!containsId(list.items, id)) try list.append(arena, id);
}

pub fn novelPredicates(arena: Allocator, checked: extract.Checked, prefetch: Prefetch) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (checked.result.facts) |f| {
        if (core.ontology.find(f.predicate) != null) continue;
        if (prefetch.predicate(f.predicate) != null) continue;
        var seen = false;
        for (out.items) |n| if (std.mem.eql(u8, n, f.predicate)) {
            seen = true;
        };
        if (!seen) try out.append(arena, f.predicate);
    }
    return out.items;
}

pub fn predicateDescription(checked: extract.Checked, name: []const u8) []const u8 {
    for (checked.result.new_predicates) |p| if (std.mem.eql(u8, p.name, name)) return p.description;
    return name;
}

fn entityIndex(checked: extract.Checked, ref: []const u8) usize {
    for (checked.result.entities, 0..) |e, i| if (std.mem.eql(u8, e.ref, ref)) return i;
    unreachable;
}

fn byCosineDesc(_: void, a: CandidateEntity, b: CandidateEntity) bool {
    return a.cosine > b.cosine;
}

fn candidatesFor(arena: Allocator, prefetch: Prefetch, item: usize) Allocator.Error![]CandidateEntity {
    var out: std.ArrayList(CandidateEntity) = .empty;
    outer: for (prefetch.entities) |c| {
        if (c.item != item) continue;
        for (out.items) |*prev| if (prev.id.eql(c.id)) {
            prev.alias_match = prev.alias_match or c.alias_match;
            prev.cosine = @max(prev.cosine, c.cosine);
            continue :outer;
        };
        try out.append(arena, c);
    }
    std.mem.sort(CandidateEntity, out.items, {}, byCosineDesc);
    return out.items;
}

fn planEntity(arena: Allocator, e: ingest.ExtractedEntity, item: usize, prefetch: Prefetch) Allocator.Error!EntityPlan {
    const cands = try candidatesFor(arena, prefetch, item);
    const e_norm = try core.text.norm(arena, e.name);

    var winner: ?CandidateEntity = null;
    for (cands) |c| if (c.alias_match and rules.compatible(e.type, c.type)) {
        winner = c;
        break;
    };
    if (winner) |w| {
        var absorb: std.ArrayList(Id) = .empty;
        for (cands) |c| {
            if (!c.alias_match or c.id.eql(w.id) or !rules.compatible(e.type, c.type)) continue;
            if (rules.hardBlocked(w.type, c.type) or prefetch.isBlocked(w.id, c.id)) continue;
            try appendUnique(arena, &absorb, c.id);
        }
        return .{ .decision = .{ .existing = w.id }, .absorb = absorb.items };
    }

    for (cands) |c| {
        if (c.type != e.type or c.cosine < rules.merge_cosine) continue;
        if (rules.tokenJaccard(e_norm, c.norm) < rules.merge_jaccard) continue;
        return .{ .decision = .{ .existing = c.id } };
    }

    var gray: std.ArrayList(Id) = .empty;
    for (cands) |c| {
        if (gray.items.len >= rules.gray_per_entity) break;
        if (rules.hardBlocked(e.type, c.type)) continue;
        const near = if (rules.compatible(e.type, c.type)) c.cosine >= rules.gray_cosine else c.cosine >= rules.gray_cross_type_cosine;
        if (near) try appendUnique(arena, &gray, c.id);
    }
    if (gray.items.len > 0) return .{ .decision = .ask, .gray = gray.items };
    return .{ .decision = .new };
}

fn candidateKey(arena: Allocator, c: CandidateFact) Allocator.Error!rules.Key {
    return .{
        .subject = c.subject_id,
        .predicate = c.predicate,
        .qualifier = c.qualifier,
        .object = if (c.object_id) |o| .{ .entity = o } else .{ .value = try core.text.norm(arena, c.object_value orelse "") },
        .valid = .{ .lower = c.valid_lower, .upper = c.valid_upper },
    };
}

fn byFactCosineDesc(_: void, a: CandidateFact, b: CandidateFact) bool {
    return a.cosine > b.cosine;
}

pub fn plan(arena: Allocator, checked: extract.Checked, prefetch: Prefetch) Allocator.Error!Plan {
    const ents = checked.result.entities;
    const entity_plans = try arena.alloc(EntityPlan, ents.len);
    var entity_labels: std.ArrayList(Id) = .empty;
    for (ents, 0..) |e, i| {
        entity_plans[i] = try planEntity(arena, e, i, prefetch);
        for (entity_plans[i].gray) |g| {
            if (entity_labels.items.len < max_entity_labels) try appendUnique(arena, &entity_labels, g);
        }
        if (entity_plans[i].decision == .ask) {
            var kept: std.ArrayList(Id) = .empty;
            for (entity_plans[i].gray) |g| if (containsId(entity_labels.items, g)) try kept.append(arena, g);
            entity_plans[i].gray = kept.items;
            if (kept.items.len == 0) entity_plans[i].decision = .new;
        }
    }

    const facts = checked.result.facts;
    const fact_plans = try arena.alloc(FactPlan, facts.len);
    var fact_labels: std.ArrayList(Id) = .empty;
    for (facts, 0..) |f, j| {
        const subj = entity_plans[entityIndex(checked, f.subject)];
        var subjects: std.ArrayList(Id) = .empty;
        switch (subj.decision) {
            .existing => |id| try subjects.append(arena, id),
            .ask => try subjects.appendSlice(arena, subj.gray),
            .new => {},
        }
        var object_known: ?Id = null;
        if (f.object) |o| switch (entity_plans[entityIndex(checked, o)].decision) {
            .existing => |id| object_known = id,
            else => {},
        };
        const value_norm = if (f.value) |v| try core.text.norm(arena, v) else null;

        var pool: std.ArrayList(CandidateFact) = .empty;
        outer: for (prefetch.facts) |c| {
            if (c.item != j) continue;
            for (pool.items) |p| if (p.id.eql(c.id)) continue :outer;
            if (subj.decision == .existing and c.subject_id.eql(subj.decision.existing) and
                std.mem.eql(u8, c.predicate, f.predicate) and std.mem.eql(u8, c.qualifier, f.qualifier orelse ""))
            {
                const same_object = if (f.object != null)
                    (if (object_known) |ok| (if (c.object_id) |co| co.eql(ok) else false) else false)
                else if (c.object_value) |cv| std.mem.eql(u8, try core.text.norm(arena, cv), value_norm.?) else false;
                if (same_object) continue;
            }
            const related = containsId(subjects.items, c.subject_id) or c.cosine >= rules.neighbour_cosine or
                (if (object_known) |ok| (if (c.object_id) |co| co.eql(ok) else false) else false);
            if (related) try pool.append(arena, c);
        }
        std.mem.sort(CandidateFact, pool.items, {}, byFactCosineDesc);
        var cands: std.ArrayList(Id) = .empty;
        for (pool.items) |c| {
            if (cands.items.len >= rules.neighbours_per_fact) break;
            if (fact_labels.items.len >= max_fact_labels and !containsId(fact_labels.items, c.id)) continue;
            try appendUnique(arena, &fact_labels, c.id);
            try cands.append(arena, c.id);
        }
        fact_plans[j] = .{ .candidates = cands.items };
    }

    return .{
        .entities = entity_plans,
        .facts = fact_plans,
        .entity_labels = entity_labels.items,
        .fact_labels = fact_labels.items,
    };
}

pub const Verdict = struct {
    links: []const ?Id,
    duplicates: []const ?Id,
    contradictions: []const []const Contradiction,

    pub const Contradiction = struct { fact: Id, kind: ingest.ConflictKind, at: ?Micros };

    pub fn none(arena: Allocator, p: Plan) Allocator.Error!Verdict {
        const links = try arena.alloc(?Id, p.entities.len);
        @memset(links, null);
        const dups = try arena.alloc(?Id, p.facts.len);
        @memset(dups, null);
        const cons = try arena.alloc([]const Contradiction, p.facts.len);
        @memset(cons, &.{});
        return .{ .links = links, .duplicates = dups, .contradictions = cons };
    }
};

pub const Interpreted = struct {
    verdict: Verdict,
    warnings: []const []const u8,
    invalid: usize,
    total: usize,
};

pub fn interpret(arena: Allocator, p: Plan, checked: extract.Checked, r: ingest.ResolveResult) Allocator.Error!Interpreted {
    const links = try arena.alloc(?Id, p.entities.len);
    @memset(links, null);
    const dups = try arena.alloc(?Id, p.facts.len);
    @memset(dups, null);
    const cons = try arena.alloc([]const Verdict.Contradiction, p.facts.len);
    @memset(cons, &.{});
    const v: Verdict = .{ .links = links, .duplicates = dups, .contradictions = cons };
    var warnings: std.ArrayList([]const u8) = .empty;
    var invalid: usize = 0;
    var total: usize = 0;

    for (r.entity_links) |link| {
        total += 1;
        const idx = for (checked.result.entities, 0..) |e, i| {
            if (std.mem.eql(u8, e.ref, std.mem.trim(u8, link.ref, " "))) break i;
        } else null;
        const i = idx orelse {
            invalid += 1;
            try warnings.append(arena, try std.fmt.allocPrint(arena, "resolution named unknown entity ref {s}", .{link.ref}));
            continue;
        };
        const label = link.existing orelse continue;
        const id = p.lookupEntityLabel(label) orelse {
            invalid += 1;
            try warnings.append(arena, try std.fmt.allocPrint(arena, "resolution named unknown entity label {s}", .{label}));
            continue;
        };
        if (!containsId(p.entities[i].gray, id)) {
            invalid += 1;
            try warnings.append(arena, try std.fmt.allocPrint(arena, "resolution linked {s} to {s}, which was not one of its candidates", .{ link.ref, label }));
            continue;
        }
        links[i] = id;
    }

    for (r.fact_verdicts) |fv| {
        total += 1;
        if (fv.fact_index >= p.facts.len) {
            invalid += 1;
            try warnings.append(arena, try std.fmt.allocPrint(arena, "resolution named fact index {d}, out of range", .{fv.fact_index}));
            continue;
        }
        const j = fv.fact_index;
        const allowed = p.facts[j].candidates;
        if (fv.duplicate_of) |label| {
            if (p.lookupFactLabel(label)) |id| {
                if (containsId(allowed, id)) dups[j] = id else invalid += 1;
            } else invalid += 1;
        }
        var list: std.ArrayList(Verdict.Contradiction) = .empty;
        for (fv.contradicts) |c| {
            const id = p.lookupFactLabel(c.fact) orelse {
                invalid += 1;
                continue;
            };
            if (!containsId(allowed, id)) {
                invalid += 1;
                continue;
            }
            const at = if (c.at) |s| (time.parseBound(s) catch null) else null;
            try list.append(arena, .{ .fact = id, .kind = c.kind, .at = at });
        }
        cons[j] = list.items;
    }
    return .{ .verdict = v, .warnings = warnings.items, .invalid = invalid, .total = total };
}

pub const Question = struct {
    kind: enum { same_entity, duplicate, contradicts, was_wrong },
    item: usize,
    target: Id,
};

pub fn decisionQuestions(arena: Allocator, p: Plan, checked: extract.Checked, prefetch: Prefetch) Allocator.Error!struct { questions: []const Question, prompts: []const []const u8 } {
    var qs: std.ArrayList(Question) = .empty;
    var prompts: std.ArrayList([]const u8) = .empty;
    for (p.entities, 0..) |ep, i| {
        if (ep.decision != .ask) continue;
        const e = checked.result.entities[i];
        for (ep.gray) |g| {
            const c = findEntity(prefetch, g) orelse continue;
            try qs.append(arena, .{ .kind = .same_entity, .item = i, .target = g });
            try prompts.append(arena, try std.fmt.allocPrint(arena, "\"{s}\" ({t}: {s}) and the existing \"{s}\" ({t}) are the same real-world entity.", .{ e.name, e.type, e.description, c.name, c.type }));
        }
    }
    for (p.facts, 0..) |fp, j| {
        const f = checked.result.facts[j];
        for (fp.candidates) |cid| {
            const c = findFact(prefetch, cid) orelse continue;
            try qs.append(arena, .{ .kind = .duplicate, .item = j, .target = cid });
            try prompts.append(arena, try std.fmt.allocPrint(arena, "The new statement \"{s}\" restates the existing fact \"{s}\".", .{ f.text, c.text }));
            try qs.append(arena, .{ .kind = .contradicts, .item = j, .target = cid });
            try prompts.append(arena, try std.fmt.allocPrint(arena, "The new statement \"{s}\" means the existing fact \"{s}\" no longer holds or never held.", .{ f.text, c.text }));
            try qs.append(arena, .{ .kind = .was_wrong, .item = j, .target = cid });
            try prompts.append(arena, try std.fmt.allocPrint(arena, "The new statement \"{s}\" says the existing fact \"{s}\" was never true (a correction), rather than that it changed.", .{ f.text, c.text }));
        }
    }
    return .{ .questions = qs.items, .prompts = prompts.items };
}

pub fn verdictFromProbabilities(arena: Allocator, p: Plan, questions: []const Question, probs: []const f64, th: Thresholds) Allocator.Error!Verdict {
    const links = try arena.alloc(?Id, p.entities.len);
    @memset(links, null);
    const dups = try arena.alloc(?Id, p.facts.len);
    @memset(dups, null);
    const cons = try arena.alloc([]const Verdict.Contradiction, p.facts.len);
    @memset(cons, &.{});
    const v: Verdict = .{ .links = links, .duplicates = dups, .contradictions = cons };
    const link_best = try arena.alloc(f64, p.entities.len);
    @memset(link_best, th.duplicate);
    const dup_best = try arena.alloc(f64, p.facts.len);
    @memset(dup_best, th.duplicate);
    var lists = try arena.alloc(std.ArrayList(Verdict.Contradiction), p.facts.len);
    for (lists) |*l| l.* = .empty;

    for (questions, 0..) |q, k| {
        if (k >= probs.len) break;
        const pr = probs[k];
        switch (q.kind) {
            .same_entity => if (pr >= link_best[q.item]) {
                link_best[q.item] = pr;
                links[q.item] = q.target;
            },
            .duplicate => if (pr >= dup_best[q.item]) {
                dup_best[q.item] = pr;
                dups[q.item] = q.target;
            },
            .contradicts => if (pr >= th.contradiction) {
                const wrong = k + 1 < probs.len and k + 1 < questions.len and questions[k + 1].kind == .was_wrong and probs[k + 1] >= 0.5;
                try lists[q.item].append(arena, .{ .fact = q.target, .kind = if (wrong) .was_wrong else .changed, .at = null });
            },
            .was_wrong => {},
        }
    }
    for (lists, 0..) |l, j| {
        if (dups[j]) |d| {
            var filtered: std.ArrayList(Verdict.Contradiction) = .empty;
            for (l.items) |c| if (!c.fact.eql(d)) try filtered.append(arena, c);
            cons[j] = filtered.items;
        } else cons[j] = l.items;
    }
    return v;
}

fn findEntity(prefetch: Prefetch, id: Id) ?CandidateEntity {
    for (prefetch.entities) |c| if (c.id.eql(id)) return c;
    return null;
}

pub fn findFact(prefetch: Prefetch, id: Id) ?CandidateFact {
    for (prefetch.facts) |c| if (c.id.eql(id)) return c;
    return null;
}

pub const Context = struct {
    episode: EpisodeInfo,
    commit_time: Micros,
    io: std.Io,
};

const PredicateChoice = struct { name: []const u8, rule: rules.PredicateRule };

fn choosePredicate(
    arena: Allocator,
    name: []const u8,
    checked: extract.Checked,
    prefetch: Prefetch,
    novel: []const []const u8,
    vectors: Vectors,
    proposed: *std.ArrayList(core.Predicate),
    warnings: *std.ArrayList([]const u8),
) Allocator.Error!PredicateChoice {
    if (core.ontology.find(name) != null) return .{ .name = name, .rule = rules.ruleFor(name, null) };
    if (prefetch.predicate(name)) |row| {
        if (row.mapped_to) |target| {
            const t_row = prefetch.predicate(target);
            return .{ .name = target, .rule = rules.ruleFor(target, if (t_row) |tr| .{ .cardinality = tr.cardinality, .opposes = tr.opposes } else null) };
        }
        return .{ .name = name, .rule = rules.ruleFor(name, .{ .cardinality = row.cardinality, .opposes = row.opposes }) };
    }
    for (proposed.items) |p| if (std.mem.eql(u8, p.name, name)) return .{ .name = p.mapped_to orelse name, .rule = .{} };

    const k = for (novel, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) break i;
    } else null;
    var mapped: ?[]const u8 = null;
    if (k) |idx| if (idx < vectors.predicates.len) {
        var known: std.ArrayList(rules.KnownPredicate) = .empty;
        for (prefetch.predicates) |row| {
            if (row.emb.len == 0 or row.mapped_to != null or row.status == .retired) continue;
            try known.append(arena, .{ .name = row.name, .emb = row.emb });
        }
        mapped = rules.collapsePredicate(vectors.predicates[idx], known.items);
    };
    const description = predicateDescription(checked, name);
    const object_kind: core.types.ObjectKind = for (checked.result.new_predicates) |p| {
        if (std.mem.eql(u8, p.name, name)) break p.object_kind;
    } else .either;
    try proposed.append(arena, .{
        .name = name,
        .description = description,
        .cardinality = .many,
        .object_kind = object_kind,
        .status = .proposed,
        .mapped_to = mapped,
    });
    if (mapped) |m| {
        try warnings.append(arena, try std.fmt.allocPrint(arena, "predicate {s} collapsed onto {s}", .{ name, m }));
        const row = prefetch.predicate(m);
        return .{ .name = m, .rule = rules.ruleFor(m, if (row) |r| .{ .cardinality = r.cardinality, .opposes = r.opposes } else null) };
    }
    return .{ .name = name, .rule = .{} };
}

const OldState = struct { fact: core.Fact, ended: bool };

fn oldFact(c: CandidateFact, graph_id: Id) core.Fact {
    return .{
        .id = c.id,
        .graph_id = graph_id,
        .subject_id = c.subject_id,
        .predicate = c.predicate,
        .qualifier = c.qualifier,
        .object = if (c.object_id) |o| .{ .entity = o } else .{ .value = c.object_value orelse "" },
        .text = c.text,
        .scope = .project,
        .valid = .{ .lower = c.valid_lower, .upper = c.valid_upper },
        .sys = .{},
        .asserted_by = .agent,
        .confidence = c.confidence,
    };
}

pub fn build(
    arena: Allocator,
    ctx: Context,
    checked: extract.Checked,
    prefetch: Prefetch,
    p: Plan,
    vectors: Vectors,
    verdict: Verdict,
) Allocator.Error!ChangeSet {
    var warnings: std.ArrayList([]const u8) = .empty;
    try warnings.appendSlice(arena, checked.warnings);

    const ents = checked.result.entities;
    const final = try arena.alloc(Id, ents.len);
    var new_entities: std.ArrayList(ChangeSet.NewEntity) = .empty;
    var new_aliases: std.ArrayList(ChangeSet.Alias) = .empty;
    var merges: std.ArrayList(ChangeSet.Merge) = .empty;
    var mentions: std.ArrayList(Id) = .empty;

    for (ents, 0..) |e, i| {
        const ep = p.entities[i];
        const existing: ?Id = switch (ep.decision) {
            .existing => |id| id,
            .ask => verdict.links[i],
            .new => null,
        };
        if (existing) |id| {
            final[i] = id;
            const known_norm = if (findEntity(prefetch, id)) |c| c.norm else "";
            var names: std.ArrayList([]const u8) = .empty;
            try names.append(arena, e.name);
            try names.appendSlice(arena, e.aliases);
            for (names.items) |n| {
                const nn = try core.text.norm(arena, n);
                if (nn.len == 0 or std.mem.eql(u8, nn, known_norm)) continue;
                var dup = false;
                for (new_aliases.items) |a| if (a.entity_id.eql(id) and std.mem.eql(u8, a.norm, nn)) {
                    dup = true;
                };
                if (!dup) try new_aliases.append(arena, .{ .entity_id = id, .alias = n, .norm = nn });
            }
            for (ep.absorb) |from| {
                var seen = false;
                for (merges.items) |m| if (m.from.eql(from)) {
                    seen = true;
                };
                if (!seen and !from.eql(id)) try merges.append(arena, .{ .from = from, .into = id, .reason = "exact alias match" });
            }
        } else {
            const id = Id.v7(ctx.io);
            final[i] = id;
            try new_entities.append(arena, .{
                .id = id,
                .name = e.name,
                .norm = try core.text.norm(arena, e.name),
                .type = e.type,
                .description = e.description,
                .aliases = e.aliases,
                .name_emb = if (i < vectors.entities.len) vectors.entities[i] else &.{},
            });
        }
        try appendUnique(arena, &mentions, final[i]);
    }

    const novel = try novelPredicates(arena, checked, prefetch);
    var proposed: std.ArrayList(core.Predicate) = .empty;

    var olds: std.ArrayList(OldState) = .empty;
    for (prefetch.facts) |c| {
        var seen = false;
        for (olds.items) |o| if (o.fact.id.eql(c.id)) {
            seen = true;
        };
        if (!seen) try olds.append(arena, .{ .fact = oldFact(c, ctx.episode.graph_id), .ended = false });
    }

    var new_facts: std.ArrayList(ChangeSet.NewFact) = .empty;
    var new_keys: std.ArrayList(rules.Key) = .empty;
    var reaffirmations: std.ArrayList(ChangeSet.Reaffirmation) = .empty;
    var invalidations: std.ArrayList(ChangeSet.Invalidation) = .empty;
    var retractions: std.ArrayList(ChangeSet.Retraction) = .empty;
    var provenance: std.ArrayList(ChangeSet.Provenance) = .empty;
    var blast: rules.BlastRadius = .{};

    for (checked.result.facts, checked.meta, 0..) |f, m, j| {
        const pred = try choosePredicate(arena, f.predicate, checked, prefetch, novel, vectors, &proposed, &warnings);
        const subject = final[entityIndex(checked, f.subject)];
        const object: core.types.FactObject = if (f.object) |o| .{ .entity = final[entityIndex(checked, o)] } else .{ .value = f.value.? };
        var valid = m.valid;
        if (f.time_basis == .reference) {
            for (verdict.contradictions[j]) |c| if (c.at) |at| {
                valid.lower = at;
                break;
            };
        }
        const key: rules.Key = .{
            .subject = subject,
            .predicate = pred.name,
            .qualifier = f.qualifier orelse "",
            .object = switch (object) {
                .entity => |id| .{ .entity = id },
                .value => |v| .{ .value = try core.text.norm(arena, v) },
            },
            .valid = valid,
        };

        var restated: ?usize = null;
        for (olds.items, 0..) |o, k| {
            if (o.ended) continue;
            const c = findFact(prefetch, o.fact.id).?;
            if (rules.sameCanonicalKey(key, try candidateKey(arena, c))) {
                restated = k;
                break;
            }
        }
        if (restated == null) if (verdict.duplicates[j]) |dup| {
            for (olds.items, 0..) |o, k| if (o.fact.id.eql(dup) and !o.ended) {
                restated = k;
            };
        };
        if (restated) |k| {
            const target = &olds.items[k].fact;
            var already = false;
            for (reaffirmations.items) |r| if (r.fact_id.eql(target.id)) {
                already = true;
            };
            if (!already) {
                try reaffirmations.append(arena, .{ .fact_id = target.id, .confidence = rules.reaffirm(target.confidence) });
                try provenance.append(arena, .{ .fact_id = target.id, .role = .reaffirmed, .quote = f.quote });
            }
            continue;
        }

        var dup_new = false;
        for (new_keys.items) |nk| if (rules.sameCanonicalKey(key, nk)) {
            dup_new = true;
        };
        if (dup_new) {
            try warnings.append(arena, try std.fmt.allocPrint(arena, "fact {d} repeats another fact in this episode", .{j}));
            continue;
        }

        var nf: core.Fact = .{
            .id = Id.v7(ctx.io),
            .graph_id = ctx.episode.graph_id,
            .subject_id = subject,
            .predicate = pred.name,
            .qualifier = f.qualifier orelse "",
            .object = object,
            .text = f.text,
            .rationale = f.rationale,
            .project = ctx.episode.project,
            .scope = f.scope,
            .valid = valid,
            .sys = .{ .lower = ctx.commit_time },
            .asserted_by = f.asserted_by,
            .confidence = rules.initialConfidence(f.asserted_by),
        };

        for (olds.items) |*o| {
            if (o.ended) continue;
            const c = findFact(prefetch, o.fact.id).?;
            const ck = try candidateKey(arena, c);
            var kind: ?ingest.ConflictKind = null;
            if (rules.conflict(key, pred.rule, ck) != null) kind = .changed;
            for (verdict.contradictions[j]) |vc| if (vc.fact.eql(o.fact.id)) {
                kind = vc.kind;
            };
            const k = kind orelse continue;
            var trial = o.fact;
            var trial_new = nf;
            switch (rules.resolveConflict(&trial, &trial_new, k, ctx.commit_time, ctx.episode.reference_time)) {
                .none => {},
                .bounded_new => nf = trial_new,
                .ended_old => if (blast.admit()) {
                    o.fact = trial;
                    o.ended = true;
                    try invalidations.append(arena, .{ .fact_id = trial.id, .valid_upper = trial.valid.upper.?, .ended_by = nf.id });
                    try provenance.append(arena, .{ .fact_id = trial.id, .role = .contradicted, .quote = f.quote });
                } else {
                    try warnings.append(arena, try std.fmt.allocPrint(arena, "skipped ending fact {f}: more than {d} endings in one episode", .{ trial.id, rules.max_invalidations }));
                },
                .retracted_old => if (blast.admit()) {
                    o.fact = trial;
                    o.ended = true;
                    try retractions.append(arena, .{ .fact_id = trial.id, .end_kind = .retracted, .ended_by = nf.id });
                    try provenance.append(arena, .{ .fact_id = trial.id, .role = .retracted, .quote = f.quote });
                } else {
                    try warnings.append(arena, try std.fmt.allocPrint(arena, "skipped retracting fact {f}: more than {d} endings in one episode", .{ trial.id, rules.max_invalidations }));
                },
            }
        }

        try new_keys.append(arena, key);
        try new_facts.append(arena, .{ .fact = nf, .emb = if (j < vectors.facts.len) vectors.facts[j] else &.{} });
        try provenance.append(arena, .{ .fact_id = nf.id, .role = .asserted, .quote = f.quote });
    }

    var preds_out: std.ArrayList(core.Predicate) = .empty;
    for (proposed.items) |pr| try preds_out.append(arena, pr);

    return .{
        .base_seq = prefetch.base_seq,
        .new_entities = new_entities.items,
        .merges = merges.items,
        .new_facts = new_facts.items,
        .reaffirmations = reaffirmations.items,
        .invalidations = invalidations.items,
        .retractions = retractions.items,
        .provenance = provenance.items,
        .mentions = mentions.items,
        .new_aliases = new_aliases.items,
        .new_predicates = preds_out.items,
        .warnings = warnings.items,
    };
}
