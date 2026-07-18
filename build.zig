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
    build_options.addOption(u16, "compiler_protocol_version", 5);

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
    const compiler_patch_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/protocol_invariant.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "build_options", .module = build_options.createModule() }},
        }),
    });
    const run_compiler_patch_tests = b.addRunArtifact(compiler_patch_tests);
    const test_step = b.step("test", "Run zig-analyzer tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_comptime_fixture_tests.step);
    test_step.dependOn(&run_compiler_patch_tests.step);

    const no_argument_command = b.addRunArtifact(executable);
    no_argument_command.expectStdOutEqual(
        \\zig-analyzer - compiler-backed language intelligence for Zig
        \\
        \\Usage:
        \\  zig-analyzer lsp
        \\  zig-analyzer check [--fix] [--no-cache] [path]
        \\  zig-analyzer doctor
        \\  zig-analyzer backend bootstrap
        \\  zig-analyzer version
        \\
    );
    test_step.dependOn(&no_argument_command.step);

    const fixtures_step = b.step("fixtures", "Run the comptime regression fixtures");
    fixtures_step.dependOn(&run_comptime_fixture_tests.step);

    const language_server_examples_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/examples.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_language_server_examples_tests = b.addRunArtifact(language_server_examples_tests);
    const examples_step = b.step("examples", "Compile and test the language-server examples");
    examples_step.dependOn(&run_language_server_examples_tests.step);
    test_step.dependOn(&run_language_server_examples_tests.step);
    const pipeline_example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/compiler/comptime_pipeline.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const conditional_example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/compiler/conditional_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const indirect_lookup_example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/compiler/indirect_type_lookup.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const parsed_configuration_example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/compiler/parsed_configuration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const recursive_wrapper_example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/compiler/recursive_wrapper.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const reflected_strategy_example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/compiler/reflected_strategy.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const reified_flags_example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/compiler/reified_flags.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const compiler_example_tests = [_]*std.Build.Step.Compile{
        pipeline_example_tests,
        conditional_example_tests,
        indirect_lookup_example_tests,
        parsed_configuration_example_tests,
        recursive_wrapper_example_tests,
        reflected_strategy_example_tests,
        reified_flags_example_tests,
    };
    for (compiler_example_tests) |compiler_example_test| {
        const run_compiler_example_test = b.addRunArtifact(compiler_example_test);
        examples_step.dependOn(&run_compiler_example_test.step);
        test_step.dependOn(&run_compiler_example_test.step);
    }

    const rule_fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/rule_fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig_analyzer", .module = analyzer_module }},
        }),
    });
    const run_rule_fuzz_tests = b.addRunArtifact(rule_fuzz_tests);
    test_step.dependOn(&run_rule_fuzz_tests.step);
    const fuzz_rules_step = b.step("fuzz-rules", "Generate clean programs and mutations to hunt rule false positives and crashes");
    fuzz_rules_step.dependOn(&run_rule_fuzz_tests.step);

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
