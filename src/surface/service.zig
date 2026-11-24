const std = @import("std");
const core = @import("core");
const retrieve = @import("retrieve");
const api = @import("api.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.service);

pub const remember_wait_ms = 8_000;

pub const Flusher = struct {
    ptr: *anyopaque,
    flushFn: *const fn (ptr: *anyopaque, req: FlushRequest) anyerror!bool,

    pub fn flush(f: Flusher, req: FlushRequest) !bool {
        return f.flushFn(f.ptr, req);
    }
};

pub const FlushRequest = struct {
    harness: ?core.Harness = null,
    session_id: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

pub const Service = struct {
    gpa: Allocator,
    io: Io,
    engine: *retrieve.Engine,
    sink: ?core.EntrySink,
    flusher: ?Flusher = null,
    remember_harness: core.Harness = .mcp,
    background: Io.Group = .init,

    pub fn handler(s: *Service) api.Handler {
        return .{ .ptr = s, .vtable = &.{ .handle = handleErased } };
    }

    pub fn deinit(s: *Service) void {
        s.background.cancel(s.io);
    }

    fn handleErased(ptr: *anyopaque, arena: Allocator, req: api.Request) anyerror!api.Reply {
        const s: *Service = @ptrCast(@alignCast(ptr));
        return s.handle(arena, req) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| e,
            error.EntityNotFound => api.errorReply(arena, 404, "no entity matches that name or id"),
            error.NotImplemented => api.errorReply(arena, 501, "this operation is not available in this build yet"),
            error.NoEntrySink => api.errorReply(arena, 503, "this process cannot accept writes"),
            error.InvalidTimestamp => api.errorReply(arena, 400, "timestamps must be ISO 8601, e.g. 2026-11-23 or 2026-11-23T10:00:00Z"),
            error.MissingForgetTarget => api.errorReply(arena, 400, "pass fact_id or query"),
            error.MissingSessionId => api.errorReply(arena, 400, "missing session id"),
            error.InvalidId => api.errorReply(arena, 400, "invalid fact_id"),
            error.EmptyText => api.errorReply(arena, 400, "text must not be empty"),
            else => if (isInputError(err))
                api.errorReply(arena, 400, try std.fmt.allocPrint(arena, "invalid arguments: {s}", .{@errorName(err)}))
            else
                err,
        };
    }

    fn handle(s: *Service, arena: Allocator, req: api.Request) !api.Reply {
        return switch (req.op) {
            .search => s.search(arena, try parse(SearchInput, arena, req.body)),
            .entity => s.entity(arena, try parse(EntityInput, arena, req.body)),
            .remember => s.remember(arena, try parse(RememberInput, arena, req.body)),
            .forget => s.forget(arena, try parse(ForgetInput, arena, req.body)),
            .entries => s.entries(arena, try parse(core.EntryDraft, arena, req.body)),
            .brief => s.brief(arena, try parse(ProjectInput, arena, req.body)),
            .flush => s.flush(arena, try parse(FlushRequest, arena, req.body)),
            .warm => s.warm(arena, req.session_id orelse return error.MissingSessionId, try parse(PromptInput, arena, req.body)),
            .recall => s.recall(arena, req.session_id orelse return error.MissingSessionId, try parse(PromptInput, arena, req.body)),
        };
    }

    const SearchInput = struct {
        query: []const u8,
        project: ?[]const u8 = null,
        as_of: ?[]const u8 = null,
        known_at: ?[]const u8 = null,
        include_history: bool = false,
        harness: ?core.Harness = null,
        max_tokens: ?u32 = null,
    };

    const FactOut = struct {
        id: core.Id,
        subject: []const u8,
        relation: []const u8,
        object: []const u8,
        text: []const u8,
        rationale: ?[]const u8,
        project: ?[]const u8,
        scope: core.types.Scope,
        valid_from: ?core.Micros,
        valid_to: ?core.Micros,
        known_from: ?core.Micros,
        known_to: ?core.Micros,
        end_kind: ?core.types.EndKind,
        author: core.types.FactAuthor,
        confidence: f32,
        harness: ?core.Harness,
        score: f64,

        fn from(h: retrieve.Hit) FactOut {
            const f = h.fact;
            return .{
                .id = f.id,
                .subject = h.subject_name,
                .relation = f.relation,
                .object = switch (f.object) {
                    .entity => h.object_name orelse "",
                    .value => |v| v,
                },
                .text = f.text,
                .rationale = f.rationale,
                .project = f.project,
                .scope = f.scope,
                .valid_from = f.valid.lower,
                .valid_to = f.valid.upper,
                .known_from = f.known.lower,
                .known_to = f.known.upper,
                .end_kind = f.end_kind,
                .author = f.author,
                .confidence = f.confidence,
                .harness = h.harness,
                .score = h.score,
            };
        }
    };

    fn facts(arena: Allocator, hits: []const retrieve.Hit) ![]const FactOut {
        const out = try arena.alloc(FactOut, hits.len);
        for (hits, out) |h, *o| o.* = .from(h);
        return out;
    }

    fn search(s: *Service, arena: Allocator, in: SearchInput) !api.Reply {
        const params: retrieve.SearchParams = .{
            .query = in.query,
            .project = in.project orelse "*",
            .as_of = try optTime(in.as_of),
            .known_at = try optTime(in.known_at),
            .include_history = in.include_history,
            .harness = in.harness,
            .max_tokens = clampTokens(in.max_tokens orelse 1500),
        };
        const result = try s.engine.search(arena, params);
        var text: Io.Writer.Allocating = .init(arena);
        try retrieve.render(&result, params, &text.writer);
        return ok(arena, .{ .text = text.written(), .reranked = result.reranked, .facts = try facts(arena, result.hits) });
    }

    const EntityInput = struct {
        name_or_id: []const u8,
        depth: u8 = 1,
        as_of: ?[]const u8 = null,
        include_history: bool = false,
        include_retracted: bool = false,
        max_tokens: ?u32 = null,
    };

    fn entity(s: *Service, arena: Allocator, in: EntityInput) !api.Reply {
        const params: retrieve.EntityParams = .{
            .name_or_id = in.name_or_id,
            .depth = if (in.depth >= 2) 2 else 1,
            .as_of = try optTime(in.as_of),
            .include_history = in.include_history,
            .include_retracted = in.include_retracted,
            .max_tokens = clampTokens(in.max_tokens orelse 1500),
        };
        const result = try s.engine.entity(arena, params);
        var text: Io.Writer.Allocating = .init(arena);
        try retrieve.renderEntity(&result, params, &text.writer);
        return ok(arena, .{ .text = text.written(), .id = result.entity.entity.id, .name = result.entity.entity.name, .type = result.entity.entity.type, .facts = try facts(arena, result.facts) });
    }

    const RememberInput = struct {
        text: []const u8,
        project: ?[]const u8 = null,
        scope: core.types.Scope = .project,
        valid_from: ?[]const u8 = null,
        wait: bool = true,
    };

    fn remember(s: *Service, arena: Allocator, in: RememberInput) !api.Reply {
        const sink = s.sink orelse return error.NoEntrySink;
        if (std.mem.trim(u8, in.text, " \t\r\n").len == 0) return error.EmptyText;
        const draft: core.EntryDraft = .{
            .kind = .note,
            .project = if (in.scope == .global) null else in.project,
            .author = .user,
            .body = .{ .text = in.text },
            .reference_time = try optTime(in.valid_from) orelse retrieve.time.now(s.io),
        };
        const id = switch (try sink.enqueue(&draft)) {
            .duplicate => return ok(arena, .{ .text = "Already remembered: an identical note is in memory.", .duplicate = true }),
            .queued => |id| id,
        };
        if (in.wait) {
            const deadline = Io.Clock.Timestamp.fromNow(s.io, .{ .raw = .fromMilliseconds(remember_wait_ms), .clock = .awake });
            while (true) {
                const outcome = try s.engine.entryOutcome(arena, id) orelse break;
                switch (outcome.status) {
                    .committed => return rememberReply(arena, id, outcome),
                    .skipped => return ok(arena, .{ .text = "Nothing durable to remember in that note.", .entry_id = id, .status = outcome.status }),
                    .dead => return api.errorReply(arena, 500, "the note could not be processed; see graf doctor"),
                    else => {},
                }
                if (deadline.durationFromNow(s.io).raw.nanoseconds <= 0) break;
                try s.io.sleep(.fromMilliseconds(100), .awake);
            }
        }
        var buf: [36]u8 = undefined;
        return ok(arena, .{ .text = try std.fmt.allocPrint(arena, "Queued as entry {s}; it will be in memory shortly.", .{id.toString(&buf)}), .entry_id = id, .status = core.types.EntryStatus.queued });
    }

    fn rememberReply(arena: Allocator, id: core.Id, o: retrieve.EntryOutcome) !api.Reply {
        var text: Io.Writer.Allocating = .init(arena);
        const w = &text.writer;
        try w.print("Remembered (entry {f}).\n", .{id});
        const groups = [_]struct { []const u8, []const retrieve.Hit }{ .{ "New", o.stated }, .{ "Restated", o.restated }, .{ "Ended", o.ended } };
        for (groups) |g| for (g[1]) |h| try w.print("- {s}: {s} (fact {f})\n", .{ g[0], h.fact.text, h.fact.id });
        if (o.stated.len + o.restated.len == 0) try w.writeAll("No new facts were extracted.\n");
        return ok(arena, .{ .text = text.written(), .entry_id = id, .status = o.status, .created = try facts(arena, o.stated), .restated = try facts(arena, o.restated), .ended = try facts(arena, o.ended) });
    }

    const ForgetInput = struct {
        fact_id: ?[]const u8 = null,
        query: ?[]const u8 = null,
        reason: ?[]const u8 = null,
    };

    fn forget(s: *Service, arena: Allocator, in: ForgetInput) !api.Reply {
        const fact_id: ?core.Id = if (in.fact_id) |f| try core.Id.parse(f) else null;
        const result = try s.engine.forget(arena, .{ .fact_id = fact_id, .query = in.query, .reason = in.reason });
        var text: Io.Writer.Allocating = .init(arena);
        const w = &text.writer;
        if (result.forgotten.len > 0) {
            for (result.forgotten) |h| try w.print("Forgot fact {f}: {s}\n", .{ h.fact.id, h.fact.text });
        } else if (result.candidates.len > 0) {
            try w.writeAll("Several facts match; nothing was forgotten. Call again with one fact_id:\n");
            for (result.candidates) |h| try w.print("- {f}: {s}\n", .{ h.fact.id, h.fact.text });
        } else {
            try w.writeAll("No current fact matches; nothing was forgotten.\n");
        }
        return ok(arena, .{ .text = text.written(), .forgotten = try facts(arena, result.forgotten), .candidates = try facts(arena, result.candidates) });
    }

    fn entries(s: *Service, arena: Allocator, draft: core.EntryDraft) !api.Reply {
        const sink = s.sink orelse return error.NoEntrySink;
        return switch (try sink.enqueue(&draft)) {
            .queued => |id| ok(arena, .{ .id = id }),
            .duplicate => ok(arena, .{ .duplicate = true }),
        };
    }

    const ProjectInput = struct { project: ?[]const u8 = null };

    fn brief(s: *Service, arena: Allocator, in: ProjectInput) !api.Reply {
        return ok(arena, .{ .text = try s.engine.brief(arena, in.project) });
    }

    fn flush(s: *Service, arena: Allocator, in: FlushRequest) !api.Reply {
        const f = s.flusher orelse return .{ .status = 202, .body = "{\"accepted\":true,\"flushed\":false}" };
        const flushed = f.flush(in) catch |err| blk: {
            log.warn("flush failed: {s}", .{@errorName(err)});
            break :blk false;
        };
        _ = arena;
        return .{ .status = 202, .body = if (flushed) "{\"accepted\":true,\"flushed\":true}" else "{\"accepted\":true,\"flushed\":false}" };
    }

    const PromptInput = struct {
        prompt: ?[]const u8 = null,
        project: ?[]const u8 = null,
    };

    const WarmJob = struct {
        session_id: []const u8,
        prompt: []const u8,
        project: ?[]const u8,
    };

    fn warm(s: *Service, arena: Allocator, session_id: []const u8, in: PromptInput) !api.Reply {
        _ = arena;
        const prompt = in.prompt orelse return .{ .status = 202, .body = "{\"accepted\":false}" };
        const job = try s.gpa.create(WarmJob);
        errdefer s.gpa.destroy(job);
        job.* = .{
            .session_id = try s.gpa.dupe(u8, session_id),
            .prompt = try s.gpa.dupe(u8, prompt),
            .project = if (in.project) |p| try s.gpa.dupe(u8, p) else null,
        };
        s.background.concurrent(s.io, warmTask, .{ s, job }) catch {
            warmTask(s, job) catch {};
        };
        return .{ .status = 202, .body = "{\"accepted\":true}" };
    }

    fn warmTask(s: *Service, job: *WarmJob) Io.Cancelable!void {
        defer {
            s.gpa.free(job.session_id);
            s.gpa.free(job.prompt);
            if (job.project) |p| s.gpa.free(p);
            s.gpa.destroy(job);
        }
        s.engine.warm(job.session_id, job.prompt, job.project orelse "*") catch |err| {
            if (err == error.Canceled) return error.Canceled;
            log.warn("warming session recall failed: {s}", .{@errorName(err)});
        };
    }

    fn recall(s: *Service, arena: Allocator, session_id: []const u8, in: PromptInput) !api.Reply {
        const prompt = in.prompt orelse return ok(arena, .{ .text = "" });
        return ok(arena, .{ .text = try s.engine.recall(arena, session_id, prompt, in.project orelse "*") });
    }
};

pub const DefaultProject = struct {
    inner: api.Handler,
    project: []const u8,

    pub fn handler(d: *DefaultProject) api.Handler {
        return .{ .ptr = d, .vtable = &.{ .handle = handle } };
    }

    fn handle(ptr: *anyopaque, arena: Allocator, req: api.Request) anyerror!api.Reply {
        const d: *DefaultProject = @ptrCast(@alignCast(ptr));
        switch (req.op) {
            .search, .remember, .brief, .warm, .recall => {},
            else => return d.inner.handle(arena, req),
        }
        var value = std.json.parseFromSliceLeaky(std.json.Value, arena, req.body, .{}) catch return d.inner.handle(arena, req);
        if (value != .object or value.object.contains("project")) return d.inner.handle(arena, req);
        if (req.op == .remember) if (value.object.get("scope")) |sc| if (sc == .string and std.mem.eql(u8, sc.string, "global")) return d.inner.handle(arena, req);
        try value.object.put(arena, "project", .{ .string = d.project });
        var patched = req;
        patched.body = try std.json.Stringify.valueAlloc(arena, value, .{});
        return d.inner.handle(arena, patched);
    }
};

fn parse(comptime T: type, arena: Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, if (body.len == 0) "{}" else body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn isInputError(err: anyerror) bool {
    const names = [_][]const u8{ "SyntaxError", "UnexpectedEndOfInput", "UnexpectedToken", "InvalidNumber", "Overflow", "InvalidCharacter", "InvalidEnumTag", "DuplicateField", "UnknownField", "MissingField", "LengthMismatch", "BufferUnderrun", "ValueTooLong" };
    for (names) |n| if (std.mem.eql(u8, n, @errorName(err))) return true;
    return false;
}

fn optTime(s: ?[]const u8) !?core.Micros {
    const t = s orelse return null;
    if (t.len == 0) return null;
    return try retrieve.time.parseIso(t);
}

fn clampTokens(n: u32) u32 {
    return std.math.clamp(n, 100, retrieve.max_tokens_limit);
}

fn ok(arena: Allocator, value: anytype) !api.Reply {
    return .{ .body = try std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false }) };
}
