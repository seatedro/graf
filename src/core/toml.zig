const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{ InvalidConfig, OutOfMemory };

pub fn parseInto(comptime T: type, arena: Allocator, src: []const u8, out: *T, diag: *Diagnostic) Error!void {
    var p: Parser = .{ .src = src, .arena = arena, .diag = diag };
    var table: std.ArrayList([]const u8) = .empty;

    while (true) {
        p.skipBlank();
        if (p.eof()) return;

        if (p.peek() == '[') {
            p.i += 1;
            if (!p.eof() and p.peek() == '[') return p.fail("arrays of tables are not supported", .{});
            table.clearRetainingCapacity();
            try p.parseKeyPath(&table);
            p.skipSpaces();
            if (p.eof() or p.peek() != ']') return p.fail("expected ']'", .{});
            p.i += 1;
            try p.expectLineEnd();
            continue;
        }

        var path: std.ArrayList([]const u8) = .empty;
        try path.appendSlice(arena, table.items);
        try p.parseKeyPath(&path);
        p.skipSpaces();
        if (p.eof() or p.peek() != '=') return p.fail("expected '=' after key", .{});
        p.i += 1;
        p.skipSpaces();
        const value = try p.parseValue();
        try assign(T, out, path.items, value, &p);
        try p.expectLineEnd();
    }
}

const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []const Value,
};

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    line: usize = 1,
    arena: Allocator,
    diag: *Diagnostic,

    fn eof(p: *Parser) bool {
        return p.i >= p.src.len;
    }

    fn peek(p: *Parser) u8 {
        return p.src[p.i];
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.diag.line = p.line;
        p.diag.message = try std.fmt.allocPrint(p.arena, fmt, args);
        return error.InvalidConfig;
    }

    fn skipSpaces(p: *Parser) void {
        while (!p.eof() and (p.peek() == ' ' or p.peek() == '\t')) p.i += 1;
    }

    fn skipComment(p: *Parser) void {
        if (!p.eof() and p.peek() == '#') {
            while (!p.eof() and p.peek() != '\n') p.i += 1;
        }
    }

    fn skipBlank(p: *Parser) void {
        while (!p.eof()) {
            switch (p.peek()) {
                ' ', '\t', '\r' => p.i += 1,
                '\n' => {
                    p.i += 1;
                    p.line += 1;
                },
                '#' => p.skipComment(),
                else => return,
            }
        }
    }

    fn expectLineEnd(p: *Parser) Error!void {
        p.skipSpaces();
        p.skipComment();
        if (p.eof()) return;
        if (p.peek() == '\r') p.i += 1;
        if (p.eof() or p.peek() != '\n') return p.fail("expected end of line", .{});
        p.i += 1;
        p.line += 1;
    }

    fn parseKeyPath(p: *Parser, path: *std.ArrayList([]const u8)) Error!void {
        while (true) {
            p.skipSpaces();
            if (p.eof()) return p.fail("expected a key", .{});
            const c = p.peek();
            const key = if (c == '"') try p.parseBasicString() else if (c == '\'') try p.parseLiteralString() else blk: {
                const start = p.i;
                while (!p.eof() and (std.ascii.isAlphanumeric(p.peek()) or p.peek() == '_' or p.peek() == '-')) p.i += 1;
                if (p.i == start) return p.fail("expected a key", .{});
                break :blk p.src[start..p.i];
            };

            try path.append(p.arena, key);
            p.skipSpaces();
            if (p.eof() or p.peek() != '.') return;
            p.i += 1;
        }
    }

    fn parseValue(p: *Parser) Error!Value {
        if (p.eof()) return p.fail("expected a value", .{});
        switch (p.peek()) {
            '"' => {
                if (std.mem.startsWith(u8, p.src[p.i..], "\"\"\"")) return p.fail("multi-line strings are not supported", .{});
                return .{ .string = try p.parseBasicString() };
            },
            '\'' => return .{ .string = try p.parseLiteralString() },
            '[' => return p.parseArray(),
            '{' => return p.fail("inline tables are not supported; use a [table] header", .{}),
            else => {},
        }

        const start = p.i;
        while (!p.eof() and std.mem.indexOfScalar(u8, " \t\r\n,]#", p.peek()) == null) p.i += 1;
        const word = p.src[start..p.i];
        if (std.mem.eql(u8, word, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, word, "false")) return .{ .boolean = false };

        var digits: std.ArrayList(u8) = .empty;
        for (word) |ch| if (ch != '_') try digits.append(p.arena, ch);
        if (std.fmt.parseInt(i64, digits.items, 10)) |n| return .{ .integer = n } else |_| {}
        if (std.fmt.parseFloat(f64, digits.items)) |f| return .{ .float = f } else |_| {}
        return p.fail("invalid value '{s}'", .{word});
    }

    fn parseArray(p: *Parser) Error!Value {
        p.i += 1;
        var items: std.ArrayList(Value) = .empty;

        while (true) {
            p.skipBlank();
            if (p.eof()) return p.fail("unterminated array", .{});
            if (p.peek() == ']') {
                p.i += 1;
                return .{ .array = items.items };
            }

            try items.append(p.arena, try p.parseValue());
            p.skipBlank();
            if (p.eof()) return p.fail("unterminated array", .{});
            switch (p.peek()) {
                ',' => p.i += 1,
                ']' => {},
                else => return p.fail("expected ',' or ']' in array", .{}),
            }
        }
    }

    fn parseLiteralString(p: *Parser) Error![]const u8 {
        p.i += 1;
        const start = p.i;
        while (!p.eof() and p.peek() != '\'') {
            if (p.peek() == '\n') return p.fail("unterminated string", .{});
            p.i += 1;
        }
        if (p.eof()) return p.fail("unterminated string", .{});
        p.i += 1;
        return p.src[start .. p.i - 1];
    }

    fn parseBasicString(p: *Parser) Error![]const u8 {
        p.i += 1;
        var out: std.ArrayList(u8) = .empty;

        while (true) {
            if (p.eof() or p.peek() == '\n') return p.fail("unterminated string", .{});
            const c = p.peek();
            p.i += 1;
            switch (c) {
                '"' => return out.items,
                '\\' => {
                    if (p.eof()) return p.fail("unterminated string", .{});
                    const e = p.peek();
                    p.i += 1;
                    switch (e) {
                        '"' => try out.append(p.arena, '"'),
                        '\\' => try out.append(p.arena, '\\'),
                        'n' => try out.append(p.arena, '\n'),
                        't' => try out.append(p.arena, '\t'),
                        'r' => try out.append(p.arena, '\r'),
                        'b' => try out.append(p.arena, 0x08),
                        'f' => try out.append(p.arena, 0x0c),
                        'u', 'U' => {
                            const n: usize = if (e == 'u') 4 else 8;
                            if (p.i + n > p.src.len) return p.fail("bad unicode escape", .{});
                            const cp = std.fmt.parseInt(u21, p.src[p.i .. p.i + n], 16) catch return p.fail("bad unicode escape", .{});
                            p.i += n;
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(cp, &buf) catch return p.fail("bad unicode escape", .{});
                            try out.appendSlice(p.arena, buf[0..len]);
                        },
                        else => return p.fail("unknown escape '\\{c}'", .{e}),
                    }
                },
                else => try out.append(p.arena, c),
            }
        }
    }
};

fn assign(comptime S: type, target: *S, path: []const []const u8, value: Value, p: *Parser) Error!void {
    const info = @typeInfo(S).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (std.mem.eql(u8, name, path[0])) {
            if (@typeInfo(F) == .@"struct") {
                if (path.len == 1) return p.fail("'{s}' is a table, not a value", .{name});
                return assign(F, &@field(target, name), path[1..], value, p);
            }

            if (path.len != 1) return p.fail("'{s}' is not a table", .{name});
            @field(target, name) = try convert(F, value, name, p);
            return;
        }
    }
    return p.fail("unknown key '{s}'", .{path[0]});
}

fn convert(comptime T: type, value: Value, name: []const u8, p: *Parser) Error!T {
    if (T == []const u8) {
        if (value != .string) return p.fail("'{s}' must be a string", .{name});
        return value.string;
    }

    if (T == []const []const u8) {
        if (value != .array) return p.fail("'{s}' must be an array of strings", .{name});
        const items = try p.arena.alloc([]const u8, value.array.len);
        for (value.array, items) |v, *item| {
            if (v != .string) return p.fail("'{s}' must be an array of strings", .{name});
            item.* = v.string;
        }
        return items;
    }

    switch (@typeInfo(T)) {
        .bool => {
            if (value != .boolean) return p.fail("'{s}' must be true or false", .{name});
            return value.boolean;
        },
        .int => {
            if (value != .integer) return p.fail("'{s}' must be an integer", .{name});
            return std.math.cast(T, value.integer) orelse p.fail("'{s}' is out of range", .{name});
        },
        .float => return switch (value) {
            .integer => |n| @floatFromInt(n),
            .float => |f| @floatCast(f),
            else => p.fail("'{s}' must be a number", .{name}),
        },
        .@"enum" => {
            if (value != .string) return p.fail("'{s}' must be a string", .{name});
            return std.meta.stringToEnum(T, value.string) orelse p.fail("'{s}' has no option '{s}'", .{ name, value.string });
        },
        else => @compileError("unsupported config field type " ++ @typeName(T)),
    }
}

const Example = struct {
    name: []const u8 = "",
    db: struct { url: []const u8 = "", pool: u16 = 4 } = .{},
    limits: struct { daily: f64 = 1, on: bool = false } = .{},
    mode: enum { fast, slow } = .fast,
    paths: []const []const u8 = &.{},
};

test "parses tables, scalars, arrays, escapes and comments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const src =
        \\# top-level
        \\name = "gr\u0061f\t!" # trailing comment
        \\mode = 'slow'
        \\paths = [
        \\  "~/a",  # first
        \\  '/b',
        \\]
        \\
        \\[db]
        \\url = "postgres://localhost/graf"
        \\pool = 1_6
        \\
        \\[limits]
        \\daily = 100
        \\on = true
        \\
    ;

    var out: Example = .{};
    var diag: Diagnostic = .{};
    try parseInto(Example, arena_state.allocator(), src, &out, &diag);

    try std.testing.expectEqualStrings("graf\t!", out.name);
    try std.testing.expectEqual(.slow, out.mode);
    try std.testing.expectEqual(@as(usize, 2), out.paths.len);
    try std.testing.expectEqualStrings("/b", out.paths[1]);
    try std.testing.expectEqualStrings("postgres://localhost/graf", out.db.url);
    try std.testing.expectEqual(@as(u16, 16), out.db.pool);
    try std.testing.expectEqual(@as(f64, 100), out.limits.daily);
    try std.testing.expect(out.limits.on);
}

test "dotted keys reach nested tables" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: Example = .{};
    var diag: Diagnostic = .{};
    try parseInto(Example, arena_state.allocator(), "db.url = \"x\"\n", &out, &diag);

    try std.testing.expectEqualStrings("x", out.db.url);
}

test "reports unknown keys and type errors with a line number" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Example = .{};
    var diag: Diagnostic = .{};

    try std.testing.expectError(error.InvalidConfig, parseInto(Example, arena, "\n[db]\nurll = \"x\"\n", &out, &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectEqualStrings("unknown key 'urll'", diag.message);

    try std.testing.expectError(error.InvalidConfig, parseInto(Example, arena, "[db]\npool = \"four\"\n", &out, &diag));
    try std.testing.expectError(error.InvalidConfig, parseInto(Example, arena, "mode = \"medium\"\n", &out, &diag));
    try std.testing.expectError(error.InvalidConfig, parseInto(Example, arena, "name = \"open\n", &out, &diag));
}
