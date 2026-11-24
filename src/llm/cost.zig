const std = @import("std");
const core = @import("core");
const Usage = @import("wire.zig").Usage;
const CostStatus = core.types.CostStatus;

pub const Cost = struct {
    usd: f64 = 0,
    status: CostStatus = .missing,
};

pub const Rate = struct {
    model: []const u8,
    input_per_mtok: f64,
    output_per_mtok: f64,
    cache_read_per_mtok: f64 = 0,
    cache_write_per_mtok: f64 = 0,
};

pub fn resolve(
    header_value: ?[]const u8,
    body_cost: ?f64,
    body_status: ?CostStatus,
    usage: Usage,
    model: []const u8,
    rates: []const Rate,
) Cost {
    if (header_value) |h| if (parseUsd(h)) |usd| return .{ .usd = usd, .status = .priced };
    if (body_cost) |usd| if (usd >= 0 and std.math.isFinite(usd)) return .{ .usd = usd, .status = body_status orelse .priced };
    for (rates) |r| if (std.mem.eql(u8, r.model, model)) return .{
        .usd = (@as(f64, @floatFromInt(usage.input_tokens)) * r.input_per_mtok +
            @as(f64, @floatFromInt(usage.output_tokens)) * r.output_per_mtok +
            @as(f64, @floatFromInt(usage.cache_read_tokens)) * r.cache_read_per_mtok +
            @as(f64, @floatFromInt(usage.cache_write_tokens)) * r.cache_write_per_mtok) / 1_000_000.0,
        .status = .estimated,
    };
    return .{};
}

fn parseUsd(text: []const u8) ?f64 {
    const usd = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t$")) catch return null;
    return if (usd >= 0 and std.math.isFinite(usd)) usd else null;
}

test "header, then body, then rate table, then missing" {
    const usage: Usage = .{ .input_tokens = 1_000_000, .output_tokens = 500_000, .cache_read_tokens = 2_000_000 };
    const rates = [_]Rate{.{ .model = "m", .input_per_mtok = 1, .output_per_mtok = 4, .cache_read_per_mtok = 0.1 }};
    try std.testing.expectEqual(Cost{ .usd = 0.00042, .status = .priced }, resolve("0.00042", 9, null, usage, "m", &rates));
    try std.testing.expectEqual(Cost{ .usd = 9, .status = .priced }, resolve("n/a", 9, null, usage, "m", &rates));
    try std.testing.expectEqual(Cost{ .usd = 9, .status = .estimated }, resolve(null, 9, .estimated, usage, "m", &rates));
    try std.testing.expectEqual(Cost{ .usd = 3.2, .status = .estimated }, resolve(null, null, null, usage, "m", &rates));
    try std.testing.expectEqual(Cost{}, resolve(null, null, null, usage, "other", &rates));
}
