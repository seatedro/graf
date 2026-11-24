const std = @import("std");
const core = @import("core");
const store = @import("store");
const mod = @import("mod.zig");
const time = @import("time.zig");
const render = @import("render.zig");

const day = std.time.us_per_day;
const dims = 512;

pub fn hashEmbed(out: []f32, s: []const u8) void {
    @memset(out, 0);
    var it = std.mem.tokenizeAny(u8, s, " .,;:!?()[]'\"\n\t-");
    while (it.next()) |tok| {
        var buf: [64]u8 = undefined;
        const lower = std.ascii.lowerString(buf[0..@min(tok.len, 64)], tok[0..@min(tok.len, 64)]);
        const h = std.hash.Wyhash.hash(7, lower);
        out[h % out.len] += if (h & (1 << 40) != 0) 1 else -1;
    }
    var n: f32 = 0;
    for (out) |x| n += x * x;
    if (n == 0) {
        out[0] = 1;
        return;
    }
    const inv = 1 / @sqrt(n);
    for (out) |*x| x.* *= inv;
}

pub const HashEmbedder = struct {
    calls: usize = 0,

    pub fn embedder(h: *HashEmbedder) mod.Embedder {
        return .{ .ptr = h, .vtable = &.{ .embedQuery = embedQuery } };
    }

    fn embedQuery(ptr: *anyopaque, arena: std.mem.Allocator, query: []const u8) anyerror![]const f32 {
        const h: *HashEmbedder = @ptrCast(@alignCast(ptr));
        h.calls += 1;
        const v = try arena.alloc(f32, dims);
        hashEmbed(v, query);
        return v;
    }
};

const FavoringReranker = struct {
    favorite: []const u8,
    io: std.Io,
    delay_ms: i64 = 0,

    fn reranker(r: *FavoringReranker) mod.Reranker {
        return .{ .ptr = r, .vtable = &.{ .score = score } };
    }

    fn score(ptr: *anyopaque, arena: std.mem.Allocator, query: []const u8, candidates: []const []const u8) anyerror![]const f64 {
        _ = query;
        const r: *FavoringReranker = @ptrCast(@alignCast(ptr));
        if (r.delay_ms > 0) try r.io.sleep(.fromMilliseconds(r.delay_ms), .awake);
        const out = try arena.alloc(f64, candidates.len);
        for (candidates, out) |c, *p| p.* = if (std.mem.indexOf(u8, c, r.favorite) != null) 0.99 else 0.05;
        return out;
    }
};

pub const Seed = struct {
    graph: core.Id,
    now: core.Micros,
    graf: core.Id,
    pgzig: core.Id,
    postgres: core.Id,
    sqlite: core.Id,
    quayline: core.Id,
    alice: core.Id,
    tabs: core.Id,
    f_graf_uses_pg: core.Id = undefined,
    f_pgzig_lacks_copy: core.Id = undefined,
    f_pgzig_supports_copy: core.Id = undefined,
    f_graf_uses_sqlite: core.Id = undefined,
    f_quayline_uses_pg: core.Id = undefined,
    f_alice_prefers_tabs: core.Id = undefined,
    f_graf_status: core.Id = undefined,
    f_graf_chose_pg: core.Id = undefined,
    f_graf_pg18: core.Id = undefined,
};

pub const FactSpec = struct {
    subject: core.Id,
    relation: []const u8,
    object: ?core.Id = null,
    value: ?[]const u8 = null,
    text: []const u8,
    rationale: ?[]const u8 = null,
    project: ?[]const u8,
    scope: []const u8 = "project",
    valid_from: ?core.Micros,
    valid_to: ?core.Micros = null,
    recorded: core.Micros,
    superseded: ?core.Micros = null,
    end_kind: ?[]const u8 = null,
    author: []const u8 = "user",
    confidence: f32 = 0.9,
    harness: []const u8 = "claude-code",
};

pub const Seeder = struct {
    s: *store.Store,
    io: std.Io,
    graph: core.Id,
    seq: usize = 0,

    pub fn exec(sd: *Seeder, sql: []const u8, args: anytype) !void {
        _ = sd.s.pool.exec(sql, args) catch |err| {
            std.debug.print("seed failed: {s}\n", .{sql});
            return err;
        };
    }

    pub fn entity(sd: *Seeder, name: []const u8, norm: []const u8, typ: []const u8, description: []const u8, aliases: []const []const u8) !core.Id {
        const id = core.Id.v7(sd.io);
        var emb: [dims]f32 = undefined;
        hashEmbed(&emb, name);
        try sd.exec(
            \\INSERT INTO entity (id, graph_id, name, norm, type, description, summary, name_emb, created_seq, updated_seq)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8::float4[]::halfvec(512), 0, 0)
        , .{ &id.bytes, &sd.graph.bytes, name, norm, typ, description, if (std.mem.eql(u8, typ, "project")) description else "", @as([]const f32, &emb) });
        try sd.exec("INSERT INTO entity_alias (graph_id, norm, entity_id, alias) VALUES ($1, $2, $3, $4)", .{ &sd.graph.bytes, norm, &id.bytes, name });
        for (aliases) |a| {
            var buf: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const n = try store.normalizeAlias(fba.allocator(), a);
            try sd.exec("INSERT INTO entity_alias (graph_id, norm, entity_id, alias) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING", .{ &sd.graph.bytes, n, &id.bytes, a });
        }
        return id;
    }

    pub fn fact(sd: *Seeder, f: FactSpec) !core.Id {
        const id = core.Id.v7(sd.io);
        var emb: [dims]f32 = undefined;
        hashEmbed(&emb, f.text);
        try sd.exec(
            \\INSERT INTO fact (id, graph_id, subject_id, relation, object_id, object_value, text, rationale, project, scope,
            \\  valid, known, end_kind, author, confidence, emb, created_seq)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, tstzrange($11::timestamptz, $12::timestamptz),
            \\  tstzrange($13::timestamptz, $14::timestamptz), $15, $16, $17, $18::float4[]::halfvec(512), 0)
        , .{
            &id.bytes,                                              &sd.graph.bytes,        &f.subject.bytes, f.relation,
            if (f.object) |o| @as(?[]const u8, &o.bytes) else null, f.value,                f.text,           f.rationale,
            f.project,                                              f.scope,                f.valid_from,     f.valid_to,
            f.recorded,                                             f.superseded,           f.end_kind,       f.author,
            f.confidence,                                           @as([]const f32, &emb),
        });
        sd.seq += 1;
        const source_id = core.Id.v7(sd.io);
        const entry_id = core.Id.v7(sd.io);
        var ext_buf: [48]u8 = undefined;
        const ext = try std.fmt.bufPrint(&ext_buf, "session-{d}", .{sd.seq});
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&id.bytes, &hash, .{});
        try sd.exec("INSERT INTO source (id, graph_id, harness, external_id, project) VALUES ($1, $2, $3, $4, $5)", .{ &source_id.bytes, &sd.graph.bytes, f.harness, ext, f.project });
        try sd.exec(
            \\INSERT INTO entry (id, graph_id, source_id, kind, project, author, body, content_hash, reference_time, status)
            \\VALUES ($1, $2, $3, 'note', $4, 'user', '{}'::jsonb, $5, $6::timestamptz, 'committed')
        , .{ &entry_id.bytes, &sd.graph.bytes, &source_id.bytes, f.project, @as([]const u8, &hash), f.recorded });
        try sd.exec("INSERT INTO fact_evidence (fact_id, entry_id, kind) VALUES ($1, $2, 'stated')", .{ &id.bytes, &entry_id.bytes });
        return id;
    }
};

pub fn seed(s: *store.Store, io: std.Io) !Seed {
    const graph = core.Id.v7(io);
    var name_buf: [36]u8 = undefined;
    _ = try s.pool.exec("INSERT INTO graph (id, name) VALUES ($1, $2)", .{ &graph.bytes, graph.toString(&name_buf) });
    var sd: Seeder = .{ .s = s, .io = io, .graph = graph };
    const now = time.now(io);
    var r: Seed = .{
        .graph = graph,
        .now = now,
        .graf = try sd.entity("graf", "graf", "project", "Zig temporal knowledge graph for agents", &.{}),
        .pgzig = try sd.entity("pg.zig", "pg zig", "software", "Zig Postgres driver", &.{ "pg-zig", "the zig postgres driver" }),
        .postgres = try sd.entity("Postgres", "postgres", "software", "Relational database", &.{"PostgreSQL"}),
        .sqlite = try sd.entity("SQLite", "sqlite", "software", "Embedded database", &.{}),
        .quayline = try sd.entity("quayline", "quayline", "project", "Elixir fare app", &.{}),
        .alice = try sd.entity("alice", "alice", "person", "The user", &.{}),
        .tabs = try sd.entity("tabs", "tabs", "concept", "Indentation with tab characters", &.{}),
    };
    r.f_graf_uses_pg = try sd.fact(.{ .subject = r.graf, .relation = "uses", .object = r.postgres, .text = "graf uses Postgres 17 with pgvector for storage.", .project = "graf", .valid_from = now - 30 * day, .recorded = now - 30 * day });
    r.f_pgzig_lacks_copy = try sd.fact(.{ .subject = r.pgzig, .relation = "lacks_feature", .value = "COPY", .text = "pg.zig lacks COPY support.", .project = "graf", .scope = "global", .valid_from = now - 25 * day, .valid_to = now - 5 * day, .end_kind = "changed", .recorded = now - 25 * day, .confidence = 0.8, .harness = "codex" });
    r.f_pgzig_supports_copy = try sd.fact(.{ .subject = r.pgzig, .relation = "supports_feature", .value = "COPY", .text = "pg.zig supports COPY since its latest release.", .project = "graf", .scope = "global", .valid_from = now - 5 * day, .recorded = now - 5 * day, .confidence = 0.85 });
    r.f_graf_uses_sqlite = try sd.fact(.{ .subject = r.graf, .relation = "uses", .object = r.sqlite, .text = "graf uses SQLite for storage.", .project = "graf", .valid_from = now - 20 * day, .recorded = now - 20 * day, .superseded = now - 10 * day, .end_kind = "retracted", .author = "agent", .confidence = 0.7 });
    r.f_quayline_uses_pg = try sd.fact(.{ .subject = r.quayline, .relation = "uses", .object = r.postgres, .text = "quayline uses Postgres 17 with pgvector for storage.", .project = "quayline", .valid_from = now - 30 * day, .recorded = now - 30 * day });
    r.f_alice_prefers_tabs = try sd.fact(.{ .subject = r.alice, .relation = "prefers", .object = r.tabs, .text = "alice prefers tabs over spaces for indentation.", .project = null, .scope = "global", .valid_from = null, .recorded = now - 40 * day });
    r.f_graf_status = try sd.fact(.{ .subject = r.graf, .relation = "has_status", .value = "beta", .text = "graf is in beta.", .project = "graf", .valid_from = now - 2 * day, .recorded = now - 2 * day });
    r.f_graf_chose_pg = try sd.fact(.{ .subject = r.graf, .relation = "chose", .object = r.postgres, .text = "graf chose Postgres over a graph database.", .rationale = "pgvector and range types cover the temporal graph", .project = "graf", .valid_from = now - 3 * day, .recorded = now - 3 * day });
    r.f_graf_pg18 = try sd.fact(.{ .subject = r.graf, .relation = "has_version", .value = "Postgres 18", .text = "graf moves to Postgres 18.", .project = "graf", .valid_from = now + 10 * day, .recorded = now - 1 * day });
    return r;
}

pub fn cleanup(s: *store.Store, graph: core.Id) void {
    const tables = [_][]const u8{ "project_brief", "fact_evidence", "fact", "entity_alias", "entity", "entry", "source" };
    inline for (tables) |t| {
        const sql = if (comptime std.mem.eql(u8, t, "fact_evidence"))
            "DELETE FROM fact_evidence WHERE fact_id IN (SELECT id FROM fact WHERE graph_id = $1)"
        else
            "DELETE FROM " ++ t ++ " WHERE graph_id = $1";
        _ = s.pool.exec(sql, .{&graph.bytes}) catch {};
    }
    _ = s.pool.exec("DELETE FROM graph WHERE id = $1", .{&graph.bytes}) catch {};
}

const Fixture = struct {
    s: store.Store,
    seed: Seed,
    arena: std.heap.ArenaAllocator,
    embedder: HashEmbedder = .{},
    config: core.Config = .{},
    engine: mod.Engine = undefined,

    fn init(f: *Fixture) !void {
        f.* = .{ .s = try store.testing.open(), .seed = undefined, .arena = .init(std.testing.allocator) };
        errdefer f.s.close();
        f.seed = try seed(&f.s, std.testing.io);
        f.engine = .init(std.testing.allocator, std.testing.io, &f.s, &f.config, f.seed.graph, .{ .embedder = f.embedder.embedder() });
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.engine.deinit();
        cleanup(&f.s, f.seed.graph);
        f.s.close();
    }
};

fn contains(hits: []const mod.Hit, id: core.Id) bool {
    return indexOf(hits, id) != null;
}

fn indexOf(hits: []const mod.Hit, id: core.Id) ?usize {
    for (hits, 0..) |h, i| if (h.fact.id.eql(id)) return i;
    return null;
}

test "search hides ended and retracted facts unless asked" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const arena = f.arena.allocator();
    const sd = f.seed;

    const now = try f.engine.search(arena, .{ .query = "pg.zig COPY support", .project = "graf" });
    try std.testing.expect(contains(now.hits, sd.f_pgzig_supports_copy));
    try std.testing.expect(!contains(now.hits, sd.f_pgzig_lacks_copy));
    try std.testing.expect(!now.reranked);

    const hist = try f.engine.search(arena, .{ .query = "pg.zig COPY support", .project = "graf", .include_history = true });
    try std.testing.expect(contains(hist.hits, sd.f_pgzig_lacks_copy));

    const past = try f.engine.search(arena, .{ .query = "pg.zig COPY support", .project = "graf", .as_of = sd.now - 10 * day });
    try std.testing.expect(contains(past.hits, sd.f_pgzig_lacks_copy));
    try std.testing.expect(!contains(past.hits, sd.f_pgzig_supports_copy));

    const storage = try f.engine.search(arena, .{ .query = "what does graf use for storage", .project = "graf" });
    try std.testing.expect(contains(storage.hits, sd.f_graf_uses_pg));
    try std.testing.expect(!contains(storage.hits, sd.f_graf_uses_sqlite));
    try std.testing.expect(!contains(storage.hits, sd.f_graf_pg18));

    const audit = try f.engine.search(arena, .{ .query = "what does graf use for storage", .project = "graf", .known_at = sd.now - 12 * day });
    try std.testing.expect(contains(audit.hits, sd.f_graf_uses_sqlite));
    try std.testing.expect(!contains(audit.hits, sd.f_graf_status));

    const future = try f.engine.search(arena, .{ .query = "graf Postgres 18", .project = "graf", .as_of = sd.now + 20 * day });
    try std.testing.expect(contains(future.hits, sd.f_graf_pg18));
}

test "search boosts the caller's project and scopes to it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const arena = f.arena.allocator();
    const sd = f.seed;
    const q = "uses Postgres 17 with pgvector for storage";

    const all_graf = try f.engine.search(arena, .{ .query = q, .project = "*" });
    try std.testing.expect(contains(all_graf.hits, sd.f_graf_uses_pg) and contains(all_graf.hits, sd.f_quayline_uses_pg));

    const graf = try f.engine.search(arena, .{ .query = q, .project = "graf" });
    try std.testing.expect(!contains(graf.hits, sd.f_quayline_uses_pg));
    try std.testing.expect(indexOf(graf.hits, sd.f_graf_uses_pg).? < 2);
    const in_all = all_graf.hits[indexOf(all_graf.hits, sd.f_graf_uses_pg).?];
    const in_graf = graf.hits[indexOf(graf.hits, sd.f_graf_uses_pg).?];
    try std.testing.expect(in_graf.score > in_all.score * 1.1);

    const quayline = try f.engine.search(arena, .{ .query = q, .project = "quayline" });
    try std.testing.expect(!contains(quayline.hits, sd.f_graf_uses_pg));
    try std.testing.expect(indexOf(quayline.hits, sd.f_quayline_uses_pg).? < 2);

    const global = try f.engine.search(arena, .{ .query = "alice prefers tabs pg.zig", .project = null });
    for (global.hits) |h| try std.testing.expectEqual(core.types.Scope.global, h.fact.scope);
    try std.testing.expect(contains(global.hits, sd.f_alice_prefers_tabs));

    const by_harness = try f.engine.search(arena, .{ .query = "pg.zig COPY support", .project = "graf", .include_history = true, .harness = .codex });
    try std.testing.expectEqual(@as(usize, 1), by_harness.hits.len);
    try std.testing.expect(by_harness.hits[0].fact.id.eql(sd.f_pgzig_lacks_copy));
    try std.testing.expectEqual(core.Harness.codex, by_harness.hits[0].harness.?);
}

test "search falls back to deterministic order when the reranker is slow" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const arena = f.arena.allocator();
    const sd = f.seed;
    const q = "what does graf use for storage";

    var favor: FavoringReranker = .{ .favorite = "beta", .io = std.testing.io };
    f.engine.reranker = favor.reranker();
    const fast = try f.engine.search(arena, .{ .query = q, .project = "graf" });
    try std.testing.expect(fast.reranked);
    try std.testing.expect(fast.hits[0].fact.id.eql(sd.f_graf_status));

    f.config.decision.rerank_timeout_ms = 100;
    favor.delay_ms = 3_000;
    const start = std.Io.Timestamp.now(std.testing.io, .awake);
    const slow = try f.engine.search(arena, .{ .query = q, .project = "graf" });
    const elapsed_ms = @divFloor(start.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds, std.time.ns_per_ms);
    try std.testing.expect(!slow.reranked);
    try std.testing.expect(elapsed_ms < 1_500);
    f.engine.reranker = null;
    const plain = try f.engine.search(arena, .{ .query = q, .project = "graf" });
    try std.testing.expectEqual(plain.hits.len, slow.hits.len);
    for (plain.hits, slow.hits) |a, b| try std.testing.expect(a.fact.id.eql(b.fact.id));
}

test "search without an embedder uses the lexical and entity arms" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.engine.embedder = null;
    const res = try f.engine.search(f.arena.allocator(), .{ .query = "tell me about pg-zig", .project = "graf" });
    try std.testing.expect(contains(res.hits, f.seed.f_pgzig_supports_copy));
    var out: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try mod.render(&res, .{ .query = "tell me about pg-zig", .project = "graf" }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "### pg.zig (software)") != null);
}

test "entity resolves aliases and walks two hops" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const arena = f.arena.allocator();
    const sd = f.seed;

    const pg = try f.engine.entity(arena, .{ .name_or_id = "PostgreSQL", .depth = 2 });
    try std.testing.expect(pg.entity.entity.id.eql(sd.postgres));
    try std.testing.expect(contains(pg.facts, sd.f_graf_uses_pg));
    try std.testing.expect(contains(pg.facts, sd.f_quayline_uses_pg));
    try std.testing.expect(!contains(pg.facts, sd.f_graf_pg18));
    var found_status = false;
    for (pg.neighbors) |n| if (n.entity.id.eql(sd.graf)) {
        found_status = contains(n.facts, sd.f_graf_status);
    };
    try std.testing.expect(found_status);

    const one_hop = try f.engine.entity(arena, .{ .name_or_id = "postgres" });
    for (one_hop.neighbors) |n| try std.testing.expectEqual(@as(usize, 0), n.facts.len);

    var id_buf: [36]u8 = undefined;
    const by_id = try f.engine.entity(arena, .{ .name_or_id = sd.pgzig.toString(&id_buf), .include_history = true });
    try std.testing.expect(contains(by_id.facts, sd.f_pgzig_lacks_copy));
    const fuzzy = try f.engine.entity(arena, .{ .name_or_id = "pg zig drivr" });
    try std.testing.expect(fuzzy.entity.entity.id.eql(sd.pgzig));
    try std.testing.expectError(error.EntityNotFound, f.engine.entity(arena, .{ .name_or_id = "nothing like this" }));

    var out: std.Io.Writer.Allocating = .init(arena);
    try mod.renderEntity(&by_id, .{ .name_or_id = "pg.zig", .include_history = true }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Aliases: the zig postgres driver") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(changed) | conf 0.80 | codex] pg.zig lacks COPY support.") != null);
}

test "forget closes system time and asks before forgetting several facts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const arena = f.arena.allocator();
    const sd = f.seed;

    const many = try f.engine.forget(arena, .{ .query = "Postgres" });
    try std.testing.expect(many.forgotten.len == 0 and many.candidates.len >= 2);

    const one = try f.engine.forget(arena, .{ .query = "tabs over spaces", .reason = "no longer true" });
    try std.testing.expectEqual(@as(usize, 1), one.forgotten.len);
    try std.testing.expect(one.forgotten[0].fact.id.eql(sd.f_alice_prefers_tabs));
    const after = try f.engine.search(arena, .{ .query = "alice prefers tabs", .project = "graf" });
    try std.testing.expect(!contains(after.hits, sd.f_alice_prefers_tabs));
    const again = try f.engine.forget(arena, .{ .fact_id = sd.f_alice_prefers_tabs });
    try std.testing.expectEqual(@as(usize, 0), again.forgotten.len);

    var row = (try f.s.pool.row("SELECT end_kind, (SELECT quote FROM fact_evidence WHERE fact_id = $1 AND kind = 'forgotten') FROM fact WHERE id = $1", .{&sd.f_alice_prefers_tabs.bytes})).?;
    defer row.deinit() catch {};
    try std.testing.expectEqualStrings("forgotten", try row.get([]const u8, 0));
    try std.testing.expectEqualStrings("no longer true", try row.get([]const u8, 1));
}

test "brief is deterministic, bounded and fast" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const arena = f.arena.allocator();

    const io = std.testing.io;
    const cold_start = std.Io.Timestamp.now(io, .awake);
    const b = try f.engine.brief(arena, "graf");
    const cold_ms = @divFloor(cold_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms);
    try std.testing.expect(cold_ms < 150);
    try std.testing.expect(render.estimateTokens(b.len) <= mod.brief_tokens);
    try std.testing.expect(std.mem.indexOf(u8, b, "### Standing preferences\n- [current | conf 0.90] alice prefers tabs") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "graf uses Postgres 17") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "chose | conf 0.90] graf chose Postgres over a graph database. (why: pgvector") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "SQLite") == null);
    try std.testing.expect(std.mem.indexOf(u8, b, "Postgres 18") == null);
    try std.testing.expect(std.mem.indexOf(u8, b, "quayline") == null);

    var samples: [200]i96 = undefined;
    for (&samples) |*s| {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        const t0 = std.Io.Timestamp.now(io, .awake);
        const again = try f.engine.brief(a.allocator(), "graf");
        s.* = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
        try std.testing.expectEqualStrings(b, again);
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    try std.testing.expect(samples[samples.len * 99 / 100] < 150 * std.time.ns_per_ms);

    var fresh = mod.Engine.init(std.testing.allocator, io, &f.s, &f.config, f.seed.graph, .{});
    defer fresh.deinit();
    try std.testing.expectEqualStrings(b, try fresh.brief(arena, "graf"));

    _ = try f.engine.forget(arena, .{ .fact_id = f.seed.f_alice_prefers_tabs });
    try f.engine.refreshBriefs();
    try std.testing.expect(std.mem.indexOf(u8, try f.engine.brief(arena, "graf"), "tabs") == null);
    const unknown = try f.engine.brief(arena, "unknown-project");
    try std.testing.expect(std.mem.indexOf(u8, unknown, "### Project") == null);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "graf uses") == null);
}

test "recall merges the warmed cache and never repeats a fact" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const arena = f.arena.allocator();

    try f.engine.warm("s1", "storage engine for graf", "graf");
    const embeds = f.embedder.calls;
    const first = try f.engine.recall(arena, "s1", "is pg-zig able to do COPY", "graf");
    try std.testing.expectEqual(embeds, f.embedder.calls);
    try std.testing.expect(std.mem.indexOf(u8, first, "pg.zig supports COPY") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "graf uses Postgres 17") != null);
    try std.testing.expect(render.estimateTokens(first.len) <= mod.recall_tokens);
    const second = try f.engine.recall(arena, "s1", "is pg-zig able to do COPY", "graf");
    try std.testing.expect(std.mem.indexOf(u8, second, "pg.zig supports COPY") == null);
    const other = try f.engine.recall(arena, "s2", "is pg-zig able to do COPY", "graf");
    try std.testing.expect(std.mem.indexOf(u8, other, "pg.zig supports COPY") != null);
    try std.testing.expectEqualStrings("", try f.engine.recall(arena, "s3", "zzzz qqqq", "graf"));
}
