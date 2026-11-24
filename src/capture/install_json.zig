const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{InvalidJson} || Allocator.Error;

pub const Span = struct {
    start: usize,
    end: usize,

    pub fn slice(s: Span, text: []const u8) []const u8 {
        return text[s.start..s.end];
    }
};

pub const Member = struct {
    key: []const u8,
    key_start: usize,
    value: Span,
};

pub fn root(text: []const u8) Error!Span {
    const start = skipWs(text, 0);
    if (start >= text.len) return error.InvalidJson;
    const end = try valueEnd(text, start);
    if (skipWs(text, end) != text.len) return error.InvalidJson;
    return .{ .start = start, .end = end };
}

pub fn isObject(text: []const u8, span: Span) bool {
    return text[span.start] == '{';
}

pub fn isArray(text: []const u8, span: Span) bool {
    return text[span.start] == '[';
}

pub fn members(arena: Allocator, text: []const u8, object: Span) Error![]Member {
    if (!isObject(text, object)) return error.InvalidJson;
    var list: std.ArrayList(Member) = .empty;
    var pos = skipWs(text, object.start + 1);
    if (text[pos] == '}') return list.items;

    while (true) {
        if (pos >= text.len or text[pos] != '"') return error.InvalidJson;
        const key_start = pos;
        const key_end = try stringEnd(text, pos);
        pos = skipWs(text, key_end);
        if (pos >= text.len or text[pos] != ':') return error.InvalidJson;

        const value_start = skipWs(text, pos + 1);
        const value_end = try valueEnd(text, value_start);
        try list.append(arena, .{
            .key = text[key_start + 1 .. key_end - 1],
            .key_start = key_start,
            .value = .{ .start = value_start, .end = value_end },
        });

        pos = skipWs(text, value_end);
        if (pos >= text.len) return error.InvalidJson;
        if (text[pos] == '}') return list.items;
        if (text[pos] != ',') return error.InvalidJson;
        pos = skipWs(text, pos + 1);
    }
}

pub fn elements(arena: Allocator, text: []const u8, array: Span) Error![]Span {
    if (!isArray(text, array)) return error.InvalidJson;
    var list: std.ArrayList(Span) = .empty;
    var pos = skipWs(text, array.start + 1);
    if (text[pos] == ']') return list.items;

    while (true) {
        const end = try valueEnd(text, pos);
        try list.append(arena, .{ .start = pos, .end = end });

        pos = skipWs(text, end);
        if (pos >= text.len) return error.InvalidJson;
        if (text[pos] == ']') return list.items;
        if (text[pos] != ',') return error.InvalidJson;
        pos = skipWs(text, pos + 1);
    }
}

pub fn find(arena: Allocator, text: []const u8, object: Span, key: []const u8) Error!?Member {
    for (try members(arena, text, object)) |m| {
        if (std.mem.eql(u8, m.key, key)) return m;
    }
    return null;
}

pub fn stringValue(arena: Allocator, text: []const u8, span: Span) Error!?[]const u8 {
    if (text[span.start] != '"') return null;
    return std.json.parseFromSliceLeaky([]const u8, arena, span.slice(text), .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
}

pub fn insertMember(arena: Allocator, text: []const u8, object: Span, key: []const u8, value: anytype) Error![]const u8 {
    const existing = try members(arena, text, object);
    const key_json = try std.json.Stringify.valueAlloc(arena, key, .{});

    if (existing.len > 0) {
        const last = existing[existing.len - 1];
        if (lineIndent(text, last.key_start)) |indent| {
            const rendered = try render(arena, value, indent, indentUnit(text));
            return splice(arena, text, last.value.end, last.value.end, &.{ ",\n", indent, key_json, ": ", rendered });
        }
        const rendered = try std.json.Stringify.valueAlloc(arena, value, .{});
        return splice(arena, text, last.value.end, last.value.end, &.{ ", ", key_json, ": ", rendered });
    }

    const outer = leadingIndent(text, object.start);
    const inner = try std.mem.concat(arena, u8, &.{ outer, indentUnit(text) });
    const rendered = try render(arena, value, inner, indentUnit(text));
    return splice(arena, text, object.start + 1, object.end - 1, &.{ "\n", inner, key_json, ": ", rendered, "\n", outer });
}

pub fn appendElement(arena: Allocator, text: []const u8, array: Span, value: anytype) Error![]const u8 {
    const existing = try elements(arena, text, array);

    if (existing.len > 0) {
        const last = existing[existing.len - 1];
        if (lineIndent(text, last.start)) |indent| {
            const rendered = try render(arena, value, indent, indentUnit(text));
            return splice(arena, text, last.end, last.end, &.{ ",\n", indent, rendered });
        }
        const rendered = try std.json.Stringify.valueAlloc(arena, value, .{});
        return splice(arena, text, last.end, last.end, &.{ ", ", rendered });
    }

    const outer = leadingIndent(text, array.start);
    const inner = try std.mem.concat(arena, u8, &.{ outer, indentUnit(text) });
    const rendered = try render(arena, value, inner, indentUnit(text));
    return splice(arena, text, array.start + 1, array.end - 1, &.{ "\n", inner, rendered, "\n", outer });
}

pub fn replaceValue(arena: Allocator, text: []const u8, span: Span, value: anytype) Error![]const u8 {
    const rendered = try render(arena, value, leadingIndent(text, span.start), indentUnit(text));
    return splice(arena, text, span.start, span.end, &.{rendered});
}

pub fn render(arena: Allocator, value: anytype, indent: []const u8, unit: []const u8) Allocator.Error![]const u8 {
    const whitespace: @FieldType(std.json.Stringify.Options, "whitespace") = if (std.mem.eql(u8, unit, "\t")) .indent_tab else switch (unit.len) {
        1 => .indent_1,
        3 => .indent_3,
        4 => .indent_4,
        8 => .indent_8,
        else => .indent_2,
    };

    const pretty = try std.json.Stringify.valueAlloc(arena, value, .{ .whitespace = whitespace });
    if (std.mem.indexOfScalar(u8, pretty, '\n') == null or indent.len == 0) return pretty;

    var out: std.ArrayList(u8) = .empty;
    for (pretty) |ch| {
        try out.append(arena, ch);
        if (ch == '\n') try out.appendSlice(arena, indent);
    }
    return out.items;
}

pub fn indentUnit(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i == 0 or i == line.len) continue;
        if (line[0] == '\t') return "\t";
        return line[0..@min(i, 8)];
    }
    return "  ";
}

fn splice(arena: Allocator, text: []const u8, start: usize, end: usize, parts: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, text[0..start]);
    for (parts) |p| try out.appendSlice(arena, p);
    try out.appendSlice(arena, text[end..]);
    return out.items;
}

fn lineIndent(text: []const u8, pos: usize) ?[]const u8 {
    var i = pos;
    while (i > 0 and (text[i - 1] == ' ' or text[i - 1] == '\t')) i -= 1;
    if (i == 0 or text[i - 1] == '\n') return text[i..pos];
    return null;
}

fn leadingIndent(text: []const u8, pos: usize) []const u8 {
    var line_start = pos;
    while (line_start > 0 and text[line_start - 1] != '\n') line_start -= 1;
    var i = line_start;
    while (i < pos and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return text[line_start..i];
}

fn skipWs(text: []const u8, start: usize) usize {
    var pos = start;
    while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
    return pos;
}

fn stringEnd(text: []const u8, start: usize) Error!usize {
    var pos = start + 1;
    while (pos < text.len) : (pos += 1) {
        switch (text[pos]) {
            '\\' => pos += 1,
            '"' => return pos + 1,
            else => {},
        }
    }
    return error.InvalidJson;
}

fn valueEnd(text: []const u8, start: usize) Error!usize {
    if (start >= text.len) return error.InvalidJson;
    switch (text[start]) {
        '"' => return stringEnd(text, start),
        '{', '[' => {
            const close: u8 = if (text[start] == '{') '}' else ']';
            var pos = skipWs(text, start + 1);
            if (pos < text.len and text[pos] == close) return pos + 1;

            while (true) {
                if (close == '}') {
                    if (pos >= text.len or text[pos] != '"') return error.InvalidJson;
                    pos = skipWs(text, try stringEnd(text, pos));
                    if (pos >= text.len or text[pos] != ':') return error.InvalidJson;
                    pos = skipWs(text, pos + 1);
                }

                pos = skipWs(text, try valueEnd(text, pos));
                if (pos >= text.len) return error.InvalidJson;
                if (text[pos] == close) return pos + 1;
                if (text[pos] != ',') return error.InvalidJson;
                pos = skipWs(text, pos + 1);
            }
        },
        't' => return literal(text, start, "true"),
        'f' => return literal(text, start, "false"),
        'n' => return literal(text, start, "null"),
        '-', '0'...'9' => {
            var pos = start + 1;
            while (pos < text.len) : (pos += 1) switch (text[pos]) {
                '0'...'9', '.', 'e', 'E', '+', '-' => {},
                else => break,
            };
            return pos;
        },
        else => return error.InvalidJson,
    }
}

fn literal(text: []const u8, start: usize, word: []const u8) Error!usize {
    if (!std.mem.startsWith(u8, text[start..], word)) return error.InvalidJson;
    return start + word.len;
}

const testing = std.testing;

test "insert into populated, empty and single-line objects keeps the rest byte-for-byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pretty = "{\n    \"a\": 1,\n    \"b\": [true, null]\n}\n";
    const r = try root(pretty);
    const added = try insertMember(arena, pretty, r, "c", .{ .x = "y" });
    try testing.expectEqualStrings("{\n    \"a\": 1,\n    \"b\": [true, null],\n    \"c\": {\n        \"x\": \"y\"\n    }\n}\n", added);

    const empty = "{ }";
    try testing.expectEqualStrings("{\n  \"k\": 1\n}", try insertMember(arena, empty, try root(empty), "k", 1));

    const inline_obj = "{\"a\":1}";
    try testing.expectEqualStrings("{\"a\":1, \"k\": [\"v\"]}", try insertMember(arena, inline_obj, try root(inline_obj), "k", .{"v"}));

    const nested = "{\n  \"outer\": {}\n}";
    const outer = (try find(arena, nested, try root(nested), "outer")).?;
    try testing.expectEqualStrings("{\n  \"outer\": {\n    \"k\": 1\n  }\n}", try insertMember(arena, nested, outer.value, "k", 1));
}

test "append elements and replace values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "{\n  \"list\": [\n    {\"keep\": \"me\"}\n  ],\n  \"s\": \"old\\\"q\"\n}";
    const list = (try find(arena, text, try root(text), "list")).?;
    const appended = try appendElement(arena, text, list.value, .{ .n = 2 });
    try testing.expectEqualStrings("{\n  \"list\": [\n    {\"keep\": \"me\"},\n    {\n      \"n\": 2\n    }\n  ],\n  \"s\": \"old\\\"q\"\n}", appended);

    const s = (try find(arena, appended, try root(appended), "s")).?;
    try testing.expectEqualStrings("old\"q", (try stringValue(arena, appended, s.value)).?);
    const replaced = try replaceValue(arena, appended, s.value, "new");
    try testing.expect(std.mem.endsWith(u8, replaced, "\"s\": \"new\"\n}"));

    const empty = "[]";
    try testing.expectEqualStrings("[\n  1\n]", try appendElement(arena, empty, try root(empty), 1));
}

test "rejects invalid documents" {
    try testing.expectError(error.InvalidJson, root(""));
    try testing.expectError(error.InvalidJson, root("{\"a\": 1,}"));
    try testing.expectError(error.InvalidJson, root("{\"a\" 1}"));
    try testing.expectError(error.InvalidJson, root("{} trailing"));
    try testing.expectError(error.InvalidJson, root("{\"a\": \"unterminated}"));
    _ = try root(" {\"a\": [1, -2.5e3, \"x\\\\\", {}, [], false]} ");
}
