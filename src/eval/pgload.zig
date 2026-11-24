const std = @import("std");
const core = @import("core");
const store = @import("store");
const score = @import("score.zig");

const Allocator = std.mem.Allocator;
const pg = store.pg;

pub const EntryLink = struct {
    eval_id: []const u8,
    id: core.Id,
};

const range_bounds =
    \\CASE WHEN lower_inf({0s}) OR NOT isfinite(lower({0s})) THEN NULL ELSE (extract(epoch FROM lower({0s})) * 1000000)::int8 END,
    \\CASE WHEN upper_inf({0s}) OR NOT isfinite(upper({0s})) THEN NULL ELSE (extract(epoch FROM upper({0s})) * 1000000)::int8 END
;

const scanned_tables = [_][]const u8{
    "SELECT 'entity ' || t.id::text, t::text FROM entity t WHERE t.graph_id = $1",
    "SELECT 'entity_alias ' || t.entity_id::text, t::text FROM entity_alias t WHERE t.graph_id = $1",
    "SELECT 'fact ' || t.id::text, t::text FROM fact t WHERE t.graph_id = $1",
    "SELECT 'fact_evidence ' || t.fact_id::text, t::text FROM fact_evidence t JOIN fact f ON f.id = t.fact_id WHERE f.graph_id = $1",
    "SELECT 'entry ' || t.id::text, t::text FROM entry t WHERE t.graph_id = $1",
    "SELECT 'llm_call ' || t.id::text, t::text FROM llm_call t WHERE t.graph_id = $1",
    "SELECT 'source ' || t.id::text, t::text FROM source t WHERE t.graph_id = $1",
    "SELECT 'relation ' || t.name, t::text FROM relation t WHERE t.graph_id = $1",
    "SELECT 'merge_log ' || t.id::text, t::text FROM merge_log t WHERE t.graph_id = $1",
};

fn idText(arena: Allocator, id: core.Id) ![]const u8 {
    var buf: [36]u8 = undefined;
    return arena.dupe(u8, id.toString(&buf));
}

fn dupe(arena: Allocator, s: []const u8) ![]const u8 {
    return arena.dupe(u8, s);
}

fn dupeOpt(arena: Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try arena.dupe(u8, v) else null;
}

fn parseEnum(comptime E: type, s: []const u8) !E {
    return std.meta.stringToEnum(E, s) orelse error.UnknownEnumValue;
}

pub fn loadGraphState(arena: Allocator, pool: *pg.Pool, graph_id: core.Id, links: []const EntryLink) !score.GraphState {
    const gid = &graph_id.bytes;

    var eval_ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (links) |l| try eval_ids.put(arena, try idText(arena, l.id), l.eval_id);
    const evalId = struct {
        fn get(map: *const std.StringHashMapUnmanaged([]const u8), a: Allocator, db_id: []const u8) ![]const u8 {
            return map.get(db_id) orelse try a.dupe(u8, db_id);
        }
    }.get;

    var aliases: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    {
        var result = try pool.query("SELECT entity_id::text, alias FROM entity_alias WHERE graph_id = $1 ORDER BY entity_id, alias", .{gid});
        defer result.deinit();
        while (try result.next()) |row| {
            const gop = try aliases.getOrPut(arena, try dupe(arena, try row.get([]const u8, 0)));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, try dupe(arena, try row.get([]const u8, 1)));
        }
    }

    var entities: std.ArrayList(score.Entity) = .empty;
    {
        var result = try pool.query("SELECT id::text, name, type, merged_into::text FROM entity WHERE graph_id = $1 ORDER BY id", .{gid});
        defer result.deinit();
        while (try result.next()) |row| {
            const key = try dupe(arena, try row.get([]const u8, 0));
            try entities.append(arena, .{
                .key = key,
                .name = try dupe(arena, try row.get([]const u8, 1)),
                .type = std.meta.stringToEnum(core.EntityType, try row.get([]const u8, 2)) orelse .other,
                .aliases = if (aliases.get(key)) |list| list.items else &.{},
                .merged_into = try dupeOpt(arena, try row.get(?[]const u8, 3)),
            });
        }
    }

    var evidence: std.StringHashMapUnmanaged(std.ArrayList(score.Evidence)) = .empty;
    {
        var result = try pool.query(
            \\SELECT p.fact_id::text, p.entry_id::text, p.kind
            \\FROM fact_evidence p JOIN fact f ON f.id = p.fact_id JOIN entry e ON e.id = p.entry_id
            \\WHERE f.graph_id = $1 ORDER BY p.fact_id, e.reference_time, p.kind
        , .{gid});
        defer result.deinit();
        while (try result.next()) |row| {
            const gop = try evidence.getOrPut(arena, try dupe(arena, try row.get([]const u8, 0)));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, .{
                .entry = try evalId(&eval_ids, arena, try row.get([]const u8, 1)),
                .kind = try parseEnum(core.types.EvidenceKind, try row.get([]const u8, 2)),
            });
        }
    }

    var facts: std.ArrayList(score.Fact) = .empty;
    {
        const sql = try std.fmt.allocPrint(arena,
            \\SELECT id::text, subject_id::text, relation, qualifier, object_id::text, object_value, text, end_kind,
            \\{s}, {s}
            \\FROM fact WHERE graph_id = $1 ORDER BY created_seq, id
        , .{ try std.fmt.allocPrint(arena, range_bounds, .{"valid"}), try std.fmt.allocPrint(arena, range_bounds, .{"known"}) });
        var result = try pool.query(sql, .{gid});
        defer result.deinit();
        while (try result.next()) |row| {
            const key = try dupe(arena, try row.get([]const u8, 0));
            const object: score.Object = if (try row.get(?[]const u8, 4)) |o|
                .{ .entity = try dupe(arena, o) }
            else
                .{ .value = try dupe(arena, (try row.get(?[]const u8, 5)) orelse "") };
            try facts.append(arena, .{
                .key = key,
                .subject = try dupe(arena, try row.get([]const u8, 1)),
                .relation = try dupe(arena, try row.get([]const u8, 2)),
                .qualifier = try dupe(arena, try row.get([]const u8, 3)),
                .object = object,
                .text = try dupe(arena, try row.get([]const u8, 6)),
                .end_kind = if (try row.get(?[]const u8, 7)) |k| try parseEnum(core.types.EndKind, k) else null,
                .valid = .{ .lower = try row.get(?i64, 8), .upper = try row.get(?i64, 9) },
                .known = .{ .lower = try row.get(?i64, 10), .upper = try row.get(?i64, 11) },
                .evidence = if (evidence.get(key)) |list| list.items else &.{},
            });
        }
    }

    var entries: std.ArrayList(score.Entry) = .empty;
    {
        var result = try pool.query("SELECT id::text, status FROM entry WHERE graph_id = $1 ORDER BY reference_time, id", .{gid});
        defer result.deinit();
        while (try result.next()) |row| {
            try entries.append(arena, .{
                .eval_id = try evalId(&eval_ids, arena, try row.get([]const u8, 0)),
                .status = try parseEnum(core.types.EntryStatus, try row.get([]const u8, 1)),
            });
        }
    }

    var calls: std.ArrayList(score.LlmCall) = .empty;
    {
        var result = try pool.query("SELECT entry_id::text, purpose, cost_usd::float8 FROM llm_call WHERE graph_id = $1 ORDER BY started_at, id", .{gid});
        defer result.deinit();
        while (try result.next()) |row| {
            try calls.append(arena, .{
                .entry = if (try row.get(?[]const u8, 0)) |e| try evalId(&eval_ids, arena, e) else null,
                .purpose = try parseEnum(core.types.LlmPurpose, try row.get([]const u8, 1)),
                .cost_usd = try row.get(f64, 2),
            });
        }
    }

    return .{
        .entities = entities.items,
        .facts = facts.items,
        .entries = entries.items,
        .llm_calls = calls.items,
        .scanned = try scanForSecrets(arena, pool, graph_id),
    };
}

pub fn scanForSecrets(arena: Allocator, pool: *pg.Pool, graph_id: core.Id) ![]const score.ScannedText {
    var texts: std.ArrayList(score.ScannedText) = .empty;
    for (scanned_tables) |sql| {
        var result = try pool.query(sql, .{&graph_id.bytes});
        defer result.deinit();
        while (try result.next()) |row| {
            try texts.append(arena, .{
                .location = try dupe(arena, try row.get([]const u8, 0)),
                .text = try dupe(arena, try row.get([]const u8, 1)),
            });
        }
    }
    return texts.items;
}

pub fn entryStatus(pool: *pg.Pool, id: core.Id) !?core.types.EntryStatus {
    var row = (try pool.row("SELECT status FROM entry WHERE id = $1", .{&id.bytes})) orelse return null;
    defer row.deinit() catch {};
    return try parseEnum(core.types.EntryStatus, try row.get([]const u8, 0));
}

pub fn countCalls(pool: *pg.Pool, entry_id: core.Id, purpose: core.types.LlmPurpose) !i64 {
    var row = (try pool.row("SELECT count(*)::int8 FROM llm_call WHERE entry_id = $1 AND purpose = $2", .{ &entry_id.bytes, @tagName(purpose) })) orelse return 0;
    defer row.deinit() catch {};
    return try row.get(i64, 0);
}

const fixture_sql =
    \\INSERT INTO graph (id, name) VALUES ('{graph}', '{name}');
    \\INSERT INTO entity (id, graph_id, name, norm, type, created_seq, updated_seq, name_emb) VALUES
    \\  ('{e_brinelog}', '{graph}', 'brinelog', 'brinelog', 'project', 1, 1, array_fill(0.01::float4, ARRAY[512])::halfvec),
    \\  ('{e_pgzig}', '{graph}', 'pg.zig', 'pg zig', 'software', 1, 1, NULL),
    \\  ('{e_quayline}', '{graph}', 'Quayline', 'quayline', 'project', 2, 2, NULL),
    \\  ('{e_mooring}', '{graph}', 'Mooring', 'mooring', 'software', 3, 3, NULL),
    \\  ('{e_hollis}', '{graph}', 'Hollis', 'hollis', 'person', 3, 3, NULL),
    \\  ('{e_juno}', '{graph}', 'Juno', 'juno', 'person', 4, 4, NULL);
    \\INSERT INTO entity (id, graph_id, name, norm, type, created_seq, updated_seq, merged_into) VALUES
    \\  ('{e_pgzig2}', '{graph}', 'karlseguin''s driver', 'karlseguins driver', 'software', 2, 3, '{e_pgzig}');
    \\INSERT INTO entity_alias (graph_id, norm, entity_id, alias) VALUES
    \\  ('{graph}', 'pg zig', '{e_pgzig}', 'pg-zig'),
    \\  ('{graph}', 'brackwater booking service', '{e_mooring}', 'Brackwater booking service');
    \\INSERT INTO entry (id, graph_id, kind, author, body, content_hash, reference_time, status) VALUES
    \\  ('{e01}', '{graph}', 'turns', 'mixed', '{"turns":[{"role":"user","text":"start brinelog"}]}', '\x01', '2026-11-18T18:00:00Z', 'committed'),
    \\  ('{e03}', '{graph}', 'turns', 'mixed', '{"turns":[]}', '\x03', '2026-11-19T22:00:00Z', 'committed'),
    \\  ('{e05}', '{graph}', 'turns', 'user', '{"turns":[]}', '\x05', '2026-11-20T16:30:00Z', 'committed'),
    \\  ('{e06}', '{graph}', 'turns', 'user', '{"turns":[]}', '\x06', '2026-11-20T18:00:00Z', 'extracted'),
    \\  ('{e18}', '{graph}', 'turns', 'mixed', '{"turns":[{"role":"user","text":"MOORING_API_KEY=mr_live_7Qk2Vx9Lp4Rt8Wz3Hn6Jb1Ys5Dc0FgAe"}]}', '\x18', '2026-11-22T20:00:00Z', 'queued');
    \\INSERT INTO fact (id, graph_id, subject_id, relation, qualifier, object_id, object_value, text, scope, valid, known, end_kind, author, confidence, emb, created_seq) VALUES
    \\  ('{f_uses}', '{graph}', '{e_brinelog}', 'uses', '', '{e_pgzig2}', NULL, 'brinelog uses pg.zig.', 'project',
    \\   tstzrange('2026-11-18T18:00:00Z', NULL), tstzrange('2026-11-18T18:00:05Z', NULL), NULL, 'user', 0.9, array_fill(0.01::float4, ARRAY[512])::halfvec, 1),
    \\  ('{f_hollis}', '{graph}', '{e_mooring}', 'has_oncall', '', '{e_hollis}', NULL, 'Hollis is oncall for Mooring.', 'project',
    \\   tstzrange('2026-11-19T22:00:00Z', '2026-11-20T17:00:00Z'), tstzrange('2026-11-19T22:00:05Z', NULL), 'changed', 'tool', 0.8, array_fill(0.01::float4, ARRAY[512])::halfvec, 3),
    \\  ('{f_ver}', '{graph}', '{e_brinelog}', 'has_setting', 'zig_version', NULL, '0.17.1', 'brinelog pins Zig 0.17.1.', 'project',
    \\   tstzrange('-infinity', 'infinity'), tstzrange('2026-11-18T18:00:05Z', '2026-11-18T19:00:00Z'), 'retracted', 'user', 0.9, array_fill(0.01::float4, ARRAY[512])::halfvec, 2);
    \\INSERT INTO fact_evidence (fact_id, entry_id, kind, quote) VALUES
    \\  ('{f_uses}', '{e01}', 'stated', 'pg.zig driver'),
    \\  ('{f_uses}', '{e05}', 'restated', NULL),
    \\  ('{f_hollis}', '{e03}', 'stated', NULL),
    \\  ('{f_ver}', '{e01}', 'stated', NULL);
    \\INSERT INTO llm_call (id, graph_id, entry_id, purpose, route, model, attempt, outcome, latency_ms, cost_usd) VALUES
    \\  ('{c1}', '{graph}', '{e01}', 'extract', 'openai-responses', 'test-model', 1, 'ok', 900, 0.0125),
    \\  ('{c2}', '{graph}', '{e01}', 'embed_batch', 'embeddings', 'test-embed', 1, 'ok', 40, 0.0001),
    \\  ('{c3}', '{graph}', NULL, 'rerank', 'openai-responses', 'test-model', 1, 'ok', 80, 0.001);
;

fn fillTemplate(arena: Allocator, io: std.Io, template: []const u8, ids: *std.StringHashMapUnmanaged([]const u8)) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |end| {
                const name = template[i + 1 .. end];
                const word = name.len > 0 and for (name) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '_') break false;
                } else true;
                if (word) {
                    const gop = try ids.getOrPut(arena, name);
                    if (!gop.found_existing) gop.value_ptr.* = try idText(arena, core.Id.v7(io));
                    try out.appendSlice(arena, gop.value_ptr.*);
                    i = end + 1;
                    continue;
                }
            }
        }
        try out.append(arena, template[i]);
        i += 1;
    }
    return out.items;
}

test "loads a hand-built graph from Postgres and scores it" {
    var s = try store.testing.open();
    defer s.close();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    const graph_name = try std.fmt.allocPrint(arena, "eval-test-{s}", .{try idText(arena, core.Id.v7(io))});
    try ids.put(arena, "name", graph_name);
    const sql = try fillTemplate(arena, io, fixture_sql, &ids);
    {
        const conn = try s.pool.acquire();
        defer conn.release();
        try conn.execIgnoringState(sql);
    }

    const graph_id = try core.Id.parse(ids.get("graph").?);
    const link = struct {
        fn make(map: *std.StringHashMapUnmanaged([]const u8), comptime name: []const u8) !EntryLink {
            return .{ .eval_id = name, .id = try core.Id.parse(map.get(name).?) };
        }
    }.make;
    const links = [_]EntryLink{
        try link(&ids, "e01"), try link(&ids, "e03"), try link(&ids, "e05"), try link(&ids, "e06"), try link(&ids, "e18"),
    };
    const state = try loadGraphState(arena, s.pool, graph_id, &links);

    try std.testing.expectEqual(@as(usize, 7), state.entities.len);
    try std.testing.expectEqual(@as(usize, 3), state.facts.len);
    try std.testing.expectEqual(@as(usize, 5), state.entries.len);
    try std.testing.expectEqual(@as(usize, 3), state.llm_calls.len);

    var merged: ?score.Entity = null;
    var pgzig: ?score.Entity = null;
    for (state.entities) |e| {
        if (std.mem.eql(u8, e.name, "karlseguin's driver")) merged = e;
        if (std.mem.eql(u8, e.name, "pg.zig")) pgzig = e;
    }
    try std.testing.expectEqualStrings(ids.get("e_pgzig").?, merged.?.merged_into.?);
    try std.testing.expectEqual(@as(usize, 1), pgzig.?.aliases.len);
    try std.testing.expectEqualStrings("pg-zig", pgzig.?.aliases[0]);

    const uses = state.facts[0];
    try std.testing.expectEqualStrings("uses", uses.relation);
    try std.testing.expectEqual(@as(usize, 2), uses.evidence.len);
    try std.testing.expectEqualStrings("e01", uses.evidence[0].entry);
    try std.testing.expectEqual(core.types.EvidenceKind.restated, uses.evidence[1].kind);
    const t = @import("time.zig");
    try std.testing.expectEqual(try t.parseRfc3339("2026-11-18T18:00:00Z"), uses.valid.lower.?);
    try std.testing.expect(uses.valid.upper == null);

    const hollis = state.facts[2];
    try std.testing.expectEqual(core.types.EndKind.changed, hollis.end_kind.?);
    try std.testing.expectEqual(try t.parseRfc3339("2026-11-20T17:00:00Z"), hollis.valid.upper.?);
    const ver = state.facts[1];
    try std.testing.expect(ver.valid.lower == null and ver.valid.upper == null);
    try std.testing.expect(ver.known.upper != null);
    try std.testing.expectEqualStrings("0.17.1", ver.object.value);

    try std.testing.expectEqual(core.types.EntryStatus.extracted, state.entries[3].status);
    try std.testing.expectEqualStrings("e06", state.entries[3].eval_id);
    var extract_cost: f64 = 0;
    for (state.llm_calls) |c| if (c.purpose == .extract) {
        extract_cost += c.cost_usd;
        try std.testing.expectEqualStrings("e01", c.entry.?);
    };
    try std.testing.expectEqual(@as(f64, 0.0125), extract_cost);

    try std.testing.expectEqual(@as(?i64, 1), try countCalls(s.pool, links[0].id, .extract));
    try std.testing.expectEqual(core.types.EntryStatus.queued, (try entryStatus(s.pool, links[4].id)).?);

    const suite = try @import("fixtures.zig").loadShippedSuite(arena, io);
    const report = try score.scoreState(arena, &suite, &state);
    try std.testing.expectEqual(@as(u32, 2), report.metrics.secret_leaks.?);
    var entry_leak = false;
    for (report.findings) |msg| entry_leak = entry_leak or std.mem.indexOf(u8, msg, "in entry ") != null;
    try std.testing.expect(entry_leak);
    try std.testing.expect(report.metrics.entity_f1.? > 0);
    try std.testing.expect(report.metrics.calls_per_entry == null);
    try std.testing.expect(!report.metrics.passes());
    var recalled_uses = false;
    var recalled_hollis = false;
    for (report.findings) |msg| {
        recalled_uses = recalled_uses or std.mem.indexOf(u8, msg, "missing f_brinelog_uses_pgzig") != null;
        recalled_hollis = recalled_hollis or std.mem.indexOf(u8, msg, "missing f_mooring_oncall_hollis") != null;
    }
    try std.testing.expect(!recalled_uses and !recalled_hollis);
}
