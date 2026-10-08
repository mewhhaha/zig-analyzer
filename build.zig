const std = @import("std");

const version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch |err| @panic(@errorName(err));

/// Digest of the files the patched backend is built from besides upstream Zig:
/// the compiler patch, then the shared protocol source. Backend bootstrap
/// computes the same value at run time, so editing either file without
/// rebuilding the backend is detected rather than trusted.
fn backendSha256(b: *std.Build) []const u8 {
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    hasher.update(@embedFile("compiler/zig-0.17.0-analysis.patch"));
    hasher.update(@embedFile("src/compiler/protocol.zig"));
    return b.graph.dupeString(&std.fmt.bytesToHex(hasher.finalResult(), .lower));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = optimize != .debug;

    const build_options = b.addOptions();
    build_options.addOption(std.SemanticVersion, "version", version);
    build_options.addOption([]const u8, "version_string", @import("build.zig.zon").version);
    build_options.addOption([]const u8, "zig_version", "0.17.0");
    build_options.addOption([]const u8, "zig_commit", "7647adab80dd088f4de3610fd245915a912eb6ad");
    build_options.addOption([]const u8, "backend_sha256", backendSha256(b));

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
            .strip = strip,
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
    run_command.addPassthruArgs();
    const run_step = b.step("run", "Run zig-analyzer");
    run_step.dependOn(&run_command.step);

    const backend_command = b.addRunArtifact(executable);
    backend_command.addArgs(&.{ "backend", "bootstrap" });
    const backend_step = b.step("backend", "Bootstrap the patched Zig compiler backend");
    backend_step.dependOn(&backend_command.step);

    const tests = Tests{
        .b = b,
        .check = check_step,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig_analyzer", .module = analyzer_module },
            .{ .name = "lsp", .module = lsp_module },
        },
    };

    const test_step = b.step("test", "Run zig-analyzer tests");
    const fixtures_step = b.step("fixtures", "Run the comptime regression fixtures");
    const examples_step = b.step("examples", "Compile and test the language-server examples");
    const fuzz_rules_step = b.step("fuzz-rules", "Generate clean programs and mutations to hunt rule false positives and crashes");
    const backend_test_step = b.step("backend-test", "Run tests against the patched compiler backend");

    // The analyzer's own unit tests, the contract tests and the language-server
    // exchanges: everything here runs without a patched compiler.
    const analyzer_tests = b.addTest(.{ .root_module = analyzer_module });
    check_step.dependOn(&analyzer_tests.step);
    const analyzer_run = b.addRunArtifact(analyzer_tests);
    analyzer_run.setCwd(b.path("."));
    test_step.dependOn(&analyzer_run.step);
    test_step.dependOn(&tests.run(.{ .root_source_file = b.path("compiler/protocol_invariant.zig"), .imports = tests.imports }).step);
    test_step.dependOn(&tests.run(.{ .root_source_file = b.path("tests/lsp.zig"), .imports = tests.imports }).step);
    test_step.dependOn(&tests.run(.{ .root_source_file = b.path("tests/build_graph.zig"), .imports = tests.imports }).step);
    test_step.dependOn(&tests.run(.{ .root_source_file = b.path("tests/rule_examples.zig"), .imports = tests.imports }).step);
    test_step.dependOn(&tests.run(.{ .root_source_file = b.path("tests/rule_docs.zig"), .imports = tests.imports }).step);
    test_step.dependOn(&tests.run(.{ .root_source_file = b.path("tests/rule_fixes.zig"), .imports = tests.imports }).step);
    test_step.dependOn(&tests.run(.{ .root_source_file = b.path("tests/example_diagnostics.zig"), .imports = tests.imports }).step);

    const fixtures = tests.run(.{ .root_source_file = b.path("fixtures/comptime/main.zig") });
    fixtures_step.dependOn(&fixtures.step);
    test_step.dependOn(&fixtures.step);

    // examples/examples.zig imports every example, compiler ones included.
    const examples = tests.run(.{ .root_source_file = b.path("examples/examples.zig") });
    examples_step.dependOn(&examples.step);
    test_step.dependOn(&examples.step);

    const fuzz = tests.run(.{ .root_source_file = b.path("tests/rule_fuzz.zig"), .imports = tests.imports });
    fuzz_rules_step.dependOn(&fuzz.step);
    test_step.dependOn(&fuzz.step);

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

    const rule_docs_module = b.createModule(.{
        .root_source_file = b.path("tools/rule_docs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zig_analyzer", .module = analyzer_module }},
    });
    const rule_docs_executable = b.addExecutable(.{ .name = "rule-docs", .root_module = rule_docs_module });
    check_step.dependOn(&rule_docs_executable.step);
    const rule_docs_command = b.addRunArtifact(rule_docs_executable);
    rule_docs_command.setCwd(b.path("."));
    b.step("rule-docs", "Regenerate docs/rules from the rule catalog").dependOn(&rule_docs_command.step);

    // Backend-dependent tests live in their own roots so that `test` never
    // needs a patched compiler and these never skip: a missing backend is
    // built by the dependency below or fails the run.
    const compiler_integration = tests.run(.{ .root_source_file = b.path("tests/compiler_integration.zig"), .imports = tests.imports });
    const lsp_compiler = tests.run(.{ .root_source_file = b.path("tests/lsp_compiler.zig"), .imports = tests.imports });
    for ([_]*std.Build.Step.Run{ compiler_integration, lsp_compiler }) |backend_tests| {
        backend_tests.step.dependOn(&backend_command.step);
        backend_test_step.dependOn(&backend_tests.step);
    }
}

/// Test roots share one recipe: each is a module with the shared target and
/// optimize mode, run from the project root. Every test binary is also a
/// dependency of the `check` step, which is what the analyzer reads to learn
/// which compile units exist: a file under test is analyzed through the test
/// that contains it.
const Tests = struct {
    b: *std.Build,
    check: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    /// The analyzer module as `zig_analyzer` (and its `lsp` dependency), for tests that drive its API.
    imports: []const std.Build.Module.Import,

    fn run(tests: Tests, options: std.Build.Module.CreateOptions) *std.Build.Step.Run {
        var module_options = options;
        module_options.target = tests.target;
        module_options.optimize = tests.optimize;
        const compile = tests.b.addTest(.{ .root_module = tests.b.createModule(module_options) });
        tests.check.dependOn(&compile.step);
        const command = tests.b.addRunArtifact(compile);
        command.setCwd(tests.b.path("."));
        return command;
    }
};
