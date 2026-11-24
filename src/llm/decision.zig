const std = @import("std");
const core = @import("core");
const wire = @import("wire.zig");

pub const Wire = core.config.DecisionWire;

pub const Field = struct {
    name: []const u8,
    text: []const u8,
};

pub const Option = struct {
    name: []const u8,
    description: []const u8 = "",
};

pub const Question = union(enum) {
    yes_no: []const u8,
    choice: struct { prompt: []const u8, options: []const Option },

    pub fn promptLen(q: Question) usize {
        return switch (q) {
            .yes_no => |p| p.len,
            .choice => |c| blk: {
                var n = c.prompt.len;
                for (c.options) |o| n += o.name.len + o.description.len;
                break :blk n;
            },
        };
    }
};

pub const Answer = union(enum) {
    yes_no: f64,
    choice: []const f64,
};

pub const Request = struct {
    state: []const Field = &.{},
    questions: []const Question,

    pub fn promptLen(r: Request, format: Wire) usize {
        var state: usize = 0;
        for (r.state) |f| state += f.name.len + f.text.len;
        var n: usize = if (format == .stateful) state else state * r.questions.len;
        for (r.questions) |q| n += q.promptLen();
        return n;
    }
};

pub const WriteError = std.Io.Writer.Error || error{OutOfMemory};

pub fn writeRequest(arena: std.mem.Allocator, format: Wire, model: []const u8, req: Request, w: *std.Io.Writer) WriteError!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();

    if (model.len > 0) {
        try s.objectField("model");
        try s.write(model);
    }
    switch (format) {
        .generic => try writeGenericQuestions(arena, &s, req),
        .stateful => try writeStatefulQuestions(&s, req),
    }

    try s.endObject();
}

fn writeGenericQuestions(arena: std.mem.Allocator, s: *std.json.Stringify, req: Request) WriteError!void {
    var prefix: std.Io.Writer.Allocating = .init(arena);
    for (req.state) |f| try prefix.writer.print("{s}: {s}\n", .{ f.name, f.text });
    if (req.state.len > 0) try prefix.writer.writeByte('\n');
    const lead = prefix.written();
    try s.objectField("questions");
    try s.beginObject();
    for (req.questions, 0..) |q, i| {
        var key_buf: [24]u8 = undefined;
        try s.objectField(std.fmt.bufPrint(&key_buf, "q{d}", .{i}) catch unreachable);
        try s.beginObject();

        switch (q) {
            .yes_no => |prompt| {
                try s.objectField("type");
                try s.write("yes_no");
                try s.objectField("prompt");
                try s.write(try std.mem.concat(arena, u8, &.{ lead, prompt }));
            },
            .choice => |c| {
                try s.objectField("type");
                try s.write("choice");
                try s.objectField("prompt");
                try s.write(try std.mem.concat(arena, u8, &.{ lead, c.prompt }));

                try s.objectField("options");
                try s.beginArray();
                for (c.options) |o| {
                    if (o.description.len == 0) try s.write(o.name) else try s.write(try std.fmt.allocPrint(arena, "{s}: {s}", .{ o.name, o.description }));
                }
                try s.endArray();
            },
        }
        try s.endObject();
    }
    try s.endObject();
}

fn writeStatefulQuestions(s: *std.json.Stringify, req: Request) std.Io.Writer.Error!void {
    try s.objectField("state");
    try s.beginObject();
    for (req.state) |f| {
        try s.objectField(f.name);
        try s.write(f.text);
    }
    try s.endObject();

    try s.objectField("questions");
    try s.beginObject();
    for (req.questions, 0..) |q, i| {
        var key_buf: [24]u8 = undefined;
        try s.objectField(std.fmt.bufPrint(&key_buf, "q{d}", .{i}) catch unreachable);
        try s.beginObject();

        switch (q) {
            .yes_no => |prompt| {
                try s.objectField("type");
                try s.write("noul");
                try s.objectField("instructions");
                try s.write(prompt);
            },
            .choice => |c| {
                try s.objectField("type");
                try s.write("choice");
                try s.objectField("instructions");
                try s.write(c.prompt);

                try s.objectField("criteria");
                try s.beginObject();
                for (c.options) |o| {
                    try s.objectField(o.name);
                    if (o.description.len == 0) try s.write(null) else try s.write(o.description);
                }
                try s.endObject();
            },
        }
        try s.endObject();
    }
    try s.endObject();
}

pub const Decoded = struct {
    answers: []const Answer,
    model: ?[]const u8 = null,
    usage: wire.Usage = .{},
    body_cost: ?f64 = null,
    body_cost_status: ?core.types.CostStatus = null,
};

pub const DecodeError = error{ MalformedResponse, MissingAnswer, AnswerOutOfRange, OutOfMemory };

pub fn decodeResponse(arena: std.mem.Allocator, format: Wire, body: []const u8, questions: []const Question) DecodeError!Decoded {
    const root = try wire.parseObject(arena, body);
    const answers_v = root.get("answers") orelse return error.MalformedResponse;
    if (answers_v != .object) return error.MalformedResponse;

    const answers = try arena.alloc(Answer, questions.len);
    for (questions, answers, 0..) |q, *a, i| {
        var key_buf: [24]u8 = undefined;
        const v = answers_v.object.get(std.fmt.bufPrint(&key_buf, "q{d}", .{i}) catch unreachable) orelse return error.MissingAnswer;
        a.* = switch (format) {
            .generic => try genericAnswer(arena, q, v),
            .stateful => try statefulAnswer(arena, q, v),
        };
    }

    var out: Decoded = .{ .answers = answers };
    if (root.get("model")) |m| if (m == .string and m.string.len > 0) {
        out.model = m.string;
    };
    wire.readBodyCost(root, &out);

    if (root.get("usage")) |u| if (u == .object) {
        if (u.object.get("input_tokens")) |t| if (t == .integer) {
            out.usage.input_tokens = std.math.cast(u32, t.integer) orelse 0;
        };
        if (u.object.get("output_tokens")) |t| if (t == .integer) {
            out.usage.output_tokens = std.math.cast(u32, t.integer) orelse 0;
        };
    };

    return out;
}

fn genericAnswer(arena: std.mem.Allocator, q: Question, v: std.json.Value) DecodeError!Answer {
    switch (q) {
        .yes_no => return .{ .yes_no = try probability(v) },
        .choice => |c| {
            if (v != .array or v.array.items.len != c.options.len) return error.MissingAnswer;
            const ps = try arena.alloc(f64, c.options.len);
            for (v.array.items, ps) |pv, *p| p.* = try probability(pv);
            return .{ .choice = ps };
        },
    }
}

fn statefulAnswer(arena: std.mem.Allocator, q: Question, v: std.json.Value) DecodeError!Answer {
    if (v != .object) return error.MalformedResponse;
    const kind = v.object.get("type") orelse return error.MalformedResponse;
    if (kind != .string) return error.MalformedResponse;

    switch (q) {
        .yes_no => {
            if (!std.mem.eql(u8, kind.string, "noul")) return error.MalformedResponse;
            return .{ .yes_no = try probability(v.object.get("noul") orelse return error.MissingAnswer) };
        },
        .choice => |c| {
            if (!std.mem.eql(u8, kind.string, "choice")) return error.MalformedResponse;
            const probs = v.object.get("probabilities") orelse return error.MissingAnswer;
            if (probs != .object) return error.MalformedResponse;
            const ps = try arena.alloc(f64, c.options.len);
            for (c.options, ps) |o, *p| p.* = try probability(probs.object.get(o.name) orelse return error.MissingAnswer);
            return .{ .choice = ps };
        },
    }
}

fn probability(v: std.json.Value) DecodeError!f64 {
    const p = wire.number(v) orelse return error.MalformedResponse;
    if (!(p >= 0 and p <= 1)) return error.AnswerOutOfRange;
    return p;
}

const test_questions = [_]Question{
    .{ .yes_no = "Is F3 a duplicate of the new fact?" },
    .{ .choice = .{ .prompt = "Which entity is meant?", .options = &.{ .{ .name = "E1" }, .{ .name = "E2", .description = "the library" }, .{ .name = "neither" } } } },
};

test "generic request and response round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(arena);
    try writeRequest(arena, .generic, "decider-1", .{ .questions = &test_questions }, &out.writer);
    try std.testing.expectEqualStrings(
        "{\"model\":\"decider-1\",\"questions\":{\"q0\":{\"type\":\"yes_no\",\"prompt\":\"Is F3 a duplicate of the new fact?\"}," ++
            "\"q1\":{\"type\":\"choice\",\"prompt\":\"Which entity is meant?\",\"options\":[\"E1\",\"E2: the library\",\"neither\"]}}}",
        out.written(),
    );

    const d = try decodeResponse(arena, .generic, "{\"answers\":{\"q0\":0.91,\"q1\":[0.1,0.8,0.1]},\"usage\":{\"cost\":0.0001}}", &test_questions);
    try std.testing.expectEqual(@as(f64, 0.91), d.answers[0].yes_no);
    try std.testing.expectEqual(@as(f64, 0.8), d.answers[1].choice[1]);
    try std.testing.expectEqual(@as(?f64, 0.0001), d.body_cost);

    try std.testing.expectError(error.MissingAnswer, decodeResponse(arena, .generic, "{\"answers\":{\"q0\":0.5}}", &test_questions));
    try std.testing.expectError(error.AnswerOutOfRange, decodeResponse(arena, .generic, "{\"answers\":{\"q0\":1.5,\"q1\":[0,0,1]}}", &test_questions));
}

test "generic requests repeat shared state in every prompt" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(arena);
    const qs = [_]Question{ .{ .yes_no = "A?" }, .{ .yes_no = "B?" } };
    try writeRequest(arena, .generic, "", .{ .state = &.{.{ .name = "query", .text = "tide tables" }}, .questions = &qs }, &out.writer);
    try std.testing.expectEqualStrings(
        "{\"questions\":{\"q0\":{\"type\":\"yes_no\",\"prompt\":\"query: tide tables\\n\\nA?\"},\"q1\":{\"type\":\"yes_no\",\"prompt\":\"query: tide tables\\n\\nB?\"}}}",
        out.written(),
    );
}

test "stateful request sends state once and typed questions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(arena);
    try writeRequest(arena, .stateful, "decider-1", .{ .state = &.{.{ .name = "entry", .text = "We moved off Go." }}, .questions = &test_questions }, &out.writer);
    try std.testing.expectEqualStrings(
        "{\"model\":\"decider-1\",\"state\":{\"entry\":\"We moved off Go.\"},\"questions\":{" ++
            "\"q0\":{\"type\":\"noul\",\"instructions\":\"Is F3 a duplicate of the new fact?\"}," ++
            "\"q1\":{\"type\":\"choice\",\"instructions\":\"Which entity is meant?\",\"criteria\":{\"E1\":null,\"E2\":\"the library\",\"neither\":null}}}}",
        out.written(),
    );

    var empty: std.Io.Writer.Allocating = .init(arena);
    try writeRequest(arena, .stateful, "", .{ .questions = test_questions[0..1] }, &empty.writer);
    try std.testing.expectEqualStrings("{\"state\":{},\"questions\":{\"q0\":{\"type\":\"noul\",\"instructions\":\"Is F3 a duplicate of the new fact?\"}}}", empty.written());
}

test "stateful response maps noul and choice answers back to question order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"model":"decider-1.2","answers":{"q1":{"type":"choice","choice":"E2","confidence":0.8,"probabilities":{"neither":0.05,"E2":0.85,"E1":0.1}},
        \\"q0":{"type":"noul","noul":0.87}},"usage":{"input_tokens":406,"output_tokens":59}}
    ;

    const d = try decodeResponse(arena, .stateful, body, &test_questions);
    try std.testing.expectEqual(@as(f64, 0.87), d.answers[0].yes_no);
    try std.testing.expectEqualSlices(f64, &.{ 0.1, 0.85, 0.05 }, d.answers[1].choice);
    try std.testing.expectEqualStrings("decider-1.2", d.model.?);
    try std.testing.expectEqual(@as(u32, 406), d.usage.input_tokens);
    try std.testing.expectEqual(@as(u32, 59), d.usage.output_tokens);
    try std.testing.expectEqual(@as(?f64, null), d.body_cost);
}

test "stateful responses with missing, mistyped, or out-of-range answers are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const choice = "\"q1\":{\"type\":\"choice\",\"probabilities\":{\"E1\":0.1,\"E2\":0.8,\"neither\":0.1}}";
    try std.testing.expectError(error.MissingAnswer, decodeResponse(arena, .stateful, "{\"answers\":{" ++ choice ++ "}}", &test_questions));
    try std.testing.expectError(error.MalformedResponse, decodeResponse(arena, .stateful, "{\"answers\":{\"q0\":0.5," ++ choice ++ "}}", &test_questions));
    try std.testing.expectError(error.MalformedResponse, decodeResponse(arena, .stateful, "{\"answers\":{\"q0\":{\"type\":\"choice\",\"noul\":0.5}," ++ choice ++ "}}", &test_questions));
    try std.testing.expectError(error.AnswerOutOfRange, decodeResponse(arena, .stateful, "{\"answers\":{\"q0\":{\"type\":\"noul\",\"noul\":1.2}," ++ choice ++ "}}", &test_questions));
    try std.testing.expectError(error.MissingAnswer, decodeResponse(arena, .stateful, "{\"answers\":{\"q0\":{\"type\":\"noul\",\"noul\":0.2},\"q1\":{\"type\":\"choice\",\"probabilities\":{\"E1\":0.9}}}}", &test_questions));
    try std.testing.expectError(error.MalformedResponse, decodeResponse(arena, .stateful, "{\"detail\":\"bad request\"}", &test_questions));
}
