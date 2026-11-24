const std = @import("std");
const core = @import("core");
const normalize = @import("normalize.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const text_budget: usize = 12_000;

pub const Meta = struct {
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const Item = struct {
    turn: core.Turn,
    start: u64,
};

pub const Sink = struct {
    arena: Allocator,
    scratch: Allocator,
    out: *std.ArrayList(Item),
};

pub const Parser = struct {
    harness: core.Harness,
    keep: Allocator,
    meta: Meta = .{},
    pending: ?Pending = null,
    lines: u64 = 0,
    malformed: u64 = 0,

    const Pending = struct {
        start: u64,
        ts: ?core.Micros,
        text: std.ArrayList(u8) = .empty,
        calls: std.ArrayList(PendingCall) = .empty,
        got_result: bool = false,
    };

    const PendingCall = struct {
        id: []const u8,
        call: normalize.Call,
        result: ?core.ToolCall = null,
    };

    const Ctx = struct {
        sink: Sink,
        start: u64,
        ts: ?core.Micros,
    };

    pub fn init(harness: core.Harness, keep: Allocator) Parser {
        return .{ .harness = harness, .keep = keep };
    }

    pub fn feed(p: *Parser, sink: Sink, line: []const u8, start: u64) Allocator.Error!void {
        p.lines += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        const root = std.json.parseFromSliceLeaky(Value, sink.scratch, trimmed, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                p.malformed += 1;
                return;
            },
        };
        if (root != .object) {
            p.malformed += 1;
            return;
        }
        switch (p.harness) {
            .@"claude-code" => try p.claudeCode(sink, root, start),
            .codex => try p.codex(sink, root, start),
            .pi => try p.pi(sink, root, start),
            .fx => try p.fx(sink, root, start),
            else => {},
        }
    }

    pub fn flushResolved(p: *Parser, sink: Sink) Allocator.Error!void {
        const pending = p.pending orelse return;
        for (pending.calls.items) |c| if (c.result == null) return;
        try p.emitPending(sink);
    }

    pub fn flushAll(p: *Parser, sink: Sink) Allocator.Error!void {
        try p.emitPending(sink);
    }

    pub fn pendingStart(p: *const Parser) ?u64 {
        return if (p.pending) |pending| pending.start else null;
    }

    pub fn pendingTs(p: *const Parser) ?core.Micros {
        return if (p.pending) |pending| pending.ts else null;
    }

    pub fn rehome(p: *Parser, arena: Allocator) Allocator.Error!void {
        const old = p.pending orelse return;
        var fresh: Pending = .{ .start = old.start, .ts = old.ts, .got_result = old.got_result };
        try fresh.text.appendSlice(arena, old.text.items);
        for (old.calls.items) |c| {
            var call = c.call;
            call.name = try arena.dupe(u8, call.name);
            call.args_preview = try arena.dupe(u8, call.args_preview);
            if (call.read) |*r| r.path = try arena.dupe(u8, r.path);
            try fresh.calls.append(arena, .{
                .id = try arena.dupe(u8, c.id),
                .call = call,
                .result = if (c.result) |r| .{
                    .name = try arena.dupe(u8, r.name),
                    .args_preview = try arena.dupe(u8, r.args_preview),
                    .result_preview = try arena.dupe(u8, r.result_preview),
                } else null,
            });
        }
        p.pending = fresh;
    }

    fn setMeta(p: *Parser, field: enum { session_id, cwd, model }, value: ?Value) Allocator.Error!void {
        const v = value orelse return;
        if (v != .string or v.string.len == 0) return;
        const slot = switch (field) {
            .session_id => &p.meta.session_id,
            .cwd => &p.meta.cwd,
            .model => &p.meta.model,
        };
        if (slot.*) |current| if (std.mem.eql(u8, current, v.string)) return;
        slot.* = try p.keep.dupe(u8, v.string);
    }

    fn emitPending(p: *Parser, sink: Sink) Allocator.Error!void {
        const pending = p.pending orelse return;
        p.pending = null;
        const calls = try sink.arena.alloc(core.ToolCall, pending.calls.items.len);
        for (pending.calls.items, calls) |c, *dst| {
            dst.* = c.result orelse try normalize.finishCall(sink.arena, sink.scratch, c.call, null, false);
        }
        if (pending.text.items.len == 0 and calls.len == 0) return;
        try sink.out.append(sink.arena, .{
            .turn = .{ .role = .assistant, .text = pending.text.items, .tool_calls = calls, .ts = pending.ts },
            .start = pending.start,
        });
    }

    fn ensurePending(p: *Parser, ctx: Ctx) Allocator.Error!*Pending {
        if (p.pending) |pending| if (pending.got_result) try p.emitPending(ctx.sink);
        if (p.pending == null) p.pending = .{ .start = ctx.start, .ts = ctx.ts };
        return &p.pending.?;
    }

    fn userText(p: *Parser, ctx: Ctx, text: []const u8) Allocator.Error!void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        try p.emitPending(ctx.sink);
        try ctx.sink.out.append(ctx.sink.arena, .{
            .turn = .{ .role = .user, .text = try normalize.cleanBounded(ctx.sink.arena, ctx.sink.scratch, trimmed, text_budget), .ts = ctx.ts },
            .start = ctx.start,
        });
    }

    fn assistantText(p: *Parser, ctx: Ctx, text: []const u8) Allocator.Error!void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        const pending = try p.ensurePending(ctx);
        if (pending.text.items.len > 0) try pending.text.appendSlice(ctx.sink.arena, "\n\n");
        try pending.text.appendSlice(ctx.sink.arena, try normalize.cleanBounded(ctx.sink.scratch, ctx.sink.scratch, trimmed, text_budget));
    }

    fn toolCall(p: *Parser, ctx: Ctx, id: []const u8, raw: normalize.RawTool) Allocator.Error!void {
        const pending = try p.ensurePending(ctx);
        try pending.calls.append(ctx.sink.arena, .{
            .id = try ctx.sink.arena.dupe(u8, id),
            .call = try normalize.prepareCall(ctx.sink.arena, ctx.sink.scratch, raw),
        });
    }

    fn toolCallDone(p: *Parser, ctx: Ctx, raw: normalize.RawTool, result: ?[]const u8, is_error: bool) Allocator.Error!void {
        const pending = try p.ensurePending(ctx);
        const call = try normalize.prepareCall(ctx.sink.arena, ctx.sink.scratch, raw);
        try pending.calls.append(ctx.sink.arena, .{
            .id = "",
            .call = call,
            .result = try normalize.finishCall(ctx.sink.arena, ctx.sink.scratch, call, result, is_error),
        });
    }

    fn toolResult(p: *Parser, ctx: Ctx, id: []const u8, name_hint: ?[]const u8, text: []const u8, is_error: bool) Allocator.Error!void {
        if (p.pending) |*pending| {
            for (pending.calls.items) |*c| {
                if (c.result != null or !std.mem.eql(u8, c.id, id)) continue;
                c.result = try normalize.finishCall(ctx.sink.arena, ctx.sink.scratch, c.call, text, is_error);
                pending.got_result = true;
                return;
            }
        }
        try p.emitPending(ctx.sink);
        const call = try normalize.prepareCall(ctx.sink.arena, ctx.sink.scratch, .{ .name = name_hint orelse "tool" });
        const calls = try ctx.sink.arena.alloc(core.ToolCall, 1);
        calls[0] = try normalize.finishCall(ctx.sink.arena, ctx.sink.scratch, call, text, is_error);
        try ctx.sink.out.append(ctx.sink.arena, .{ .turn = .{ .role = .tool, .text = "", .tool_calls = calls, .ts = ctx.ts }, .start = ctx.start });
    }

    fn claudeCode(p: *Parser, sink: Sink, root: Value, start: u64) Allocator.Error!void {
        try p.setMeta(.cwd, root.object.get("cwd"));
        try p.setMeta(.session_id, root.object.get("sessionId"));
        const kind = str(root, "type") orelse return;
        if (boolField(root, "isMeta") or boolField(root, "isCompactSummary")) return;
        const message = obj(root, "message") orelse return;
        const ctx: Ctx = .{ .sink = sink, .start = start, .ts = normalize.jsonTimestamp(root.object.get("timestamp")) };
        const content = message.object.get("content") orelse return;
        if (std.mem.eql(u8, kind, "user")) {
            if (content == .string) {
                if (!isHarnessNoise(content.string)) try p.userText(ctx, content.string);
                return;
            }
            if (content != .array) return;
            for (content.array.items) |block| {
                if (!isType(block, "tool_result")) continue;
                const text = try textOf(sink.scratch, block.object.get("content")) orelse "";
                try p.toolResult(ctx, str(block, "tool_use_id") orelse "", null, text, boolField(block, "is_error"));
            }
            var text: std.ArrayList(u8) = .empty;
            for (content.array.items) |block| {
                if (!isType(block, "text")) continue;
                const t = str(block, "text") orelse continue;
                if (isHarnessNoise(t)) continue;
                if (text.items.len > 0) try text.appendSlice(sink.scratch, "\n");
                try text.appendSlice(sink.scratch, t);
            }
            try p.userText(ctx, text.items);
        } else if (std.mem.eql(u8, kind, "assistant")) {
            try p.setMeta(.model, message.object.get("model"));
            if (content == .string) return p.assistantText(ctx, content.string);
            if (content != .array) return;
            for (content.array.items) |block| {
                if (isType(block, "text")) {
                    try p.assistantText(ctx, str(block, "text") orelse "");
                } else if (isType(block, "tool_use")) {
                    try p.toolCall(ctx, str(block, "id") orelse "", .{ .name = str(block, "name") orelse "tool", .args = block.object.get("input") });
                }
            }
        }
    }

    fn codex(p: *Parser, sink: Sink, root: Value, start: u64) Allocator.Error!void {
        const ctx: Ctx = .{ .sink = sink, .start = start, .ts = normalize.jsonTimestamp(root.object.get("timestamp")) };
        if (obj(root, "payload")) |payload| {
            const kind = str(root, "type") orelse return;
            if (std.mem.eql(u8, kind, "session_meta")) {
                try p.setMeta(.session_id, payload.object.get("id"));
                try p.setMeta(.cwd, payload.object.get("cwd"));
            } else if (std.mem.eql(u8, kind, "turn_context")) {
                try p.setMeta(.cwd, payload.object.get("cwd"));
                try p.setMeta(.model, payload.object.get("model"));
            } else if (std.mem.eql(u8, kind, "response_item")) {
                try p.codexItem(ctx, payload);
            }
            return;
        }
        if (root.object.get("record_type") != null) return;
        if (str(root, "type") == null) {
            try p.setMeta(.session_id, root.object.get("id"));
            return;
        }
        try p.codexItem(ctx, root);
    }

    fn codexItem(p: *Parser, ctx: Ctx, item: Value) Allocator.Error!void {
        const kind = str(item, "type") orelse return;
        const scratch = ctx.sink.scratch;
        if (std.mem.eql(u8, kind, "message")) {
            const role = str(item, "role") orelse return;
            const text = try textOf(scratch, item.object.get("content")) orelse return;
            if (std.mem.eql(u8, role, "user")) {
                if (!isCodexInjected(text)) try p.userText(ctx, text);
            } else if (std.mem.eql(u8, role, "assistant")) {
                try p.assistantText(ctx, text);
            }
        } else if (std.mem.eql(u8, kind, "function_call")) {
            const arguments = str(item, "arguments") orelse "";
            const parsed = std.json.parseFromSliceLeaky(Value, scratch, arguments, .{}) catch null;
            try p.toolCall(ctx, str(item, "call_id") orelse "", .{ .name = str(item, "name") orelse "tool", .args = parsed, .args_text = arguments });
        } else if (std.mem.eql(u8, kind, "custom_tool_call")) {
            try p.toolCall(ctx, str(item, "call_id") orelse "", .{ .name = str(item, "name") orelse "tool", .args_text = str(item, "input") orelse "" });
        } else if (std.mem.eql(u8, kind, "local_shell_call")) {
            const id = str(item, "call_id") orelse str(item, "id") orelse "";
            try p.toolCall(ctx, id, .{ .name = "shell", .args = item.object.get("action") });
        } else if (std.mem.eql(u8, kind, "web_search_call")) {
            const action = item.object.get("action");
            try p.toolCallDone(ctx, .{ .name = "web_search", .args = action }, null, false);
        } else if (std.mem.endsWith(u8, kind, "_call_output")) {
            const output = item.object.get("output") orelse return;
            var text: []const u8 = "";
            var is_error = false;
            switch (output) {
                .string => |s| {
                    text = s;
                    if (s.len > 0 and s[0] == '{') {
                        if (std.json.parseFromSliceLeaky(Value, scratch, s, .{})) |wrapped| {
                            if (str(wrapped, "output")) |inner| text = inner;
                            if (obj(wrapped, "metadata")) |m| if (m.object.get("exit_code")) |code| {
                                is_error = code == .integer and code.integer != 0;
                            };
                        } else |_| {}
                    }
                },
                .object => {
                    text = try textOf(scratch, output.object.get("content")) orelse str(output, "output") orelse "";
                    if (output.object.get("success")) |ok| is_error = ok == .bool and !ok.bool;
                },
                else => {},
            }
            try p.toolResult(ctx, str(item, "call_id") orelse "", null, text, is_error);
        }
    }

    fn pi(p: *Parser, sink: Sink, root: Value, start: u64) Allocator.Error!void {
        const kind = str(root, "type") orelse return;
        if (std.mem.eql(u8, kind, "session")) {
            try p.setMeta(.session_id, root.object.get("id"));
            try p.setMeta(.cwd, root.object.get("cwd"));
            return;
        }
        if (std.mem.eql(u8, kind, "model_change")) return p.setMeta(.model, root.object.get("modelId"));
        if (!std.mem.eql(u8, kind, "message")) return;
        const message = obj(root, "message") orelse return;
        const ts = normalize.jsonTimestamp(message.object.get("timestamp")) orelse normalize.jsonTimestamp(root.object.get("timestamp"));
        const ctx: Ctx = .{ .sink = sink, .start = start, .ts = ts };
        const role = str(message, "role") orelse return;
        const content = message.object.get("content");
        if (std.mem.eql(u8, role, "user")) {
            try p.userText(ctx, try textOf(sink.scratch, content) orelse "");
        } else if (std.mem.eql(u8, role, "assistant")) {
            try p.setMeta(.model, message.object.get("model"));
            const blocks = content orelse return;
            if (blocks != .array) return;
            for (blocks.array.items) |block| {
                if (isType(block, "text")) {
                    try p.assistantText(ctx, str(block, "text") orelse "");
                } else if (isType(block, "toolCall")) {
                    try p.toolCall(ctx, str(block, "id") orelse "", .{ .name = str(block, "name") orelse "tool", .args = block.object.get("arguments") });
                }
            }
        } else if (std.mem.eql(u8, role, "toolResult")) {
            const text = try textOf(sink.scratch, content) orelse "";
            try p.toolResult(ctx, str(message, "toolCallId") orelse "", str(message, "toolName"), text, boolField(message, "isError"));
        } else if (std.mem.eql(u8, role, "bashExecution")) {
            try p.emitPending(sink);
            const command = str(message, "command") orelse "";
            const output = str(message, "output") orelse "";
            const exit_ok = if (message.object.get("exitCode")) |c| c != .integer or c.integer == 0 else true;
            const call = try normalize.prepareCall(sink.arena, sink.scratch, .{ .name = "bash", .args_text = command });
            const calls = try sink.arena.alloc(core.ToolCall, 1);
            calls[0] = try normalize.finishCall(sink.arena, sink.scratch, call, output, !exit_ok);
            try sink.out.append(sink.arena, .{ .turn = .{ .role = .tool, .text = "", .tool_calls = calls, .ts = ts }, .start = start });
        }
    }

    fn fx(p: *Parser, sink: Sink, root: Value, start: u64) Allocator.Error!void {
        const ctx: Ctx = .{ .sink = sink, .start = start, .ts = normalize.jsonTimestamp(root.object.get("timestamp_ms")) };
        if (str(root, "kind")) |kind| {
            const payload = obj(root, "payload") orelse return;
            if (std.mem.eql(u8, kind, "session_started")) {
                try p.setMeta(.session_id, payload.object.get("id"));
                try p.setMeta(.cwd, payload.object.get("workspace_root"));
                if (obj(payload, "preferences")) |prefs| try p.setMeta(.model, prefs.object.get("model_id"));
            } else if (std.mem.eql(u8, kind, "workspace_rebound")) {
                try p.setMeta(.cwd, payload.object.get("workspace_root"));
            } else if (std.mem.eql(u8, kind, "preferences_changed")) {
                try p.setMeta(.model, payload.object.get("model"));
            } else if (std.mem.eql(u8, kind, "history_turn_committed")) {
                const turn = obj(payload, "turn") orelse return;
                try p.fxCommittedTurn(ctx, turn);
            }
            return;
        }
        const event = obj(root, "event") orelse return;
        var it = event.object.iterator();
        const entry = it.next() orelse return;
        const name = entry.key_ptr.*;
        const body = entry.value_ptr.*;
        if (std.mem.eql(u8, name, "user") or std.mem.eql(u8, name, "steering")) {
            try p.userText(ctx, str(body, "text") orelse "");
        } else if (std.mem.eql(u8, name, "assistant")) {
            try p.assistantText(ctx, str(body, "text") orelse "");
        } else if (std.mem.eql(u8, name, "tool_call")) {
            try p.toolCall(ctx, str(body, "call_id") orelse "", try fxRawTool(sink.scratch, body, "tool_name"));
        } else if (std.mem.eql(u8, name, "tool_result")) {
            const status = str(body, "status") orelse "success";
            try p.toolResult(ctx, str(body, "call_id") orelse "", str(body, "tool_name"), str(body, "preview") orelse "", !std.mem.eql(u8, status, "success"));
        } else if (std.mem.eql(u8, name, "interrupted")) {
            try p.assistantText(ctx, str(body, "partial_text") orelse "");
            try p.emitPending(sink);
        } else if (std.mem.eql(u8, name, "turn_completed")) {
            try p.emitPending(sink);
        }
    }

    fn fxCommittedTurn(p: *Parser, ctx: Ctx, turn: Value) Allocator.Error!void {
        const kind = str(turn, "kind") orelse return;
        if (!std.mem.eql(u8, kind, "assistant") and !std.mem.eql(u8, kind, "interrupted")) return;
        if (obj(turn, "user")) |user| try p.userText(ctx, str(user, "text") orelse "");
        if (obj(turn, "execution")) |execution| if (arr(execution, "tool_steps")) |steps| {
            for (steps) |step| {
                if (str(step, "assistant")) |text| try p.assistantText(ctx, text);
                if (arr(step, "tool_calls")) |calls| for (calls) |c| {
                    try p.toolCall(ctx, str(c, "id") orelse "", try fxRawTool(ctx.sink.scratch, c, "name"));
                };
                if (arr(step, "tool_results")) |results| for (results) |r| {
                    const status = str(r, "status") orelse "success";
                    const text = str(r, "output") orelse str(r, "preview") orelse "";
                    try p.toolResult(ctx, str(r, "tool_call_id") orelse "", str(r, "tool_name"), text, !std.mem.eql(u8, status, "success"));
                };
                try p.emitPending(ctx.sink);
            }
        };
        if (str(turn, "assistant")) |text| try p.assistantText(ctx, text);
        try p.emitPending(ctx.sink);
    }
};

fn fxRawTool(scratch: Allocator, call: Value, name_key: []const u8) Allocator.Error!normalize.RawTool {
    const arguments = str(call, "arguments_json") orelse "";
    const parsed = std.json.parseFromSliceLeaky(Value, scratch, arguments, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    return .{ .name = str(call, name_key) orelse "tool", .args = parsed, .args_text = arguments };
}

fn isHarnessNoise(text: []const u8) bool {
    const t = std.mem.trimStart(u8, text, " \t\r\n");
    const prefixes = [_][]const u8{ "<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>", "<local-command-stderr>", "<system-reminder>", "Caveat: The messages below were generated by the user while running local commands" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, t, prefix)) return true;
    return false;
}

fn isCodexInjected(text: []const u8) bool {
    const t = std.mem.trimStart(u8, text, " \t\r\n");
    const prefixes = [_][]const u8{ "<environment_context>", "<user_instructions>", "<permissions instructions>", "# AGENTS.md instructions", "<user_shell_command>", "<turn_aborted>" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, t, prefix)) return true;
    return false;
}

fn str(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn obj(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    return if (field == .object) field else null;
}

fn arr(v: Value, key: []const u8) ?[]const Value {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    return if (field == .array) field.array.items else null;
}

fn boolField(v: Value, key: []const u8) bool {
    if (v != .object) return false;
    const field = v.object.get(key) orelse return false;
    return field == .bool and field.bool;
}

fn isType(block: Value, kind: []const u8) bool {
    const t = str(block, "type") orelse return false;
    return std.mem.eql(u8, t, kind);
}

fn textOf(scratch: Allocator, content: ?Value) Allocator.Error!?[]const u8 {
    const v = content orelse return null;
    switch (v) {
        .string => |s| return s,
        .array => |a| {
            var out: std.ArrayList(u8) = .empty;
            for (a.items) |block| {
                const t = switch (block) {
                    .string => |s| s,
                    .object => blk: {
                        const kind = str(block, "type") orelse "text";
                        if (!std.mem.eql(u8, kind, "text") and !std.mem.eql(u8, kind, "input_text") and !std.mem.eql(u8, kind, "output_text")) continue;
                        break :blk str(block, "text") orelse continue;
                    },
                    else => continue,
                };
                if (out.items.len > 0) try out.append(scratch, '\n');
                try out.appendSlice(scratch, t);
            }
            return out.items;
        },
        .object => return str(v, "text"),
        else => return null,
    }
}

const testing = std.testing;

const Parsed = struct {
    items: []const Item,
    meta: Meta,
    malformed: u64,
};

fn parseAll(arena: Allocator, harness: core.Harness, bytes: []const u8) !Parsed {
    var scratch_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch_state.deinit();
    var out: std.ArrayList(Item) = .empty;
    var p = Parser.init(harness, arena);
    const sink: Sink = .{ .arena = arena, .scratch = scratch_state.allocator(), .out = &out };
    var offset: u64 = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        try p.feed(sink, line, offset);
        _ = scratch_state.reset(.retain_capacity);
        offset += line.len + 1;
    }
    try p.flushAll(sink);
    return .{ .items = out.items, .meta = p.meta, .malformed = p.malformed };
}

fn expectTurn(item: Item, role: core.types.Role, text: []const u8, calls: []const core.ToolCall) !void {
    try testing.expectEqual(role, item.turn.role);
    try testing.expectEqualStrings(text, item.turn.text);
    try testing.expectEqual(calls.len, item.turn.tool_calls.len);
    for (calls, item.turn.tool_calls) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.args_preview, got.args_preview);
        try testing.expectEqualStrings(want.result_preview, got.result_preview);
    }
}

fn expectAbsent(items: []const Item, needle: []const u8) !void {
    for (items) |item| {
        try testing.expect(std.mem.indexOf(u8, item.turn.text, needle) == null);
        for (item.turn.tool_calls) |tc| {
            try testing.expect(std.mem.indexOf(u8, tc.args_preview, needle) == null);
            try testing.expect(std.mem.indexOf(u8, tc.result_preview, needle) == null);
        }
    }
}

test "claude code transcript" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseAll(arena_state.allocator(), .@"claude-code", @embedFile("testdata/claude-code/session.jsonl"));
    try testing.expectEqual(@as(usize, 5), parsed.items.len);
    try expectTurn(parsed.items[0], .user, "Switch the widget service to Postgres 17 and check the migration runner.", &.{});
    try expectTurn(parsed.items[1], .assistant, "I'll read the runner first.", &.{.{ .name = "Read", .args_preview = "/home/dev/acme/widget/src/migrate.zig:1-3" }});
    try expectTurn(parsed.items[2], .assistant, "", &.{.{ .name = "Bash", .args_preview = "zig build test", .result_preview = "All 42 tests passed." }});
    try expectTurn(parsed.items[3], .assistant, "The runner applies each migration in its own transaction, and the tests pass.", &.{});
    try expectTurn(parsed.items[4], .user, "Thanks. Also note that we deploy on Fridays.", &.{});
    try testing.expectEqual(@as(?core.Micros, 1_795_194_000_000_000), parsed.items[0].turn.ts);
    try testing.expect(parsed.items[1].start > parsed.items[0].start);
    try expectAbsent(parsed.items, "HIDDEN-THOUGHT");
    try expectAbsent(parsed.items, "Caveat");
    try expectAbsent(parsed.items, "command-name");
    try testing.expectEqual(@as(u64, 1), parsed.malformed);
    try testing.expectEqualStrings("/home/dev/acme/widget", parsed.meta.cwd.?);
    try testing.expectEqualStrings("0b6f9c1e-5a0d-4c7e-9a51-3f1e2d4c5b6a", parsed.meta.session_id.?);
    try testing.expectEqualStrings("example-model-large", parsed.meta.model.?);
}

test "codex rollout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseAll(arena_state.allocator(), .codex, @embedFile("testdata/codex/rollout.jsonl"));
    try testing.expectEqual(@as(usize, 5), parsed.items.len);
    try expectTurn(parsed.items[0], .user, "Why is the queue test flaky?", &.{});
    try expectTurn(parsed.items[1], .assistant, "", &.{.{ .name = "shell", .args_preview = "src/queue.zig:1-3" }});
    try expectTurn(parsed.items[2], .assistant, "", &.{.{ .name = "shell", .args_preview = "zig build test -Dtest-filter=queue", .result_preview = "error: lease expired before heartbeat\n" }});
    try testing.expectEqualStrings("apply_patch", parsed.items[3].turn.tool_calls[0].name);
    try testing.expect(std.mem.indexOf(u8, parsed.items[3].turn.tool_calls[0].args_preview, "+const lease_ms = 1000;") != null);
    try expectTurn(parsed.items[4], .assistant, "The lease was shorter than the heartbeat interval, so I raised it to 1 s.", &.{});
    try expectAbsent(parsed.items, "HIDDEN-REASONING");
    try expectAbsent(parsed.items, "environment_context");
    try testing.expectEqualStrings("/home/dev/acme/widget", parsed.meta.cwd.?);
    try testing.expectEqualStrings("5973b6c0-94b8-487b-a530-2aeb6098ae0e", parsed.meta.session_id.?);
    try testing.expectEqualStrings("example-model-mini", parsed.meta.model.?);
}

test "codex legacy rollout without envelopes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const legacy =
        \\{"id":"legacy-1","timestamp":"2025-05-01T10:00:00Z","instructions":null}
        \\{"record_type":"state"}
        \\{"type":"message","role":"user","content":[{"type":"input_text","text":"hello there"}]}
        \\{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}
    ;
    const parsed = try parseAll(arena_state.allocator(), .codex, legacy);
    try testing.expectEqual(@as(usize, 2), parsed.items.len);
    try expectTurn(parsed.items[1], .assistant, "hi", &.{});
    try testing.expectEqualStrings("legacy-1", parsed.meta.session_id.?);
}

test "pi session" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseAll(arena_state.allocator(), .pi, @embedFile("testdata/pi/session.jsonl"));
    try testing.expectEqual(@as(usize, 5), parsed.items.len);
    try expectTurn(parsed.items[0], .user, "Rename the notes CLI to jot.", &.{});
    try expectTurn(parsed.items[1], .assistant, "Checking the package name.", &.{.{ .name = "read", .args_preview = "package.json:1-3" }});
    try expectTurn(parsed.items[2], .assistant, "", &.{.{ .name = "bash", .args_preview = "npm test", .result_preview = "3 passing" }});
    try expectTurn(parsed.items[3], .assistant, "Renamed the CLI to jot; tests pass.", &.{});
    try expectTurn(parsed.items[4], .tool, "", &.{.{ .name = "bash", .args_preview = "git status --short", .result_preview = " M package.json\n" }});
    try expectAbsent(parsed.items, "HIDDEN-THOUGHT");
    try expectAbsent(parsed.items, "expert coding assistant");
    try testing.expectEqualStrings("/home/dev/acme/notes", parsed.meta.cwd.?);
    try testing.expectEqualStrings("example-model", parsed.meta.model.?);
}

test "fx conversation log" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseAll(arena_state.allocator(), .fx, @embedFile("testdata/fx/conversation.jsonl"));
    try testing.expectEqual(@as(usize, 3), parsed.items.len);
    try expectTurn(parsed.items[0], .user, "List the open TODOs in the parser.", &.{});
    try expectTurn(parsed.items[1], .assistant, "", &.{.{ .name = "grep", .args_preview = "{\"pattern\":\"TODO\",\"path\":\"src\"}", .result_preview = "src/parse.zig:12: TODO handle CRLF" }});
    try expectTurn(parsed.items[2], .assistant, "One TODO: CRLF handling in src/parse.zig.", &.{});
}

test "fx event log" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseAll(arena_state.allocator(), .fx, @embedFile("testdata/fx/events.jsonl"));
    try testing.expectEqual(@as(usize, 4), parsed.items.len);
    try expectTurn(parsed.items[0], .user, "Bump the zig version to 0.17.1.", &.{});
    try expectTurn(parsed.items[1], .assistant, "Reading build.zig.zon first.", &.{.{ .name = "read_file", .args_preview = "build.zig.zon:1-3" }});
    try expectTurn(parsed.items[2], .assistant, "", &.{.{ .name = "run_command", .args_preview = "zig build", .result_preview = "build ok" }});
    try expectTurn(parsed.items[3], .assistant, "Bumped to 0.17.1; the build passes.", &.{});
    try testing.expectEqualStrings("/home/dev/acme/widget", parsed.meta.cwd.?);
    try testing.expectEqualStrings("sess-fx-1", parsed.meta.session_id.?);
}

test "a step is held until its results arrive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(Item) = .empty;
    var p = Parser.init(.@"claude-code", arena);
    const sink: Sink = .{ .arena = arena, .scratch = arena, .out = &out };
    try p.feed(sink, "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"sleep 600\"}}]}}", 100);
    try p.flushResolved(sink);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try testing.expectEqual(@as(?u64, 100), p.pendingStart());

    var other = std.heap.ArenaAllocator.init(testing.allocator);
    defer other.deinit();
    try p.rehome(other.allocator());
    try p.feed(sink, "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"done\"}]}}", 200);
    try p.flushResolved(sink);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, 100), out.items[0].start);
    try testing.expectEqualStrings("done", out.items[0].turn.tool_calls[0].result_preview);
    try testing.expectEqual(@as(?u64, null), p.pendingStart());
}

test "orphan tool results become tool turns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(Item) = .empty;
    var p = Parser.init(.pi, arena);
    const sink: Sink = .{ .arena = arena, .scratch = arena, .out = &out };
    try p.feed(sink, "{\"type\":\"message\",\"message\":{\"role\":\"toolResult\",\"toolCallId\":\"x\",\"toolName\":\"bash\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}", 0);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try expectTurn(out.items[0], .tool, "", &.{.{ .name = "bash", .result_preview = "ok" }});
}
