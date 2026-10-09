const std = @import("std");

const manifest = @import("build.zig.zon");

const version = std.SemanticVersion.parse(manifest.version) catch |err| @panic(@errorName(err));

/// The Zig release the analyzer and its patched compiler are built for: the
/// manifest's `minimum_zig_version`, which is exact because the backend is
/// pinned to it.
const zig_version = manifest.minimum_zig_version;

/// The upstream commit `zig_version` was tagged at, which the backend checks
/// out. It changes together with `zig_version`; see compiler/README.md.
const zig_commit = "7647adab80dd088f4de3610fd245915a912eb6ad";

/// What the patched compiler reports from `zig version`.
const backend_version = zig_version ++ "+zig-analyzer.1";

/// Digest of the files the patched backend is built from besides upstream Zig:
/// the compiler patch, then the shared protocol source. Backend bootstrap
/// computes the same value at run time, so editing either file without
/// rebuilding the backend is detected rather than trusted.
fn backendSha256(b: *std.Build) []const u8 {
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    hasher.update(@embedFile("compiler/analysis.patch"));
    hasher.update(@embedFile("src/compiler/protocol.zig"));
    return b.graph.dupeString(&std.fmt.bytesToHex(hasher.finalResult(), .lower));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = optimize != .debug;

    const build_options = b.addOptions();
    build_options.addOption(std.SemanticVersion, "version", version);
    build_options.addOption([]const u8, "version_string", manifest.version);
    build_options.addOption([]const u8, "zig_version", zig_version);
    build_options.addOption([]const u8, "zig_commit", zig_commit);
    build_options.addOption([]const u8, "backend_version", backend_version);
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
    const fix_check_step = b.step("fix-check", "Apply every rule's fixes to its catalog example and compile the originals and results together");
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
    const rule_fixes = tests.run(.{ .root_source_file = b.path("tests/rule_fixes.zig"), .imports = tests.imports });
    test_step.dependOn(&rule_fixes.step);
    fix_check_step.dependOn(&rule_fixes.step);
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

    // The single verification entry point, shared by CI, the release workflow
    // and contributors: formatting, every test (compiler-backed ones included)
    // and the analyzer's own lint run over this repository.
    const ci_step = b.step("ci", "Run every check CI runs: formatting, tests, backend tests and the self-check");
    const format_check = b.addFmt(.{
        .paths = &.{
            b.path("build.zig"),
            b.path("build.zig.zon"),
            b.path("compiler"),
            b.path("examples"),
            b.path("fixtures"),
            b.path("src"),
            b.path("tests"),
            b.path("tools"),
        },
        .check = true,
    });
    const self_check = b.addRunArtifact(executable);
    self_check.addArgs(&.{ "check", "--no-cache", "." });
    self_check.setCwd(b.path("."));
    self_check.has_side_effects = true;
    ci_step.dependOn(&format_check.step);
    ci_step.dependOn(test_step);
    ci_step.dependOn(backend_test_step);
    ci_step.dependOn(&self_check.step);

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
