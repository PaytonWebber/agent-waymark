const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Which model2vec model to compile into the binary. The embedding
    // dimension is baked into the quantal index type at comptime, so it must
    // be a build-time constant and MUST match the model; a store written at a
    // different dimension is re-embedded on first load.
    const model = b.option([]const u8, "model", "Bundled embedding model (potion-retrieval-32M or potion-base-8M)") orelse "potion-retrieval-32M";
    const model_dim: usize = if (std.mem.eql(u8, model, "potion-retrieval-32M")) 512 else 256;
    const dim = b.option(usize, "dim", "Embedding vector dimension") orelse model_dim;
    const options = b.addOptions();
    options.addOption(usize, "dim", dim);
    options.addOption([]const u8, "model_name", model);

    // The embedding model is compiled into the binary (src/embedder.zig
    // embeds src/model/<name>/*); run scripts/fetch-model.sh once per model.
    const quantal = b.dependency("quantal", .{ .target = target, .optimize = optimize });
    const sdk = b.dependency("zig_mcp_sdk", .{ .target = target, .optimize = optimize });
    const m2v = b.dependency("model2vec", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "quantal", .module = quantal.module("quantal") },
            .{ .name = "zig_mcp_sdk", .module = sdk.module("zig_mcp_sdk") },
            .{ .name = "model2vec", .module = m2v.module("model2vec") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    const exe = b.addExecutable(.{ .name = "agent-waymark", .root_module = mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the agent-waymark CLI (pass args after --)");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Quantize the fetched f32 model to tq4 in place (8x smaller in the
    // binary and in daemon memory; measured within 0.002 NDCG@10 of f32 on
    // MTEB retrieval). Run once after scripts/fetch-model.sh; it needs the
    // f32 file as input, so re-fetch before re-running.
    const quantize = b.addRunArtifact(m2v.artifact("m2v-quantize"));
    quantize.addArg("--tq4");
    quantize.addArg(b.fmt("src/model/{s}/model.safetensors", .{model}));
    quantize.addArg(b.fmt("src/model/{s}/model.safetensors", .{model}));
    b.step("quantize-model", "Quantize the bundled model to tq4 in place").dependOn(&quantize.step);

    const integration = b.addSystemCommand(&.{"node"});
    integration.addFileArg(b.path("scripts/integration-smoke.mjs"));
    integration.addArtifactArg(exe);
    integration.addArg(b.fmt("{d}", .{dim}));
    const integration_step = b.step("integration", "Run daemon/MCP/hook integration smoke tests");
    integration_step.dependOn(&integration.step);
}
