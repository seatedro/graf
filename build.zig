const std = @import("std");

const modules = [_]struct { name: []const u8, deps: []const []const u8 }{
    .{ .name = "core", .deps = &.{} },
    .{ .name = "store", .deps = &.{ "core", "pg" } },
    .{ .name = "llm", .deps = &.{"core"} },
    .{ .name = "capture", .deps = &.{"core"} },
    .{ .name = "ingest", .deps = &.{ "core", "store", "llm", "pg" } },
    .{ .name = "retrieve", .deps = &.{ "core", "store", "llm", "pg" } },
    .{ .name = "eval", .deps = &.{ "core", "store", "llm", "ingest", "retrieve" } },
    .{ .name = "surface", .deps = &.{ "core", "store", "llm", "capture", "ingest", "retrieve", "eval" } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filters = b.option([]const []const u8, "test-filter", "Run only tests whose names contain this text") orelse &.{};

    var registry: std.StringHashMapUnmanaged(*std.Build.Module) = .empty;
    const pg = b.dependency("pg", .{ .target = target, .optimize = optimize }).module("pg");
    registry.put(b.allocator, "pg", pg) catch @panic("OOM");

    const test_db = b.graph.environ_map.get("GRAF_TEST_DATABASE_URL");

    const test_step = b.step("test", "Run every module's unit and integration tests");
    for (modules) |m| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}/mod.zig", .{m.name})),
            .target = target,
            .optimize = optimize,
        });
        for (m.deps) |dep| {
            const imported = registry.get(dep) orelse
                std.debug.panic("module '{s}' depends on '{s}', which must be listed before it", .{ m.name, dep });
            mod.addImport(dep, imported);
        }
        registry.put(b.allocator, m.name, mod) catch @panic("OOM");

        const tests = b.addTest(.{ .name = m.name, .root_module = mod, .filters = filters });
        const run_tests = b.addRunArtifact(tests);
        if (test_db) |url| {
            run_tests.setEnvironmentVariable("GRAF_TEST_DATABASE_URL", url);
            run_tests.has_side_effects = true;
        }
        test_step.dependOn(&run_tests.step);
        b.step(b.fmt("test-{s}", .{m.name}), b.fmt("Run the {s} module's tests", .{m.name})).dependOn(&run_tests.step);
    }

    const exe = b.addExecutable(.{
        .name = "graf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "surface", .module = registry.get("surface").? }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run graf (pass arguments after --)").dependOn(&run.step);
}
