const std = @import("std");
const core = @import("core");
const mod = @import("mod.zig");
const fixtures = @import("fixtures.zig");
const score = @import("score.zig");
const runner = @import("runner.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const usage =
    \\usage: graf eval run [--suite DIR] [--graph NAME] [--serve-bin PATH] [--json]
    \\
    \\Replays the labeled entry suite into a fresh graph, scores the release gates,
    \\and exits non-zero when any gate fails or could not be measured.
    \\
    \\  --suite DIR        directory holding entries.jsonl and expected.json (default: evals)
    \\  --graph NAME       graph to create for the run (default: eval-<unix ms>)
    \\  --serve-bin PATH   graf binary used for the crash-resume check (skipped when absent)
    \\  --json             print the report as JSON instead of a table
    \\
;

pub const Args = struct {
    run: runner.RunOptions = .{},
    json: bool = false,
};

pub fn parseArgs(args: []const []const u8) error{Usage}!Args {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "run")) return error.Usage;
    var out: Args = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--json")) {
            out.json = true;
            continue;
        }
        if (i + 1 >= args.len) return error.Usage;
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, flag, "--suite")) {
            out.run.suite_dir = value;
        } else if (std.mem.eql(u8, flag, "--graph")) {
            out.run.graph = value;
        } else if (std.mem.eql(u8, flag, "--serve-bin")) {
            out.run.serve_bin = value;
        } else return error.Usage;
    }
    return out;
}

pub fn main(
    arena: Allocator,
    io: std.Io,
    config: *const core.Config,
    environ: *const std.process.Environ.Map,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    for (args) |a| if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
        try out.writeAll(usage);
        return 0;
    };
    var parsed = parseArgs(args) catch {
        try err.writeAll(usage);
        return 2;
    };
    parsed.run.environ = environ;

    const suite = fixtures.loadSuite(arena, io, parsed.run.suite_dir) catch |e| {
        try err.print("graf eval: cannot load suite from {s}: {s}\n", .{ parsed.run.suite_dir, @errorName(e) });
        return 2;
    };
    const problems = try fixtures.validate(arena, &suite);
    if (problems.len > 0) {
        for (problems) |p| try err.print("graf eval: {s}\n", .{p});
        return 2;
    }
    if (config.database.url.len == 0) {
        try err.writeAll("graf eval: set database.url or GRAF_DATABASE_URL\n");
        return 2;
    }

    const report = try runner.run(arena, io, config, parsed.run);
    if (parsed.json) try writeJson(report, out) else try writeScorecard(report, out);
    return if (report.metrics.passes()) 0 else 1;
}

fn formatValue(buf: []u8, unit: mod.Gate.Unit, value: f64) []const u8 {
    return switch (unit) {
        .ratio => std.fmt.bufPrint(buf, "{d:.3}", .{value}),
        .count => std.fmt.bufPrint(buf, "{d:.0}", .{value}),
        .calls => std.fmt.bufPrint(buf, "{d:.2}", .{value}),
        .usd => std.fmt.bufPrint(buf, "${d:.4}", .{value}),
    } catch "?";
}

fn statusLabel(s: mod.Gate.Status) []const u8 {
    return switch (s) {
        .pass => "PASS",
        .fail => "FAIL",
        .unmeasured => "n/a",
    };
}

pub fn writeScorecard(report: score.Report, w: *Writer) !void {
    const d = report.detail;
    try w.print("graf eval: graph {s}, {d} of {d} entries finished\n\n", .{ report.graph orelse "(none)", d.terminal_entries, d.suite_entries });
    try w.print("{s:<24} {s:>10}  {s:<11} {s}\n", .{ "metric", "value", "gate", "result" });
    var failing: u32 = 0;
    const list = report.metrics.gateList();
    for (list) |g| {
        var value_buf: [32]u8 = undefined;
        var limit_buf: [32]u8 = undefined;
        var gate_buf: [40]u8 = undefined;
        const value = if (g.value) |v| formatValue(&value_buf, g.unit, v) else "-";
        const limit = formatValue(&limit_buf, if (g.unit == .ratio) .calls else g.unit, g.limit);
        const gate = std.fmt.bufPrint(&gate_buf, "{s} {s}", .{ if (g.bound == .at_least) ">=" else "<=", limit }) catch "?";
        const status = g.status();
        if (status != .pass) failing += 1;
        try w.print("{s:<24} {s:>10}  {s:<11} {s}\n", .{ g.metric, value, gate, statusLabel(status) });
    }

    try w.writeAll("\ndetails\n");
    try w.print("  entities: {d} matched, {d} false positives, {d} missing, {d} unlabeled\n", .{ d.entity_tp, d.entity_fp, d.entity_fn, d.unlabeled_entities });
    try w.print("  merges: {d} of {d} pairs correct\n", .{ d.merges_correct, d.merge_pairs });
    try w.print("  facts: {d} true positives, {d} false positives; {d} of {d} gold items found\n", .{ d.fact_tp, d.fact_fp, d.gold_fact_items_found, d.gold_fact_items });
    try w.print("  invalidations: {d} correct, {d} false positives, {d} missed\n", .{ d.invalidation_tp, d.invalidation_fp, d.invalidation_fn });
    try w.print("  temporal: {d} of {d} bounds within one day\n", .{ d.temporal_correct, d.temporal_items });
    if (d.retrieval_exclusion_violations) |v| {
        try w.print("  retrieval: {d} of {d} expected facts in the top 5, {d} exclusion violations\n", .{ d.retrieval_found, d.retrieval_expected, v });
    } else try w.writeAll("  retrieval: not run\n");
    try w.print("  ledger: {d} extraction, {d} resolution, {d} repair, {d} embedding calls; ${d:.4} total\n", .{ d.extraction_calls, d.resolution_calls, d.repair_calls, d.embedding_calls, d.total_cost_usd });

    if (report.findings.len > 0) {
        try w.print("\nfindings ({d})\n", .{report.findings.len});
        for (report.findings) |f| try w.print("  - {s}\n", .{f});
    }
    if (failing == 0) {
        try w.print("\nresult: PASS ({d} of {d} gates)\n", .{ list.len, list.len });
    } else try w.print("\nresult: FAIL ({d} of {d} gates failed or unmeasured)\n", .{ failing, list.len });
}

const JsonGate = struct {
    metric: []const u8,
    value: ?f64,
    bound: mod.Gate.Bound,
    limit: f64,
    status: mod.Gate.Status,
};

pub fn writeJson(report: score.Report, w: *Writer) !void {
    var gates: [12]JsonGate = undefined;
    for (report.metrics.gateList(), &gates) |g, *j| j.* = .{ .metric = g.metric, .value = g.value, .bound = g.bound, .limit = g.limit, .status = g.status() };
    try std.json.Stringify.value(.{
        .graph = report.graph,
        .passes = report.metrics.passes(),
        .gates = gates,
        .detail = report.detail,
        .findings = report.findings,
    }, .{ .whitespace = .indent_2 }, w);
    try w.writeAll("\n");
}

const testing = std.testing;

test "arguments parse into run options" {
    const a = try parseArgs(&.{ "run", "--suite", "x/evals", "--graph", "g1", "--serve-bin", "zig-out/bin/graf", "--json" });
    try testing.expectEqualStrings("x/evals", a.run.suite_dir);
    try testing.expectEqualStrings("g1", a.run.graph.?);
    try testing.expectEqualStrings("zig-out/bin/graf", a.run.serve_bin.?);
    try testing.expect(a.json);
    const d = try parseArgs(&.{"run"});
    try testing.expectEqualStrings("evals", d.run.suite_dir);
    try testing.expect(d.run.graph == null and !d.json);
    try testing.expectError(error.Usage, parseArgs(&.{}));
    try testing.expectError(error.Usage, parseArgs(&.{ "run", "--suite" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "run", "--bogus", "1" }));
    try testing.expectError(error.Usage, parseArgs(&.{"score"}));
}

test "main rejects bad usage and a missing database without touching the network" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(arena);
    const config: core.Config = .{};
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var err: Writer = .fixed(&err_buf);
    try testing.expectEqual(@as(u8, 2), try main(arena, testing.io, &config, &env, &.{"nope"}, &out, &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "usage: graf eval run") != null);
    err.end = 0;
    const dir = try fixtures.shippedSuiteDir(arena, testing.io);
    try testing.expectEqual(@as(u8, 2), try main(arena, testing.io, &config, &env, &.{ "run", "--suite", dir }, &out, &err));
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "GRAF_DATABASE_URL") != null);
    try testing.expectEqual(@as(u8, 0), try main(arena, testing.io, &config, &env, &.{"--help"}, &out, &err));
}

test "the scorecard shows every gate with its status" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suite = try fixtures.loadShippedSuite(arena, testing.io);
    const gold = try score.goldState(arena, &suite);
    var report = try score.scoreState(arena, &suite, &gold);
    report.graph = "eval-test";

    var buf: std.Io.Writer.Allocating = .init(arena);
    try writeScorecard(report, &buf.writer);
    const text = buf.written();
    try testing.expect(std.mem.indexOf(u8, text, "graph eval-test, 20 of 20 entries finished") != null);
    try testing.expect(std.mem.indexOf(u8, text, "entity_f1                     1.000  >= 0.85     PASS") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cost_per_entry_usd          $0.0059  <= $0.0200  PASS") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cross_type_merges                 0  <= 0        PASS") != null);
    try testing.expect(std.mem.indexOf(u8, text, "result: PASS (12 of 12 gates)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "FAIL") == null);

    const empty = try score.scoreState(arena, &suite, &.{});
    var buf2: std.Io.Writer.Allocating = .init(arena);
    try writeScorecard(empty, &buf2.writer);
    const text2 = buf2.written();
    try testing.expect(std.mem.indexOf(u8, text2, "crash_resume_pass_rate            -  >= 1.00     n/a") != null);
    try testing.expect(std.mem.indexOf(u8, text2, "result: FAIL (12 of 12 gates failed or unmeasured)") != null);
    try testing.expect(std.mem.indexOf(u8, text2, "retrieval: not run") != null);
}

test "the json report round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suite = try fixtures.loadShippedSuite(arena, testing.io);
    const report = try score.scoreState(arena, &suite, &.{});
    var buf: std.Io.Writer.Allocating = .init(arena);
    try writeJson(report, &buf.writer);
    const Parsed = struct { passes: bool, gates: []const JsonGate, findings: []const []const u8 };
    const parsed = try std.json.parseFromSliceLeaky(Parsed, arena, buf.written(), .{ .ignore_unknown_fields = true });
    try testing.expect(!parsed.passes);
    try testing.expectEqual(@as(usize, 12), parsed.gates.len);
    try testing.expectEqual(mod.Gate.Status.unmeasured, parsed.gates[0].status);
    try testing.expect(parsed.gates[0].value == null);
}
