const std = @import("std");
const core = @import("core");
const Io = std.Io;

pub const schema_gen = @import("schema_gen.zig");
pub const wire = @import("wire.zig");
pub const classify = @import("classify.zig");
pub const recovery = @import("recovery.zig");
pub const limiter = @import("limiter.zig");
pub const cost = @import("cost.zig");
pub const transport = @import("transport.zig");
pub const decision = @import("decision.zig");
pub const request_deadlines = @import("request_deadlines.zig");

pub const Route = core.config.Route;
pub const ErrorClass = classify.ErrorClass;
pub const DeliveryCertainty = classify.DeliveryCertainty;
pub const Disposition = recovery.Disposition;
pub const Usage = wire.Usage;
pub const Cost = cost.Cost;
pub const Rate = cost.Rate;
pub const Priority = limiter.Priority;
pub const Limiter = limiter.Limiter;
pub const RouteKey = limiter.RouteKey;
pub const Transport = transport.Transport;
pub const Question = decision.Question;
pub const Answer = decision.Answer;
pub const jsonSchema = schema_gen.jsonSchema;

pub const Failure = struct {
    class: ErrorClass,
    certainty: DeliveryCertainty,
    disposition: Disposition = .dead,
    http_status: ?u16 = null,
    retry_after_ms: ?u32 = null,
    message: []const u8 = "",
};

pub const StructuredRequest = struct {
    purpose: core.types.LlmPurpose,
    entry_id: ?core.Id = null,
    system: []const u8,
    user: []const u8,
    schema_name: []const u8,
    schema_json: []const u8,
    priority: Priority = .background,
    max_output_tokens: u32 = 16_384,
    failure: ?*Failure = null,
};

pub const StructuredResponse = struct {
    json: []const u8,
    model: []const u8,
    usage: Usage,
    cost: Cost,
    latency_ms: u32,
    repaired: bool = false,
};

pub fn Typed(comptime T: type) type {
    return struct { value: T, response: StructuredResponse };
}

pub const EmbedRequest = struct {
    purpose: core.types.LlmPurpose,
    entry_id: ?core.Id = null,
    inputs: []const []const u8,
    priority: Priority = .background,
    failure: ?*Failure = null,
};

pub const EmbedResponse = struct {
    vectors: []const []const f32,
    usage: Usage,
    cost: Cost,
};

pub const Error = error{
    ProviderFailed,
    RouteHalted,
    SpendCapReached,
    ModelNotConfigured,
    DecisionDisabled,
    Canceled,
    OutOfMemory,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: *const core.Config,
    ledger: ?core.LlmLedger,
    graph_id: core.Id = .nil,
    limiter: Limiter,
    http: transport.Http,
    transport: ?Transport = null,
    rates: []const []const u8,
    policy: recovery.Policy = .{},
    shutdown: std.atomic.Value(bool) = .init(false),
    last_failure: ?Failure = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: *const core.Config, ledger: ?core.LlmLedger) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .ledger = ledger,
            .limiter = .init(.fromConfig(config), ledger),
            .rates = config.llm.rates,
            .http = .init(allocator, io),
        };
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
        c.* = undefined;
    }

    pub fn cancelAll(c: *Client) void {
        c.shutdown.store(true, .release);
    }

    pub fn resumeRoutes(c: *Client) void {
        c.limiter.resumeRoute(c.io, null);
    }

    pub fn structured(c: *Client, arena: std.mem.Allocator, req: StructuredRequest) Error!StructuredResponse {
        return c.runStructured(arena, req, validateObject, .original, null);
    }

    pub fn structuredAs(c: *Client, comptime T: type, arena: std.mem.Allocator, req: StructuredRequest) Error!Typed(T) {
        const response = try c.runStructured(arena, req, Validator(T).validate, .original, null);
        const value = std.json.parseFromSliceLeaky(T, arena, response.json, parse_options) catch return error.ProviderFailed;
        return .{ .value = value, .response = response };
    }

    pub fn repair(c: *Client, arena: std.mem.Allocator, req: StructuredRequest, broken: []const u8, problem: []const u8) Error!StructuredResponse {
        return c.runStructured(arena, req, validateObject, .repair, .{ .broken = broken, .problem = problem });
    }

    pub fn embed(c: *Client, arena: std.mem.Allocator, req: EmbedRequest) Error!EmbedResponse {
        const cfg = c.config.embed;
        if (cfg.model.len == 0) return error.ModelNotConfigured;
        if (req.inputs.len == 0) return .{ .vectors = &.{}, .usage = .{}, .cost = .{} };
        var body: Io.Writer.Allocating = .init(arena);
        wire.writeEmbedRequest(cfg.model, req.inputs, cfg.dimensions, &body.writer) catch return error.OutOfMemory;
        var tokens: usize = 0;
        for (req.inputs) |s| tokens += s.len / 4 + 1;

        const Ctx = struct {
            arena: std.mem.Allocator,
            n: usize,
            dims: u32,
            out: EmbedResponse = undefined,

            fn decode(ctx: *@This(), res: transport.Response) Decoded {
                const d = wire.decodeEmbeddings(ctx.arena, res.body, ctx.n, ctx.dims) catch |err| return .{ .malformed = err };
                ctx.out = .{ .vectors = d.vectors, .usage = d.usage, .cost = .{} };
                return .{ .ok = .{ .usage = d.usage, .body_cost = d.body_cost, .body_cost_status = d.body_cost_status, .model = null } };
            }
        };
        var ctx: Ctx = .{ .arena = arena, .n = req.inputs.len, .dims = cfg.dimensions };
        const out = try c.run(arena, .{
            .key = .embeddings,
            .route_name = "embeddings",
            .model = cfg.model,
            .url = try joinUrl(arena, cfg.base_url, "/embeddings"),
            .headers = try bearer(arena, cfg.api_key),
            .cost_header = cfg.cost_header,
            .purpose = req.purpose,
            .entry_id = req.entry_id,
            .priority = req.priority,
            .input_tokens = std.math.cast(u32, tokens) orelse std.math.maxInt(u32),
            .bounds = c.bounds(),
            .failure = req.failure,
        }, body.written(), null, &ctx, Ctx.decode);
        ctx.out.cost = out.cost;
        return ctx.out;
    }

    pub fn decide(c: *Client, arena: std.mem.Allocator, purpose: core.types.LlmPurpose, questions: []const Question) Error![]const Answer {
        if (!c.config.decisionEnabled()) return error.DecisionDisabled;
        const cfg = c.config.decision;
        if (questions.len == 0) return &.{};
        var body: Io.Writer.Allocating = .init(arena);
        decision.writeRequest(cfg.model, questions, &body.writer) catch return error.OutOfMemory;
        var tokens: usize = 0;
        for (questions) |q| tokens += q.promptLen() / 4 + 1;

        const Ctx = struct {
            arena: std.mem.Allocator,
            questions: []const Question,
            answers: []const Answer = &.{},

            fn decode(ctx: *@This(), res: transport.Response) Decoded {
                const d = decision.decodeResponse(ctx.arena, res.body, ctx.questions) catch |err| return .{ .invalid = @errorName(err) };
                ctx.answers = d.answers;
                return .{ .ok = .{ .usage = d.usage, .body_cost = d.body_cost, .body_cost_status = d.body_cost_status, .model = null } };
            }
        };
        var ctx: Ctx = .{ .arena = arena, .questions = questions };
        const interactive = purpose == .rerank;
        var call: Call = .{
            .key = .@"typed-decisions",
            .route_name = "typed-decisions",
            .model = cfg.model,
            .url = try joinUrl(arena, cfg.base_url, cfg.path),
            .headers = try bearer(arena, cfg.api_key),
            .cost_header = c.config.llm.cost_header,
            .purpose = purpose,
            .priority = if (interactive) .interactive else .background,
            .input_tokens = std.math.cast(u32, tokens) orelse std.math.maxInt(u32),
            .bounds = c.bounds(),
        };
        if (interactive) {
            const t = cfg.rerank_timeout_ms;
            call.bounds = .{ .connect_ms = t, .first_response_ms = t, .stall_ms = t };
            call.total_ms = t;
            call.policy = .{ .transient_backoff_ms = &.{}, .rate_limit_backoff_ms = &.{}, .max_retry_after_ms = 0 };
        }
        _ = try c.run(arena, call, body.written(), null, &ctx, Ctx.decode);
        return ctx.answers;
    }

    const RepairInput = struct { broken: []const u8, problem: []const u8 };

    fn runStructured(
        c: *Client,
        arena: std.mem.Allocator,
        req: StructuredRequest,
        validate: *const fn (std.mem.Allocator, []const u8) ?[]const u8,
        phase: recovery.Phase,
        repair_input: ?RepairInput,
    ) Error!StructuredResponse {
        const cfg = c.config.llm;
        if (cfg.model.len == 0) return error.ModelNotConfigured;
        const route = cfg.route;
        const prompt: wire.Prompt = .{
            .model = cfg.model,
            .system = req.system,
            .user = req.user,
            .schema_name = req.schema_name,
            .schema_json = req.schema_json,
            .max_output_tokens = req.max_output_tokens,
        };
        const original = if (phase == .original) try requestBody(arena, route, prompt) else "";
        const preset_repair = if (repair_input) |r| try repairBody(arena, route, prompt, r.broken, r.problem) else null;

        const Ctx = struct {
            arena: std.mem.Allocator,
            route: Route,
            prompt: wire.Prompt,
            validate: *const fn (std.mem.Allocator, []const u8) ?[]const u8,
            text: []const u8 = "",
            model: []const u8 = "",
            repair_body: ?[]const u8 = null,

            fn decode(ctx: *@This(), res: transport.Response) Decoded {
                const d = wire.decodeStructured(ctx.route, ctx.arena, res.body) catch |err| return .{ .malformed = err };
                const ok: Decoded.Ok = .{ .usage = d.usage, .body_cost = d.body_cost, .body_cost_status = d.body_cost_status, .model = d.model };
                switch (d.stop) {
                    .truncated => return .{ .truncated = ok },
                    .refused => return .{ .refused = .{ .ok = ok, .detail = d.detail } },
                    .complete => {},
                }
                ctx.text = d.text;
                ctx.model = d.model orelse ctx.prompt.model;
                if (ctx.validate(ctx.arena, d.text)) |problem| {
                    ctx.repair_body = repairBody(ctx.arena, ctx.route, ctx.prompt, d.text, problem) catch null;
                    return .{ .needs_repair = ok };
                }
                return .{ .ok = ok };
            }
        };
        var ctx: Ctx = .{ .arena = arena, .route = route, .prompt = prompt, .validate = validate, .repair_body = preset_repair };
        const out = try c.run(arena, .{
            .key = .of(route),
            .route_name = @tagName(route),
            .model = cfg.model,
            .url = try joinUrl(arena, cfg.base_url, wire.path(route)),
            .headers = try routeHeaders(arena, route, cfg.api_key),
            .cost_header = cfg.cost_header,
            .purpose = req.purpose,
            .entry_id = req.entry_id,
            .priority = req.priority,
            .input_tokens = std.math.cast(u32, (req.system.len + req.user.len) / 4 + 1) orelse std.math.maxInt(u32),
            .bounds = c.bounds(),
            .failure = req.failure,
            .start_phase = phase,
        }, original, &ctx.repair_body, &ctx, Ctx.decode);
        return .{
            .json = ctx.text,
            .model = ctx.model,
            .usage = out.usage,
            .cost = out.cost,
            .latency_ms = out.latency_ms,
            .repaired = out.repaired,
        };
    }

    const Decoded = union(enum) {
        ok: Ok,
        needs_repair: Ok,
        truncated: Ok,
        refused: struct { ok: Ok, detail: []const u8 },
        malformed: anyerror,
        invalid: []const u8,

        const Ok = struct {
            usage: Usage,
            body_cost: ?f64,
            body_cost_status: ?core.types.CostStatus,
            model: ?[]const u8,
        };
    };

    const Call = struct {
        key: RouteKey,
        route_name: []const u8,
        model: []const u8,
        url: []const u8,
        headers: []const std.http.Header,
        cost_header: []const u8,
        purpose: core.types.LlmPurpose,
        entry_id: ?core.Id = null,
        priority: Priority,
        input_tokens: u32,
        bounds: transport.Bounds,
        total_ms: u64 = request_deadlines.never,
        failure: ?*Failure = null,
        start_phase: recovery.Phase = .original,
        policy: ?recovery.Policy = null,
    };

    const Outcome = struct { usage: Usage, cost: Cost, latency_ms: u32, repaired: bool };

    fn run(
        c: *Client,
        arena: std.mem.Allocator,
        call: Call,
        original_body: []const u8,
        repair_body: ?*const ?[]const u8,
        ctx: anytype,
        comptime decode: fn (@TypeOf(ctx), transport.Response) Decoded,
    ) Error!Outcome {
        const io = c.io;
        const t = c.transport orelse c.http.transport();
        var seed: u64 = undefined;
        io.random(std.mem.asBytes(&seed));
        var state = recovery.State.init(seed);
        state.policy = call.policy orelse c.policy;
        state.phase = call.start_phase;
        var action = recovery.step(&state, .start, limiter.nowMs(io));
        const capture = [_][]const u8{ call.cost_header, "retry-after", "retry-after-ms" };
        const capture_list: []const []const u8 = if (call.cost_header.len == 0) capture[1..] else &capture;
        var attempt: i32 = 0;
        var certainty: DeliveryCertainty = .not_sent;
        var last_status: ?u16 = null;
        var last_retry_after: ?u32 = null;
        var last_message: []const u8 = "";

        while (true) {
            const send = switch (action) {
                .done => unreachable,
                .give_up => |g| {
                    if (g.disposition == .pause_route)
                        c.limiter.halt(io, call.key, if (g.class == .auth_401_403) .auth else .quota);
                    c.report(call.failure, .{
                        .class = g.class,
                        .certainty = certainty,
                        .disposition = g.disposition,
                        .http_status = last_status,
                        .retry_after_ms = last_retry_after,
                        .message = last_message,
                    });
                    return error.ProviderFailed;
                },
                .send => |s| s,
            };
            if (send.cooldown_until_ms) |until| c.limiter.cooldown(io, call.key, until);
            try c.sleepUntil(send.at_ms);
            const is_repair = send.phase == .repair;
            const body = if (is_repair) (if (repair_body) |rb| rb.* orelse "" else "") else original_body;

            c.limiter.acquire(io, call.key, call.priority, call.input_tokens) catch |err| {
                c.report(call.failure, .{
                    .class = if (err == error.SpendCapReached) .quota_exhausted else .auth_401_403,
                    .certainty = .not_sent,
                    .disposition = if (err == error.SpendCapReached) .requeue else .pause_route,
                    .message = @errorName(err),
                });
                return err;
            };
            attempt += 1;
            const started_us = Io.Clock.real.now(io).toMicroseconds();
            const started_ms = limiter.nowMs(io);
            const req: transport.Request = .{
                .url = call.url,
                .headers = call.headers,
                .body = body,
                .bounds = call.bounds,
                .total_ms = call.total_ms,
                .capture = capture_list,
                .cancel = &c.shutdown,
            };
            const result = t.send(io, arena, &req) catch |err| {
                c.limiter.release(io);
                return err;
            };
            c.limiter.release(io);
            const latency: u32 = std.math.cast(u32, limiter.nowMs(io) -| started_ms) orelse std.math.maxInt(u32);
            var row: core.LlmCall = .{
                .id = core.Id.v7(io),
                .graph_id = c.graph_id,
                .entry_id = call.entry_id,
                .purpose = if (is_repair) .repair else call.purpose,
                .route = call.route_name,
                .model = call.model,
                .attempt = attempt,
                .ok = false,
                .latency_ms = @intCast(@min(latency, std.math.maxInt(i32))),
                .started_at = started_us,
            };
            const now = limiter.nowMs(io);

            switch (result) {
                .failure => |f| {
                    if (f.cancelled) {
                        row.error_class = "canceled";
                        c.record(&row);
                        return error.Canceled;
                    }
                    const tc = classify.fromTransport(f.err, f.sent, f.timed_out);
                    certainty = tc.certainty;
                    last_status = null;
                    last_message = @errorName(f.err);
                    row.error_class = @tagName(tc.class);
                    c.record(&row);
                    action = recovery.step(&state, .{ .failed = .{ .class = tc.class } }, now);
                },
                .response => |res| {
                    certainty = .possibly_sent;
                    last_status = res.status;
                    row.http_status = res.status;
                    if (res.status < 200 or res.status > 299) {
                        const class = classify.fromStatus(res.status, res.body);
                        last_retry_after = retryAfter(res, io);
                        last_message = wire.errorMessage(arena, res.body);
                        row.error_class = @tagName(class);
                        row.cost_usd, row.cost_status = costPair(cost.resolve(header(res, call.cost_header), null, null, .{}, call.model, null, c.rates));
                        c.record(&row);
                        action = recovery.step(&state, .{ .failed = .{ .class = class, .retry_after_ms = last_retry_after } }, now);
                        continue;
                    }
                    const decoded = decode(ctx, res);
                    const ok: ?Decoded.Ok = switch (decoded) {
                        .ok, .needs_repair, .truncated => |o| o,
                        .refused => |r| r.ok,
                        .malformed, .invalid => null,
                    };
                    var resolved: Cost = .{};
                    if (ok) |o| {
                        row.input_tokens = @intCast(@min(o.usage.input_tokens, std.math.maxInt(i32)));
                        row.output_tokens = @intCast(@min(o.usage.output_tokens, std.math.maxInt(i32)));
                        row.cache_read_tokens = @intCast(@min(o.usage.cache_read_tokens, std.math.maxInt(i32)));
                        row.cache_write_tokens = @intCast(@min(o.usage.cache_write_tokens, std.math.maxInt(i32)));
                        resolved = cost.resolve(header(res, call.cost_header), o.body_cost, o.body_cost_status, o.usage, call.model, o.model, c.rates);
                    } else {
                        resolved = cost.resolve(header(res, call.cost_header), null, null, .{}, call.model, null, c.rates);
                    }
                    row.cost_usd, row.cost_status = costPair(resolved);
                    switch (decoded) {
                        .ok => |o| {
                            row.ok = true;
                            c.record(&row);
                            return .{ .usage = o.usage, .cost = resolved, .latency_ms = latency, .repaired = is_repair };
                        },
                        .needs_repair => {
                            row.error_class = "invalid_output";
                            last_message = "output failed validation";
                            c.record(&row);
                            action = recovery.step(&state, .invalid_output, now);
                        },
                        .truncated => {
                            row.error_class = "context_overflow";
                            last_message = "output truncated at the token limit";
                            c.record(&row);
                            action = recovery.step(&state, .{ .failed = .{ .class = .context_overflow } }, now);
                        },
                        .refused => |r| {
                            row.error_class = "invalid_output";
                            last_message = r.detail;
                            c.record(&row);
                            action = recovery.step(&state, .{ .failed = .{ .class = .invalid_output } }, now);
                        },
                        .invalid => |why| {
                            row.error_class = "invalid_output";
                            last_message = why;
                            c.record(&row);
                            action = recovery.step(&state, .{ .failed = .{ .class = .invalid_output } }, now);
                        },
                        .malformed => |err| {
                            if (err == error.OutOfMemory) return error.OutOfMemory;
                            row.error_class = "network_dropped";
                            last_message = "response body is not the expected wire format";
                            c.record(&row);
                            action = recovery.step(&state, .{ .failed = .{ .class = .network_dropped } }, now);
                        },
                    }
                },
            }
        }
    }

    fn report(c: *Client, out: ?*Failure, f: Failure) void {
        c.last_failure = f;
        if (out) |p| p.* = f;
    }

    fn record(c: *Client, row: *const core.LlmCall) void {
        c.limiter.addSpend(c.io, row.cost_usd);
        const ledger = c.ledger orelse return;
        ledger.record(row) catch |err| std.log.scoped(.llm).warn("ledger write failed: {s}", .{@errorName(err)});
    }

    fn sleepUntil(c: *Client, at_ms: u64) Error!void {
        while (true) {
            if (c.shutdown.load(.acquire)) return error.Canceled;
            const now = limiter.nowMs(c.io);
            if (now >= at_ms) return;
            const step: i64 = @intCast(@min(at_ms - now, 100));
            c.io.sleep(.fromMilliseconds(step), .awake) catch return error.Canceled;
        }
    }

    fn bounds(c: *const Client) transport.Bounds {
        const total: u64 = c.config.llm.timeout_ms;
        return .{ .connect_ms = @min(total, 30_000), .first_response_ms = total, .stall_ms = @min(total, 60_000) };
    }
};

const parse_options: std.json.ParseOptions = .{ .duplicate_field_behavior = .@"error" };

fn validateObject(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, parse_options) catch |err|
        return std.fmt.allocPrint(arena, "the reply is not valid JSON ({s})", .{@errorName(err)}) catch "the reply is not valid JSON";
    if (v != .object) return "the reply is not a JSON object";
    return null;
}

fn Validator(comptime T: type) type {
    return struct {
        fn validate(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
            var diag: std.json.Diagnostics = .{};
            var scanner = std.json.Scanner.initCompleteInput(arena, text);
            scanner.enableDiagnostics(&diag);
            _ = std.json.parseFromTokenSourceLeaky(T, arena, &scanner, parse_options) catch |err|
                return std.fmt.allocPrint(arena, "the reply does not match the schema: {s} at line {d}, column {d}", .{
                    @errorName(err), diag.getLine(), diag.getColumn(),
                }) catch "the reply does not match the schema";
            return null;
        }
    };
}

const max_repair_echo = 64 * 1024;

fn requestBody(arena: std.mem.Allocator, route: Route, prompt: wire.Prompt) error{OutOfMemory}![]const u8 {
    var body: Io.Writer.Allocating = .init(arena);
    wire.writeStructuredRequest(route, prompt, &body.writer) catch return error.OutOfMemory;
    return body.written();
}

fn repairBody(arena: std.mem.Allocator, route: Route, prompt: wire.Prompt, broken: []const u8, problem: []const u8) error{OutOfMemory}![]const u8 {
    var p = prompt;
    p.user = try std.fmt.allocPrint(arena,
        \\Your previous reply could not be used: {s}.
        \\
        \\Previous reply:
        \\{s}
        \\
        \\Reply again with only the corrected JSON object, following the required schema exactly.
    , .{ problem, broken[0..@min(broken.len, max_repair_echo)] });
    return requestBody(arena, route, p);
}

fn joinUrl(arena: std.mem.Allocator, base: []const u8, path: []const u8) error{OutOfMemory}![]const u8 {
    const b = std.mem.trimEnd(u8, base, "/");
    if (path.len == 0) return b;
    if (path[0] == '/') return std.mem.concat(arena, u8, &.{ b, path });
    return std.mem.concat(arena, u8, &.{ b, "/", path });
}

fn bearer(arena: std.mem.Allocator, key: []const u8) error{OutOfMemory}![]const std.http.Header {
    if (key.len == 0) return &.{};
    const h = try arena.alloc(std.http.Header, 1);
    h[0] = .{ .name = "authorization", .value = try std.mem.concat(arena, u8, &.{ "Bearer ", key }) };
    return h;
}

fn routeHeaders(arena: std.mem.Allocator, route: Route, key: []const u8) error{OutOfMemory}![]const std.http.Header {
    if (route != .@"anthropic-messages") return bearer(arena, key);
    const h = try arena.alloc(std.http.Header, if (key.len == 0) 1 else 2);
    h[0] = .{ .name = "anthropic-version", .value = "2023-06-01" };
    if (key.len > 0) h[1] = .{ .name = "x-api-key", .value = key };
    return h;
}

fn header(res: transport.Response, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    return res.header(name);
}

fn retryAfter(res: transport.Response, io: Io) ?u32 {
    if (res.header("retry-after-ms")) |v| if (classify.retryAfterMsHeader(v)) |ms| return ms;
    const v = res.header("retry-after") orelse return null;
    return classify.retryAfterMs(v, Io.Clock.real.now(io).toMilliseconds());
}

fn costPair(c: Cost) struct { f64, core.types.CostStatus } {
    return .{ c.usd, c.status };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("client_test.zig");
    _ = @import("transport_test.zig");
}

test "decide reports a disabled backend so callers can fall back" {
    const cfg: core.Config = .{};
    var client = Client.init(std.testing.allocator, std.testing.io, &cfg, null);
    defer client.deinit();
    try std.testing.expectError(error.DecisionDisabled, client.decide(std.testing.allocator, .rerank, &.{}));
}
