const std = @import("std");
const core = @import("core");
const wire = @import("wire.zig");

pub const Question = union(enum) {
    yes_no: []const u8,
    choice: struct { prompt: []const u8, options: []const []const u8 },

    pub fn promptLen(q: Question) usize {
        return switch (q) {
            .yes_no => |p| p.len,
            .choice => |c| blk: {
                var n = c.prompt.len;
                for (c.options) |o| n += o.len;
                break :blk n;
            },
        };
    }
};

pub const Answer = union(enum) {
    yes_no: f64,
    choice: []const f64,
};

pub fn writeRequest(model: []const u8, questions: []const Question, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    if (model.len > 0) {
        try s.objectField("model");
        try s.write(model);
    }
    try s.objectField("questions");
    try s.beginObject();
    for (questions, 0..) |q, i| {
        var key_buf: [24]u8 = undefined;
        try s.objectField(std.fmt.bufPrint(&key_buf, "q{d}", .{i}) catch unreachable);
        try s.beginObject();
        switch (q) {
            .yes_no => |prompt| {
                try s.objectField("type");
                try s.write("yes_no");
                try s.objectField("prompt");
                try s.write(prompt);
            },
            .choice => |c| {
                try s.objectField("type");
                try s.write("choice");
                try s.objectField("prompt");
                try s.write(c.prompt);
                try s.objectField("options");
                try s.write(c.options);
            },
        }
        try s.endObject();
    }
    try s.endObject();
    try s.endObject();
}

pub const Decoded = struct {
    answers: []const Answer,
    usage: wire.Usage = .{},
    body_cost: ?f64 = null,
    body_cost_status: ?core.types.CostStatus = null,
};

pub const DecodeError = error{ MalformedResponse, MissingAnswer, AnswerOutOfRange, OutOfMemory };

pub fn decodeResponse(arena: std.mem.Allocator, body: []const u8, questions: []const Question) DecodeError!Decoded {
    const root = try wire.parseObject(arena, body);
    const answers_v = root.get("answers") orelse return error.MalformedResponse;
    if (answers_v != .object) return error.MalformedResponse;
    const answers = try arena.alloc(Answer, questions.len);
    for (questions, answers, 0..) |q, *a, i| {
        var key_buf: [24]u8 = undefined;
        const v = answers_v.object.get(std.fmt.bufPrint(&key_buf, "q{d}", .{i}) catch unreachable) orelse return error.MissingAnswer;
        switch (q) {
            .yes_no => a.* = .{ .yes_no = try probability(v) },
            .choice => |c| {
                if (v != .array or v.array.items.len != c.options.len) return error.MissingAnswer;
                const ps = try arena.alloc(f64, c.options.len);
                for (v.array.items, ps) |pv, *p| p.* = try probability(pv);
                a.* = .{ .choice = ps };
            },
        }
    }
    var out: Decoded = .{ .answers = answers };
    if (root.get("usage")) |u| if (u == .object) {
        if (u.object.get("cost")) |c| out.body_cost = wire.number(c);
        if (u.object.get("cost_status")) |cs| if (cs == .string) {
            out.body_cost_status = std.meta.stringToEnum(core.types.CostStatus, cs.string);
        };
        if (u.object.get("input_tokens")) |t| if (t == .integer) {
            out.usage.input_tokens = std.math.cast(u32, t.integer) orelse 0;
        };
        if (u.object.get("output_tokens")) |t| if (t == .integer) {
            out.usage.output_tokens = std.math.cast(u32, t.integer) orelse 0;
        };
    };
    return out;
}

fn probability(v: std.json.Value) DecodeError!f64 {
    const p = wire.number(v) orelse return error.MalformedResponse;
    if (!(p >= 0 and p <= 1)) return error.AnswerOutOfRange;
    return p;
}

test "decision request and response round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const qs = [_]Question{
        .{ .yes_no = "Is F3 a duplicate of the new fact?" },
        .{ .choice = .{ .prompt = "Which entity is meant?", .options = &.{ "E1", "E2", "neither" } } },
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeRequest("decider-1", &qs, &out.writer);
    try std.testing.expectEqualStrings(
        "{\"model\":\"decider-1\",\"questions\":{\"q0\":{\"type\":\"yes_no\",\"prompt\":\"Is F3 a duplicate of the new fact?\"}," ++
            "\"q1\":{\"type\":\"choice\",\"prompt\":\"Which entity is meant?\",\"options\":[\"E1\",\"E2\",\"neither\"]}}}",
        out.written(),
    );
    const d = try decodeResponse(arena, "{\"answers\":{\"q0\":0.91,\"q1\":[0.1,0.8,0.1]},\"usage\":{\"cost\":0.0001}}", &qs);
    try std.testing.expectEqual(@as(f64, 0.91), d.answers[0].yes_no);
    try std.testing.expectEqual(@as(f64, 0.8), d.answers[1].choice[1]);
    try std.testing.expectEqual(@as(?f64, 0.0001), d.body_cost);
    try std.testing.expectError(error.MissingAnswer, decodeResponse(arena, "{\"answers\":{\"q0\":0.5}}", &qs));
    try std.testing.expectError(error.AnswerOutOfRange, decodeResponse(arena, "{\"answers\":{\"q0\":1.5,\"q1\":[0,0,1]}}", &qs));
}
