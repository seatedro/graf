//! Storage: Postgres schema and migrations, the episode queue and leases,
//! the fenced commit, the LLM cost ledger, and managed local Postgres (`graf init`).
//! See AGENTS.md for ownership.

const std = @import("std");
const core = @import("core");
pub const pg = @import("pg");
pub const migrations = @import("migrations.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    pool: *pg.Pool,

    pub const OpenOptions = struct {
        pool_size: u16 = 4,
    };

    /// Connects to `url` (`postgres://user:pass@host:port/db`).
    pub fn open(io: std.Io, allocator: std.mem.Allocator, url: []const u8, opts: OpenOptions) !Store {
        const uri = try std.Uri.parse(url);
        const pool = try pg.Pool.initUri(io, allocator, uri, .{ .size = opts.pool_size });
        return .{ .allocator = allocator, .pool = pool };
    }

    pub fn close(s: *Store) void {
        s.pool.deinit();
        s.* = undefined;
    }

    /// Applies any pending embedded migrations. Safe to run concurrently.
    pub fn migrate(s: *Store) !migrations.Report {
        return migrations.run(s.allocator, s.pool);
    }

    /// Returns the graph's id, creating it (and seeding the core predicates) if needed.
    pub fn ensureGraph(s: *Store, name: []const u8) !core.Id {
        _ = s;
        _ = name;
        return core.NotImplemented;
    }

    /// Inserts a queued episode and advances its source cursor in one transaction,
    /// then `NOTIFY graf_queue`. A repeated content hash is a no-op.
    pub fn enqueue(s: *Store, graph_id: core.Id, draft: *const core.EpisodeDraft) !core.EpisodeSink.Outcome {
        _ = s;
        _ = graph_id;
        _ = draft;
        return core.NotImplemented;
    }

    /// Claims the next eligible episode (per-source ordering, `FOR UPDATE SKIP LOCKED`)
    /// and mints a lease.
    pub fn claim(s: *Store, arena: std.mem.Allocator, graph_id: core.Id, worker: []const u8) !?Lease {
        _ = s;
        _ = arena;
        _ = graph_id;
        _ = worker;
        return core.NotImplemented;
    }

    /// Persists a validated extraction result (`status = extracted`). The JSON is opaque here.
    pub fn saveExtraction(s: *Store, lease: Lease, extraction_json: []const u8) !void {
        _ = s;
        _ = lease;
        _ = extraction_json;
        return core.NotImplemented;
    }

    /// Persists a staged change set (`status = staged`).
    pub fn saveChangeSet(s: *Store, lease: Lease, change_set: *const core.ChangeSet) !void {
        _ = s;
        _ = lease;
        _ = change_set;
        return core.NotImplemented;
    }

    /// The fenced commit: advisory lock, lease fence, optional
    /// rebase through `rebase` when `commit_log` moved past `base_seq`, batched
    /// apply, `commit_log` row, `NOTIFY graf_commit`.
    pub fn commit(s: *Store, lease: Lease, change_set: *const core.ChangeSet, rebase: ?Rebase) !CommitResult {
        _ = s;
        _ = lease;
        _ = change_set;
        _ = rebase;
        return core.NotImplemented;
    }

    /// The `EpisodeSink` capture writes into, bound to one graph.
    pub fn sink(s: *Store, graph_id: core.Id) core.EpisodeSink {
        _ = s;
        _ = graph_id;
        @panic("Store.sink is not implemented yet");
    }

    /// The `LlmLedger` the LLM client writes into.
    pub fn ledger(s: *Store) core.LlmLedger {
        _ = s;
        @panic("Store.ledger is not implemented yet");
    }
};

/// A claimed episode plus its fencing token.
pub const Lease = struct {
    episode_id: core.Id,
    graph_id: core.Id,
    token: i64,
    episode: core.Episode,
    /// Validated extraction output if a previous attempt already paid for it.
    extraction_json: ?[]const u8 = null,
};

/// Called inside the commit lock when other commits landed after `base_seq`. Must
/// be deterministic and make no network calls; it may rewrite the change set.
pub const Rebase = struct {
    ptr: *anyopaque,
    run: *const fn (ptr: *anyopaque, conn: *pg.Conn, change_set: *core.ChangeSet, base_seq: i64, latest_seq: i64) anyerror!void,
};

pub const CommitResult = union(enum) {
    committed: struct { seq: i64 },
    /// Lease lost or already committed; nothing was written.
    fenced,
};

/// Test helpers for integration tests in any module.
pub const testing = struct {
    /// `GRAF_TEST_DATABASE_URL`, or null when unset (integration tests then skip).
    pub fn databaseUrl() ?[]const u8 {
        const url = std.testing.environ.getPosix("GRAF_TEST_DATABASE_URL") orelse return null;
        return if (url.len == 0) null else url;
    }

    /// Opens a store on the test database with migrations applied, or skips the test.
    pub fn open() !Store {
        const url = databaseUrl() orelse return error.SkipZigTest;
        var s = try Store.open(std.testing.io, std.testing.allocator, url, .{ .pool_size = 2 });
        errdefer s.close();
        _ = try s.migrate();
        return s;
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = migrations;
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
