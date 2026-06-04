const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The embedding dimension is baked into the quantal index type at comptime,
    // so it must be a build-time constant and MUST match the embedding model
    // (nomic-embed-text = 768). Changing it invalidates an existing store.
    const dim = b.option(usize, "dim", "Embedding vector dimension") orelse 768;
    const options = b.addOptions();
    options.addOption(usize, "dim", dim);

    const quantal = b.dependency("quantal", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "quantal", .module = quantal.module("quantal") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    const exe = b.addExecutable(.{ .name = "cairn", .root_module = mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the cairn CLI (pass args after --)");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
