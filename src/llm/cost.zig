const std = @import("std");
const core = @import("core");
const Usage = @import("wire.zig").Usage;
const CostStatus = core.types.CostStatus;

pub const Cost = struct {
    usd: f64 = 0,
    status: CostStatus = .missing,
};

pub const Rate = core.config.Rate;

pub fn resolve(
    header_value: ?[]const u8,
    body_cost: ?f64,
    body_status: ?CostStatus,
    usage: Usage,
    model: []const u8,
    reported_model: ?[]const u8,
    rates: []const []const u8,
) Cost {
    if (header_value) |h| if (parseUsd(h)) |usd| return .{ .usd = usd, .status = .priced };
    if (body_cost) |usd| if (usd >= 0 and std.math.isFinite(usd)) return .{ .usd = usd, .status = body_status orelse .priced };

    for (rates) |text| {
        const r = core.config.parseRate(text) catch continue;
        const reported = reported_model orelse "";
        if (!std.mem.eql(u8, r.model, model) and !std.mem.eql(u8, r.model, reported)) continue;
        return .{
            .usd = (@as(f64, @floatFromInt(usage.input_tokens)) * r.input_per_mtok +
                @as(f64, @floatFromInt(usage.output_tokens)) * r.output_per_mtok +
                @as(f64, @floatFromInt(usage.cache_read_tokens)) * r.cache_read_per_mtok +
                @as(f64, @floatFromInt(usage.cache_write_tokens)) * r.cache_write_per_mtok) / 1_000_000.0,
            .status = .estimated,
        };
    }

    return .{};
}

fn parseUsd(text: []const u8) ?f64 {
    const usd = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t$")) catch return null;
    return if (usd >= 0 and std.math.isFinite(usd)) usd else null;
}

test "header, then body, then rate table, then missing" {
    const usage: Usage = .{ .input_tokens = 1_000_000, .output_tokens = 500_000, .cache_read_tokens = 2_000_000 };
    const rates = [_][]const u8{ "bad entry", "m input=1 output=4 cache_read=0.1" };

    try std.testing.expectEqual(Cost{ .usd = 0.00042, .status = .priced }, resolve("0.00042", 9, null, usage, "m", null, &rates));
    try std.testing.expectEqual(Cost{ .usd = 9, .status = .priced }, resolve("n/a", 9, null, usage, "m", null, &rates));
    try std.testing.expectEqual(Cost{ .usd = 9, .status = .estimated }, resolve(null, 9, .estimated, usage, "m", null, &rates));
    try std.testing.expectEqual(Cost{ .usd = 3.2, .status = .estimated }, resolve(null, null, null, usage, "m", null, &rates));
    try std.testing.expectEqual(Cost{}, resolve(null, null, null, usage, "other", null, &rates));
}

test "the rate table matches the configured or the reported model id" {
    const usage: Usage = .{ .input_tokens = 1_000_000 };
    const rates = [_][]const u8{"model-2026-01-01 input=3 output=0"};

    try std.testing.expectEqual(Cost{ .usd = 3, .status = .estimated }, resolve(null, null, null, usage, "model", "model-2026-01-01", &rates));
    try std.testing.expectEqual(Cost{}, resolve(null, null, null, usage, "model", null, &rates));
}
