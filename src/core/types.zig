const std = @import("std");

pub const Micros = i64;

pub const Range = struct {
    lower: ?Micros = null,
    upper: ?Micros = null,

    pub fn isOpen(r: Range) bool {
        return r.upper == null;
    }

    pub fn contains(r: Range, t: Micros) bool {
        if (r.lower) |lo| if (t < lo) return false;
        if (r.upper) |hi| if (t >= hi) return false;
        return true;
    }
};

pub const Id = struct {
    bytes: [16]u8,

    pub const nil: Id = .{ .bytes = @splat(0) };

    pub fn v7(io: std.Io) Id {
        var rand: [10]u8 = undefined;
        io.random(&rand);
        const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
        return fromParts(@intCast(@divFloor(ns, std.time.ns_per_ms)), rand);
    }

    pub fn fromParts(unix_ms: u48, rand: [10]u8) Id {
        var b: [16]u8 = undefined;
        std.mem.writeInt(u48, b[0..6], unix_ms, .big);
        @memcpy(b[6..], &rand);
        b[6] = 0x70 | (b[6] & 0x0f);
        b[8] = 0x80 | (b[8] & 0x3f);
        return .{ .bytes = b };
    }

    pub fn unixMs(id: Id) u48 {
        return std.mem.readInt(u48, id.bytes[0..6], .big);
    }

    pub fn toString(id: Id, buf: *[36]u8) []const u8 {
        const hex = "0123456789abcdef";
        var o: usize = 0;
        for (id.bytes, 0..) |byte, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[o] = '-';
                o += 1;
            }
            buf[o] = hex[byte >> 4];
            buf[o + 1] = hex[byte & 0x0f];
            o += 2;
        }
        return buf;
    }

    pub fn parse(s: []const u8) error{InvalidId}!Id {
        if (s.len != 36) return error.InvalidId;

        var id: Id = undefined;
        var o: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (s[i] != '-') return error.InvalidId;
                i += 1;
                continue;
            }
            id.bytes[o] = std.fmt.parseInt(u8, s[i .. i + 2], 16) catch return error.InvalidId;
            o += 1;
            i += 2;
        }

        return id;
    }

    pub fn format(id: Id, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [36]u8 = undefined;
        try w.writeAll(id.toString(&buf));
    }

    pub fn jsonStringify(id: Id, jw: anytype) !void {
        var buf: [36]u8 = undefined;
        try jw.write(id.toString(&buf));
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Id {
        const s = try std.json.innerParse([]const u8, allocator, source, options);
        return parse(s) catch error.UnexpectedToken;
    }

    pub fn eql(a: Id, b: Id) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

pub const Harness = enum { @"claude-code", codex, pi, fx, capy, api, cli, mcp };

pub const Role = enum { user, assistant, tool, system };

pub const ToolCall = struct {
    name: []const u8,
    args_preview: []const u8 = "",
    result_preview: []const u8 = "",
};

pub const Turn = struct {
    role: Role,
    text: []const u8,
    tool_calls: []const ToolCall = &.{},
    ts: ?Micros = null,
};

pub const SourceKey = struct {
    harness: Harness,
    external_id: []const u8,
    project: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const EntryKind = enum { turns, note, text, json };
pub const Author = enum { user, agent, mixed, tool };
pub const FactAuthor = enum { user, agent, tool };

pub const EntryStatus = enum { queued, extracting, extracted, staged, committing, committed, skipped, split, dead };

pub const EntryBody = struct {
    turns: []const Turn = &.{},
    text: ?[]const u8 = null,
};

pub const EntryDraft = struct {
    source: ?SourceKey = null,
    seq_in_source: i32 = 0,
    kind: EntryKind,
    project: ?[]const u8 = null,
    author: Author,
    body: EntryBody,
    reference_time: Micros,
    cursor: ?[]const u8 = null,
    backfill: bool = false,
};

pub const Entry = struct {
    id: Id,
    graph_id: Id,
    source_id: ?Id = null,
    seq_in_source: i32 = 0,
    kind: EntryKind,
    project: ?[]const u8 = null,
    author: Author,
    body: EntryBody,
    content_hash: [32]u8,
    reference_time: Micros,
    status: EntryStatus = .queued,
    attempts: i32 = 0,
    lease_token: ?i64 = null,
    base_seq: ?i64 = null,
    commit_seq: ?i64 = null,
    cost_usd: f64 = 0,
};

pub const EntityType = enum {
    person,
    organization,
    project,
    repository,
    code,
    software,
    ai_model,
    dataset,
    document,
    decision,
    task,
    change,
    session,
    environment,
    run,
    problem,
    concept,
    event,
    other,
};

pub const Entity = struct {
    id: Id,
    graph_id: Id,
    name: []const u8,
    norm: []const u8,
    type: EntityType,
    description: []const u8 = "",
    summary: []const u8 = "",
    merged_into: ?Id = null,
};

pub const Scope = enum { project, global };
pub const EndKind = enum { changed, retracted, forgotten };
pub const Cardinality = enum { many, one_per_subject, one_per_subject_qualifier, one_per_object };
pub const RelationStatus = enum { core, learned, proposed, retired };
pub const ObjectKind = enum { entity, value, either };
pub const EvidenceKind = enum { stated, restated, contradicted, retracted, forgotten };

pub const FactObject = union(enum) {
    entity: Id,
    value: []const u8,
};

pub const Fact = struct {
    id: Id,
    graph_id: Id,
    subject_id: Id,
    relation: []const u8,
    qualifier: []const u8 = "",
    object: FactObject,
    text: []const u8,
    rationale: ?[]const u8 = null,
    project: ?[]const u8 = null,
    scope: Scope,
    valid: Range,
    known: Range,
    end_kind: ?EndKind = null,
    ended_by: ?Id = null,
    author: FactAuthor,
    confidence: f32,
};

pub const Relation = struct {
    name: []const u8,
    description: []const u8,
    cardinality: Cardinality = .many,
    opposes: ?[]const u8 = null,
    object_kind: ObjectKind = .either,
    status: RelationStatus = .proposed,
    mapped_to: ?[]const u8 = null,
};

pub const ChangeSet = struct {
    base_seq: i64,
    new_entities: []const NewEntity = &.{},
    merges: []const Merge = &.{},
    new_facts: []const NewFact = &.{},
    restatements: []const Restatement = &.{},
    invalidations: []const Invalidation = &.{},
    retractions: []const Retraction = &.{},
    evidence: []const Evidence = &.{},
    mentions: []const Id = &.{},
    new_aliases: []const Alias = &.{},
    new_relations: []const Relation = &.{},
    warnings: []const []const u8 = &.{},

    pub const NewEntity = struct {
        id: Id,
        name: []const u8,
        norm: []const u8,
        type: EntityType,
        description: []const u8 = "",
        aliases: []const []const u8 = &.{},
        name_emb: []const f32 = &.{},
    };

    pub const Merge = struct { from: Id, into: Id, reason: []const u8 };

    pub const Alias = struct { entity_id: Id, alias: []const u8, norm: []const u8 };

    pub const NewFact = struct {
        fact: Fact,
        emb: []const f32,
    };

    pub const Restatement = struct { fact_id: Id, confidence: f32 };

    pub const Invalidation = struct { fact_id: Id, valid_upper: Micros, ended_by: ?Id };

    pub const Retraction = struct { fact_id: Id, end_kind: EndKind, ended_by: ?Id };

    pub const Evidence = struct { fact_id: Id, kind: EvidenceKind, quote: ?[]const u8 = null };
};

pub const LlmPurpose = enum { extract, resolve, repair, rerank, summarize, embed_entry, embed_batch, embed_query, judge };
pub const CostStatus = enum { priced, estimated, missing };

pub const LlmCall = struct {
    id: Id,
    graph_id: Id,
    entry_id: ?Id = null,
    purpose: LlmPurpose,
    route: []const u8,
    model: []const u8,
    attempt: i32,
    ok: bool,
    error_class: ?[]const u8 = null,
    http_status: ?i32 = null,
    input_tokens: i32 = 0,
    output_tokens: i32 = 0,
    cache_read_tokens: i32 = 0,
    cache_write_tokens: i32 = 0,
    cost_usd: f64 = 0,
    cost_status: CostStatus = .missing,
    latency_ms: i32,
    started_at: Micros,
};

pub const EntrySink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Outcome = union(enum) {
        queued: Id,
        duplicate,
    };

    pub const VTable = struct {
        enqueue: *const fn (ptr: *anyopaque, draft: *const EntryDraft) anyerror!Outcome,
        loadCursor: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, source: *const SourceKey) anyerror!?[]const u8,
    };

    pub fn enqueue(s: EntrySink, draft: *const EntryDraft) !Outcome {
        return s.vtable.enqueue(s.ptr, draft);
    }

    pub fn loadCursor(s: EntrySink, arena: std.mem.Allocator, source: *const SourceKey) !?[]const u8 {
        return s.vtable.loadCursor(s.ptr, arena, source);
    }
};

pub const LlmLedger = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        record: *const fn (ptr: *anyopaque, call: *const LlmCall) anyerror!void,
        spentSince: *const fn (ptr: *anyopaque, since: Micros) anyerror!f64,
    };

    pub fn record(l: LlmLedger, call: *const LlmCall) !void {
        return l.vtable.record(l.ptr, call);
    }

    pub fn spentSince(l: LlmLedger, since: Micros) !f64 {
        return l.vtable.spentSince(l.ptr, since);
    }
};

test "uuidv7 layout and string round trip" {
    const id = Id.fromParts(0x0193_0000_abcd, .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    try std.testing.expectEqual(@as(u8, 7), id.bytes[6] >> 4);
    try std.testing.expectEqual(@as(u8, 2), id.bytes[8] >> 6);
    try std.testing.expectEqual(@as(u48, 0x0193_0000_abcd), id.unixMs());

    var buf: [36]u8 = undefined;
    const s = id.toString(&buf);
    try std.testing.expect(id.eql(try Id.parse(s)));
    try std.testing.expectError(error.InvalidId, Id.parse("not-a-uuid"));
}

test "uuidv7 ids from io are time ordered" {
    const a = Id.v7(std.testing.io);
    const b = Id.v7(std.testing.io);
    try std.testing.expect(a.unixMs() <= b.unixMs());
    try std.testing.expect(!a.eql(b));
}

test "change set round-trips through json" {
    const gpa = std.testing.allocator;
    const id = Id.fromParts(1, @splat(7));
    const cs: ChangeSet = .{
        .base_seq = 41,
        .new_facts = &.{.{
            .fact = .{
                .id = id,
                .graph_id = id,
                .subject_id = id,
                .relation = "uses",
                .object = .{ .value = "Postgres 17" },
                .text = "graf uses Postgres 17.",
                .scope = .project,
                .valid = .{ .lower = 1_700_000_000_000_000 },
                .known = .{ .lower = 1_700_000_000_000_000 },
                .author = .user,
                .confidence = 0.9,
            },
            .emb = &.{ 0.25, -0.5 },
        }},
        .retractions = &.{.{ .fact_id = id, .end_kind = .retracted, .ended_by = null }},
    };

    const json = try std.json.Stringify.valueAlloc(gpa, cs, .{});
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(ChangeSet, gpa, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 41), parsed.value.base_seq);
    try std.testing.expectEqualStrings("Postgres 17", parsed.value.new_facts[0].fact.object.value);
    try std.testing.expect(parsed.value.new_facts[0].fact.valid.upper == null);
    try std.testing.expectEqual(EndKind.retracted, parsed.value.retractions[0].end_kind);
}

test "range containment is half-open" {
    const r: Range = .{ .lower = 10, .upper = 20 };
    try std.testing.expect(r.contains(10));
    try std.testing.expect(!r.contains(20));
    try std.testing.expect((Range{}).contains(-5));
}
