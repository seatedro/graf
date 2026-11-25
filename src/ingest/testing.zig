const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");
const pipeline = @import("pipeline.zig");
const resolve = @import("resolve.zig");
const prompt = @import("prompt.zig");
const rules = @import("rules.zig");

const Allocator = std.mem.Allocator;
const Id = core.Id;
const Micros = core.Micros;

pub fn at(s: []const u8) Micros {
    return core.time.parseRfc3339(s) catch unreachable;
}

pub fn turns(comptime text: []const u8) []const core.Turn {
    return &.{.{ .role = .user, .text = text }};
}

pub const relay_hollis =
    \\{"skip":null,"entities":[{"ref":"n1","name":"Relay","type":"software","aliases":[],"description":"Request gateway."},{"ref":"n2","name":"Hollis","type":"person","aliases":[],"description":"Engineer."}],
    \\"facts":[{"subject":"n1","relation":"has_oncall","qualifier":null,"object":"n2","value":null,"text":"Hollis is on call for Relay.","rationale":null,"valid_from":null,"valid_to":null,"time_basis":"reference","scope":"project","author":"agent","quote":"Hollis is currently on call for Relay."},
    \\{"subject":"n1","relation":"located_at","qualifier":null,"object":null,"value":"infra/relay","text":"Relay lives under infra/relay.","rationale":null,"valid_from":null,"valid_to":null,"time_basis":"reference","scope":"project","author":"agent","quote":"Relay lives under infra/relay"}],"new_relations":[]}
;

pub const FakeModel = struct {
    pub const Reply = union(enum) {
        json: []const u8,
        fail: pipeline.Disposition,
        raise: anyerror,
    };

    pub const dims = 64;

    replies: std.ArrayList(Reply) = .empty,
    next: usize = 0,
    calls: std.EnumArray(core.types.LlmPurpose, u32) = .initFill(0),
    requests: std.ArrayList(llm.StructuredRequest) = .empty,
    embed_fail: ?pipeline.Disposition = null,
    decision_enabled: bool = false,
    decision_answers: ?[]const llm.Answer = null,
    decisions: std.ArrayList(llm.DecisionRequest) = .empty,
    last: ?pipeline.ModelFailure = null,
    gpa: Allocator,
    kept: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator) FakeModel {
        return .{ .gpa = gpa, .kept = .init(gpa) };
    }

    pub fn deinit(m: *FakeModel) void {
        m.replies.deinit(m.gpa);
        m.requests.deinit(m.gpa);
        m.decisions.deinit(m.gpa);
        m.kept.deinit();
    }

    pub fn push(m: *FakeModel, reply: Reply) !void {
        try m.replies.append(m.gpa, reply);
    }

    pub fn repair(m: *FakeModel, arena: Allocator, req: llm.StructuredRequest, broken: []const u8, problem: []const u8) !pipeline.Completion {
        var r = req;
        r.purpose = .repair;
        r.user = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ problem, broken });
        const out = try m.structured(arena, r);
        return .{ .json = out.json, .repaired = true };
    }

    pub fn structured(m: *FakeModel, arena: Allocator, req: llm.StructuredRequest) !pipeline.Completion {
        _ = arena;
        m.calls.getPtr(req.purpose).* += 1;
        var copy = req;
        copy.system = try m.kept.allocator().dupe(u8, req.system);
        copy.user = try m.kept.allocator().dupe(u8, req.user);
        try m.requests.append(m.gpa, copy);

        if (m.next >= m.replies.items.len) return error.NoScriptedReply;
        const reply = m.replies.items[m.next];
        m.next += 1;

        switch (reply) {
            .json => |j| {
                m.last = null;
                return .{ .json = j };
            },
            .fail => |disposition| {
                m.last = .{ .disposition = disposition };
                return error.ProviderFailed;
            },
            .raise => |err| {
                m.last = null;
                return err;
            },
        }
    }

    pub fn embed(m: *FakeModel, arena: Allocator, req: llm.EmbedRequest) !llm.EmbedResponse {
        m.calls.getPtr(req.purpose).* += 1;
        if (m.embed_fail) |disposition| {
            m.last = .{ .disposition = disposition };
            return error.ProviderFailed;
        }

        const out = try arena.alloc([]const f32, req.inputs.len);
        for (req.inputs, 0..) |input, i| out[i] = try vector(arena, input);
        return .{ .vectors = out, .usage = .{}, .cost = .{} };
    }

    pub fn decide(m: *FakeModel, arena: Allocator, req: llm.DecisionRequest) ![]const llm.Answer {
        _ = arena;
        if (!m.decision_enabled) return error.DecisionDisabled;
        const kept = m.kept.allocator();

        var copy = req;
        const state = try kept.alloc(llm.decision.Field, req.state.len);
        for (req.state, state) |f, *out| out.* = .{ .name = try kept.dupe(u8, f.name), .text = try kept.dupe(u8, f.text) };
        copy.state = state;

        const questions = try kept.alloc(llm.Question, req.questions.len);
        for (req.questions, questions) |q, *out| out.* = switch (q) {
            .yes_no => |p| .{ .yes_no = try kept.dupe(u8, p) },
            .choice => |c| .{ .choice = .{ .prompt = try kept.dupe(u8, c.prompt), .options = &.{} } },
        };
        copy.questions = questions;

        try m.decisions.append(m.gpa, copy);
        return m.decision_answers orelse error.ProviderFailed;
    }

    pub fn decisionEnabled(m: *FakeModel) bool {
        return m.decision_enabled;
    }

    pub fn failure(m: *FakeModel) ?pipeline.ModelFailure {
        return m.last;
    }

    pub fn count(m: *const FakeModel, purpose: core.types.LlmPurpose) u32 {
        return m.calls.get(purpose);
    }

    pub fn vector(arena: Allocator, text: []const u8) ![]const f32 {
        const v = try arena.alloc(f32, dims);
        @memset(v, 0);

        const n = try core.text.norm(arena, text);
        var it = std.mem.tokenizeScalar(u8, n, ' ');
        while (it.next()) |tok| {
            const h = std.hash.Wyhash.hash(0, tok);
            v[h % dims] += if ((h >> 32) & 1 == 0) 1 else -1;
        }
        return v;
    }
};

pub const MemoryBackend = struct {
    pub const EntryRow = struct {
        entry: core.Entry,
        source: []const u8,
        status: core.types.EntryStatus = .queued,
        attempts: i32 = 0,
        token: i64 = 0,
        extraction_json: ?[]const u8 = null,
        change_set: ?core.ChangeSet = null,
        last_error: ?[]const u8 = null,
    };

    pub const EntityRow = struct {
        id: Id,
        name: []const u8,
        norm: []const u8,
        type: core.EntityType,
        aliases: std.ArrayList([]const u8) = .empty,
        emb: []const f32,
        merged_into: ?Id = null,
    };

    pub const FactRow = struct { fact: core.Fact, emb: []const f32 };
    pub const EvidenceRow = struct { fact_id: Id, entry_id: Id, kind: core.types.EvidenceKind };

    arena_state: std.heap.ArenaAllocator,
    io: std.Io,
    entries: std.ArrayList(EntryRow) = .empty,
    entities: std.ArrayList(EntityRow) = .empty,
    facts: std.ArrayList(FactRow) = .empty,
    evidence: std.ArrayList(EvidenceRow) = .empty,
    relations: std.ArrayList(resolve.RelationRow) = .empty,
    seq: i64 = 0,
    next_token: i64 = 0,
    crash_after_extraction: bool = false,

    pub fn init(gpa: Allocator, io: std.Io) !MemoryBackend {
        var b: MemoryBackend = .{ .arena_state = .init(gpa), .io = io };
        const a = b.arena_state.allocator();
        for (core.ontology.core_relations) |rel| try b.relations.append(a, .{
            .name = rel.name,
            .cardinality = rel.cardinality,
            .opposes = rel.opposes,
            .status = .core,
            .description = rel.description,
        });
        return b;
    }

    pub fn deinit(b: *MemoryBackend) void {
        b.arena_state.deinit();
    }

    fn arena(b: *MemoryBackend) Allocator {
        return b.arena_state.allocator();
    }

    pub fn add(b: *MemoryBackend, source: []const u8, reference_time: Micros, project: ?[]const u8, entry_turns: []const core.Turn) !Id {
        const a = b.arena();
        const id = Id.v7(b.io);
        var seq: i32 = 0;
        for (b.entries.items) |e| if (std.mem.eql(u8, e.source, source)) {
            seq += 1;
        };

        try b.entries.append(a, .{
            .entry = .{
                .id = id,
                .graph_id = graph,
                .seq_in_source = seq,
                .kind = .turns,
                .project = if (project) |p| try a.dupe(u8, p) else null,
                .author = .user,
                .body = .{ .turns = try copy([]const core.Turn, a, entry_turns) },
                .content_hash = @splat(0),
                .reference_time = reference_time,
            },
            .source = try a.dupe(u8, source),
        });

        return id;
    }

    pub const graph = Id.fromParts(1, @splat(1));

    fn copy(comptime T: type, a: Allocator, v: T) !T {
        const json = try std.json.Stringify.valueAlloc(a, v, .{});
        return std.json.parseFromSliceLeaky(T, a, json, .{ .allocate = .alloc_always });
    }

    pub fn row(b: *MemoryBackend, id: Id) *EntryRow {
        for (b.entries.items) |*e| if (e.entry.id.eql(id)) return e;
        unreachable;
    }

    fn blocked(b: *MemoryBackend, e: EntryRow) bool {
        for (b.entries.items) |o| {
            if (!std.mem.eql(u8, o.source, e.source) or o.entry.seq_in_source >= e.entry.seq_in_source) continue;
            switch (o.status) {
                .queued, .extracting, .extracted, .staged, .committing => return true,
                else => {},
            }
        }
        return false;
    }

    pub fn claim(b: *MemoryBackend) ?store.Lease {
        for (b.entries.items) |*e| {
            if (e.status != .queued and e.status != .extracted and e.status != .staged) continue;
            if (b.blocked(e.*)) continue;

            b.next_token += 1;
            e.token = b.next_token;
            var entry = e.entry;
            entry.attempts = e.attempts;
            entry.status = e.status;
            e.status = if (e.extraction_json != null) .extracted else .extracting;
            return .{ .entry_id = entry.id, .graph_id = graph, .token = e.token, .entry = entry, .extraction_json = e.extraction_json };
        }
        return null;
    }

    pub fn expireLease(b: *MemoryBackend, id: Id) void {
        const e = b.row(id);
        e.status = if (e.extraction_json != null) .extracted else .queued;
        e.token = 0;
    }

    fn fenced(b: *MemoryBackend, lease: store.Lease) !*EntryRow {
        const e = b.row(lease.entry_id);
        if (e.token != lease.token) return error.LeaseLost;
        return e;
    }

    pub fn loadContext(b: *MemoryBackend, a: Allocator, lease: store.Lease) !pipeline.Context {
        const me = b.row(lease.entry_id);
        var prior: std.ArrayList(prompt.PriorEntry) = .empty;
        for (b.entries.items) |e| {
            if (e.status != .committed or !std.mem.eql(u8, e.source, me.source)) continue;
            var texts: std.ArrayList([]const u8) = .empty;
            if (e.change_set) |cs| for (cs.new_facts) |nf| try texts.append(a, nf.fact.text);
            try prior.append(a, .{ .reference_time = e.entry.reference_time, .facts = texts.items });
        }

        const start = prior.items.len -| 3;
        return .{ .prior = prior.items[start..], .relations = try a.dupe(resolve.RelationRow, b.relations.items) };
    }

    pub fn saveExtraction(b: *MemoryBackend, lease: store.Lease, json: []const u8) !void {
        const e = try b.fenced(lease);
        e.extraction_json = try b.arena().dupe(u8, json);
        e.status = .extracted;
    }

    pub fn saveRelationEmbeddings(b: *MemoryBackend, names: []const []const u8, embs: []const []const f32) !void {
        for (names, embs) |n, v| for (b.relations.items) |*rel| if (std.mem.eql(u8, rel.name, n)) {
            rel.emb = try b.arena().dupe(f32, v);
        };
    }

    fn canonical(b: *MemoryBackend, id: Id) Id {
        var cur = id;
        while (true) {
            const e = b.entity(cur) orelse return cur;
            cur = e.merged_into orelse return cur;
        }
    }

    pub fn entity(b: *MemoryBackend, id: Id) ?*EntityRow {
        for (b.entities.items) |*e| if (e.id.eql(id)) return e;
        return null;
    }

    pub fn prefetch(b: *MemoryBackend, a: Allocator, req: pipeline.PrefetchRequest) !resolve.Prefetch {
        if (b.crash_after_extraction) return error.SimulatedCrash;

        var ents: std.ArrayList(resolve.CandidateEntity) = .empty;
        for (req.entity_norms, req.entity_embs, 0..) |norms, emb, i| {
            for (b.entities.items) |e| {
                if (e.merged_into != null) continue;
                var via: std.ArrayList([]const u8) = .empty;
                for (norms) |n| {
                    var hit = std.mem.eql(u8, n, e.norm);
                    for (e.aliases.items) |al| hit = hit or std.mem.eql(u8, n, al);
                    if (hit) try via.append(a, n);
                }

                const cos = rules.cosine(emb, e.emb);
                if (via.items.len == 0 and cos < 0.5) continue;
                try ents.append(a, .{ .item = @intCast(i), .id = e.id, .name = e.name, .norm = e.norm, .type = e.type, .via = via.items, .cosine = cos });
            }
        }

        var facts: std.ArrayList(resolve.CandidateFact) = .empty;
        for (req.fact_subject, req.fact_object, req.fact_embs, 0..) |si, oi, emb, j| {
            for (b.facts.items) |f| {
                if (f.fact.known.upper != null or f.fact.valid.upper != null) continue;
                var related = rules.cosine(emb, f.emb) >= rules.neighbour_cosine;
                for (ents.items) |c| {
                    if (c.item == si and c.id.eql(f.fact.subject_id)) related = true;
                    if (oi) |o| if (c.item == o) switch (f.fact.object) {
                        .entity => |fo| if (fo.eql(c.id)) {
                            related = true;
                        },
                        .value => {},
                    };
                }

                if (!related) continue;
                try facts.append(a, .{
                    .item = @intCast(j),
                    .id = f.fact.id,
                    .subject_id = f.fact.subject_id,
                    .relation = f.fact.relation,
                    .qualifier = f.fact.qualifier,
                    .object_id = switch (f.fact.object) {
                        .entity => |x| x,
                        .value => null,
                    },
                    .object_value = switch (f.fact.object) {
                        .entity => null,
                        .value => |v| v,
                    },
                    .text = f.fact.text,
                    .valid_lower = f.fact.valid.lower,
                    .valid_upper = f.fact.valid.upper,
                    .confidence = f.fact.confidence,
                    .cosine = rules.cosine(emb, f.emb),
                });
            }
        }
        return .{ .base_seq = b.seq, .entities = ents.items, .facts = facts.items };
    }

    pub fn saveChangeSet(b: *MemoryBackend, lease: store.Lease, cs: *const core.ChangeSet) !void {
        const e = try b.fenced(lease);
        e.change_set = try copy(core.ChangeSet, b.arena(), cs.*);
        e.status = .staged;
    }

    pub fn commit(b: *MemoryBackend, a: Allocator, lease: store.Lease, cs_in: *const core.ChangeSet) !store.CommitResult {
        _ = a;
        const e = b.fenced(lease) catch return .fenced;
        if (e.status != .staged) return .fenced;

        const al = b.arena();
        const cs = try copy(core.ChangeSet, al, cs_in.*);
        const t = core.time.now(b.io);

        for (cs.new_entities) |ne| {
            var aliases: std.ArrayList([]const u8) = .empty;
            for (ne.aliases) |x| try aliases.append(al, try core.text.norm(al, x));
            try b.entities.append(al, .{ .id = ne.id, .name = ne.name, .norm = ne.norm, .type = ne.type, .aliases = aliases, .emb = ne.name_emb });
        }

        for (cs.new_aliases) |x| if (b.entity(x.entity_id)) |ent| try ent.aliases.append(al, x.norm);
        for (cs.merges) |m| {
            if (b.entity(m.from)) |ent| ent.merged_into = m.into;
            for (b.facts.items) |*f| {
                if (f.fact.subject_id.eql(m.from)) f.fact.subject_id = m.into;
                switch (f.fact.object) {
                    .entity => |o| if (o.eql(m.from)) {
                        f.fact.object = .{ .entity = m.into };
                    },
                    .value => {},
                }
            }
        }

        for (cs.new_facts) |nf| {
            var f = nf.fact;
            f.known.lower = t;
            f.subject_id = b.canonical(f.subject_id);
            try b.facts.append(al, .{ .fact = f, .emb = nf.emb });
        }

        for (cs.restatements) |r| if (b.fact(r.fact_id)) |f| {
            f.fact.confidence = r.confidence;
        };
        for (cs.invalidations) |inv| if (b.fact(inv.fact_id)) |f| {
            f.fact.valid.upper = inv.valid_upper;
            f.fact.end_kind = .changed;
            f.fact.ended_by = inv.ended_by;
        };
        for (cs.retractions) |r| if (b.fact(r.fact_id)) |f| {
            f.fact.known.upper = t;
            f.fact.end_kind = r.end_kind;
            f.fact.ended_by = r.ended_by;
        };

        for (cs.evidence) |ev| try b.evidence.append(al, .{ .fact_id = ev.fact_id, .entry_id = lease.entry_id, .kind = ev.kind });
        for (cs.new_relations) |rel| {
            var seen = false;
            for (b.relations.items) |known| if (std.mem.eql(u8, known.name, rel.name)) {
                seen = true;
            };
            if (!seen) try b.relations.append(al, .{ .name = rel.name, .status = rel.status, .mapped_to = rel.mapped_to, .description = rel.description });
        }

        b.seq += 1;
        e.status = .committed;
        e.change_set = cs;
        return .{ .committed = .{ .seq = b.seq } };
    }

    pub fn fact(b: *MemoryBackend, id: Id) ?*FactRow {
        for (b.facts.items) |*f| if (f.fact.id.eql(id)) return f;
        return null;
    }

    pub fn afterCommit(b: *MemoryBackend, a: Allocator, cs: *const core.ChangeSet) !void {
        _ = b;
        _ = a;
        _ = cs;
    }

    pub fn finish(b: *MemoryBackend, lease: store.Lease, t: pipeline.Transition) !void {
        const e = try b.fenced(lease);
        const al = b.arena();
        switch (t) {
            .skipped => e.status = .skipped,
            .dead => |why| {
                e.status = .dead;
                e.last_error = try al.dupe(u8, why);
            },
            .requeue => |r| {
                e.status = if (e.extraction_json != null) .extracted else .queued;
                if (r.count_attempt) e.attempts += 1;
            },
            .split => |halves| {
                e.status = .split;
                e.token = 0;
                const parent = e.*;
                for (halves) |h| {
                    var child = parent;
                    child.entry.id = Id.v7(b.io);
                    child.entry.body = try copy(core.EntryBody, al, h);
                    child.status = .queued;
                    child.token = 0;
                    child.extraction_json = null;
                    try b.entries.append(al, child);
                }

                return;
            },
        }

        e.token = 0;
    }

    pub fn activeFacts(b: *MemoryBackend, a: Allocator) ![]const core.Fact {
        var out: std.ArrayList(core.Fact) = .empty;
        for (b.facts.items) |f| if (f.fact.known.upper == null and f.fact.valid.upper == null) try out.append(a, f.fact);
        return out.items;
    }
};
