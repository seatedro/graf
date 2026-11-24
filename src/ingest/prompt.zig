const std = @import("std");
const core = @import("core");
const ingest = @import("mod.zig");
const resolve = @import("resolve.zig");
const extract = @import("extract.zig");
const time = @import("time.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const extraction_rules =
    \\You extract durable knowledge from one entry of an agent session into a temporal knowledge graph.
    \\
    \\Output one JSON object that matches the schema. Rules:
    \\- Extract only knowledge that stays useful later: decisions, choices and rejections with their reasons, settings, versions, ownership, on-call and status, capabilities, preferences, architecture, causes and fixes.
    \\- Set "skip" to a short reason, with no entities or facts, when the entry holds nothing durable: test or lint output, routine command chatter, hypotheticals, brainstorming that commits to nothing, greetings.
    \\- Entities get local refs n1, n2, ... Use the most canonical name as "name" and list other spellings in "aliases". Reuse one ref for every mention of the same thing.
    \\- Entity type "code" is a module, file or service inside a repository the user works in; "software" is a product, library, tool or service they use, and programming languages, databases and frameworks are "software" too. A commit is not an entity: record it on the "change" it belongs to. Bugs, failure modes and open questions are "problem".
    \\- Keep one entity per real thing: a service and its API, or a project and its repository, are the same entity unless the entry treats them as separate things. Relate the named things directly; do not invent an entity for a request, a check or a comparison just to hang facts on it.
    \\- Every fact has a subject ref, a relation, and exactly one of "object" (an entity ref) or "value" (a literal). The other is null.
    \\- Reuse a listed relation whenever one fits. Use "related_to" only as a last resort. If none fits, invent a snake_case relation and describe it in "new_relations".
    \\- Use "uses" for what a subject is built with or relies on, also when the entry phrases it as a pick or a plan ("we'll use X", "we picked X"), and put the stated reason in "rationale". Keep "chose" for a decision that is not about using the object, and "rejected" for something decided against. Where something runs or is hosted is "located_at"; a URL or endpoint is a has_setting value with a qualifier such as "api_url".
    \\- has_setting needs a "qualifier" naming the setting, for example "extraction_model". Other relations use a null qualifier. When a setting's value is a model, library or host, make it an entity and use it as the object. Features in supports_feature and lacks_feature are values.
    \\- "text" is one self-contained sentence that names the subject and object explicitly. "rationale" holds the stated why behind a decision, or null.
    \\- "quote" is a verbatim excerpt of at most 200 characters from the entry that supports the fact.
    \\- Time: "valid_from" and "valid_to" are RFC 3339. Resolve relative phrases ("today at 17:00", "last Tuesday") against the reference time and set time_basis "relative". Use time_basis "explicit" for stated dates. Otherwise leave both null and set time_basis "reference". Use "-infinity" for valid_from only when the fact has held for as long as anyone knows.
    \\- valid_from is when the fact began to hold, not a date that appears in its value: "the launch is now set for March 9" says when the launch happens, so its valid_from follows the rules above while the value is the date.
    \\- Set valid_to only when the entry states that the fact ended or will end.
    \\- A state the entry mentions only as earlier history ("before Dana took over", "we used to") is not current: give it its stated period, or leave it out when the entry gives none.
    \\- When a speaker corrects themselves or someone else in this entry, extract only the corrected statement. Never extract a claim the entry refutes, and do not add a separate fact that negates it.
    \\- Skip one-off requests and instructions that will not matter after the session, such as who to ping or what to try next.
    \\- author is "user" for what the user states, "agent" for unconfirmed assistant claims, "tool" for observed tool output.
    \\- scope is "global" for a person's standing preferences and conventions that apply across all their projects. Everything else is "project", including facts about tools and libraries.
    \\- Never put credentials, tokens, keys or redaction markers into any field.
    \\- The recent context lists what earlier entries from the same source established. Use it to resolve references like "it" or "switch it"; do not re-extract it.
    \\
;

const examples =
    \\Example 1
    \\Entry:
    \\[user] We picked SQLite for the brackwater cache because it needs no server. Dana owns the cache now.
    \\Output:
    \\{"skip":null,"entities":[{"ref":"n1","name":"brackwater cache","type":"code","aliases":[],"description":"Cache service in the brackwater project."},{"ref":"n2","name":"SQLite","type":"software","aliases":[],"description":"Embedded SQL database."},{"ref":"n3","name":"Dana","type":"person","aliases":[],"description":"Engineer."}],"facts":[{"subject":"n1","relation":"uses","qualifier":null,"object":"n2","value":null,"text":"The brackwater cache uses SQLite.","rationale":"It needs no server.","valid_from":null,"valid_to":null,"time_basis":"reference","scope":"project","author":"user","quote":"We picked SQLite for the brackwater cache because it needs no server."},{"subject":"n1","relation":"owned_by","qualifier":null,"object":"n3","value":null,"text":"The brackwater cache is owned by Dana.","rationale":null,"valid_from":null,"valid_to":null,"time_basis":"reference","scope":"project","author":"user","quote":"Dana owns the cache now."}],"new_relations":[]}
    \\
    \\Example 2
    \\Reference time: 2026-03-04T10:00:00Z (Wednesday, UTC)
    \\Entry:
    \\[user] Set the relay timeout to 30s. Wait, no, make it 45s. Also the example.test endpoint went read-only yesterday.
    \\Output:
    \\{"skip":null,"entities":[{"ref":"n1","name":"relay","type":"software","aliases":[],"description":"Request relay service."},{"ref":"n2","name":"example.test endpoint","type":"software","aliases":[],"description":"HTTP endpoint at example.test."}],"facts":[{"subject":"n1","relation":"has_setting","qualifier":"timeout","object":null,"value":"45s","text":"The relay timeout is set to 45s.","rationale":null,"valid_from":null,"valid_to":null,"time_basis":"reference","scope":"project","author":"user","quote":"Wait, no, make it 45s."},{"subject":"n2","relation":"has_status","qualifier":null,"object":null,"value":"read-only","text":"The example.test endpoint is read-only.","rationale":null,"valid_from":"2026-03-03T00:00:00Z","valid_to":null,"time_basis":"relative","scope":"project","author":"user","quote":"the example.test endpoint went read-only yesterday"}],"new_relations":[]}
    \\
    \\Example 3
    \\Entry:
    \\[user] run the tests
    \\[assistant] All 42 tests passed in 1.2s.
    \\Output:
    \\{"skip":"Routine test output with no durable knowledge.","entities":[],"facts":[],"new_relations":[]}
    \\
;

pub fn extractionSystem(arena: Allocator, learned: []const resolve.RelationRow) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    writeExtractionSystem(&out.writer, learned) catch return error.OutOfMemory;
    return out.written();
}

fn byName(_: void, a: resolve.RelationRow, b: resolve.RelationRow) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn writeExtractionSystem(w: *Writer, learned: []const resolve.RelationRow) Writer.Error!void {
    try w.writeAll(extraction_rules);
    try w.writeAll("\nEntity types: ");
    inline for (@typeInfo(core.EntityType).@"enum".field_names, 0..) |n, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(n);
    }
    try w.writeAll("\n\nRelations (name, cardinality: meaning):\n");
    for (core.ontology.core_relations) |p| {
        try w.print("- {s} ({t}): {s}\n", .{ p.name, p.cardinality, p.description });
    }
    var sorted_buf: [256]resolve.RelationRow = undefined;
    var n: usize = 0;
    for (learned) |p| {
        if (p.status != .learned or p.mapped_to != null or n == sorted_buf.len) continue;
        sorted_buf[n] = p;
        n += 1;
    }
    const sorted = sorted_buf[0..n];
    std.mem.sort(resolve.RelationRow, sorted, {}, byName);
    for (sorted) |p| try w.print("- {s} ({t}): {s}\n", .{ p.name, p.cardinality, p.description });
    try w.writeAll("\n");
    try w.writeAll(examples);
}

pub const PriorEntry = struct {
    reference_time: core.Micros,
    facts: []const []const u8 = &.{},
    excerpt: []const u8 = "",
};

pub const EntryView = struct {
    reference_time: core.Micros,
    project: ?[]const u8,
    kind: core.types.EntryKind,
    author: core.types.Author,
    body: core.EntryBody,
};

pub fn extractionUser(arena: Allocator, entry: EntryView, context: []const PriorEntry) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    writeExtractionUser(&out.writer, entry, context) catch return error.OutOfMemory;
    return out.written();
}

fn writeExtractionUser(w: *Writer, entry: EntryView, context: []const PriorEntry) Writer.Error!void {
    var buf: [20]u8 = undefined;
    try w.print("Reference time: {s} ({s}, UTC)\n", .{ time.format(entry.reference_time, &buf), time.weekday(entry.reference_time) });
    try w.print("Project: {s}\nKind: {t}\nAuthor: {t}\n", .{ entry.project orelse "none", entry.kind, entry.author });
    if (context.len > 0) {
        try w.writeAll("\nRecent context from this source, oldest first:\n");
        for (context) |c| {
            try w.print("- {s}:", .{time.format(c.reference_time, &buf)});
            if (c.facts.len == 0) {
                try w.print(" {s}\n", .{c.excerpt});
                continue;
            }
            try w.writeAll("\n");
            for (c.facts) |f| try w.print("  - {s}\n", .{f});
        }
    }
    try w.writeAll("\nEntry:\n");
    if (entry.body.text) |t| try w.print("{s}\n", .{t});
    for (entry.body.turns) |turn| {
        try w.print("[{t}] {s}\n", .{ turn.role, turn.text });
        for (turn.tool_calls) |tc| {
            try w.print("  [tool {s}] {s}\n", .{ tc.name, tc.args_preview });
            if (tc.result_preview.len > 0) try w.print("  [result] {s}\n", .{tc.result_preview});
        }
    }
}

pub const resolution_system =
    \\You reconcile newly extracted knowledge with what a knowledge graph already holds. Output one JSON object that matches the schema.
    \\
    \\Entities: for each new entity listed with candidates, set "existing" to the label (E1, E2, ...) of the candidate that is the same real-world thing, or null when none is. Same name is not enough: a company and its product, a tool and a dataset, or two people who share a first name are different entities. A project and its repository are the same entity. List every such entity in "entity_links".
    \\
    \\Facts: for each new fact listed with candidates, give one entry in "fact_verdicts" with its index:
    \\- "duplicate_of": the label (F1, F2, ...) of an existing fact that already says the same thing, else null.
    \\- "contradicts": existing facts that can no longer be current if the new fact is true. Use kind "changed" when the world changed (a handoff, a switch, an upgrade) and kind "was_wrong" when the old fact was never true (a correction or a misstatement). Set "at" to the RFC 3339 time of the change when the entry states it, else null.
    \\Facts that merely add detail, or that can both be true, are neither duplicates nor contradictions.
;

pub fn resolutionUser(arena: Allocator, p: resolve.Plan, checked: extract.Checked, prefetch: resolve.Prefetch, reference_time: core.Micros) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    writeResolutionUser(&out.writer, p, checked, prefetch, reference_time) catch return error.OutOfMemory;
    return out.written();
}

fn writeRange(w: *Writer, lower: ?core.Micros, upper: ?core.Micros) Writer.Error!void {
    var a: [20]u8 = undefined;
    var b: [20]u8 = undefined;
    try w.print("valid {s} to {s}", .{
        if (lower) |l| time.format(l, &a) else "-infinity",
        if (upper) |u| time.format(u, &b) else "now",
    });
}

fn writeResolutionUser(w: *Writer, p: resolve.Plan, checked: extract.Checked, prefetch: resolve.Prefetch, reference_time: core.Micros) Writer.Error!void {
    var buf: [20]u8 = undefined;
    try w.print("Reference time: {s}\n", .{time.format(reference_time, &buf)});
    if (p.entity_labels.len > 0) {
        try w.writeAll("\nExisting entities:\n");
        for (p.entity_labels, 0..) |id, i| {
            const c = resolve.findEntity(prefetch, id) orelse continue;
            try w.print("E{d}: {s} ({t})\n", .{ i + 1, c.name, c.type });
        }
        try w.writeAll("\nNew entities with candidates:\n");
        for (p.entities, checked.result.entities) |entry, e| {
            if (entry.decision != .ask) continue;
            try w.print("{s}: {s} ({t}) {s}; candidates:", .{ e.ref, e.name, e.type, e.description });
            for (entry.gray) |g| try w.print(" E{d}", .{p.entityLabel(g).? + 1});
            try w.writeAll("\n");
        }
    }
    if (p.fact_labels.len > 0) {
        try w.writeAll("\nExisting facts:\n");
        for (p.fact_labels, 0..) |id, i| {
            const c = resolve.findFact(prefetch, id) orelse continue;
            try w.print("F{d}: {s} [{s}", .{ i + 1, c.text, c.relation });
            if (c.qualifier.len > 0) try w.print(" {s}", .{c.qualifier});
            try w.writeAll("; ");
            try writeRange(w, c.valid_lower, c.valid_upper);
            try w.writeAll("]\n");
        }
        try w.writeAll("\nNew facts with candidates:\n");
        for (p.facts, checked.result.facts, checked.meta, 0..) |fp, f, m, j| {
            if (fp.candidates.len == 0) continue;
            try w.print("{d}: {s} [{s}", .{ j, f.text, f.relation });
            if (f.qualifier) |q| try w.print(" {s}", .{q});
            try w.writeAll("; ");
            try writeRange(w, m.valid.lower, m.valid.upper);
            try w.print("] quote: \"{s}\"; candidates:", .{f.quote});
            for (fp.candidates) |cid| try w.print(" F{d}", .{p.factLabel(cid).? + 1});
            try w.writeAll("\n");
        }
    }
}

pub const summary_system =
    \\Summarize what a knowledge graph knows about one entity in at most three short sentences. Use only the listed facts. Prefer current facts and decisions; mention a change only when it matters. Output one JSON object that matches the schema.
;

pub const SummaryResult = struct { summary: []const u8 };

const testing = std.testing;

test "the extraction prefix is byte-stable and lists learned relations in name order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try extractionSystem(arena, &.{
        .{ .name = "zeta_rel", .status = .learned, .description = "z" },
        .{ .name = "alpha_rel", .status = .learned, .description = "a" },
        .{ .name = "draft_rel", .status = .proposed, .description = "d" },
    });
    const b = try extractionSystem(arena, &.{
        .{ .name = "alpha_rel", .status = .learned, .description = "a" },
        .{ .name = "zeta_rel", .status = .learned, .description = "z" },
    });
    try testing.expectEqualStrings(a, b);
    try testing.expect(std.mem.indexOf(u8, a, "- has_setting (one_per_subject_qualifier)") != null);
    try testing.expect(std.mem.indexOf(u8, a, "draft_rel") == null);
    try testing.expect(std.mem.indexOf(u8, a, "alpha_rel").? < std.mem.indexOf(u8, a, "zeta_rel").?);
}

test "the extraction message carries reference time, context and turns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msg = try extractionUser(arena, .{
        .reference_time = try core.time.parseRfc3339("2026-11-20T18:00:00Z"),
        .project = "lantern",
        .kind = .turns,
        .author = .user,
        .body = .{ .turns = &.{
            .{ .role = .user, .text = "switch it to Postgres" },
            .{ .role = .assistant, .text = "done", .tool_calls = &.{.{ .name = "bash", .args_preview = "make migrate", .result_preview = "ok" }} },
        } },
    }, &.{.{ .reference_time = try core.time.parseRfc3339("2026-11-19T10:00:00Z"), .facts = &.{"Lantern uses SQLite."} }});
    try testing.expect(std.mem.startsWith(u8, msg, "Reference time: 2026-11-20T18:00:00Z (Friday, UTC)\n"));
    try testing.expect(std.mem.indexOf(u8, msg, "  - Lantern uses SQLite.\n") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "[user] switch it to Postgres\n") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "  [tool bash] make migrate\n") != null);
}
