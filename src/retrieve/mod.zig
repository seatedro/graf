const std = @import("std");
const core = @import("core");
const store = @import("store");
const llm = @import("llm");

pub const time = @import("time.zig");
pub const rank = @import("rank.zig");
pub const render_ = @import("render.zig");
const db = @import("db.zig");
const search_ = @import("search.zig");
const entity_ = @import("entity.zig");
const brief_ = @import("brief.zig");
const recall_ = @import("recall.zig");
const outcome_ = @import("outcome.zig");

pub const testing = @import("tests.zig");
pub const Hit = db.Hit;
pub const render = render_.render;
pub const renderEntity = render_.renderEntity;
pub const estimateTokens = render_.estimateTokens;
pub const EntityResult = entity_.EntityResult;
pub const ForgetResult = entity_.ForgetResult;
pub const RecallCache = recall_.RecallCache;
pub const EntryOutcome = outcome_.EntryOutcome;
pub const ForgetTarget = entity_.ForgetTarget;

pub const SearchParams = struct {
    query: []const u8,
    project: ?[]const u8 = null,
    as_of: ?core.Micros = null,
    known_at: ?core.Micros = null,
    include_history: bool = false,
    harness: ?core.Harness = null,
    max_tokens: u32 = 1500,
};

pub const EntityParams = struct {
    name_or_id: []const u8,
    depth: u2 = 1,
    as_of: ?core.Micros = null,
    include_history: bool = false,
    include_retracted: bool = false,
    max_tokens: u32 = 1500,
};

pub const SearchResult = struct {
    hits: []const Hit,
    entities: []const core.Entity,
    reranked: bool,
    as_of: core.Micros = 0,
};

pub const max_tokens_limit = 4000;
pub const brief_tokens = 800;
pub const recall_tokens = 400;

pub const Embedder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        embedQuery: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, query: []const u8) anyerror![]const f32,
    };

    pub fn embedQuery(e: Embedder, arena: std.mem.Allocator, query: []const u8) ![]const f32 {
        return e.vtable.embedQuery(e.ptr, arena, query);
    }
};

pub const Reranker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        score: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, query: []const u8, candidates: []const []const u8) anyerror![]const f64,
    };

    pub fn score(r: Reranker, arena: std.mem.Allocator, query: []const u8, candidates: []const []const u8) anyerror![]const f64 {
        return r.vtable.score(r.ptr, arena, query, candidates);
    }
};

pub const LlmBackend = struct {
    client: *llm.Client,

    pub fn embedder(b: *LlmBackend) Embedder {
        return .{ .ptr = b, .vtable = &.{ .embedQuery = embedQuery } };
    }

    pub fn reranker(b: *LlmBackend) ?Reranker {
        if (!b.client.config.decisionEnabled()) return null;
        return .{ .ptr = b, .vtable = &.{ .score = score } };
    }

    fn embedQuery(ptr: *anyopaque, arena: std.mem.Allocator, query: []const u8) anyerror![]const f32 {
        const b: *LlmBackend = @ptrCast(@alignCast(ptr));
        const res = try b.client.embed(arena, .{ .purpose = .embed_query, .inputs = &.{query}, .priority = .interactive });
        if (res.vectors.len != 1) return error.UnexpectedEmbeddingCount;
        return res.vectors[0];
    }

    fn score(ptr: *anyopaque, arena: std.mem.Allocator, query: []const u8, candidates: []const []const u8) anyerror![]const f64 {
        const b: *LlmBackend = @ptrCast(@alignCast(ptr));
        const questions = try arena.alloc(llm.Question, candidates.len);
        for (candidates, questions) |c, *q| q.* = .{
            .yes_no = try std.fmt.allocPrint(arena, "Query: {s}\nMemory: {s}\nIs this memory relevant to answering the query?", .{ query, c }),
        };
        const answers = try b.client.decide(arena, .rerank, questions);
        const out = try arena.alloc(f64, answers.len);
        for (answers, out) |a, *o| o.* = switch (a) {
            .yes_no => |p| p,
            .choice => return error.UnexpectedDecisionAnswer,
        };
        return out;
    }
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *store.Store,
    config: *const core.Config,
    graph_id: core.Id,
    embedder: ?Embedder = null,
    reranker: ?Reranker = null,
    briefs: brief_.BriefCache = .{},
    sessions: RecallCache = .{},

    pub const Backends = struct {
        embedder: ?Embedder = null,
        reranker: ?Reranker = null,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, s: *store.Store, config: *const core.Config, graph_id: core.Id, backends: Backends) Engine {
        return .{ .gpa = gpa, .io = io, .store = s, .config = config, .graph_id = graph_id, .embedder = backends.embedder, .reranker = backends.reranker };
    }

    pub fn deinit(e: *Engine) void {
        e.briefs.deinit(e.gpa);
        e.sessions.deinit(e.gpa);
        e.* = undefined;
    }

    pub fn search(e: *Engine, arena: std.mem.Allocator, params: SearchParams) !SearchResult {
        return search_.run(e, arena, params, .{});
    }

    pub fn searchInstant(e: *Engine, arena: std.mem.Allocator, params: SearchParams) !SearchResult {
        return search_.run(e, arena, params, .{ .embed = false, .rerank = false });
    }

    pub fn entity(e: *Engine, arena: std.mem.Allocator, params: EntityParams) !EntityResult {
        return entity_.lookup(e, arena, params);
    }

    pub fn forget(e: *Engine, arena: std.mem.Allocator, target: entity_.ForgetTarget) !ForgetResult {
        return entity_.forget(e, arena, target);
    }

    pub fn brief(e: *Engine, arena: std.mem.Allocator, project: ?[]const u8) ![]const u8 {
        return brief_.get(e, arena, project);
    }

    pub fn refreshBriefs(e: *Engine) !void {
        return brief_.refreshAll(e);
    }

    pub fn buildBrief(e: *Engine, arena: std.mem.Allocator, project: ?[]const u8) ![]const u8 {
        return brief_.build(e, arena, project);
    }

    pub fn entryOutcome(e: *Engine, arena: std.mem.Allocator, entry_id: core.Id) !?EntryOutcome {
        return outcome_.get(e, arena, entry_id);
    }

    pub fn warm(e: *Engine, session_id: []const u8, prompt: []const u8, project: ?[]const u8) !void {
        return recall_.warm(e, session_id, prompt, project);
    }

    pub fn recall(e: *Engine, arena: std.mem.Allocator, session_id: []const u8, prompt: []const u8, project: ?[]const u8) ![]const u8 {
        return recall_.recall(e, arena, session_id, prompt, project);
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = time;

    _ = rank;
    _ = render_;
    _ = search_;
    _ = entity_;
    _ = brief_;
    _ = recall_;
    _ = outcome_;
    _ = testing;
}
