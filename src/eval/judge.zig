const std = @import("std");
const core = @import("core");
const llm = @import("llm");
const ingest = @import("ingest");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const EntryView = ingest.prompt.EntryView;

pub const Overrides = struct {
    model: ?[]const u8 = null,
    route: ?[]const u8 = null,
};

pub const Setup = struct {
    llm: core.Config.Llm,
    warning: ?[]const u8 = null,
};

pub fn setup(arena: Allocator, config: *const core.Config, overrides: Overrides) error{ InvalidRoute, OutOfMemory }!Setup {
    const e = config.eval;
    var out: Setup = .{ .llm = config.llm };
    const route = overrides.route orelse e.judge_route;
    if (route.len > 0) out.llm.route = std.meta.stringToEnum(core.config.Route, route) orelse return error.InvalidRoute;
    if (e.judge_base_url.len > 0) out.llm.base_url = e.judge_base_url;
    if (e.judge_api_key.len > 0) out.llm.api_key = e.judge_api_key;
    const model = overrides.model orelse e.judge_model;
    if (model.len == 0) {
        if (config.llm.model.len > 0) out.warning = try std.fmt.allocPrint(arena, "no judge model is set, so the extraction model {s} grades its own residual facts; set eval.judge_model or GRAF_EVAL_JUDGE_MODEL to another model family", .{config.llm.model});
        return out;
    }
    out.llm.model = model;
    if (sameFamily(model, config.llm.model)) {
        out.warning = try std.fmt.allocPrint(arena, "the judge model {s} is in the same family as the extraction model {s}, so residual faithfulness may be lenient", .{ model, config.llm.model });
    }
    return out;
}

pub fn family(model: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| model[i + 1 ..] else model;
    const end = std.mem.indexOfAny(u8, base, "-_.: 0123456789") orelse base.len;
    return base[0..end];
}

pub fn sameFamily(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    const fa = family(a);
    return fa.len > 0 and std.ascii.eqlIgnoreCase(fa, family(b));
}

pub const Fact = struct {
    text: []const u8,
    subject: []const u8,
    relation: []const u8,
    qualifier: []const u8 = "",
    object: []const u8,
};

pub const Verdict = struct {
    supported: bool,
    durable: bool,
    reason: []const u8 = "",

    pub fn faithful(v: Verdict) bool {
        return v.supported and v.durable;
    }
};

pub const ReplyVerdict = struct {
    fact: u32,
    reason: []const u8,
    supported: bool,
    durable: bool,

    pub const schema_descriptions = .{
        .fact = "The number of the fact in the list.",
        .reason = "One short sentence that cites the entry.",
        .supported = "The entry states or directly implies the fact, and does not refute, retract, or correct it.",
        .durable = "The fact is lasting knowledge rather than transient chatter or an uncommitted idea.",
    };
};

pub const Reply = struct {
    verdicts: []const ReplyVerdict,
};

pub const schema = llm.jsonSchema(Reply);

pub const system =
    \\You audit facts that a knowledge-graph extractor wrote from one entry of a coding-agent conversation. These facts did not match any reference label, so you decide whether each is still a faithful, durable fact. Judge only against the entry shown. Do not use outside knowledge.
    \\
    \\Answer two questions for every fact.
    \\
    \\supported: true when the entry states the fact or directly implies it. Paraphrase and normalized names are fine. False when the fact adds a detail the entry does not contain, contradicts the entry, or asserts something the entry refutes, retracts, or corrects, such as a claim someone says is wrong or a value replaced by a correction later in the same entry. A past state counts as supported when the entry presents it as past.
    \\
    \\durable: true when the fact is lasting knowledge worth recalling in a later session: a decision, preference, or convention; ownership or responsibility; a property, dependency, location, or setting of a system, codebase, or tool; a capability or limitation; or a commitment such as a scheduled change. False for transient chatter: test or build output, the result of a one-off command or request, progress narration, a request that only matters in this session, brainstorming nobody committed to, a hypothetical, or a question.
    \\
    \\Judge each fact on its own. Write the reason first, then the two booleans. Return exactly one verdict per fact, numbered as in the list.
;

pub fn userPrompt(arena: Allocator, entry: EntryView, facts: []const Fact) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    writeUser(&out.writer, try ingest.prompt.extractionUser(arena, entry, &.{}), facts) catch return error.OutOfMemory;
    return out.written();
}

fn writeUser(w: *Writer, entry_text: []const u8, facts: []const Fact) Writer.Error!void {
    try w.writeAll(entry_text);
    try w.writeAll("\nFacts written from this entry:\n");
    for (facts, 1..) |f, n| {
        try w.print("{d}. {s}\n   as: {s} {s}", .{ n, f.text, f.subject, f.relation });
        if (f.qualifier.len > 0) try w.print(" ({s})", .{f.qualifier});
        try w.print(" {s}\n", .{f.object});
    }
}

pub fn judgeEntry(client: *llm.Client, arena: Allocator, entry: EntryView, facts: []const Fact) llm.Error![]const ?Verdict {
    if (facts.len == 0) return &.{};
    const out = try client.structuredAs(Reply, arena, .{
        .purpose = .judge,
        .system = system,
        .user = try userPrompt(arena, entry, facts),
        .schema_name = "residual_verdicts",
        .schema_json = schema,
        .max_output_tokens = 4096,
    });
    return verdicts(arena, out.value, facts.len);
}

pub fn verdicts(arena: Allocator, reply: Reply, n: usize) Allocator.Error![]const ?Verdict {
    const list = try arena.alloc(?Verdict, n);
    @memset(list, null);
    for (reply.verdicts) |v| {
        if (v.fact == 0 or v.fact > n) continue;
        const slot = &list[v.fact - 1];
        if (slot.* == null) slot.* = .{ .supported = v.supported, .durable = v.durable, .reason = v.reason };
    }
    return list;
}

const testing = std.testing;
const fixtures = @import("fixtures.zig");
const runner = @import("runner.zig");

fn suiteView(suite: *const fixtures.Suite, id: []const u8) !EntryView {
    const ep = suite.entries[suite.entryIndex(id).?];
    const draft = try runner.toDraft(ep);
    return .{ .reference_time = draft.reference_time, .project = draft.project, .kind = draft.kind, .author = draft.author, .body = draft.body };
}

const Planted = struct {
    entry: []const u8,
    capture: []const u8,
    facts: []const Fact,
    want: []const Verdict,
};

const valid: Verdict = .{ .supported = true, .durable = true };
const invented: Verdict = .{ .supported = false, .durable = true };
const transient: Verdict = .{ .supported = true, .durable = false };

const planted = [_]Planted{
    .{ .entry = "e01", .capture = @embedFile("fixtures/judge_e01.http"), .facts = &.{
        .{ .text = "brinelog is kept separate from Quayline", .subject = "brinelog", .relation = "kept_separate_from", .object = "Quayline" },
        .{ .text = "brinelog caches tide readings in Redis", .subject = "brinelog", .relation = "uses", .qualifier = "cache", .object = "Redis" },
    }, .want = &.{ valid, invented } },
    .{ .entry = "e13", .capture = @embedFile("fixtures/judge_e13.http"), .facts = &.{
        .{ .text = "Quayline uses Cowboy as its HTTP server library", .subject = "Quayline", .relation = "uses", .qualifier = "http_server", .object = "Cowboy" },
    }, .want = &.{invented} },
    .{ .entry = "e07", .capture = @embedFile("fixtures/judge_e07.http"), .facts = &.{
        .{ .text = "Quayline uses Go for its backend service", .subject = "Quayline", .relation = "uses", .qualifier = "backend_language", .object = "Go" },
    }, .want = &.{invented} },
    .{ .entry = "e04", .capture = @embedFile("fixtures/judge_e04.http"), .facts = &.{
        .{ .text = "All 14 brinelog tests passed in 0.42s", .subject = "brinelog", .relation = "has_setting", .qualifier = "test_result", .object = "14/14 passed in 0.42s" },
    }, .want = &.{transient} },
    .{ .entry = "e10", .capture = @embedFile("fixtures/judge_e10.http"), .facts = &.{
        .{ .text = "brinelog uses COPY for bulk backfill", .subject = "brinelog", .relation = "uses", .qualifier = "bulk_backfill", .object = "COPY" },
    }, .want = &.{transient} },
    .{ .entry = "e05", .capture = @embedFile("fixtures/judge_e05.http"), .facts = &.{
        .{ .text = "pg.zig needs a separate branch for each Zig release", .subject = "pg.zig", .relation = "has_setting", .qualifier = "zig_release_branch", .object = "separate branch per Zig release" },
        .{ .text = "brinelog pins pg.zig in build.zig.zon", .subject = "brinelog", .relation = "has_setting", .qualifier = "pg.zig pin", .object = "build.zig.zon" },
    }, .want = &.{ valid, valid } },
    .{ .entry = "e16", .capture = @embedFile("fixtures/judge_e16.http"), .facts = &.{
        .{ .text = "The buoy telemetry poller runs on kittiwake", .subject = "buoy telemetry poller", .relation = "located_at", .object = "kittiwake" },
    }, .want = &.{valid} },
    .{ .entry = "e19", .capture = @embedFile("fixtures/judge_e19.http"), .facts = &.{
        .{ .text = "The harbor-ops team runs Mooring", .subject = "Mooring", .relation = "owned_by", .object = "harbor-ops team" },
    }, .want = &.{valid} },
    .{ .entry = "e09", .capture = @embedFile("fixtures/judge_e09.http"), .facts = &.{
        .{ .text = "brackwater-buoy runs on Brackwater's remote tide buoys", .subject = "brackwater-buoy", .relation = "located_at", .object = "remote tide buoys" },
    }, .want = &.{valid} },
};

const Ledger = struct {
    rows: std.ArrayList(core.LlmCall) = .empty,

    fn ledger(l: *Ledger) core.LlmLedger {
        return .{ .ptr = l, .vtable = &.{ .record = record, .spentSince = spentSince } };
    }

    fn record(ptr: *anyopaque, call: *const core.LlmCall) anyerror!void {
        const l: *Ledger = @ptrCast(@alignCast(ptr));
        try l.rows.append(testing.allocator, call.*);
    }

    fn spentSince(_: *anyopaque, _: core.Micros) anyerror!f64 {
        return 0;
    }
};

test "planted residuals replay with the recorded cross-family verdicts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suite = try fixtures.loadShippedSuite(arena, testing.io);
    var extraction: core.Config = .{ .llm = .{ .base_url = "https://llm.example.test/v1", .api_key = "test-key", .model = "extract-model-1", .cost_header = "x-example-cost-usd" } };
    extraction.eval = .{ .judge_model = "claude-opus-5-5", .judge_route = "anthropic-messages" };
    const judge_setup = try setup(arena, &extraction, .{});
    try testing.expect(judge_setup.warning == null);
    var cfg = extraction;
    cfg.llm = judge_setup.llm;

    var steps: [planted.len]llm.transport.Replay.Step = undefined;
    for (planted, &steps) |p, *step| step.* = .{ .capture = p.capture };
    var replay = llm.transport.Replay.init(testing.allocator, &steps);
    defer replay.deinit();
    var ledger: Ledger = .{};
    defer ledger.rows.deinit(testing.allocator);
    var client = llm.Client.init(testing.allocator, testing.io, &cfg, ledger.ledger());
    defer client.deinit();
    client.transport = replay.transport();

    var bad: usize = 0;
    for (planted) |p| {
        const got = try judgeEntry(&client, arena, try suiteView(&suite, p.entry), p.facts);
        try testing.expectEqual(p.facts.len, got.len);
        for (got, p.want) |v, want| {
            const verdict = v.?;
            try testing.expectEqual(want.faithful(), verdict.faithful());
            if (!want.supported) try testing.expect(!verdict.supported);
            if (!want.durable) try testing.expect(!verdict.durable);
            try testing.expect(verdict.reason.len > 0);
            if (!want.faithful()) bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 5), bad);
    try testing.expectEqual(@as(usize, 0), replay.remaining());
    try testing.expectEqualStrings("https://llm.example.test/v1/messages", replay.sent.items[0].url);
    try testing.expectEqual(planted.len, ledger.rows.items.len);
    for (ledger.rows.items) |row| {
        try testing.expectEqual(core.types.LlmPurpose.judge, row.purpose);
        try testing.expectEqualStrings("claude-opus-5-5", row.model);
        try testing.expectEqualStrings("anthropic-messages", row.route);
        try testing.expect(row.ok and row.cost_usd > 0);
    }
}

test "the prompt shows the entry and numbers every fact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suite = try fixtures.loadShippedSuite(arena, testing.io);
    const text = try userPrompt(arena, try suiteView(&suite, "e01"), planted[0].facts);
    try testing.expect(std.mem.indexOf(u8, text, "Project: github.com/tidewright/brinelog") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[user] Let's start brinelog") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1. brinelog is kept separate from Quayline\n   as: brinelog kept_separate_from Quayline\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2. brinelog caches tide readings in Redis\n   as: brinelog uses (cache) Redis\n") != null);
    try testing.expect(std.mem.indexOf(u8, system, "refutes, retracts, or corrects") != null);
    try testing.expect(std.mem.indexOf(u8, system, "test or build output") != null);
    try testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"fact\",\"reason\",\"supported\",\"durable\"]") != null);
}

test "verdicts are matched by fact number and strays are dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const reply = try std.json.parseFromSliceLeaky(Reply, arena_state.allocator(),
        \\{"verdicts":[{"fact":2,"reason":"b","supported":false,"durable":true},{"fact":0,"reason":"x","supported":true,"durable":true},{"fact":2,"reason":"again","supported":true,"durable":true},{"fact":9,"reason":"y","supported":true,"durable":true}]}
    , .{});
    const got = try verdicts(arena_state.allocator(), reply, 3);
    try testing.expect(got[0] == null);
    try testing.expect(!got[1].?.supported);
    try testing.expectEqualStrings("b", got[1].?.reason);
    try testing.expect(got[2] == null);
}

test "the judge reuses the extraction route unless configured, and warns on a shared family" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg: core.Config = .{ .llm = .{ .base_url = "https://llm.example.test/v1", .api_key = "k", .model = "alpha-6.2-sol" } };

    const fallback = try setup(arena, &cfg, .{});
    try testing.expectEqualStrings("alpha-6.2-sol", fallback.llm.model);
    try testing.expect(std.mem.indexOf(u8, fallback.warning.?, "grades its own residual facts") != null);

    cfg.eval = .{ .judge_model = "beta-sonnet-5", .judge_route = "anthropic-messages", .judge_base_url = "https://judge.example.test/v1", .judge_api_key = "jk" };
    const cross = try setup(arena, &cfg, .{});
    try testing.expect(cross.warning == null);
    try testing.expectEqual(core.config.Route.@"anthropic-messages", cross.llm.route);
    try testing.expectEqualStrings("https://judge.example.test/v1", cross.llm.base_url);
    try testing.expectEqualStrings("jk", cross.llm.api_key);

    const same = try setup(arena, &cfg, .{ .model = "alpha-5-mini", .route = "openai-chat" });
    try testing.expectEqualStrings("alpha-5-mini", same.llm.model);
    try testing.expectEqual(core.config.Route.@"openai-chat", same.llm.route);
    try testing.expect(std.mem.indexOf(u8, same.warning.?, "same family") != null);

    try testing.expectError(error.InvalidRoute, setup(arena, &cfg, .{ .route = "carrier-pigeon" }));
    try testing.expectEqualStrings("beta", family("vendor/beta-sonnet-5"));
    try testing.expect(!sameFamily("", "alpha"));
}
