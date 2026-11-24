const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");
const ingest = @import("mod.zig");
const extract = @import("extract.zig");
const resolve = @import("resolve.zig");
const prompt = @import("prompt.zig");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Id = core.Id;
const Micros = core.Micros;

pub const max_attempts = 3;

pub const Disposition = llm.Disposition;

pub const ModelFailure = struct {
    disposition: Disposition,
    retry_after_ms: ?u32 = null,
};

pub const Completion = struct {
    json: []const u8,
    repaired: bool = false,
};

pub const Context = struct {
    prior: []const prompt.PriorEntry = &.{},
    relations: []const resolve.RelationRow = &.{},
};

pub const PrefetchRequest = struct {
    entity_norms: []const []const []const u8,
    entity_embs: []const []const f32,
    fact_subject: []const u32,
    fact_object: []const ?u32,
    fact_relations: []const []const u8,
    fact_opposed: []const ?[]const u8,
    fact_embs: []const []const f32,
    fact_texts: []const []const u8,
};

pub const Transition = union(enum) {
    skipped: []const u8,
    requeue: struct { delay_ms: i64, count_attempt: bool, reason: []const u8 },
    dead: []const u8,
    split: [2]core.EntryBody,
};

pub fn Driver(comptime Backend: type, comptime Model: type) type {
    return struct {
        const Self = @This();

        backend: *Backend,
        model: *Model,
        config: *const core.Config,
        graph_id: Id,
        io: std.Io,

        pub fn process(d: *Self, arena: Allocator, lease: store.Lease) !ingest.Outcome {
            const entry = lease.entry;
            const body_text = try extract.bodyText(arena, entry.body);
            const ctx = try d.backend.loadContext(arena, lease);

            const checked = if (lease.extraction_json) |saved|
                try extract.check(arena, try extract.decode(arena, saved), body_text, entry.reference_time)
            else blk: {
                const got = try d.extractCall(arena, lease, ctx, body_text);
                switch (got) {
                    .checked => |c| {
                        const json = try std.json.Stringify.valueAlloc(arena, c.result, .{});
                        try d.backend.saveExtraction(lease, json);
                        break :blk c;
                    },
                    .outcome => |o| return o,
                }
            };

            if (checked.isEmpty()) {
                try d.backend.finish(lease, .{ .skipped = checked.result.skip orelse "no durable facts" });
                return .skipped;
            }

            var relations = try arena.dupe(resolve.RelationRow, ctx.relations);
            const novel = try resolve.novelRelations(arena, checked, .{ .relations = relations });
            var missing: std.ArrayList(usize) = .empty;
            if (novel.len > 0) for (relations, 0..) |row, k| {
                if (row.emb.len == 0 and row.mapped_to == null and row.status != .retired) try missing.append(arena, k);
            };

            const ents = checked.result.entities;
            const facts = checked.result.facts;
            var inputs: std.ArrayList([]const u8) = .empty;
            for (ents) |e| try inputs.append(arena, e.name);
            for (facts) |f| try inputs.append(arena, f.text);
            for (novel) |n| try inputs.append(arena, resolve.relationDescription(checked, n));
            for (missing.items) |k| try inputs.append(arena, relations[k].description);

            const embedded = d.model.embed(arena, .{ .purpose = .embed_batch, .entry_id = entry.id, .inputs = inputs.items }) catch |err| {
                return d.providerFailure(arena, lease, err, .after_extraction);
            };
            if (embedded.vectors.len != inputs.items.len) return error.EmbeddingCountMismatch;
            const vecs = embedded.vectors;
            const ent_vecs = vecs[0..ents.len];
            const fact_vecs = vecs[ents.len..][0..facts.len];
            const novel_vecs = vecs[ents.len + facts.len ..][0..novel.len];
            const missing_vecs = vecs[ents.len + facts.len + novel.len ..];
            if (missing.items.len > 0) {
                var names: std.ArrayList([]const u8) = .empty;
                for (missing.items, missing_vecs) |k, v| {
                    relations[k].emb = v;
                    try names.append(arena, relations[k].name);
                }
                try d.backend.saveRelationEmbeddings(names.items, missing_vecs);
            }

            var prefetched = try d.backend.prefetch(arena, try prefetchRequest(arena, checked, ent_vecs, fact_vecs));
            prefetched.relations = relations;

            const p = try resolve.plan(arena, checked, prefetched);
            var verdict = try resolve.Verdict.none(arena, p);
            var extra_warnings: std.ArrayList([]const u8) = .empty;
            if (p.needsResolution()) {
                switch (try d.resolutionCall(arena, lease, body_text, checked, prefetched, p, &extra_warnings)) {
                    .verdict => |v| verdict = v,
                    .outcome => |o| return o,
                }
            }

            var cs = try resolve.build(arena, .{
                .entry = .{ .graph_id = d.graph_id, .reference_time = entry.reference_time, .project = entry.project },
                .commit_time = core.time.now(d.io),
                .io = d.io,
            }, checked, prefetched, p, .{ .entities = ent_vecs, .facts = fact_vecs, .relations = novel_vecs }, verdict);
            if (extra_warnings.items.len > 0) {
                var all: std.ArrayList([]const u8) = .empty;
                try all.appendSlice(arena, cs.warnings);
                try all.appendSlice(arena, extra_warnings.items);
                cs.warnings = all.items;
            }

            try d.backend.saveChangeSet(lease, &cs);
            return switch (try d.backend.commit(arena, lease, &cs)) {
                .fenced => .fenced,
                .committed => blk: {
                    try d.backend.afterCommit(arena, &cs);
                    break :blk .committed;
                },
            };
        }

        const ExtractOutcome = union(enum) { checked: extract.Checked, outcome: ingest.Outcome };

        fn extractCall(d: *Self, arena: Allocator, lease: store.Lease, ctx: Context, body_text: []const u8) !ExtractOutcome {
            const entry = lease.entry;
            const req: llm.StructuredRequest = .{
                .purpose = .extract,
                .entry_id = entry.id,
                .system = try prompt.extractionSystem(arena, ctx.relations),
                .user = try prompt.extractionUser(arena, .{
                    .reference_time = entry.reference_time,
                    .project = entry.project,
                    .kind = entry.kind,
                    .author = entry.author,
                    .body = entry.body,
                }, ctx.prior),
                .schema_name = "extract_result",
                .schema_json = schema.extract_result,
            };
            const resp = d.model.structured(arena, req) catch |err| return .{ .outcome = try d.providerFailure(arena, lease, err, .extraction) };

            const first = try decodeChecked(arena, resp.json, body_text, entry.reference_time);
            if (first.checked) |c| if (!c.needs_repair) return .{ .checked = c };

            if (!resp.repaired) {
                const problem = first.problem orelse "more than half of the facts failed validation";
                const repaired = d.model.repair(arena, req, resp.json, problem) catch |err| return .{ .outcome = try d.providerFailure(arena, lease, err, .extraction) };
                const second = try decodeChecked(arena, repaired.json, body_text, entry.reference_time);
                if (second.checked) |c| if (!c.needs_repair) return .{ .checked = c };
            }
            try d.backend.finish(lease, .{ .dead = "extraction output failed validation after one repair" });
            return .{ .outcome = .dead };
        }

        const Decoded = struct { checked: ?extract.Checked, problem: ?[]const u8 };

        fn decodeChecked(arena: Allocator, json: []const u8, body_text: []const u8, reference_time: Micros) !Decoded {
            const raw = extract.decode(arena, json) catch |err| {
                return .{ .checked = null, .problem = try std.fmt.allocPrint(arena, "the output did not decode: {t}", .{err}) };
            };
            return .{ .checked = try extract.check(arena, raw, body_text, reference_time), .problem = null };
        }

        const ResolutionOutcome = union(enum) { verdict: resolve.Verdict, outcome: ingest.Outcome };

        fn resolutionCall(
            d: *Self,
            arena: Allocator,
            lease: store.Lease,
            body_text: []const u8,
            checked: extract.Checked,
            prefetched: resolve.Prefetch,
            p: resolve.Plan,
            warnings: *std.ArrayList([]const u8),
        ) !ResolutionOutcome {
            if (d.model.decisionEnabled()) decision: {
                const q = try resolve.decisionQuestions(arena, p, checked, prefetched);
                if (q.asks.len == 0) break :decision;
                const answers = d.model.decide(arena, .{
                    .purpose = .resolve,
                    .entry_id = lease.entry.id,
                    .state = &.{.{ .name = "entry", .text = body_text }},
                    .questions = q.asks,
                }) catch {
                    try warnings.append(arena, "decision backend failed; used the structured resolution call");
                    break :decision;
                };
                if (answers.len != q.questions.len) {
                    try warnings.append(arena, "decision backend answered the wrong number of questions; used the structured resolution call");
                    break :decision;
                }
                return .{ .verdict = try resolve.verdictFromAnswers(arena, p, q.questions, answers, .{
                    .duplicate = d.config.decision.dup_threshold,
                    .contradiction = d.config.decision.contradict_threshold,
                }) };
            }

            const req: llm.StructuredRequest = .{
                .purpose = .resolve,
                .entry_id = lease.entry.id,
                .system = prompt.resolution_system,
                .user = try prompt.resolutionUser(arena, p, checked, prefetched, lease.entry.reference_time),
                .schema_name = "resolve_result",
                .schema_json = schema.resolve_result,
            };
            const resp = d.model.structured(arena, req) catch |err| {
                if (try d.resolutionFallback(arena, lease, err)) |o| return .{ .outcome = o };
                try warnings.append(arena, "resolution call failed; resolved deterministically");
                return .{ .verdict = try resolve.Verdict.none(arena, p) };
            };
            if (try interpretResolution(arena, p, checked, resp.json, warnings)) |v| return .{ .verdict = v };

            if (resp.repaired) {
                try warnings.append(arena, "resolution output invalid after one repair; resolved deterministically");
                return .{ .verdict = try resolve.Verdict.none(arena, p) };
            }
            const repaired = d.model.repair(arena, req, resp.json, "the output did not match the resolution schema or named unknown labels") catch |err| {
                if (try d.resolutionFallback(arena, lease, err)) |o| return .{ .outcome = o };
                try warnings.append(arena, "resolution repair failed; resolved deterministically");
                return .{ .verdict = try resolve.Verdict.none(arena, p) };
            };
            if (try interpretResolution(arena, p, checked, repaired.json, warnings)) |v| return .{ .verdict = v };
            try warnings.append(arena, "resolution output invalid after one repair; resolved deterministically");
            return .{ .verdict = try resolve.Verdict.none(arena, p) };
        }

        fn interpretResolution(arena: Allocator, p: resolve.Plan, checked: extract.Checked, json: []const u8, warnings: *std.ArrayList([]const u8)) !?resolve.Verdict {
            const r = std.json.parseFromSliceLeaky(ingest.ResolveResult, arena, json, .{
                .duplicate_field_behavior = .@"error",
                .allocate = .alloc_always,
            }) catch return null;
            const got = try resolve.interpret(arena, p, checked, r);
            if (got.total > 0 and got.invalid * 2 > got.total) return null;
            try warnings.appendSlice(arena, got.warnings);
            return got.verdict;
        }

        fn failureOf(d: *Self, err: anyerror) ?ModelFailure {
            return switch (err) {
                error.ProviderFailed => d.model.failure(),
                error.RouteHalted, error.SpendCapReached, error.ModelNotConfigured => .{ .disposition = .pause_route },
                else => null,
            };
        }

        fn resolutionFallback(d: *Self, arena: Allocator, lease: store.Lease, err: anyerror) !?ingest.Outcome {
            const f = d.failureOf(err) orelse return err;
            return switch (f.disposition) {
                .split, .dead => null,
                .requeue, .pause_route => try d.providerFailure(arena, lease, err, .after_extraction),
            };
        }

        const Stage = enum { extraction, after_extraction };

        fn providerFailure(d: *Self, arena: Allocator, lease: store.Lease, err: anyerror, stage: Stage) !ingest.Outcome {
            if (err == error.ModelNotConfigured) {
                try d.backend.finish(lease, .{ .requeue = .{ .delay_ms = 0, .count_attempt = false, .reason = "no model is configured" } });
                return err;
            }
            const f = d.failureOf(err) orelse return err;
            switch (f.disposition) {
                .split => {
                    if (stage == .extraction) if (try splitBody(arena, lease.entry.body)) |halves| {
                        try d.backend.finish(lease, .{ .split = halves });
                        return .split;
                    };
                    try d.backend.finish(lease, .{ .dead = "context overflow on an entry too small to split" });
                    return .dead;
                },
                .dead => {
                    try d.backend.finish(lease, .{ .dead = "the provider rejected the request" });
                    return .dead;
                },
                .pause_route => {
                    try d.backend.finish(lease, .{ .requeue = .{ .delay_ms = 60_000, .count_attempt = false, .reason = "model route paused" } });
                    return .requeued;
                },
                .requeue => {
                    if (lease.entry.attempts + 1 >= max_attempts) {
                        try d.backend.finish(lease, .{ .dead = "transient provider failures exhausted the retry budget" });
                        return .dead;
                    }
                    const delay: i64 = if (f.retry_after_ms) |ra| ra else @as(i64, 30_000) << @intCast(@max(lease.entry.attempts, 0));
                    try d.backend.finish(lease, .{ .requeue = .{ .delay_ms = delay, .count_attempt = true, .reason = "transient provider failure" } });
                    return .requeued;
                },
            }
        }
    };
}

fn prefetchRequest(arena: Allocator, checked: extract.Checked, ent_vecs: []const []const f32, fact_vecs: []const []const f32) !PrefetchRequest {
    const ents = checked.result.entities;
    const norms = try arena.alloc([]const []const u8, ents.len);
    for (ents, 0..) |e, i| {
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(arena, try core.text.norm(arena, e.name));
        for (e.aliases) |a| {
            const n = try core.text.norm(arena, a);
            if (n.len > 0) try list.append(arena, n);
        }
        norms[i] = list.items;
    }
    const facts = checked.result.facts;
    const subj = try arena.alloc(u32, facts.len);
    const obj = try arena.alloc(?u32, facts.len);
    const rels = try arena.alloc([]const u8, facts.len);
    const opp = try arena.alloc(?[]const u8, facts.len);
    const texts = try arena.alloc([]const u8, facts.len);
    for (facts, 0..) |f, j| {
        subj[j] = @intCast(resolve.entityIndex(checked, f.subject));
        obj[j] = if (f.object) |o| @intCast(resolve.entityIndex(checked, o)) else null;
        rels[j] = f.relation;
        opp[j] = if (core.ontology.find(f.relation)) |rel| rel.opposes else null;
        texts[j] = f.text;
    }
    return .{
        .entity_norms = norms,
        .entity_embs = ent_vecs,
        .fact_subject = subj,
        .fact_object = obj,
        .fact_relations = rels,
        .fact_opposed = opp,
        .fact_embs = fact_vecs,
        .fact_texts = texts,
    };
}

pub fn splitBody(arena: Allocator, body: core.EntryBody) Allocator.Error!?[2]core.EntryBody {
    if (body.turns.len >= 2) {
        const mid = body.turns.len / 2;
        return .{ .{ .turns = body.turns[0..mid], .text = body.text }, .{ .turns = body.turns[mid..] } };
    }
    const text = if (body.text) |t| t else if (body.turns.len == 1) body.turns[0].text else return null;
    if (text.len < 64) return null;
    var mid = text.len / 2;
    while (mid < text.len and text[mid] != ' ' and text[mid] != '\n') mid += 1;
    if (mid == text.len) mid = text.len / 2;
    while (mid > 0 and (text[mid] & 0xC0) == 0x80) mid -= 1;
    if (body.turns.len == 0) return .{ .{ .text = text[0..mid] }, .{ .text = text[mid..] } };
    const halves = try arena.alloc(core.Turn, 2);
    halves[0] = body.turns[0];
    halves[0].text = text[0..mid];
    halves[0].tool_calls = &.{};
    halves[1] = body.turns[0];
    halves[1].text = text[mid..];
    return .{ .{ .turns = halves[0..1] }, .{ .turns = halves[1..2] } };
}
