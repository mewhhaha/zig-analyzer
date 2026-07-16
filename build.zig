const std = @import("std");

const version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption(std.SemanticVersion, "version", version);
    build_options.addOption([]const u8, "version_string", @import("build.zig.zon").version);
    build_options.addOption([]const u8, "zig_version", "0.16.0");
    build_options.addOption([]const u8, "zig_commit", "24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8");
    build_options.addOption(u16, "compiler_protocol_version", 4);

    const lsp_module = b.dependency("lsp_kit", .{
        .target = target,
        .optimize = optimize,
    }).module("lsp");

    const analyzer_module = b.addModule("zig_analyzer", .{
        .root_source_file = b.path("src/zig_analyzer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options.createModule() },
            .{ .name = "lsp", .module = lsp_module },
        },
    });

    const executable = b.addExecutable(.{
        .name = "zig-analyzer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig_analyzer", .module = analyzer_module }},
        }),
    });
    b.installArtifact(executable);

    const check_executable = b.addExecutable(.{
        .name = "zig-analyzer",
        .root_module = executable.root_module,
    });
    const check_step = b.step("check", "Check that zig-analyzer compiles");
    check_step.dependOn(&check_executable.step);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_command.addArgs(args);
    const run_step = b.step("run", "Run zig-analyzer");
    run_step.dependOn(&run_command.step);

    const backend_command = b.addRunArtifact(executable);
    backend_command.addArgs(&.{ "backend", "bootstrap" });
    const backend_step = b.step("backend", "Bootstrap the patched Zig compiler backend");
    backend_step.dependOn(&backend_command.step);

    const module_tests = b.addTest(.{ .root_module = analyzer_module });
    const run_module_tests = b.addRunArtifact(module_tests);
    const comptime_fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("fixtures/comptime/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_comptime_fixture_tests = b.addRunArtifact(comptime_fixture_tests);
    const test_step = b.step("test", "Run zig-analyzer tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_comptime_fixture_tests.step);

    const fixtures_step = b.step("fixtures", "Run the comptime regression fixtures");
    fixtures_step.dependOn(&run_comptime_fixture_tests.step);

    const comparison_examples_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/examples.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_comparison_examples_tests = b.addRunArtifact(comparison_examples_tests);
    const examples_step = b.step("examples", "Compile and test the language-server comparison examples");
    examples_step.dependOn(&run_comparison_examples_tests.step);
    test_step.dependOn(&run_comparison_examples_tests.step);

    const compiler_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/compiler_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig_analyzer", .module = analyzer_module }},
        }),
    });
    const run_compiler_integration_tests = b.addRunArtifact(compiler_integration_tests);
    run_compiler_integration_tests.step.dependOn(&backend_command.step);
    const backend_test_step = b.step("backend-test", "Run tests against the patched compiler backend");
    backend_test_step.dependOn(&run_compiler_integration_tests.step);
}
