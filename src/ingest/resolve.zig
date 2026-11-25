const std = @import("std");
const core = @import("core");
const ingest = @import("mod.zig");
const rules = @import("rules.zig");
const extract = @import("extract.zig");
const time = @import("time.zig");
const llm = @import("llm");

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
    via: []const []const u8 = &.{},
    cosine: f32 = 0,
    lexical: f32 = 0,
    description: []const u8 = "",
    aliases: []const []const u8 = &.{},
    facts: []const []const u8 = &.{},
    shares_project: bool = false,

    fn exactHit(c: CandidateEntity, mention_norm: []const u8) bool {
        for (c.via) |v| {
            if (rules.exactAlias(c.type, v, c.norm)) return true;
            if (std.mem.eql(u8, v, mention_norm) and std.mem.eql(u8, v, c.norm)) return true;
        }
        return false;
    }

    fn sharesSpecific(a: CandidateEntity, b: CandidateEntity) bool {
        for (a.via) |v| if (rules.exactAlias(a.type, v, a.norm) and rules.exactAlias(b.type, v, b.norm) and hasNorm(b.via, v)) return true;
        return false;
    }
};

fn hasNorm(list: []const []const u8, n: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

pub const CandidateFact = struct {
    item: u32,
    id: Id,
    subject_id: Id,
    relation: []const u8,
    qualifier: []const u8 = "",
    object_id: ?Id = null,
    object_value: ?[]const u8 = null,
    text: []const u8,
    valid_lower: ?Micros = null,
    valid_upper: ?Micros = null,
    confidence: f32,
    cosine: f32 = 0,

    pub fn key(c: CandidateFact, arena: Allocator) Allocator.Error!rules.Key {
        return .{
            .subject = c.subject_id,
            .relation = c.relation,
            .qualifier = c.qualifier,
            .object = if (c.object_id) |o| .{ .entity = o } else .{ .value = try core.text.norm(arena, c.object_value orelse "") },
            .valid = .{ .lower = c.valid_lower, .upper = c.valid_upper },
        };
    }

    pub fn toFact(c: CandidateFact, graph_id: Id) core.Fact {
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
};

pub const RelationRow = struct {
    name: []const u8,
    cardinality: core.types.Cardinality = .many,
    opposes: ?[]const u8 = null,
    status: core.types.RelationStatus = .proposed,
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
    relations: []const RelationRow = &.{},

    fn isBlocked(p: Prefetch, a: Id, b: Id) bool {
        for (p.blocked) |pair| {
            if ((pair.a.eql(a) and pair.b.eql(b)) or (pair.a.eql(b) and pair.b.eql(a))) return true;
        }
        return false;
    }

    fn relation(p: Prefetch, name: []const u8) ?RelationRow {
        for (p.relations) |row| if (std.mem.eql(u8, row.name, name)) return row;
        return null;
    }

    fn rule(p: Prefetch, name: []const u8) rules.RelationRule {
        return rules.ruleFor(name, if (p.relation(name)) |row| .{ .cardinality = row.cardinality, .opposes = row.opposes } else null);
    }
};

pub const EntryInfo = struct {
    graph_id: Id,
    reference_time: Micros,
    project: ?[]const u8 = null,
};

pub const Vectors = struct {
    entities: []const []const f32,
    facts: []const []const f32,
    relations: []const []const f32 = &.{},
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

pub fn novelRelations(arena: Allocator, checked: extract.Checked, prefetch: Prefetch) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (checked.result.facts) |f| {
        if (core.ontology.find(f.relation) != null) continue;
        if (prefetch.relation(f.relation) != null) continue;
        var seen = false;
        for (out.items) |n| if (std.mem.eql(u8, n, f.relation)) {
            seen = true;
        };
        if (!seen) try out.append(arena, f.relation);
    }

    return out.items;
}

pub fn relationDescription(checked: extract.Checked, name: []const u8) []const u8 {
    for (checked.result.new_relations) |p| if (std.mem.eql(u8, p.name, name)) return p.description;
    return name;
}

pub fn entityIndex(checked: extract.Checked, ref: []const u8) usize {
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
            var via: std.ArrayList([]const u8) = .empty;
            try via.appendSlice(arena, prev.via);
            for (c.via) |v| if (!hasNorm(via.items, v)) try via.append(arena, v);
            prev.via = via.items;
            prev.cosine = @max(prev.cosine, c.cosine);
            prev.lexical = @max(prev.lexical, c.lexical);
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
    for (cands) |c| if (c.exactHit(e_norm) and rules.compatible(e.type, c.type)) {
        winner = c;
        break;
    };
    if (winner) |w| {
        var absorb: std.ArrayList(Id) = .empty;
        for (cands) |c| {
            if (c.id.eql(w.id) or !rules.mergeCompatible(w.type, c.type) or prefetch.isBlocked(w.id, c.id)) continue;
            if (!w.sharesSpecific(c) or c.cosine < rules.gray_cosine) continue;
            try appendUnique(arena, &absorb, c.id);
        }
        return .{ .decision = .{ .existing = w.id }, .absorb = absorb.items };
    }

    for (cands) |c| {
        if (c.type != e.type or c.cosine < rules.merge_cosine) continue;
        if (rules.tokenJaccard(e_norm, c.norm) < rules.merge_jaccard or rules.distinctMarkers(e_norm, c.norm)) continue;
        return .{ .decision = .{ .existing = c.id } };
    }

    var gray: std.ArrayList(Id) = .empty;
    for (cands) |c| {
        if (gray.items.len >= rules.gray_per_entity) break;
        if (rules.hardBlocked(e.type, c.type) or rules.distinctMarkers(e_norm, c.norm)) continue;
        const near = if (rules.compatible(e.type, c.type)) c.cosine >= rules.gray_cosine else c.cosine >= rules.gray_cross_type_cosine;
        const context = rules.contextualGray(e.type, c.type, e_norm, c.norm, .{ .cosine = c.cosine, .lexical = c.lexical, .shares_project = c.shares_project });
        if (near or context) try appendUnique(arena, &gray, c.id);
    }

    if (gray.items.len > 0) return .{ .decision = .ask, .gray = gray.items };
    return .{ .decision = .new };
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

        const opposed = rules.ruleFor(f.relation, null).opposes;
        var restated = false;
        var pool: std.ArrayList(CandidateFact) = .empty;
        outer: for (prefetch.facts) |c| {
            if (c.item != j) continue;
            for (pool.items) |p| if (p.id.eql(c.id)) continue :outer;
            const same_relation = std.mem.eql(u8, c.relation, f.relation);
            const same_object_entity = if (object_known) |ok| (if (c.object_id) |co| co.eql(ok) else false) else false;
            if (subj.decision == .existing and c.subject_id.eql(subj.decision.existing) and
                same_relation and std.mem.eql(u8, c.qualifier, f.qualifier orelse ""))
            {
                const same_object = if (f.object != null)
                    same_object_entity
                else if (c.object_value) |cv| std.mem.eql(u8, try core.text.norm(arena, cv), value_norm.?) else false;
                if (same_object) {
                    restated = true;
                    continue;
                }
            }

            const kin = same_relation or (if (opposed) |o| std.mem.eql(u8, c.relation, o) else false);
            const related = (kin and (containsId(subjects.items, c.subject_id) or same_object_entity)) or
                c.cosine >= rules.neighbour_cosine;
            if (related) try pool.append(arena, c);
        }

        if (restated) pool.clearRetainingCapacity();
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
    links: []?Id,
    duplicates: []?Id,
    contradictions: [][]const Contradiction,

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
    const v = try Verdict.none(arena, p);
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
        v.links[i] = id;
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
                if (containsId(allowed, id)) v.duplicates[j] = id else invalid += 1;
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
        v.contradictions[j] = list.items;
    }

    return .{ .verdict = v, .warnings = warnings.items, .invalid = invalid, .total = total };
}

pub const Question = struct {
    kind: enum { entity_link, fact_relation },
    item: usize,
    targets: []const Id,
};

pub const Decisions = struct {
    questions: []const Question,
    asks: []const llm.Question,
};

pub const relation_options = [_]llm.decision.Option{
    .{ .name = "same", .description = "the new statement says the same thing as the existing fact" },
    .{ .name = "changed", .description = "the existing fact was true until now or until a stated time and has since stopped holding: a handoff, rotation, switch, upgrade, removal, or new release" },
    .{ .name = "corrected", .description = "the entry says the existing fact was a mistake that was never true, for example 'that's wrong', 'I misspoke', or 'we never used it'; a switch or a change of plan is not a correction" },
    .{ .name = "compatible", .description = "both can be true at once: the new statement adds detail or is about something else" },
};

const entity_none: llm.decision.Option = .{ .name = "none", .description = "none of the above: a different real-world entity" };

pub const entity_link_rule = "Same name is not enough: a company and its product, a tool and a dataset, or numbered siblings such as Phase 1 and Phase 2 are different entities. A project and its repository are the same entity. A first name, nickname or handle names the same person as a full name when their projects, teammates or work overlap; two people who only share a first name and do unrelated work are different people.";

pub fn writeCandidateContext(w: *std.Io.Writer, c: CandidateEntity) std.Io.Writer.Error!void {
    if (c.description.len > 0) try w.print(": {s}", .{c.description});
    if (c.aliases.len > 0) {
        try w.writeAll("; also called ");
        for (c.aliases, 0..) |a, i| try w.print("{s}\"{s}\"", .{ if (i > 0) ", " else "", a });
    }

    if (c.facts.len > 0) {
        try w.writeAll("; known facts:");
        for (c.facts) |f| try w.print(" {s}", .{f});
    }

    if (c.shares_project) try w.writeAll("; active in this entry's project");
}

fn candidateDescription(arena: Allocator, c: CandidateEntity) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.print("the existing \"{s}\" ({t})", .{ c.name, c.type }) catch return error.OutOfMemory;
    writeCandidateContext(&out.writer, c) catch return error.OutOfMemory;
    return out.written();
}

pub fn decisionQuestions(arena: Allocator, p: Plan, checked: extract.Checked, prefetch: Prefetch) Allocator.Error!Decisions {
    var qs: std.ArrayList(Question) = .empty;
    var asks: std.ArrayList(llm.Question) = .empty;
    for (p.entities, 0..) |entry, i| {
        if (entry.decision != .ask) continue;
        const e = checked.result.entities[i];

        var targets: std.ArrayList(Id) = .empty;
        var options: std.ArrayList(llm.decision.Option) = .empty;
        for (entry.gray) |g| {
            const c = findEntity(prefetch, g) orelse continue;
            try targets.append(arena, g);
            try options.append(arena, .{
                .name = try std.fmt.allocPrint(arena, "E{d}", .{targets.items.len}),
                .description = try candidateDescription(arena, c),
            });
        }

        if (targets.items.len == 0) continue;
        try options.append(arena, entity_none);
        try qs.append(arena, .{ .kind = .entity_link, .item = i, .targets = targets.items });
        try asks.append(arena, .{ .choice = .{
            .prompt = try std.fmt.allocPrint(arena, "Which existing entity is the new entity \"{s}\" ({t}: {s})? {s}", .{ e.name, e.type, e.description, entity_link_rule }),
            .options = options.items,
        } });
    }

    for (p.facts, 0..) |fp, j| {
        const f = checked.result.facts[j];
        for (fp.candidates) |cid| {
            const c = findFact(prefetch, cid) orelse continue;
            try qs.append(arena, .{ .kind = .fact_relation, .item = j, .targets = try arena.dupe(Id, &.{cid}) });
            try asks.append(arena, .{ .choice = .{
                .prompt = try std.fmt.allocPrint(arena, "How does the new statement \"{s}\" relate to the existing fact \"{s}\"?", .{ f.text, c.text }),
                .options = &relation_options,
            } });
        }
    }

    return .{ .questions = qs.items, .asks = asks.items };
}

pub fn verdictFromAnswers(arena: Allocator, p: Plan, questions: []const Question, answers: []const llm.Answer, th: Thresholds) Allocator.Error!Verdict {
    const v = try Verdict.none(arena, p);
    const dup_best = try arena.alloc(f64, p.facts.len);
    @memset(dup_best, th.duplicate);
    const lists = try arena.alloc(std.ArrayList(Verdict.Contradiction), p.facts.len);
    for (lists) |*l| l.* = .empty;

    for (questions, answers) |q, a| {
        const probs = switch (a) {
            .choice => |c| c,
            .yes_no => continue,
        };

        switch (q.kind) {
            .entity_link => {
                if (probs.len != q.targets.len + 1) continue;
                const best = std.mem.indexOfMax(f64, probs[0..q.targets.len]);
                if (probs[best] >= th.duplicate) v.links[q.item] = q.targets[best];
            },
            .fact_relation => {
                if (probs.len != relation_options.len) continue;
                const same, const changed, const corrected = .{ probs[0], probs[1], probs[2] };
                if (same >= dup_best[q.item]) {
                    dup_best[q.item] = same;
                    v.duplicates[q.item] = q.targets[0];
                }
                if (changed + corrected >= th.contradiction)
                    try lists[q.item].append(arena, .{ .fact = q.targets[0], .kind = if (corrected > changed) .was_wrong else .changed, .at = null });
            },
        }
    }

    for (lists, 0..) |l, j| {
        if (v.duplicates[j]) |d| {
            var filtered: std.ArrayList(Verdict.Contradiction) = .empty;
            for (l.items) |c| if (!c.fact.eql(d)) try filtered.append(arena, c);
            v.contradictions[j] = filtered.items;
        } else v.contradictions[j] = l.items;
    }

    return v;
}

pub fn findEntity(prefetch: Prefetch, id: Id) ?CandidateEntity {
    for (prefetch.entities) |c| if (c.id.eql(id)) return c;
    return null;
}

pub fn findFact(prefetch: Prefetch, id: Id) ?CandidateFact {
    for (prefetch.facts) |c| if (c.id.eql(id)) return c;
    return null;
}

pub const Context = struct {
    entry: EntryInfo,
    commit_time: Micros,
    io: std.Io,
};

const RelationChoice = struct { name: []const u8, rule: rules.RelationRule };

fn chooseRelation(
    arena: Allocator,
    name: []const u8,
    checked: extract.Checked,
    prefetch: Prefetch,
    novel: []const []const u8,
    vectors: Vectors,
    proposed: *std.ArrayList(core.Relation),
    warnings: *std.ArrayList([]const u8),
) Allocator.Error!RelationChoice {
    if (core.ontology.find(name) != null) return .{ .name = name, .rule = prefetch.rule(name) };
    if (prefetch.relation(name)) |row| {
        const chosen = row.mapped_to orelse name;
        return .{ .name = chosen, .rule = prefetch.rule(chosen) };
    }
    for (proposed.items) |p| if (std.mem.eql(u8, p.name, name)) return .{ .name = p.mapped_to orelse name, .rule = .{} };

    const k = for (novel, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) break i;
    } else null;
    var mapped: ?[]const u8 = null;
    if (k) |idx| if (idx < vectors.relations.len) {
        var known: std.ArrayList(rules.KnownRelation) = .empty;
        for (prefetch.relations) |row| {
            if (row.emb.len == 0 or row.mapped_to != null or row.status == .retired) continue;
            try known.append(arena, .{ .name = row.name, .emb = row.emb });
        }
        mapped = rules.collapseRelation(vectors.relations[idx], known.items);
    };

    const description = relationDescription(checked, name);
    const object_kind: core.types.ObjectKind = for (checked.result.new_relations) |p| {
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
        try warnings.append(arena, try std.fmt.allocPrint(arena, "relation {s} collapsed onto {s}", .{ name, m }));
        return .{ .name = m, .rule = prefetch.rule(m) };
    }
    return .{ .name = name, .rule = .{} };
}

fn heldElsewhere(prefetch: Prefetch, item: usize, id: Id, absorbed: []const Id, norm: []const u8) bool {
    for (prefetch.entities) |c| {
        if (c.item != item or c.id.eql(id) or containsId(absorbed, c.id)) continue;
        if (hasNorm(c.via, norm)) return true;
    }
    return false;
}

const OldState = struct { fact: core.Fact, key: rules.Key, ended: bool };

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
        const entry = p.entities[i];
        const existing: ?Id = switch (entry.decision) {
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
                if (nn.len == 0 or std.mem.eql(u8, nn, known_norm) or !rules.specificAlias(nn)) continue;
                if (heldElsewhere(prefetch, i, id, entry.absorb, nn)) continue;
                var dup = false;
                for (new_aliases.items) |a| if (a.entity_id.eql(id) and std.mem.eql(u8, a.norm, nn)) {
                    dup = true;
                };
                if (!dup) try new_aliases.append(arena, .{ .entity_id = id, .alias = n, .norm = nn });
            }

            for (entry.absorb) |from| {
                var seen = false;
                for (merges.items) |m| if (m.from.eql(from)) {
                    seen = true;
                };
                if (!seen and !from.eql(id)) try merges.append(arena, .{ .from = from, .into = id, .reason = "exact alias match" });
            }
        } else {
            var aliases: std.ArrayList([]const u8) = .empty;
            for (e.aliases) |a| if (rules.specificAlias(try core.text.norm(arena, a))) try aliases.append(arena, a);

            const id = Id.v7(ctx.io);
            final[i] = id;
            try new_entities.append(arena, .{
                .id = id,
                .name = e.name,
                .norm = try core.text.norm(arena, e.name),
                .type = e.type,
                .description = e.description,
                .aliases = aliases.items,
                .name_emb = if (i < vectors.entities.len) vectors.entities[i] else &.{},
            });
        }

        try appendUnique(arena, &mentions, final[i]);
    }

    const novel = try novelRelations(arena, checked, prefetch);
    var proposed: std.ArrayList(core.Relation) = .empty;

    var olds: std.ArrayList(OldState) = .empty;
    for (prefetch.facts) |c| {
        var seen = false;
        for (olds.items) |o| if (o.fact.id.eql(c.id)) {
            seen = true;
        };
        if (!seen) try olds.append(arena, .{ .fact = c.toFact(ctx.entry.graph_id), .key = try c.key(arena), .ended = false });
    }

    var new_facts: std.ArrayList(ChangeSet.NewFact) = .empty;
    var new_keys: std.ArrayList(rules.Key) = .empty;
    var restatements: std.ArrayList(ChangeSet.Restatement) = .empty;
    var invalidations: std.ArrayList(ChangeSet.Invalidation) = .empty;
    var retractions: std.ArrayList(ChangeSet.Retraction) = .empty;
    var evidence: std.ArrayList(ChangeSet.Evidence) = .empty;
    var blast: rules.BlastRadius = .{};

    for (checked.result.facts, checked.meta, 0..) |f, m, j| {
        const relation = try chooseRelation(arena, f.relation, checked, prefetch, novel, vectors, &proposed, &warnings);
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
            .relation = relation.name,
            .qualifier = f.qualifier orelse "",
            .object = switch (object) {
                .entity => |id| .{ .entity = id },
                .value => |v| .{ .value = try core.text.norm(arena, v) },
            },
            .valid = valid,
        };

        var restated: ?usize = null;
        for (olds.items, 0..) |o, k| {
            if (o.ended and o.fact.end_kind != .changed) continue;
            if (rules.sameFact(key, o.key)) {
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
            for (restatements.items) |r| if (r.fact_id.eql(target.id)) {
                already = true;
            };
            if (!already) {
                try restatements.append(arena, .{ .fact_id = target.id, .confidence = rules.restate(target.confidence) });
                try evidence.append(arena, .{ .fact_id = target.id, .kind = .restated, .quote = f.quote });
            }

            const old = &olds.items[k];
            if (valid.upper) |end| if (!old.ended and old.fact.valid.upper == null) {
                if (blast.admit()) {
                    old.fact.valid.upper = end;
                    old.fact.end_kind = .changed;
                    old.key.valid = old.fact.valid;
                    old.ended = true;
                    try invalidations.append(arena, .{ .fact_id = old.fact.id, .valid_upper = end, .ended_by = null });
                } else try warnings.append(arena, try std.fmt.allocPrint(arena, "skipped ending fact {f}: more than {d} endings in one entry", .{ old.fact.id, rules.max_invalidations }));
            };
            continue;
        }

        var dup_new = false;
        for (new_keys.items) |nk| if (rules.sameFact(key, nk)) {
            dup_new = true;
        };
        if (dup_new) {
            try warnings.append(arena, try std.fmt.allocPrint(arena, "fact {d} repeats another fact in this entry", .{j}));
            continue;
        }

        var nf: core.Fact = .{
            .id = Id.v7(ctx.io),
            .graph_id = ctx.entry.graph_id,
            .subject_id = subject,
            .relation = relation.name,
            .qualifier = f.qualifier orelse "",
            .object = object,
            .text = f.text,
            .rationale = f.rationale,
            .project = ctx.entry.project,
            .scope = f.scope,
            .valid = valid,
            .known = .{ .lower = ctx.commit_time },
            .author = f.author,
            .confidence = rules.initialConfidence(f.author),
        };

        for (olds.items) |*o| {
            if (o.ended) continue;
            var kind: ?ingest.ConflictKind = null;
            if (rules.conflict(key, relation.rule, o.key) != null) kind = .changed;
            for (verdict.contradictions[j]) |vc| if (vc.fact.eql(o.fact.id)) {
                kind = vc.kind;
            };
            const k = kind orelse continue;

            var trial = o.fact;
            var trial_new = nf;
            switch (rules.resolveConflict(&trial, &trial_new, k, ctx.commit_time, ctx.entry.reference_time)) {
                .none => {},
                .bounded_new => nf = trial_new,
                .ended_old => if (blast.admit()) {
                    o.fact = trial;
                    o.key.valid = trial.valid;
                    o.ended = true;
                    try invalidations.append(arena, .{ .fact_id = trial.id, .valid_upper = trial.valid.upper.?, .ended_by = nf.id });
                    try evidence.append(arena, .{ .fact_id = trial.id, .kind = .contradicted, .quote = f.quote });
                } else {
                    try warnings.append(arena, try std.fmt.allocPrint(arena, "skipped ending fact {f}: more than {d} endings in one entry", .{ trial.id, rules.max_invalidations }));
                },
                .retracted_old => if (blast.admit()) {
                    o.fact = trial;
                    o.ended = true;
                    try retractions.append(arena, .{ .fact_id = trial.id, .end_kind = .retracted, .ended_by = nf.id });
                    try evidence.append(arena, .{ .fact_id = trial.id, .kind = .retracted, .quote = f.quote });
                } else {
                    try warnings.append(arena, try std.fmt.allocPrint(arena, "skipped retracting fact {f}: more than {d} endings in one entry", .{ trial.id, rules.max_invalidations }));
                },
            }
        }

        try new_keys.append(arena, key);
        try new_facts.append(arena, .{ .fact = nf, .emb = if (j < vectors.facts.len) vectors.facts[j] else &.{} });
        try evidence.append(arena, .{ .fact_id = nf.id, .kind = .stated, .quote = f.quote });
    }

    return .{
        .base_seq = prefetch.base_seq,
        .new_entities = new_entities.items,
        .merges = merges.items,
        .new_facts = new_facts.items,
        .restatements = restatements.items,
        .invalidations = invalidations.items,
        .retractions = retractions.items,
        .evidence = evidence.items,
        .mentions = mentions.items,
        .new_aliases = new_aliases.items,
        .new_relations = proposed.items,
        .warnings = warnings.items,
    };
}
