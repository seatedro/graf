const std = @import("std");
const core = @import("core");
pub const pg = @import("pg");
pub const migrations = @import("migrations.zig");
pub const managed = @import("managed.zig");
const queue = @import("queue.zig");
const committer = @import("commit.zig");

pub const Id = core.Id;

pub const embedding_dims = 512;

pub const Error = error{
    LeaseLost,
    InvalidEmbedding,
    InvalidDatabaseUrl,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: *pg.Pool,
    lease_ms: u32,
    default_graph: Id = .nil,

    pub const OpenOptions = struct {
        pool_size: u16 = 4,
        lease_ms: u32 = 5 * std.time.ms_per_min,
    };

    pub fn open(io: std.Io, allocator: std.mem.Allocator, url: []const u8, opts: OpenOptions) !Store {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const pool_opts = try poolOptions(arena_state.allocator(), url, opts.pool_size);
        const pool = try pg.Pool.init(io, allocator, pool_opts);
        return .{ .allocator = allocator, .io = io, .pool = pool, .lease_ms = opts.lease_ms };
    }

    pub fn close(s: *Store) void {
        s.pool.deinit();
        s.* = undefined;
    }

    pub fn migrate(s: *Store) !migrations.Report {
        return migrations.run(s.allocator, s.pool);
    }

    pub fn ensureGraph(s: *Store, name: []const u8) !Id {
        return queue.ensureGraph(s, name);
    }

    pub fn enqueue(s: *Store, graph_id: Id, draft: *const core.EpisodeDraft) !core.EpisodeSink.Outcome {
        return queue.enqueue(s, graph_id, draft);
    }

    pub fn loadCursor(s: *Store, arena: std.mem.Allocator, graph_id: Id, source: *const core.SourceKey) !?[]const u8 {
        return queue.loadCursor(s, arena, graph_id, source);
    }

    pub fn claim(s: *Store, arena: std.mem.Allocator, graph_id: Id, worker: []const u8) !?Lease {
        return queue.claim(s, arena, graph_id, worker);
    }

    pub fn heartbeat(s: *Store, lease: Lease) !void {
        return queue.heartbeat(s, lease);
    }

    pub fn saveExtraction(s: *Store, lease: Lease, extraction_json: []const u8) !void {
        return queue.saveExtraction(s, lease, extraction_json);
    }

    pub fn saveChangeSet(s: *Store, lease: Lease, change_set: *const core.ChangeSet) !void {
        return queue.saveChangeSet(s, lease, change_set);
    }

    pub fn commit(s: *Store, lease: Lease, change_set: *const core.ChangeSet, rebase: ?Rebase) !CommitResult {
        return committer.commit(s, lease, change_set, rebase);
    }

    pub fn spentSince(s: *Store, since: core.Micros) !f64 {
        var row = (try s.pool.row(
            "SELECT COALESCE(sum(cost_usd), 0)::float8 FROM llm_call WHERE started_at >= $1",
            .{since},
        )).?;
        defer row.deinit() catch {};
        return row.get(f64, 0);
    }

    pub fn recordCall(s: *Store, call: *const core.LlmCall) !void {
        var id_buf: [16]u8 = call.id.bytes;
        var graph_buf: [16]u8 = call.graph_id.bytes;
        const graph: ?[]const u8 = if (call.graph_id.eql(.nil)) null else &graph_buf;
        var fallback_buf: [16]u8 = s.default_graph.bytes;
        const fallback: ?[]const u8 = if (s.default_graph.eql(.nil)) null else &fallback_buf;
        var ep_buf: [16]u8 = undefined;
        const episode: ?[]const u8 = if (call.episode_id) |e| blk: {
            ep_buf = e.bytes;
            break :blk &ep_buf;
        } else null;
        _ = try s.pool.exec(
            \\INSERT INTO llm_call (id, graph_id, episode_id, purpose, route, model, attempt, outcome,
            \\  error_class, http_status, input_tokens, output_tokens, cache_read_tokens,
            \\  cache_write_tokens, cost_usd, cost_status, latency_ms, started_at)
            \\VALUES ($1, COALESCE($2, (SELECT graph_id FROM episode WHERE id = $3), $19), $3, $4, $5, $6, $7, $8,
            \\  $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
        , .{
            @as([]const u8, &id_buf),   graph,                          episode,
            @tagName(call.purpose),     call.route,                     call.model,
            call.attempt,               if (call.ok) "ok" else "error", call.error_class,
            call.http_status,           call.input_tokens,              call.output_tokens,
            call.cache_read_tokens,     call.cache_write_tokens,        call.cost_usd,
            @tagName(call.cost_status), call.latency_ms,                call.started_at,
            fallback,
        });
    }

    pub fn sink(s: *Store, graph_id: Id) core.EpisodeSink {
        s.default_graph = graph_id;
        return .{ .ptr = s, .vtable = &sink_vtable };
    }

    pub fn ledger(s: *Store) core.LlmLedger {
        return .{ .ptr = s, .vtable = &ledger_vtable };
    }

    const sink_vtable: core.EpisodeSink.VTable = .{
        .enqueue = sinkEnqueue,
        .loadCursor = sinkLoadCursor,
    };

    fn sinkEnqueue(ptr: *anyopaque, draft: *const core.EpisodeDraft) anyerror!core.EpisodeSink.Outcome {
        const s: *Store = @ptrCast(@alignCast(ptr));
        return s.enqueue(s.default_graph, draft);
    }

    fn sinkLoadCursor(ptr: *anyopaque, arena: std.mem.Allocator, source: *const core.SourceKey) anyerror!?[]const u8 {
        const s: *Store = @ptrCast(@alignCast(ptr));
        return s.loadCursor(arena, s.default_graph, source);
    }

    const ledger_vtable: core.LlmLedger.VTable = .{
        .record = ledgerRecord,
        .spentSince = ledgerSpentSince,
    };

    fn ledgerRecord(ptr: *anyopaque, call: *const core.LlmCall) anyerror!void {
        const s: *Store = @ptrCast(@alignCast(ptr));
        return s.recordCall(call);
    }

    fn ledgerSpentSince(ptr: *anyopaque, since: core.Micros) anyerror!f64 {
        const s: *Store = @ptrCast(@alignCast(ptr));
        return s.spentSince(since);
    }
};

pub const Lease = struct {
    episode_id: Id,
    graph_id: Id,
    token: i64,
    episode: core.Episode,
    extraction_json: ?[]const u8 = null,
};

pub const Rebase = struct {
    ptr: *anyopaque,
    run: *const fn (ptr: *anyopaque, conn: *pg.Conn, change_set: *core.ChangeSet, base_seq: i64, latest_seq: i64) anyerror!void,
};

pub const CommitResult = union(enum) {
    committed: struct { seq: i64 },
    fenced,
};

pub fn contentHash(gpa: std.mem.Allocator, draft: *const core.EpisodeDraft) ![32]u8 {
    const Key = struct { harness: core.Harness, external_id: []const u8 };
    const canonical = try std.json.Stringify.valueAlloc(gpa, .{
        .source = if (draft.source) |src| Key{ .harness = src.harness, .external_id = src.external_id } else null,
        .kind = draft.kind,
        .body = draft.body,
    }, .{});
    defer gpa.free(canonical);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &out, .{});
    return out;
}

pub fn normalizeAlias(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (comptime @hasDecl(core, "text") and @hasDecl(core.text, "norm")) return core.text.norm(arena, s);
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    for (s) |c| {
        if (c < 0x80 and !std.ascii.isAlphanumeric(c)) {
            pending_space = out.items.len != 0;
            continue;
        }
        if (pending_space) try out.append(arena, ' ');
        pending_space = false;
        try out.append(arena, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(arena);
}

pub fn vectorLiteral(arena: std.mem.Allocator, v: []const f32) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeByte('[');
    for (v, 0..) |x, i| {
        if (i != 0) try out.writer.writeByte(',');
        try out.writer.print("{d}", .{x});
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

pub fn idFromPg(raw: []const u8) !Id {
    if (raw.len != 16) return error.InvalidId;
    return .{ .bytes = raw[0..16].* };
}

fn poolOptions(arena: std.mem.Allocator, url: []const u8, size: u16) !pg.Pool.Opts {
    const uri = std.Uri.parse(url) catch return error.InvalidDatabaseUrl;
    if (!std.mem.eql(u8, uri.scheme, "postgres") and !std.mem.eql(u8, uri.scheme, "postgresql"))
        return error.InvalidDatabaseUrl;

    var opts: pg.Pool.Opts = .{ .size = size };
    if (uri.user) |u| opts.auth.username = try u.toRawMaybeAlloc(arena);
    if (uri.password) |p| opts.auth.password = try p.toRawMaybeAlloc(arena);
    const path = std.mem.trimStart(u8, try uri.path.toRawMaybeAlloc(arena), "/");
    if (path.len != 0) opts.auth.database = path;
    if (uri.host) |h| opts.connect.host = try h.toRawMaybeAlloc(arena);
    opts.connect.port = uri.port;
    if (uri.query) |q| {
        var it = std.mem.splitScalar(u8, try q.toRawMaybeAlloc(arena), '&');
        while (it.next()) |param| {
            const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
            const key = param[0..eq];
            const val = param[eq + 1 ..];
            if (std.mem.eql(u8, key, "host")) {
                const dir = try percentDecode(arena, val);
                opts.connect.host = if (std.mem.startsWith(u8, std.fs.path.basename(dir), ".s.PGSQL."))
                    dir
                else
                    try managed.socketPath(arena, dir, uri.port);
            } else if (std.mem.eql(u8, key, "sslmode")) {
                if (std.mem.eql(u8, val, "require")) {
                    opts.connect.tls = .require;
                } else if (std.mem.eql(u8, val, "verify-full")) {
                    opts.connect.tls = .{ .verify_full = null };
                }
            }
        }
    }
    return opts;
}

fn percentDecode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const buf = try arena.dupe(u8, s);
    return std.Uri.percentDecodeInPlace(buf);
}

pub const testing = struct {
    pub fn databaseUrl() ?[]const u8 {
        const url = std.testing.environ.getPosix("GRAF_TEST_DATABASE_URL") orelse return null;
        return if (url.len == 0) null else url;
    }

    pub fn open() !Store {
        return openWith(.{ .pool_size = 2 });
    }

    pub fn openWith(opts: Store.OpenOptions) !Store {
        const url = databaseUrl() orelse return error.SkipZigTest;
        var s = try Store.open(std.testing.io, std.testing.allocator, url, opts);
        errdefer s.close();
        _ = try s.migrate();
        return s;
    }

    pub fn freshGraph(s: *Store) !Id {
        var buf: [36]u8 = undefined;
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "test-{s}", .{Id.v7(s.io).toString(&buf)});
        return s.ensureGraph(name);
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = migrations;
    _ = managed;
    _ = @import("seam_test.zig");
    _ = @import("store_test.zig");
}

test "migrations apply, are idempotent, and create halfvec(512) columns" {
    var s = try testing.open();
    defer s.close();
    const again = try s.migrate();
    try std.testing.expectEqual(@as(u32, 0), again.applied);

    var row = (try s.pool.row(
        "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'fact'::regclass AND attname = 'emb'",
        .{},
    )) orelse return error.MissingColumn;
    defer row.deinit() catch {};
    try std.testing.expectEqualStrings("halfvec(512)", try row.get([]const u8, 0));
}

test "normalizeAlias folds case, punctuation and whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("pg zig", try normalizeAlias(a, "pg.zig"));
    try std.testing.expectEqualStrings("pg zig", try normalizeAlias(a, "pg-zig"));
    try std.testing.expectEqualStrings("pg zig", try normalizeAlias(a, " PG_Zig "));
    try std.testing.expectEqualStrings("karlseguin s driver", try normalizeAlias(a, "  Karlseguin's   Driver!"));
}

test "content hash ignores reference time and cursor but not the source" {
    const gpa = std.testing.allocator;
    var a: core.EpisodeDraft = .{
        .source = .{ .harness = .codex, .external_id = "s1" },
        .kind = .note,
        .asserted_by = .user,
        .body = .{ .text = "graf uses Postgres" },
        .reference_time = 1,
        .cursor = "10",
    };
    var b = a;
    b.reference_time = 2;
    b.cursor = "20";
    try std.testing.expectEqual(try contentHash(gpa, &a), try contentHash(gpa, &b));
    b.source = .{ .harness = .codex, .external_id = "s2" };
    try std.testing.expect(!std.mem.eql(u8, &(try contentHash(gpa, &a)), &(try contentHash(gpa, &b))));
}

test "database urls parse into pool options, including a unix socket host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tcp = try poolOptions(arena.allocator(), "postgres://graf:pw@127.0.0.1:54329/graf_test", 3);
    try std.testing.expectEqualStrings("graf", tcp.auth.username);
    try std.testing.expectEqualStrings("pw", tcp.auth.password.?);
    try std.testing.expectEqualStrings("graf_test", tcp.auth.database.?);
    try std.testing.expectEqual(@as(?u16, 54329), tcp.connect.port);
    const unix = try poolOptions(arena.allocator(), "postgres://graf@localhost/graf?host=%2Fhome%2Fu%2F.local%2Fshare%2Fgraf%2Fpg", 3);
    try std.testing.expectEqualStrings("/home/u/.local/share/graf/pg/.s.PGSQL.5432", unix.connect.host.?);
    try std.testing.expectError(error.InvalidDatabaseUrl, poolOptions(arena.allocator(), "mysql://x/y", 1));
}
