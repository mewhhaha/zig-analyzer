const std = @import("std");

const analysis = @import("../analysis.zig");
const compiler_bootstrap = @import("../compiler/bootstrap.zig");
const compile_units = @import("../compiler/compile_units.zig");
const compiler_session = @import("../compiler/session.zig");
const catalog = @import("../rules/catalog.zig");
const project_rules = @import("../rules/project.zig");
const syntax_scope = @import("../syntax/scope.zig");
const text_edits = @import("../syntax/text_edits.zig");
const tokens_util = @import("../syntax/tokens.zig");
const baseline = @import("baseline.zig");
const build_roots = @import("build_roots.zig");
const check_cache = @import("check_cache.zig");
const check_report = @import("check_report.zig");
const project_config = @import("config.zig");
const cross_file = @import("cross_file.zig");
const tokenize = tokens_util.tokenize;

const max_source_size = 64 * 1024 * 1024;

test "CLI imported deprecations refresh when an unscanned dependency changes despite cache" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "const api = @import(\"dependency.zig\"); pub fn run() void { api.old(); }" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "/// Deprecated; use current\npub fn old() void {}" });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const first = try runWithWriter(std.testing.io, std.testing.allocator, .{ .path = path }, &output.writer);
    try std.testing.expectEqual(@as(u8, 1), first);
    try std.testing.expect(std.mem.find(u8, output.written(), "warning[deprecated-declaration]") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "use current") != null);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "pub fn old() void {}" });
    var refreshed: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refreshed.deinit();
    const second = try runWithWriter(std.testing.io, std.testing.allocator, .{ .path = path }, &refreshed.writer);
    try std.testing.expectEqual(@as(u8, 0), second);
    try std.testing.expect(std.mem.find(u8, refreshed.written(), "deprecated-declaration") == null);
}

test "CLI module member findings refresh when an imported file changes despite cache" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "const dependency = @import(\"dependency.zig\");\npub fn run() u8 { return dependency.missing; }\n" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "pub const present: u8 = 1;\n" });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    _ = try runWithWriter(std.testing.io, std.testing.allocator, .{ .path = path }, &first.writer);
    try std.testing.expect(std.mem.find(u8, first.written(), "unresolved-member") != null);
    var cached: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer cached.deinit();
    _ = try runWithWriter(std.testing.io, std.testing.allocator, .{ .path = path }, &cached.writer);
    try std.testing.expectEqualStrings(first.written(), cached.written());
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "pub const present: u8 = 1;\npub const missing: u8 = 2;\n" });
    var refreshed: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refreshed.deinit();
    _ = try runWithWriter(std.testing.io, std.testing.allocator, .{ .path = path }, &refreshed.writer);
    try std.testing.expect(std.mem.find(u8, refreshed.written(), "unresolved-member") == null);
}

test "CLI public API documentation follows the module roots the build exports" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "zig-analyzer.json", .data = "{\"lints\":{\"rules\":{\"public-declaration-docs\":\"warning\"}}}" });
    try temporary.dir.createDirPath(io, "src");
    try temporary.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "//! The app.\npub const api = @import(\"api.zig\");\npub fn helper() void {}\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/api.zig", .data = "//! The API.\npub fn call() void {}\n" });
    const path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const builds = [_]struct { []const u8, usize }{
        // An executable publishes no declarations.
        .{ "pub fn build(b: *std.Build) void { _ = b.addExecutable(.{ .name = \"app\", .root_module = b.createModule(.{ .root_source_file = b.path(\"src/main.zig\") }) }); }\n", 0 },
        // A module root publishes its surface and what it re-exports.
        .{ "pub fn build(b: *std.Build) void { _ = b.addModule(\"app\", .{ .root_source_file = b.path(\"src/main.zig\") }); }\n", 2 },
    };
    for (builds) |build| {
        const build_source, const expected = build;
        try temporary.dir.writeFile(io, .{ .sub_path = "build.zig", .data = build_source });
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        _ = try runWithWriter(io, std.testing.allocator, .{ .path = path }, &output.writer);
        try std.testing.expectEqual(expected, std.mem.count(u8, output.written(), "[public-declaration-docs]"));
    }
}

test "CLI without the compiler backend says once that compiler facts are missing" {
    const io = std.testing.io;
    if (try compiler_bootstrap.findBackend(io, std.testing.allocator)) |found| {
        var backend = found;
        backend.deinit(std.testing.allocator);
        return error.SkipZigTest;
    }
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "zig-analyzer.json", .data = "{\"lints\":{\"rules\":{\"unreachable-public-declaration\":\"warning\"}}}" });
    try temporary.dir.createDirPath(io, "tool");
    for ([_][]const u8{ "build.zig", "tool/build.zig" }) |sub_path| {
        try temporary.dir.writeFile(io, .{ .sub_path = sub_path, .data = "pub fn build(b: *@import(\"std\").Build) void {\n    _ = b;\n}\n" });
    }
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "pub fn run() void {}\n" });
    const path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path }, &output.writer);
    try std.testing.expectEqual(1, std.mem.count(u8, output.written(), "information[compiler-backend]"));
    try std.testing.expect(std.mem.find(u8, output.written(), "the compiler backend is missing") != null);
}

test "CLI removed std paths name their replacement instead of a bare unresolved member" {
    _ = @import("../compiler/zig_environment.zig").libDirectory(std.testing.io) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ZigEnvironmentUnavailable, error.ZigEnvironmentMalformed => return error.SkipZigTest,
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // The defaults, rather than the configuration of a directory above.
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "zig-analyzer.json", .data = "{}" });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "main.zig",
        .data = "const std = @import(\"std\");\nconst fs = std.fs;\npub fn run() void {\n    _ = fs.cwd();\n    _ = std.fs.cwd();\n}\n",
    });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try runWithWriter(std.testing.io, std.testing.allocator, .{ .path = path, .cache = false }, &output.writer);
    const finding = "warning[removed-std-api]: std.fs.cwd was removed from the standard library; use std.Io.Dir.cwd()";
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), finding));
    try std.testing.expect(std.mem.find(u8, output.written(), "unresolved-member") == null);
}

pub const Format = check_report.Format;
pub const FailOn = check_report.FailOn;

pub const Options = struct {
    path: []const u8 = ".",
    fix: bool = false,
    cache: bool = true,
    /// Stop with status 2, analyzing nothing, when the configuration has an error.
    strict_config: bool = false,
    /// A baseline file whose recorded findings are not reported.
    baseline: ?[]const u8 = null,
    /// A baseline file to record every finding in instead of reporting it.
    write_baseline: ?[]const u8 = null,
    format: Format = .text,
    /// The rules whose findings are reported, counted, recorded and fixed;
    /// null for every rule. The other rules still run, so findings that
    /// depend on them, such as unused suppressions, stay the same.
    rules: ?std.EnumSet(analysis.Rule) = null,
    /// The least severe finding that makes the check exit with status 1.
    fail_on: FailOn = .hint,
};

/// What a `check` command line asks for.
pub const Command = union(enum) {
    run: Options,
    help,
    /// The command line is invalid; why was written to the error writer.
    invalid,
};

/// Reads the arguments after `check`; `arguments` yields them from `next()`,
/// and the options it returns point into them.
pub fn parseArguments(arguments: anytype, errors: *std.Io.Writer) !Command {
    var options: Options = .{};
    var path: ?[]const u8 = null;
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--fix")) {
            options.fix = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--no-cache")) {
            options.cache = false;
            continue;
        }
        if (std.mem.eql(u8, argument, "--strict-config")) {
            options.strict_config = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "--baseline") or std.mem.eql(u8, argument, "--write-baseline")) {
            const file = arguments.next() orelse {
                try errors.print("zig-analyzer check: option '{s}' requires a file\n", .{argument});
                return .invalid;
            };
            if (std.mem.eql(u8, argument, "--baseline")) options.baseline = file else options.write_baseline = file;
            continue;
        }
        if (std.mem.eql(u8, argument, "--format")) {
            const name = arguments.next() orelse {
                try errors.writeAll("zig-analyzer check: option '--format' requires a format\n");
                return .invalid;
            };
            options.format = std.meta.stringToEnum(Format, name) orelse {
                try errors.print("zig-analyzer check: unknown format '{s}'; expected text, json, sarif or github\n", .{name});
                return .invalid;
            };
            continue;
        }
        if (std.mem.eql(u8, argument, "--rule")) {
            const list = arguments.next() orelse "";
            var rules: std.EnumSet(analysis.Rule) = options.rules orelse .empty;
            var codes = std.mem.splitScalar(u8, list, ',');
            var named = false;
            while (codes.next()) |untrimmed| {
                const code = std.mem.trim(u8, untrimmed, " \t");
                if (code.len == 0) continue;
                const rule = analysis.ruleNamed(code) orelse {
                    try errors.print("zig-analyzer check: unknown rule '{s}'{f}\n", .{ code, analysis.DidYouMean{ .name = analysis.nearestRuleCode(code) } });
                    return .invalid;
                };
                rules.insert(rule);
                named = true;
            }
            if (!named) {
                try errors.writeAll("zig-analyzer check: option '--rule' requires a rule code\n");
                return .invalid;
            }
            options.rules = rules;
            continue;
        }
        if (std.mem.eql(u8, argument, "--fail-on")) {
            const name = arguments.next() orelse {
                try errors.writeAll("zig-analyzer check: option '--fail-on' requires a level\n");
                return .invalid;
            };
            options.fail_on = std.meta.stringToEnum(FailOn, name) orelse {
                try errors.print("zig-analyzer check: unknown level '{s}' for '--fail-on'; expected error, warning, information, hint or never\n", .{name});
                return .invalid;
            };
            continue;
        }
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) return .help;
        if (argument.len > 0 and argument[0] == '-') {
            try errors.print("zig-analyzer check: unknown option '{s}'\n", .{argument});
            return .invalid;
        }
        if (path != null) {
            try errors.writeAll("zig-analyzer check accepts one path\n");
            return .invalid;
        }
        path = argument;
    }
    options.path = path orelse ".";
    return .{ .run = options };
}

test "CLI deprecations skip ambiguous named module bindings and oversized imports" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "const api = @import(\"api\"); const large = @import(\"large.zig\"); pub fn run() void { api.old(); _ = large.old; }" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "deprecated.zig", .data = "/// Deprecated: wrong module\npub fn old() void {}" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "custom.zig", .data = "pub fn old() void {}" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "const std = @import(\"std\"); pub fn build(b: *std.Build) void { _ = b.addModule(\"api\", .{ .root_source_file = b.path(\"deprecated.zig\") }); const custom = b.createModule(.{ .root_source_file = b.path(\"custom.zig\") }); const root = b.createModule(.{ .root_source_file = b.path(\"main.zig\") }); root.addImport(\"api\", custom); }" });
    const large = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024 + 1);
    defer std.testing.allocator.free(large);
    @memset(large, ' ');
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "large.zig", .data = large });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runWithWriter(std.testing.io, std.testing.allocator, .{ .path = path, .cache = false }, &output.writer));
    try std.testing.expect(std.mem.find(u8, output.written(), "deprecated-declaration") == null);
}

const Summary = check_report.Totals;

const FileCheckResult = struct {
    entries: []const check_report.Entry = &.{},
    summary: Summary = .{},
    failure: ?anyerror = null,
};

const ProjectCheckResult = struct {
    /// The cross-file findings, which the report lists first.
    cross: []const check_report.Entry = &.{},
    /// The compiler-backend notices and project-rule findings.
    rules: []const check_report.Entry = &.{},
    failure: ?anyerror = null,
};

const ReportedFinding = struct {
    rule: analysis.Rule,
    level: analysis.Level,
    span: std.zig.Token.Loc,
    message: []const u8,
    related: []const analysis.RelatedSpan = &.{},
    fix: catalog.Fixes = .none,

    fn of(finding: analysis.Finding) ReportedFinding {
        return .{
            .rule = finding.rule,
            .level = finding.level,
            .span = finding.span,
            .message = finding.message,
            .related = finding.related,
            .fix = check_cache.fixOf(finding.fixes) orelse .none,
        };
    }

    /// The finding a cache record stores, `check_cache.Record` or `ProjectRecord`.
    fn ofRecord(record: anytype) ReportedFinding {
        return .{
            .rule = record.rule,
            .level = record.level,
            .span = .{ .start = record.start, .end = record.end },
            .message = record.message,
            .related = record.related orelse &.{},
            .fix = record.fix orelse .none,
        };
    }

    fn cacheRecord(finding: ReportedFinding) check_cache.Record {
        return .{
            .rule = finding.rule,
            .level = finding.level,
            .start = finding.span.start,
            .end = finding.span.end,
            .message = finding.message,
            .related = if (finding.related.len == 0) null else finding.related,
            .fix = if (finding.fix == .none) null else finding.fix,
        };
    }
};

/// What every pass needs to turn its findings into report entries.
const Reporting = struct {
    /// Holds the entries until the report is written; safe to use from threads.
    arena: std.mem.Allocator,
    /// `Options.rules`.
    rules: ?std.EnumSet(analysis.Rule),

    fn selects(reporting: Reporting, rule: analysis.Rule) bool {
        const rules = reporting.rules orelse return true;
        return rules.contains(rule);
    }

    /// The entry for `finding` in the file at `path`, located in its source.
    fn entry(
        reporting: Reporting,
        locator: SourceLocator,
        text_path: []const u8,
        path: []const u8,
        finding: ReportedFinding,
    ) !check_report.Entry {
        const related = try reporting.arena.alloc(check_report.Related, finding.related.len);
        for (finding.related, related) |span, *located| located.* = .{
            .message = try reporting.arena.dupe(u8, span.message),
            .start = locator.location(span.span.start),
            .end = locator.location(span.span.end),
        };
        return .{
            .subject = .{ .rule = finding.rule },
            .level = finding.level,
            .text_path = text_path,
            .path = path,
            .message = try reporting.arena.dupe(u8, finding.message),
            .start = locator.location(finding.span.start),
            .end = locator.location(finding.span.end),
            .related = related,
            .fix = finding.fix,
        };
    }
};

const SourceLocator = struct {
    source: []const u8,
    line_starts: []const usize,

    fn init(allocator: std.mem.Allocator, source: []const u8) !SourceLocator {
        return .{ .source = source, .line_starts = try tokens_util.lineStarts(allocator, source) };
    }

    fn location(locator: SourceLocator, offset: usize) SourceLocation {
        const bounded_offset = @min(offset, locator.source.len);
        const line_index = tokens_util.lineOf(locator.line_starts, bounded_offset);
        const column_source = locator.source[locator.line_starts[line_index]..bounded_offset];
        return .{
            .line = line_index + 1,
            .column = (std.unicode.utf8CountCodepoints(column_source) catch column_source.len) + 1,
        };
    }
};

const LoadedFile = struct {
    relative_path: []const u8,
    /// The path relative to the project root, which per-path configuration
    /// and baselines judge.
    config_path: []const u8,
    source: ?[:0]const u8,
    tokens: []const std.zig.Token,
    read_error: ?anyerror,
    /// Nested too deeply to parse safely (`tokens.excessiveNesting`):
    /// every analysis skips the file.
    excessive_nesting: bool = false,
};

const ScanRoot = struct {
    dir: std.Io.Dir,
    absolute_path: []const u8,
    /// Owns the analyzer's per-project state (see `project_config`).
    project_root: []const u8 = "",
    /// Where `dir` lies inside `project_root`; empty when they are one.
    project_prefix: []const u8 = "",
    display_path: []const u8,
    single_file: ?[]const u8,
    /// The baseline the reported findings are checked against.
    baseline: *baseline.Policy,

    fn deinit(root: *ScanRoot, io: std.Io) void {
        root.dir.close(io);
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options) !u8 {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    var error_buffer: [256]u8 = undefined;
    var error_writer = std.Io.File.stderr().writer(io, &error_buffer);
    const exit_code = try runWithWriters(io, allocator, options, &file_writer.interface, &error_writer.interface);
    try file_writer.interface.flush();
    try error_writer.interface.flush();
    return exit_code;
}

fn runWithWriter(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
) !u8 {
    return runWithWriters(io, allocator, options, writer, writer);
}

/// Checks `options.path` and writes the report to `writer`. What stops the
/// check with status 2 is written to `errors`, except in the text format,
/// which has always printed it with the report.
fn runWithWriters(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
    errors: *std.Io.Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fatal = if (options.format == .text) writer else errors;

    var baseline_policy: baseline.Policy = .{ .record = options.write_baseline != null, .allocator = allocator, .io = io };
    defer baseline_policy.deinit();
    if (options.baseline) |baseline_path| {
        baseline_policy.known = baseline.load(io, arena, baseline_path) catch |err| {
            try fatal.print("zig-analyzer check: could not read baseline '{s}': {t}\n", .{ baseline_path, err });
            return 2;
        };
    }
    var root = openScanRoot(io, arena, options.path, &baseline_policy) catch |err| switch (err) {
        error.FileNotFound => {
            try fatal.print("zig-analyzer check: path '{s}' does not exist\n", .{options.path});
            return 2;
        },
        error.NotZigFile => {
            try fatal.print("zig-analyzer check: path '{s}' is not a Zig source file\n", .{options.path});
            return 2;
        },
        else => {
            try fatal.print("zig-analyzer check: could not access '{s}': {t}\n", .{ options.path, err });
            return 2;
        },
    };
    defer root.deinit(io);

    var configurations = project_config.Store.init(io, arena);
    const project = try configurations.forDirectory(root.absolute_path);
    root.project_root = project.root;
    if (isWithin(root.absolute_path, project.root)) {
        root.project_prefix = std.mem.trim(u8, root.absolute_path[project.root.len..], "/\\");
    }
    var configuration = project.configuration;
    if (project.new_warning) |warning| if (options.strict_config) {
        try fatal.print("{s}: error[configuration]: {s}\n", .{ options.path, warning });
        return 2;
    };
    // The configuration warning and the skipped files, which the report
    // lists first.
    var head: std.ArrayList(check_report.Entry) = .empty;
    if (project.new_warning) |warning| try head.append(arena, .{
        .subject = .{ .notice = .configuration },
        .level = .warning,
        .text_path = options.path,
        .path = null,
        .message = warning,
    });

    const relative_paths = collectZigPaths(io, arena, root, configuration) catch |err| {
        // The text report lists the configuration warning before the failure.
        if (options.format == .text) try check_report.writeEntries(writer, &.{head.items});
        try fatal.print("zig-analyzer check: could not scan '{s}': {t}\n", .{ options.path, err });
        return 2;
    };
    const loaded_files = try loadFiles(io, arena, root, relative_paths);
    // Each file is checked on its own, so the project's naming convention is
    // settled first and travels with the configuration (and its cache key).
    configuration.naming_conventions = try namingConventions(arena, loaded_files, configuration);
    var cache = if (options.cache) check_cache.Cache.init(io, root.dir, configuration) else check_cache.Cache{};
    defer cache.deinit(io);
    for (loaded_files) |loaded_file| {
        const source = loaded_file.source orelse continue;
        const notice: check_report.Notice = if (loaded_file.excessive_nesting)
            .nesting_limit
        else if (analysis.isTranslateCOutput(source))
            .generated_source
        else
            continue;
        try head.append(arena, .{
            .subject = .{ .notice = notice },
            .level = .information,
            .text_path = try displayPath(arena, root, loaded_file.relative_path),
            .path = loaded_file.relative_path,
            .message = if (notice == .nesting_limit) analysis.excessive_nesting_notice else "skipped translate-c output",
        });
    }
    const exposures = try moduleExposures(arena, loaded_files, configuration);
    const file_results = try arena.alloc(FileCheckResult, loaded_files.len);
    for (file_results) |*result| result.* = .{};
    var project_result: ProjectCheckResult = .{};
    const reporting: Reporting = .{ .arena = arena, .rules = options.rules };

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var concurrency_available = true;
    group.concurrent(io, checkProjectTask, .{
        io,
        allocator,
        reporting,
        root,
        loaded_files,
        configuration,
        cache,
        &project_result,
    }) catch {
        concurrency_available = false;
        checkProjectTask(io, allocator, reporting, root, loaded_files, configuration, cache, &project_result);
    };
    var file_checks: FileChecks = .{
        .io = io,
        .allocator = allocator,
        .reporting = reporting,
        .root = root,
        .loaded_files = loaded_files,
        .configuration = configuration,
        .fix = options.fix,
        .cache = cache,
        .exposures = exposures,
        .results = file_results,
        .order = try largestFirst(arena, loaded_files),
    };
    if (concurrency_available) {
        const workers = @min(std.Thread.getCpuCount() catch 1, loaded_files.len);
        for (1..workers) |_| group.concurrent(io, FileChecks.work, .{&file_checks}) catch break;
    }
    file_checks.work();
    try group.await(io);
    if (project_result.failure) |failure| return failure;
    const parts = try arena.alloc([]const check_report.Entry, file_results.len + 3);
    parts[0] = head.items;
    parts[1] = project_result.cross;
    parts[2] = project_result.rules;
    var summary: Summary = .{};
    for (file_results, parts[3..]) |result, *part| {
        if (result.failure) |failure| return failure;
        part.* = result.entries;
        summary.files_checked += result.summary.files_checked;
        summary.files_changed += result.summary.files_changed;
        summary.edits_applied += result.summary.edits_applied;
    }

    var report: check_report.Report = .{
        .root = root.display_path,
        .root_absolute = root.absolute_path,
        .parts = parts,
        .totals = summary,
        .fix = options.fix,
    };
    if (options.write_baseline) |baseline_path| {
        baseline.write(io, arena, baseline_path, baseline_policy.recorded.items) catch |err| {
            // The text report lists what was found before the failure.
            if (options.format == .text) try check_report.writeEntries(writer, report.parts);
            try fatal.print("zig-analyzer check: could not write baseline '{s}': {t}\n", .{ baseline_path, err });
            return 2;
        };
        report.baseline = .{ .written = .{ .path = baseline_path, .findings = baseline_policy.recorded.items.len } };
    } else if (options.baseline) |baseline_path| {
        report.baseline = .{ .read = .{ .path = baseline_path, .findings = baseline_policy.covered.load(.monotonic) } };
    }
    try check_report.write(arena, writer, options.format, report);
    return if (report.count(options.fail_on) == 0) 0 else 1;
}

fn namingConventions(
    allocator: std.mem.Allocator,
    loaded_files: []const LoadedFile,
    configuration: analysis.Configuration,
) !analysis.NamingConventions {
    if (configuration.level(.non_idiomatic_name) == .off) return .{};
    var files: std.ArrayList(project_rules.SourceFile) = .empty;
    defer files.deinit(allocator);
    for (loaded_files) |loaded_file| {
        const source = loaded_file.source orelse continue;
        try files.append(allocator, .{ .path = loaded_file.relative_path, .source = source, .tokens = loaded_file.tokens });
    }
    return project_rules.namingConventions(allocator, files.items);
}

fn checkProjectTask(
    io: std.Io,
    allocator: std.mem.Allocator,
    reporting: Reporting,
    root: ScanRoot,
    loaded_files: []const LoadedFile,
    configuration: analysis.Configuration,
    cache: check_cache.Cache,
    result: *ProjectCheckResult,
) void {
    var project_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer project_arena_state.deinit();
    reportProjectFindings(
        io,
        project_arena_state.allocator(),
        reporting,
        root,
        loaded_files,
        configuration,
        cache,
        result,
    ) catch |err| {
        result.failure = err;
    };
}

fn reportProjectFindings(
    io: std.Io,
    allocator: std.mem.Allocator,
    reporting: Reporting,
    root: ScanRoot,
    loaded_files: []const LoadedFile,
    configuration: analysis.Configuration,
    cache: check_cache.Cache,
    result: *ProjectCheckResult,
) !void {
    var files: std.ArrayList(project_rules.SourceFile) = .empty;
    defer files.deinit(allocator);
    for (loaded_files) |loaded_file| {
        const source = loaded_file.source orelse continue;
        if (loaded_file.excessive_nesting) continue;
        try files.append(allocator, .{
            .path = loaded_file.relative_path,
            .source = source,
            .tokens = loaded_file.tokens,
            .config_path = loaded_file.config_path,
        });
    }
    // The cross-file pass and the project rules read the same files and share
    // only their scope indexes, so they run side by side; their entries are
    // reported in that order.
    var scopes: syntax_scope.LazyIndexes = try .init(std.heap.smp_allocator, io, files.items.len);
    defer scopes.deinit();
    var cross: CrossFileTask = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    group.concurrent(io, crossFileTask, .{ io, allocator, reporting, root, files.items, configuration, cache, &scopes, &cross }) catch
        crossFileTask(io, allocator, reporting, root, files.items, configuration, cache, &scopes, &cross);
    var rules_entries: std.ArrayList(check_report.Entry) = .empty;
    const rules_failure = reportProjectRules(io, allocator, reporting, root, loaded_files, files.items, configuration, cache, &scopes, &rules_entries);
    try group.await(io);
    if (cross.failure) |failure| return failure;
    try rules_failure;
    result.cross = cross.entries;
    result.rules = try rules_entries.toOwnedSlice(reporting.arena);
}

const CrossFileTask = struct {
    entries: []const check_report.Entry = &.{},
    failure: ?anyerror = null,
};

fn crossFileTask(
    io: std.Io,
    allocator: std.mem.Allocator,
    reporting: Reporting,
    root: ScanRoot,
    files: []const project_rules.SourceFile,
    configuration: analysis.Configuration,
    cache: check_cache.Cache,
    scopes: *syntax_scope.LazyIndexes,
    task: *CrossFileTask,
) void {
    var entries: std.ArrayList(check_report.Entry) = .empty;
    reportCrossFileFindings(io, allocator, reporting, root, files, configuration, cache, scopes, &entries) catch |err| {
        task.failure = err;
        return;
    };
    task.entries = entries.toOwnedSlice(reporting.arena) catch |err| {
        task.failure = err;
        return;
    };
}

/// Adds the project rules' entries to `entries`, in `reporting.arena`.
fn reportProjectRules(
    io: std.Io,
    allocator: std.mem.Allocator,
    reporting: Reporting,
    root: ScanRoot,
    loaded_files: []const LoadedFile,
    files: []const project_rules.SourceFile,
    configuration: analysis.Configuration,
    cache: check_cache.Cache,
    scopes: *syntax_scope.LazyIndexes,
    entries: *std.ArrayList(check_report.Entry),
) !void {
    const cache_sources = try allocator.alloc(check_cache.ProjectSource, files.len);
    for (files, cache_sources) |file, *cache_source| cache_source.* = .{
        .path = file.path,
        .source = file.source,
    };
    const source_locators = try allocator.alloc(?SourceLocator, files.len);
    @memset(source_locators, null);
    var baseline_scopes: BaselineScopes = try .init(allocator, root.baseline, files);
    defer baseline_scopes.deinit();
    if (!project_rules.needsCompilerFacts(configuration)) if (try cache.loadProject(io, allocator, cache_sources)) |cached| {
        for (cached) |finding| {
            const file = files[finding.file_index];
            if (!reporting.selects(finding.rule)) continue;
            if (try baseline_scopes.covers(finding.file_index, finding.rule, finding.start)) continue;
            if (source_locators[finding.file_index] == null) {
                source_locators[finding.file_index] = try SourceLocator.init(allocator, file.source);
            }
            const display_path = try displayPath(reporting.arena, root, file.path);
            try entries.append(reporting.arena, try reporting.entry(source_locators[finding.file_index].?, display_path, file.path, .ofRecord(finding)));
        }
        return baseline_scopes.finish();
    };
    const compiler_facts = try collectCompilerFacts(io, allocator, reporting, root, loaded_files, configuration, entries);
    // Not the arena: the per-file passes release their scratch as they go.
    const findings = try project_rules.findingsConcurrently(io, std.heap.smp_allocator, files, configuration, compiler_facts, scopes);
    defer project_rules.freeFindings(std.heap.smp_allocator, findings);
    var records: std.ArrayList(check_cache.ProjectRecord) = .empty;
    defer records.deinit(allocator);
    const suppressions = try allocator.alloc(?analysis.Suppressions, files.len);
    defer {
        for (suppressions) |table| if (table) |present| present.deinit(allocator);
        allocator.free(suppressions);
    }
    @memset(suppressions, null);
    for (findings) |found| {
        const finding = found.finding;
        const file = files[found.file_index];
        if (suppressions[found.file_index] == null) {
            suppressions[found.file_index] = try analysis.Suppressions.init(allocator, file.source);
        }
        if (suppressions[found.file_index].?.isSuppressed(finding.rule, finding.span.start)) continue;
        try records.append(allocator, .{
            .file_index = found.file_index,
            .rule = finding.rule,
            .level = finding.level,
            .start = finding.span.start,
            .end = finding.span.end,
            .message = finding.message,
            .related = if (finding.related.len == 0) null else finding.related,
            .fix = check_cache.fixOf(finding.fixes),
        });
        if (!reporting.selects(finding.rule)) continue;
        if (try baseline_scopes.covers(found.file_index, finding.rule, finding.span.start)) continue;
        if (source_locators[found.file_index] == null) {
            source_locators[found.file_index] = try SourceLocator.init(allocator, file.source);
        }
        const display_path = try displayPath(reporting.arena, root, file.path);
        try entries.append(reporting.arena, try reporting.entry(source_locators[found.file_index].?, display_path, file.path, .of(finding)));
    }
    if (!project_rules.needsCompilerFacts(configuration)) try cache.storeProject(io, allocator, cache_sources, records.items);
    try baseline_scopes.finish();
}

/// The baseline scopes of one pass over several files, made on first use.
const BaselineScopes = struct {
    allocator: std.mem.Allocator,
    policy: *baseline.Policy,
    files: []const project_rules.SourceFile,
    scopes: []?baseline.Scope,

    fn init(allocator: std.mem.Allocator, policy: *baseline.Policy, files: []const project_rules.SourceFile) !BaselineScopes {
        const scopes = try allocator.alloc(?baseline.Scope, if (policy.active()) files.len else 0);
        @memset(scopes, null);
        return .{ .allocator = allocator, .policy = policy, .files = files, .scopes = scopes };
    }

    fn deinit(scopes: *BaselineScopes) void {
        for (scopes.scopes) |*scope| if (scope.*) |*present| present.deinit(scopes.allocator);
        scopes.allocator.free(scopes.scopes);
    }

    fn covers(scopes: *BaselineScopes, file_index: usize, rule: analysis.Rule, offset: usize) !bool {
        if (!scopes.policy.active()) return false;
        const slot = &scopes.scopes[file_index];
        if (slot.* == null) {
            const file = scopes.files[file_index];
            slot.* = baseline.Scope.init(scopes.policy, file.config_path orelse file.path, file.source);
        }
        return slot.*.?.covers(scopes.allocator, rule, offset);
    }

    fn finish(scopes: *BaselineScopes) !void {
        for (scopes.scopes) |*scope| if (scope.*) |*present| try present.finish();
    }
};

/// Adds the cross-file findings (deprecations reached through imports, then
/// members missing from imported modules), each in file order, to `entries`.
fn reportCrossFileFindings(
    io: std.Io,
    allocator: std.mem.Allocator,
    reporting: Reporting,
    root: ScanRoot,
    files: []const project_rules.SourceFile,
    configuration: analysis.Configuration,
    cache: check_cache.Cache,
    scopes: *syntax_scope.LazyIndexes,
    entries: *std.ArrayList(check_report.Entry),
) !void {
    var results = try cross_file.run(.{
        .io = io,
        .allocator = std.heap.smp_allocator,
        .root_path = root.absolute_path,
        .files = files,
        .configuration = configuration,
        .cache = cache,
        .scopes = scopes,
    });
    defer results.deinit();
    if (results.failure) |failure| return failure;
    var baseline_scopes: BaselineScopes = try .init(allocator, root.baseline, files);
    defer baseline_scopes.deinit();
    for ([_]enum { imports, members }{ .imports, .members }) |pass| {
        for (files, results.files, 0..) |file, result, position| {
            const records = switch (pass) {
                .imports => result.imports,
                .members => result.members,
            };
            if (records.len == 0) continue;
            const locator = try SourceLocator.init(allocator, file.source);
            const display = try displayPath(reporting.arena, root, file.path);
            for (records) |record| {
                if (!reporting.selects(record.rule)) continue;
                if (try baseline_scopes.covers(position, record.rule, record.start)) continue;
                try entries.append(reporting.arena, try reporting.entry(locator, display, file.path, .ofRecord(record)));
            }
        }
    }
    try baseline_scopes.finish();
}

/// Adds a notice to `entries` for each build whose compile units are not all
/// analyzed.
fn collectCompilerFacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    reporting: Reporting,
    root: ScanRoot,
    loaded_files: []const LoadedFile,
    configuration: analysis.Configuration,
    entries: *std.ArrayList(check_report.Entry),
) !project_rules.CompilerFacts {
    if (!project_rules.needsCompilerFacts(configuration)) return .{};
    // Without the backend no compile unit yields facts, so the builds are not
    // configured to find the units.
    var backend = (try compiler_bootstrap.findBackend(io, allocator)) orelse {
        try entries.append(reporting.arena, .{
            .subject = .{ .notice = .compiler_backend },
            .level = .information,
            .text_path = root.display_path,
            .path = null,
            .message = "no compiler facts: the compiler backend is missing; install a release archive or run 'zig build backend'",
        });
        return .{ .roots_complete = false };
    };
    backend.deinit(allocator);
    var public_type_names = try collectPublicTypeNames(allocator, loaded_files);
    defer public_type_names.deinit(allocator);

    var build_files: std.ArrayList([]const u8) = .empty;
    defer build_files.deinit(allocator);
    var build_directories: std.ArrayList([]const u8) = .empty;
    defer build_directories.deinit(allocator);
    for (loaded_files) |loaded_file| {
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(loaded_file.relative_path), "build.zig")) continue;
        const build_path = try std.Io.Dir.path.join(allocator, &.{ root.absolute_path, loaded_file.relative_path });
        try build_files.append(allocator, loaded_file.relative_path);
        try build_directories.append(allocator, std.Io.Dir.path.dirname(build_path) orelse root.absolute_path);
    }
    // Each configuration runs a build script, so they run side by side as the
    // cross-file pass runs its own; the units are then read in order.
    try build_roots.discover(io, build_directories.items);

    var units: std.ArrayList(project_rules.CompilerUnitFacts) = .empty;
    var roots_complete = true;
    for (build_files.items, build_directories.items) |build_file, build_directory| {
        const graph = (try compile_units.buildGraph(io, build_directory, .discover)) orelse continue;
        defer graph.release();
        for (try graph.takeNotices(allocator)) |notice| {
            try entries.append(reporting.arena, .{
                .subject = .{ .notice = .compiler_backend },
                .level = .information,
                .text_path = build_file,
                .path = build_file,
                .message = try reporting.arena.dupe(u8, notice.text),
            });
            roots_complete = false;
        }
        if (graph.failure != null) roots_complete = false;
        for (graph.units) |*unit| {
            const root_source = unit.root().source.path().?;
            const relative_root = try std.Io.Dir.path.relativeAlloc(allocator, "/", null, root.absolute_path, root_source);
            if (std.mem.startsWith(u8, relative_root, "..")) continue;
            if (containsCompilerRoot(units.items, relative_root)) continue;
            if (units.items.len == max_compiler_units) {
                roots_complete = false;
                continue;
            }
            const shapes = compilerShapes(io, allocator, root, unit, configuration, &public_type_names) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => return err,
                else => {
                    // The project check continues without this unit's facts; say so
                    // once instead of silently reporting fewer findings.
                    const path = try reporting.arena.dupe(u8, relative_root);
                    try entries.append(reporting.arena, .{
                        .subject = .{ .notice = .compiler_backend },
                        .level = .information,
                        .text_path = try displayPath(reporting.arena, root, path),
                        .path = path,
                        .message = try reporting.arena.print("no compiler facts for this compile unit: {t}", .{err}),
                    });
                    roots_complete = false;
                    continue;
                },
            };
            try units.append(allocator, .{ .root_path = relative_root, .shapes = shapes });
        }
    }
    return .{
        .units = try units.toOwnedSlice(allocator),
        .roots_complete = roots_complete,
    };
}

/// Compile units analyzed per check; more than this leave the facts incomplete.
const max_compiler_units = 16;

/// Starts the backend for one compile unit and collects the shapes of the
/// project's public types.
fn compilerShapes(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    unit: *const compile_units.Unit,
    configuration: analysis.Configuration,
    public_type_names: *const std.StringHashMapUnmanaged(void),
) ![]const project_rules.CompilerShape {
    const launch = try compile_units.lower(allocator, unit);
    var session = try compiler_session.Session.start(io, allocator, .empty, launch, root.project_root);
    defer session.deinit();
    var shapes: std.ArrayList(project_rules.CompilerShape) = .empty;
    if (configuration.level(.configuration_divergent_api) == .off) return try shapes.toOwnedSlice(allocator);
    for (try session.declarations()) |declaration| {
        if (!public_type_names.contains(analysis.declarationBaseName(declaration))) continue;
        const shape = try session.resolveShape(allocator, declaration) orelse continue;
        try shapes.append(allocator, shape);
    }
    return try shapes.toOwnedSlice(allocator);
}

fn collectPublicTypeNames(
    allocator: std.mem.Allocator,
    loaded_files: []const LoadedFile,
) !std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    errdefer names.deinit(allocator);
    for (loaded_files) |loaded_file| {
        const source = loaded_file.source orelse continue;
        for (loaded_file.tokens, 0..) |token, index| {
            if (token.tag != .keyword_pub or index + 3 >= loaded_file.tokens.len or
                loaded_file.tokens[index + 1].tag != .keyword_const or
                loaded_file.tokens[index + 2].tag != .identifier) continue;
            const name = source[loaded_file.tokens[index + 2].loc.start..loaded_file.tokens[index + 2].loc.end];
            try names.put(allocator, name, {});
        }
    }
    return names;
}

fn containsCompilerRoot(units: []const project_rules.CompilerUnitFacts, candidate: []const u8) bool {
    for (units) |unit| if (std.mem.eql(u8, unit.root_path, candidate)) return true;
    return false;
}

fn openScanRoot(io: std.Io, allocator: std.mem.Allocator, requested_path: []const u8, baseline_policy: *baseline.Policy) !ScanRoot {
    const absolute_path = try std.Io.Dir.cwd().realPathFileAlloc(io, requested_path, allocator);
    const stat = try std.Io.Dir.cwd().statFile(io, absolute_path, .{});
    if (stat.kind == .directory) {
        return .{
            .dir = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = true }),
            .absolute_path = absolute_path,
            .display_path = requested_path,
            .single_file = null,
            .baseline = baseline_policy,
        };
    }
    if (stat.kind != .file or !std.mem.endsWith(u8, absolute_path, ".zig")) return error.NotZigFile;

    const parent_path = std.Io.Dir.path.dirname(absolute_path) orelse return error.NotZigFile;
    return .{
        .dir = try std.Io.Dir.openDirAbsolute(io, parent_path, .{}),
        .absolute_path = parent_path,
        .display_path = std.Io.Dir.path.dirname(requested_path) orelse ".",
        .single_file = std.Io.Dir.path.basename(absolute_path),
        .baseline = baseline_policy,
    };
}

/// `relative_path`, relative to the scanned directory, as a path relative to
/// the project root.
fn projectPath(allocator: std.mem.Allocator, root: ScanRoot, relative_path: []const u8) ![]const u8 {
    if (root.project_prefix.len == 0) return relative_path;
    return try std.Io.Dir.path.join(allocator, &.{ root.project_prefix, relative_path });
}

fn isWithin(path: []const u8, directory: []const u8) bool {
    if (!std.mem.startsWith(u8, path, directory)) return false;
    return path.len == directory.len or std.Io.Dir.path.isSep(path[directory.len]) or
        (directory.len != 0 and std.Io.Dir.path.isSep(directory[directory.len - 1]));
}

fn collectZigPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    configuration: analysis.Configuration,
) ![]const []const u8 {
    if (root.single_file) |file_name| {
        const paths = try allocator.alloc([]const u8, 1);
        paths[0] = try allocator.dupe(u8, file_name);
        return paths;
    }

    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try root.dir.walkSelectively(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (!skipDirectory(entry.basename) and !pathIsExcluded(try projectPath(allocator, root, entry.path), configuration.check_excludes)) {
                try walker.enter(io, entry);
            }
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (pathIsExcluded(try projectPath(allocator, root, entry.path), configuration.check_excludes)) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    return try paths.toOwnedSlice(allocator);
}

/// Reads and tokenizes every file, a few at a time. `allocator` must be safe
/// to use from threads.
fn loadFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    relative_paths: []const []const u8,
) ![]const LoadedFile {
    const loaded_files = try allocator.alloc(LoadedFile, relative_paths.len);
    var load: FileLoad = .{ .io = io, .allocator = allocator, .root = root, .relative_paths = relative_paths, .loaded_files = loaded_files };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (1..@max(1, @min(max_load_workers, relative_paths.len / 16))) |_| group.concurrent(io, FileLoad.work, .{&load}) catch break;
    load.work();
    try group.await(io);
    if (load.failure) |failure| return failure;
    return loaded_files;
}

const max_load_workers = 8;

const FileLoad = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    relative_paths: []const []const u8,
    loaded_files: []LoadedFile,
    next: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,
    mutex: std.Io.Mutex = .init,

    fn work(load: *FileLoad) void {
        while (true) {
            const index = load.next.fetchAdd(1, .monotonic);
            if (index >= load.relative_paths.len) return;
            load.one(index) catch |err| {
                load.mutex.lockUncancelable(load.io);
                defer load.mutex.unlock(load.io);
                if (load.failure == null) load.failure = err;
                load.next.store(load.relative_paths.len, .monotonic);
                return;
            };
        }
    }

    fn one(load: *FileLoad, index: usize) !void {
        const relative_path = load.relative_paths[index];
        const source = load.root.dir.readFileAllocOptions(
            load.io,
            relative_path,
            load.allocator,
            .limited(max_source_size),
            .of(u8),
            0,
        ) catch |err| {
            load.loaded_files[index] = .{
                .relative_path = relative_path,
                .config_path = try projectPath(load.allocator, load.root, relative_path),
                .source = null,
                .tokens = &.{},
                .read_error = err,
            };
            return;
        };
        const tokens = try tokenize(load.allocator, source);
        load.loaded_files[index] = .{
            .relative_path = relative_path,
            .config_path = try projectPath(load.allocator, load.root, relative_path),
            .source = source,
            .tokens = tokens,
            .read_error = null,
            .excessive_nesting = tokens_util.excessiveNesting(tokens) != null,
        };
    }
};

fn pathIsExcluded(path: []const u8, exclusions: []const []const u8) bool {
    for (exclusions) |exclusion| {
        if (analysis.pathMatches(exclusion, path)) return true;
    }
    return false;
}

fn skipDirectory(name: []const u8) bool {
    const skipped = [_][]const u8{
        ".git",
        ".zig-analyzer",
        ".zig-cache",
        ".zig-global-cache",
        "node_modules",
        "vendor",
        "zig-out",
        "zig-pkg",
    };
    for (skipped) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// Checks one file, adding its entries to `entries`, in `reporting.arena`.
fn checkFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    reporting: Reporting,
    root: ScanRoot,
    loaded_file: LoadedFile,
    configuration: analysis.Configuration,
    fix: bool,
    cache: check_cache.Cache,
    exposure: analysis.ModuleExposure,
    entries: *std.ArrayList(check_report.Entry),
    summary: *Summary,
) !void {
    var file_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer file_arena_state.deinit();
    const file_arena = file_arena_state.allocator();

    const display_path = try displayPath(reporting.arena, root, loaded_file.relative_path);
    const source = loaded_file.source orelse {
        try entries.append(reporting.arena, .{
            .subject = .{ .notice = .io },
            .level = .@"error",
            .text_path = display_path,
            .path = loaded_file.relative_path,
            .message = try reporting.arena.print("could not read file: {t}", .{loaded_file.read_error.?}),
        });
        return;
    };
    var checked_tokens = loaded_file.tokens;
    summary.files_checked += 1;
    if (loaded_file.excessive_nesting) return;
    const file_configuration = project_config.configurationForPath(configuration, loaded_file.config_path);

    var checked_source: [:0]const u8 = source;
    if (fix) {
        const fixed = try text_edits.fixAllOf(file_arena, source, loaded_file.tokens, file_configuration, reporting.rules);
        if (fixed.edits != 0) {
            var replaced = true;
            replaceFile(io, root.dir, loaded_file.relative_path, fixed.source) catch |err| {
                try entries.append(reporting.arena, .{
                    .subject = .{ .notice = .io },
                    .level = .@"error",
                    .text_path = display_path,
                    .path = loaded_file.relative_path,
                    .message = try reporting.arena.print("could not apply fixes: {t}", .{err}),
                });
                replaced = false;
            };
            if (replaced) {
                summary.files_changed += 1;
                summary.edits_applied += fixed.edits;
                checked_source = fixed.source;
                checked_tokens = fixed.tokens;
            }
        }
    }

    if (try analysis.suppressionWarning(file_arena, checked_source)) |warning| {
        try entries.append(reporting.arena, .{
            .subject = .{ .notice = .configuration },
            .level = .warning,
            .text_path = display_path,
            .path = loaded_file.relative_path,
            .message = try reporting.arena.dupe(u8, warning),
            .start = .{ .line = 1, .column = 1 },
        });
    }

    const reported = try reportedFindings(
        io,
        file_arena,
        checked_source,
        checked_tokens,
        loaded_file.relative_path,
        file_configuration,
        cache,
        exposure,
    );
    const source_locator = if (reported.len == 0) null else try SourceLocator.init(file_arena, checked_source);
    var baseline_scope = baseline.Scope.init(root.baseline, loaded_file.config_path, checked_source);
    defer baseline_scope.deinit(file_arena);
    for (reported) |finding| {
        if (!reporting.selects(finding.rule)) continue;
        if (try baseline_scope.covers(file_arena, finding.rule, finding.span.start)) continue;
        try entries.append(reporting.arena, try reporting.entry(source_locator.?, display_path, loaded_file.relative_path, finding));
    }
    try baseline_scope.finish();
}

/// The per-file checks, shared by one worker per CPU. A task per file would
/// start a thread per file, keeping every file's analysis in memory at once
/// and contending for the allocator's per-CPU state.
const FileChecks = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    reporting: Reporting,
    root: ScanRoot,
    loaded_files: []const LoadedFile,
    configuration: analysis.Configuration,
    fix: bool,
    cache: check_cache.Cache,
    /// What of each of `loaded_files` the module roots expose.
    exposures: []const analysis.ModuleExposure,
    results: []FileCheckResult,
    /// File indexes in the order workers take them.
    order: []const usize,
    next: std.atomic.Value(usize) = .init(0),

    fn work(checks: *FileChecks) void {
        while (true) {
            const position = checks.next.fetchAdd(1, .monotonic);
            if (position >= checks.order.len) return;
            const index = checks.order[position];
            checkFileTask(
                checks.io,
                checks.allocator,
                checks.reporting,
                checks.root,
                checks.loaded_files[index],
                checks.configuration,
                checks.fix,
                checks.cache,
                checks.exposures[index],
                &checks.results[index],
            );
        }
    }
};

/// Indexes of `loaded_files`, largest source first, so the slowest files
/// start early instead of finishing last on one worker.
fn largestFirst(allocator: std.mem.Allocator, loaded_files: []const LoadedFile) ![]const usize {
    const order = try allocator.alloc(usize, loaded_files.len);
    for (order, 0..) |*index, position| index.* = position;
    std.mem.sort(usize, order, loaded_files, struct {
        fn lessThan(files: []const LoadedFile, left: usize, right: usize) bool {
            const left_len = if (files[left].source) |source| source.len else 0;
            const right_len = if (files[right].source) |source| source.len else 0;
            if (left_len != right_len) return left_len > right_len;
            return left < right;
        }
    }.lessThan);
    return order;
}

fn checkFileTask(
    io: std.Io,
    allocator: std.mem.Allocator,
    reporting: Reporting,
    root: ScanRoot,
    loaded_file: LoadedFile,
    configuration: analysis.Configuration,
    fix: bool,
    cache: check_cache.Cache,
    exposure: analysis.ModuleExposure,
    result: *FileCheckResult,
) void {
    var entries: std.ArrayList(check_report.Entry) = .empty;
    checkFile(io, allocator, reporting, root, loaded_file, configuration, fix, cache, exposure, &entries, &result.summary) catch |err| {
        result.failure = err;
        return;
    };
    result.entries = entries.toOwnedSlice(reporting.arena) catch |err| {
        result.failure = err;
        return;
    };
}

fn reportedFindings(
    io: std.Io,
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    path: []const u8,
    configuration: analysis.Configuration,
    cache: check_cache.Cache,
    exposure: analysis.ModuleExposure,
) ![]const ReportedFinding {
    if (try cache.load(io, allocator, path, source, exposure)) |cached| {
        const reported = try allocator.alloc(ReportedFinding, cached.len);
        for (cached, reported) |record, *reported_finding| reported_finding.* = .ofRecord(record);
        return reported;
    }
    var reported: std.ArrayList(ReportedFinding) = .empty;
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    defer tree.deinit(allocator);
    const native_findings = try analysis.findingsWith(allocator, source, configuration, .{
        .tokens = tokens,
        .tree = &tree,
        .module_exposure = exposure,
    });
    for (native_findings) |finding| try reported.append(allocator, .of(finding));
    // A generated file keeps no style findings (`configuration.forGeneratedSource`).
    if (!analysis.hasGeneratedHeader(source)) if (try analysis.fileNameFinding(allocator, &tree, path, configuration)) |finding| {
        try reported.append(allocator, .of(finding));
    };

    std.mem.sort(ReportedFinding, reported.items, {}, struct {
        fn lessThan(_: void, left: ReportedFinding, right: ReportedFinding) bool {
            if (left.span.start != right.span.start) return left.span.start < right.span.start;
            return @backingInt(left.rule) < @backingInt(right.rule);
        }
    }.lessThan);
    const sorted = try reported.toOwnedSlice(allocator);
    const records = try allocator.alloc(check_cache.Record, sorted.len);
    for (sorted, records) |finding, *record| record.* = finding.cacheRecord();
    try cache.store(io, allocator, path, source, exposure, records);
    return sorted;
}

/// What of each loaded file the module roots its package's build script
/// exports reach; only `public-declaration-docs` reads it.
fn moduleExposures(
    arena: std.mem.Allocator,
    loaded_files: []const LoadedFile,
    configuration: analysis.Configuration,
) ![]const analysis.ModuleExposure {
    if (configuration.level(.public_declaration_docs) == .off) {
        const exposures = try arena.alloc(analysis.ModuleExposure, loaded_files.len);
        @memset(exposures, .whole);
        return exposures;
    }
    // A file that could not be read takes part as an empty one.
    const files = try arena.alloc(project_rules.SourceFile, loaded_files.len);
    for (loaded_files, files) |loaded_file, *file| file.* = .{
        .path = loaded_file.relative_path,
        .source = loaded_file.source orelse "",
        .tokens = loaded_file.tokens,
    };
    return project_rules.moduleExposures(arena, files);
}

fn replaceFile(io: std.Io, dir: std.Io.Dir, path: []const u8, source: []const u8) !void {
    const stat = try dir.statFile(io, path, .{});
    var atomic_file = try dir.createFileAtomic(io, path, .{
        .permissions = stat.permissions,
        .replace = true,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, source);
    try atomic_file.replace(io);
}

fn displayPath(allocator: std.mem.Allocator, root: ScanRoot, relative_path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, root.display_path, ".")) return relative_path;
    return try std.Io.Dir.path.join(allocator, &.{ root.display_path, relative_path });
}

const SourceLocation = check_report.Location;

test "source locations use indexed UTF-8 line and column positions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source = "const π = 1;\n  π\n";
    const locator = try SourceLocator.init(arena_state.allocator(), source);

    try std.testing.expectEqual(SourceLocation{ .line = 1, .column = 1 }, locator.location(0));
    const second_pi = std.mem.findLast(u8, source, "π").?;
    try std.testing.expectEqual(SourceLocation{ .line = 2, .column = 3 }, locator.location(second_pi));
    try std.testing.expectEqual(SourceLocation{ .line = 3, .column = 1 }, locator.location(source.len));
}

test "check fixes safe findings recursively and skips dependency directories" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "src");
    try temporary.dir.createDirPath(io, "node_modules/package");
    try temporary.dir.createDirPath(io, ".zig-global-cache/generated");
    try temporary.dir.createDirPath(io, "vendor/package");
    try temporary.dir.createDirPath(io, "tests/syntax");
    try temporary.dir.writeFile(io, .{
        .sub_path = "zig-analyzer.json",
        .data = "{\"check\":{\"exclude\":[\"tests/syntax\"]},\"lints\":{\"rules\":{\"redundant-boolean-if\":\"warning\"}}}\n",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data = "fn main(ready: bool) void { var answer: u32 = 42; _ = answer; _ = if (ready) true else false; missing(); }\n",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "node_modules/package/ignored.zig",
        .data = "fn ignored() void { var dependency = 1; _ = dependency; }\n",
    });
    try temporary.dir.writeFile(io, .{ .sub_path = ".zig-global-cache/generated/ignored.zig", .data = "fn generated() void { missing(); }\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "vendor/package/ignored.zig", .data = "fn vendored() void { missing(); }\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "tests/syntax/fixture.zig", .data = "fn fixture() void { fixtureCall(); }\n" });

    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const exit_code = try runWithWriter(io, std.testing.allocator, .{ .path = path, .fix = true }, &output.writer);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    const fixed = try temporary.dir.readFileAlloc(io, "src/main.zig", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(fixed);
    try std.testing.expectEqualStrings("fn main(ready: bool) void { var answer: u32 = 42; _ = answer; _ = ready; missing(); }\n", fixed);
    const ignored = try temporary.dir.readFileAlloc(io, "node_modules/package/ignored.zig", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(ignored);
    try std.testing.expect(std.mem.find(u8, ignored, "var dependency") != null);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "unresolved-call") != null);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "fixtureCall") == null);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "checked 1 Zig files") != null);
}

test "concurrent checks preserve sorted deterministic output" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "fn b() void { missingB(); }\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn a() void { missingA(); }\n" });
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);

    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &first.writer);
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &second.writer);

    try std.testing.expectEqualStrings(first.writer.buffered(), second.writer.buffered());
    const first_a = std.mem.find(u8, first.writer.buffered(), "a.zig") orelse return error.TestUnexpectedResult;
    const first_b = std.mem.find(u8, first.writer.buffered(), "b.zig") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_a < first_b);
}

test "check skips a file nested too deep to parse and still checks the rest" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(std.testing.allocator);
    try blob.appendSlice(std.testing.allocator, "const blob = @import(\"main.zig\").value + ");
    try blob.appendNTimes(std.testing.allocator, '(', 100_000);
    try temporary.dir.writeFile(io, .{ .sub_path = "blob.zig", .data = blob.items });
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "pub const value = 1;\npub fn a() void { missing(); }\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "zig-analyzer.json", .data = "{}\n" });
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &output.writer));
    const written = output.writer.buffered();
    try std.testing.expect(std.mem.find(u8, written, "blob.zig: information[nesting-limit]: skipped: nested too deeply to parse safely") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "blob.zig"));
    try std.testing.expect(std.mem.find(u8, written, "main.zig:2:19: ") != null);
    try std.testing.expect(std.mem.find(u8, written, "[unresolved-call]") != null);
    try std.testing.expect(std.mem.find(u8, written, "checked 2 Zig files; 1 findings remain") != null);
}

test "check exclusions reject parent paths" {
    const configuration = try analysis.parseConfiguration(std.testing.allocator,
        \\{"check":{"exclude":["../fixtures"]}}
    );
    defer std.testing.allocator.free(configuration.warning.?);
    try std.testing.expect(std.mem.find(u8, configuration.warning.?, "../fixtures") != null);
}

test "check reports UTF-8 source locations without modifying explicit fixes" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "main.zig",
        .data = "const label = \"😀\"; missing();\n",
    });

    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}/main.zig", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const exit_code = try runWithWriter(io, std.testing.allocator, .{ .path = path, .fix = true }, &output.writer);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), ":1:20: error[unresolved-call]") != null);
    const unchanged = try temporary.dir.readFileAlloc(io, "main.zig", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("const label = \"😀\"; missing();\n", unchanged);
}

test "check discovers project configuration for style fixes" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "zig-analyzer.json",
        .data = "{\"lints\":{\"profile\":\"idiomatic\",\"correctness\":\"off\",\"style\":\"warning\"}}\n",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "main.zig",
        .data = "/// Runs the configured operation.\npub fn run(enabled: bool) void { _ = enabled == true; }\n",
    });

    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const exit_code = try runWithWriter(io, std.testing.allocator, .{ .path = path, .fix = true }, &output.writer);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const fixed = try temporary.dir.readFileAlloc(io, "main.zig", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(fixed);
    try std.testing.expectEqualStrings(
        "/// Runs the configured operation.\npub fn run(enabled: bool) void { _ = enabled; }\n",
        fixed,
    );
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "applied 1 safe edits across 1 files") != null);
}

test "check reports normalized duplicate module imports" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "main.zig",
        .data =
        \\const first = @import("./shared.zig");
        \\const second = @import("sub/../shared.zig");
        \\fn main() void { _ = first; _ = second; }
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "shared.zig", .data = "pub const value = 1;\n" });

    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const exit_code = try runWithWriter(io, std.testing.allocator, .{ .path = path }, &output.writer);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.find(u8, output.writer.buffered(), "duplicate-module-import") != null);
}

test "strict configuration stops the check on a configuration error" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "zig-analyzer.json", .data = "{\"lints\":{\"rules\":{\"line-lenght\":\"warning\"}}}\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "fn main() void { missing(); }\n" });
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);

    var lenient: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lenient.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &lenient.writer));
    try std.testing.expect(std.mem.find(u8, lenient.written(), "warning[configuration]: zig-analyzer.json contains unknown lint rule 'line-lenght'; did you mean 'line-length'?") != null);
    try std.testing.expect(std.mem.find(u8, lenient.written(), "unresolved-call") != null);

    var strict: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer strict.deinit();
    try std.testing.expectEqual(@as(u8, 2), try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false, .strict_config = true }, &strict.writer));
    try std.testing.expect(std.mem.find(u8, strict.written(), "error[configuration]: zig-analyzer.json contains unknown lint rule 'line-lenght'") != null);
    try std.testing.expect(std.mem.find(u8, strict.written(), "unresolved-call") == null);
}

test "overrides and exclusions match paths inside the project when a subdirectory is checked" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "src/generated");
    try temporary.dir.writeFile(io, .{
        .sub_path = "zig-analyzer.json",
        .data =
        \\{"check":{"exclude":["src/generated"]},
        \\ "lints":{"rules":{"redundant-boolean-if":"warning"}},
        \\ "overrides":[{"paths":["src/legacy_*.zig"],"lints":{"rules":{"redundant-boolean-if":"off"}}}]}
        \\
        ,
    });
    const source = "fn run(ready: bool) bool { return if (ready) true else false; }\n";
    try temporary.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = source });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/legacy_main.zig", .data = source });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/generated/table.zig", .data = source });
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}/src", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &output.writer);
    try std.testing.expect(std.mem.find(u8, output.written(), "src/main.zig:1:35: warning[redundant-boolean-if]") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "legacy_main.zig") == null);
    try std.testing.expect(std.mem.find(u8, output.written(), "table.zig") == null);
    try std.testing.expect(std.mem.find(u8, output.written(), "checked 2 Zig files; 1 findings remain") != null);
}

test "a written baseline hides its findings until their lines change" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "zig-analyzer.json",
        .data = "{\"lints\":{\"profile\":\"idiomatic\",\"rules\":{\"literal-boolean-argument\":\"warning\"}}}\n",
    });
    const original =
        \\fn run(ready: bool) bool {
        \\    return if (ready) true else false;
        \\}
        \\fn step(count: u8, verbose: bool) void {
        \\    _ = count;
        \\    _ = verbose;
        \\}
        \\pub fn main() void {
        \\    _ = run(true);
        \\    step(1, true);
        \\}
        \\
    ;
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = original });
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const baseline_path = try std.testing.allocator.print(".zig-cache/tmp/{s}/baseline.json", .{temporary.sub_path});
    defer std.testing.allocator.free(baseline_path);

    var recording: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer recording.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false, .write_baseline = baseline_path }, &recording.writer));
    try std.testing.expect(std.mem.find(u8, recording.written(), "recorded 2 findings in") != null);

    // Unrelated lines move the findings; they stay covered.
    const shifted = try std.mem.concat(std.testing.allocator, u8, &.{ "const extra = 1;\n\n", original, "fn later() bool {\n    return if (extra == 1) true else false;\n}\n" });
    defer std.testing.allocator.free(shifted);
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = shifted });
    var checking: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer checking.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runWithWriter(io, std.testing.allocator, .{ .path = path, .baseline = baseline_path }, &checking.writer));
    try std.testing.expect(std.mem.find(u8, checking.written(), "main.zig:15:12: information[redundant-boolean-if]") != null);
    try std.testing.expect(std.mem.find(u8, checking.written(), "2 findings recorded in") != null);
    try std.testing.expect(std.mem.find(u8, checking.written(), "1 findings remain") != null);

    var missing: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 2), try runWithWriter(io, std.testing.allocator, .{ .path = path, .baseline = "no/such/baseline.json" }, &missing.writer));
}

test "rule selection and structured reports compose with baselines" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "zig-analyzer.json",
        .data = "{\"lints\":{\"rules\":{\"redundant-boolean-if\":\"warning\",\"literal-boolean-argument\":\"warning\"}}}\n",
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "main.zig",
        .data = "fn run(ready: bool) bool {\n    return if (ready) true else false;\n}\nfn step(count: u8, verbose: bool) void {\n    _ = count;\n    _ = verbose;\n}\npub fn main() void {\n    _ = run(true);\n    step(1, true);\n}\n",
    });
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const baseline_path = try std.testing.allocator.print(".zig-cache/tmp/{s}/baseline.json", .{temporary.sub_path});
    defer std.testing.allocator.free(baseline_path);
    var only: std.EnumSet(analysis.Rule) = .empty;
    only.insert(.redundant_boolean_if);

    // Only the selected rule's finding is recorded.
    var recording: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer recording.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false, .write_baseline = baseline_path, .rules = only }, &recording.writer));
    try std.testing.expect(std.mem.find(u8, recording.written(), "recorded 1 findings in") != null);

    var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer json.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runWithWriter(io, std.testing.allocator, .{ .path = path, .baseline = baseline_path, .format = .json }, &json.writer));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json.written(), .{});
    defer parsed.deinit();
    const findings = try jsonItems(parsed.value, "findings");
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("literal-boolean-argument", try jsonText(findings[0], "rule"));
    const summary = try jsonField(parsed.value, "summary");
    try std.testing.expectEqual(@as(i64, 1), try jsonInteger(summary, "baseline_covered"));
    try std.testing.expectEqual(@as(i64, 1), try jsonInteger(summary, "findings"));

    // A covered selection leaves nothing to fail on.
    var selected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer selected.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runWithWriter(io, std.testing.allocator, .{ .path = path, .baseline = baseline_path, .format = .sarif, .rules = only }, &selected.writer));
    const log = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, selected.written(), .{});
    defer log.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try jsonItems((try jsonItems(log.value, "runs"))[0], "results")).len);
}

test "check accepts the casing a project's majority chose" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "zig-analyzer.json",
        .data = "{\"lints\":{\"rules\":{\"non-idiomatic-name\":\"warning\"}}}\n",
    });
    for (0..20) |index| {
        var name_buffer: [32]u8 = undefined;
        var source_buffer: [64]u8 = undefined;
        try temporary.dir.writeFile(io, .{
            .sub_path = try std.mem.print(&name_buffer, "part{d}.zig", .{index}),
            .data = try std.mem.print(&source_buffer, "pub fn read_value_{d}() void {{}}\n", .{index}),
        });
    }
    try temporary.dir.writeFile(io, .{ .sub_path = "odd.zig", .data = "pub fn Read_Mixed() void {}\n" });

    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &output.writer);

    const written = output.writer.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "[non-idiomatic-name]"));
    try std.testing.expect(std.mem.find(u8, written, "'Read_Mixed' follows neither Zig's camelCase naming convention nor the project's snake_case") != null);
}

/// A project with an entry from every pass: per-file findings with a fix-all
/// and a related span, a cross-file deprecation, a project rule, and a
/// suppression directive's configuration warning.
fn writeEveryPassProject(dir: std.Io.Dir) !void {
    const io = std.testing.io;
    try dir.writeFile(io, .{ .sub_path = "zig-analyzer.json", .data = "{\"lints\":{\"rules\":{\"redundant-boolean-if\":\"warning\"}}}\n" });
    try dir.writeFile(io, .{ .sub_path = "dependency.zig", .data = "/// Deprecated; use current\npub fn old() void {}\npub fn current() void {}\n" });
    try dir.writeFile(io, .{ .sub_path = "shared.zig", .data = "pub const value = 1;\n" });
    try dir.writeFile(io, .{
        .sub_path = "main.zig",
        .data =
        \\// zig-analyzer: disable-next-line not-a-rule
        \\const api = @import("dependency.zig");
        \\const first = @import("./shared.zig");
        \\const second = @import("shared.zig");
        \\pub fn run(ready: bool) bool {
        \\    api.old();
        \\    _ = first;
        \\    _ = second;
        \\    return if (ready) true else false;
        \\}
        \\pub fn answer() u32 {
        \\    return 42;
        \\    missing();
        \\}
        \\
        ,
    });
}

/// Command-line arguments for `parseArguments`.
const TestArguments = struct {
    items: []const []const u8,
    index: usize = 0,

    fn next(arguments: *TestArguments) ?[]const u8 {
        if (arguments.index == arguments.items.len) return null;
        defer arguments.index += 1;
        return arguments.items[arguments.index];
    }
};

/// How many text report lines name `rule`.
fn textCount(text: []const u8, rule: []const u8) usize {
    var buffer: [128]u8 = undefined;
    return std.mem.count(u8, text, std.mem.print(&buffer, "[{s}]: ", .{rule}) catch unreachable);
}

fn jsonField(value: std.json.Value, name: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(name) orelse error.TestUnexpectedResult,
        else => error.TestUnexpectedResult,
    };
}

fn jsonText(value: std.json.Value, name: []const u8) ![]const u8 {
    return switch (try jsonField(value, name)) {
        .string => |text| text,
        else => error.TestUnexpectedResult,
    };
}

fn jsonItems(value: std.json.Value, name: []const u8) ![]const std.json.Value {
    return switch (try jsonField(value, name)) {
        .array => |array| array.items,
        else => error.TestUnexpectedResult,
    };
}

fn jsonInteger(value: std.json.Value, name: []const u8) !i64 {
    return switch (try jsonField(value, name)) {
        .integer => |integer| integer,
        else => error.TestUnexpectedResult,
    };
}

test "the JSON report holds every pass's findings and the text report's counts" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try writeEveryPassProject(temporary.dir);
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);

    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &text.writer));
    var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer json.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runWithWriter(io, std.testing.allocator, .{ .path = path, .format = .json }, &json.writer));
    // A second run reads the cache, which keeps related spans and fixes.
    var cached: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer cached.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path, .format = .json }, &cached.writer);
    try std.testing.expectEqualStrings(json.written(), cached.written());

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json.written(), .{});
    defer parsed.deinit();
    const report = parsed.value;
    try std.testing.expectEqual(@as(i64, 1), try jsonInteger(report, "version"));
    try std.testing.expectEqualStrings(path, try jsonText(report, "root"));
    const findings = try jsonItems(report, "findings");
    for ([_][]const u8{ "unresolved-call", "deprecated-declaration", "duplicate-module-import", "redundant-boolean-if", "unreachable-code" }) |rule| {
        var count: usize = 0;
        for (findings) |finding| {
            if (std.mem.eql(u8, try jsonText(finding, "rule"), rule)) count += 1;
        }
        errdefer std.debug.print("rule {s}\n", .{rule});
        try std.testing.expect(count != 0);
        try std.testing.expectEqual(textCount(text.written(), rule), count);
    }
    for (findings) |finding| {
        try std.testing.expectEqualStrings("main.zig", try jsonText(finding, "path"));
        const start = try jsonField(finding, "start");
        const end = try jsonField(finding, "end");
        try std.testing.expect(try jsonInteger(start, "line") >= 1 and try jsonInteger(start, "column") >= 1);
        try std.testing.expect(try jsonInteger(end, "line") >= try jsonInteger(start, "line"));
        const rule = try jsonText(finding, "rule");
        var location_buffer: [64]u8 = undefined;
        const location = try std.mem.print(&location_buffer, "main.zig:{d}:{d}: {s}[{s}]: ", .{
            try jsonInteger(start, "line"),
            try jsonInteger(start, "column"),
            try jsonText(finding, "level"),
            rule,
        });
        try std.testing.expect(std.mem.find(u8, text.written(), location) != null);
        if (std.mem.eql(u8, rule, "redundant-boolean-if")) {
            try std.testing.expectEqualStrings("fix_all", try jsonText(finding, "fix"));
        } else if (std.mem.eql(u8, rule, "unreachable-code")) {
            try std.testing.expectEqualStrings("quick_fix", try jsonText(finding, "fix"));
            const related = try jsonItems(finding, "related");
            try std.testing.expectEqual(@as(usize, 1), related.len);
            try std.testing.expectEqualStrings("control flow is diverted here", try jsonText(related[0], "message"));
            try std.testing.expectEqual(@as(i64, 12), try jsonInteger(try jsonField(related[0], "start"), "line"));
        } else if (std.mem.eql(u8, rule, "unresolved-call")) {
            try std.testing.expect(try jsonField(finding, "fix") == .null);
        }
    }
    const notices = try jsonItems(report, "notices");
    try std.testing.expectEqual(@as(usize, 1), notices.len);
    try std.testing.expectEqualStrings("configuration", try jsonText(notices[0], "kind"));
    try std.testing.expectEqualStrings("warning", try jsonText(notices[0], "level"));
    try std.testing.expect(std.mem.find(u8, try jsonText(notices[0], "message"), "unknown lint rule 'not-a-rule'") != null);
    const summary = try jsonField(report, "summary");
    try std.testing.expectEqual(@as(i64, 3), try jsonInteger(summary, "files_checked"));
    try std.testing.expectEqual(@as(i64, @intCast(findings.len + 1)), try jsonInteger(summary, "findings"));
    var line_buffer: [64]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, text.written(), try std.mem.print(&line_buffer, "checked 3 Zig files; {d} findings remain\n", .{findings.len + 1})));
}

test "the SARIF report is a SARIF 2.1.0 log of every finding" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try writeEveryPassProject(temporary.dir);
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);

    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &text.writer);
    var sarif: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sarif.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false, .format = .sarif }, &sarif.writer));

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sarif.written(), .{});
    defer parsed.deinit();
    const log = parsed.value;
    try std.testing.expectEqualStrings("2.1.0", try jsonText(log, "version"));
    try std.testing.expect(std.mem.endsWith(u8, try jsonText(log, "$schema"), "sarif-schema-2.1.0.json"));
    const runs = try jsonItems(log, "runs");
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    const driver = try jsonField(try jsonField(runs[0], "tool"), "driver");
    try std.testing.expectEqualStrings("zig-analyzer", try jsonText(driver, "name"));
    try std.testing.expectEqualStrings(@import("build_options").version_string, try jsonText(driver, "version"));
    try std.testing.expectEqualStrings(catalog.repository_url, try jsonText(driver, "informationUri"));
    try std.testing.expectEqualStrings("unicodeCodePoints", try jsonText(runs[0], "columnKind"));
    const base = try jsonText(try jsonField(try jsonField(runs[0], "originalUriBaseIds"), "SRCROOT"), "uri");
    try std.testing.expect(std.mem.startsWith(u8, base, "file:///") and base[base.len - 1] == '/');

    const rules = try jsonItems(driver, "rules");
    const results = try jsonItems(runs[0], "results");
    try std.testing.expectEqual(textCount(text.written(), "unresolved-call") + textCount(text.written(), "deprecated-declaration") +
        textCount(text.written(), "duplicate-module-import") + textCount(text.written(), "redundant-boolean-if") +
        textCount(text.written(), "unreachable-code"), results.len);
    for (rules) |rule| {
        const id = try jsonText(rule, "id");
        try std.testing.expect(analysis.ruleNamed(id) != null);
        try std.testing.expectEqualStrings(catalog.entry(analysis.ruleNamed(id).?).summary, try jsonText(try jsonField(rule, "shortDescription"), "text"));
        try std.testing.expectEqualStrings(analysis.ruleDocumentationUrl(analysis.ruleNamed(id).?), try jsonText(rule, "helpUri"));
    }
    var related_seen = false;
    for (results) |result| {
        const id = try jsonText(result, "ruleId");
        try std.testing.expectEqualStrings(id, try jsonText(rules[@intCast(try jsonInteger(result, "ruleIndex"))], "id"));
        const level = try jsonText(result, "level");
        try std.testing.expect(std.mem.eql(u8, level, "error") or std.mem.eql(u8, level, "warning") or std.mem.eql(u8, level, "note"));
        try std.testing.expect((try jsonText(try jsonField(result, "message"), "text")).len != 0);
        const locations = try jsonItems(result, "locations");
        try std.testing.expectEqual(@as(usize, 1), locations.len);
        const physical = try jsonField(locations[0], "physicalLocation");
        const artifact = try jsonField(physical, "artifactLocation");
        try std.testing.expectEqualStrings("main.zig", try jsonText(artifact, "uri"));
        try std.testing.expectEqualStrings("SRCROOT", try jsonText(artifact, "uriBaseId"));
        const region = try jsonField(physical, "region");
        var location_buffer: [64]u8 = undefined;
        const location = try std.mem.print(&location_buffer, "main.zig:{d}:{d}: ", .{ try jsonInteger(region, "startLine"), try jsonInteger(region, "startColumn") });
        try std.testing.expect(std.mem.find(u8, text.written(), location) != null);
        try std.testing.expect(try jsonInteger(region, "endLine") >= try jsonInteger(region, "startLine"));
        _ = try jsonInteger(region, "endColumn");
        if (std.mem.eql(u8, id, "unreachable-code")) {
            const related = try jsonItems(result, "relatedLocations");
            try std.testing.expectEqualStrings("control flow is diverted here", try jsonText(try jsonField(related[0], "message"), "text"));
            try std.testing.expectEqual(@as(i64, 0), try jsonInteger(related[0], "id"));
            related_seen = true;
        }
    }
    try std.testing.expect(related_seen);
    const invocations = try jsonItems(runs[0], "invocations");
    try std.testing.expect(try jsonField(invocations[0], "executionSuccessful") == .bool);
    const configuration_notices = try jsonItems(invocations[0], "toolConfigurationNotifications");
    try std.testing.expectEqual(@as(usize, 1), configuration_notices.len);
    try std.testing.expectEqualStrings("warning", try jsonText(configuration_notices[0], "level"));
    try std.testing.expectEqualStrings("configuration", try jsonText(try jsonField(configuration_notices[0], "descriptor"), "id"));
}

test "the GitHub report annotates each finding with a workflow command" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try writeEveryPassProject(temporary.dir);
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);

    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &text.writer);
    var github: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer github.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false, .format = .github }, &github.writer));
    const written = github.written();
    var commands: usize = 0;
    var lines = std.mem.splitScalar(u8, written, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "::")) commands += 1;
    }
    // One command per text line but the summary.
    try std.testing.expectEqual(std.mem.countScalar(u8, text.written(), '\n') - 1, commands);
    var expected_buffer: [256]u8 = undefined;
    const unresolved = try std.mem.print(&expected_buffer, "::error file={s}/main.zig,line=13,col=5,endLine=13,endColumn=12,title=unresolved-call::", .{path});
    try std.testing.expect(std.mem.find(u8, written, unresolved) != null);
    try std.testing.expect(std.mem.find(u8, written, "line=1,col=1,endLine=1,endColumn=1,title=configuration::zig-analyzer suppression on line 1 contains unknown lint rule 'not-a-rule'") != null);
    try std.testing.expect(std.mem.find(u8, written, ",title=deprecated-declaration::") != null);
    // The summary line follows the commands.
    const summary_start = std.mem.findScalarLast(u8, text.written()[0 .. text.written().len - 1], '\n').? + 1;
    try std.testing.expect(std.mem.endsWith(u8, written, text.written()[summary_start..]));
}

test "selected rules are the only ones reported, counted and fixed" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try writeEveryPassProject(temporary.dir);
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);

    var all: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer all.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &all.writer);
    var arguments: TestArguments = .{ .items = &.{ "--rule", "duplicate-module-import, deprecated-declaration", "--rule", "unresolved-call", "--no-cache" } };
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    var options = (try parseArguments(&arguments, &errors.writer)).run;
    options.path = path;
    var selected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer selected.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runWithWriter(io, std.testing.allocator, options, &selected.writer));
    const written = selected.written();
    var count: usize = 1; // the configuration warning
    for ([_][]const u8{ "duplicate-module-import", "deprecated-declaration", "unresolved-call" }) |rule| {
        try std.testing.expect(textCount(written, rule) != 0);
        try std.testing.expectEqual(textCount(all.written(), rule), textCount(written, rule));
        count += textCount(written, rule);
    }
    try std.testing.expectEqual(@as(usize, 0), textCount(written, "redundant-boolean-if"));
    try std.testing.expectEqual(@as(usize, 0), textCount(written, "unreachable-code"));
    try std.testing.expectEqual(@as(usize, 1), textCount(written, "configuration"));
    var line_buffer: [64]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, written, try std.mem.print(&line_buffer, "checked 3 Zig files; {d} findings remain\n", .{count})));

    // Fixing one rule leaves another rule's fix-all alone.
    try temporary.dir.writeFile(io, .{ .sub_path = "fixable.zig", .data = "pub fn run(ready: bool) bool {\n    if (ready == true) {}\n    return if (ready) true else false;\n}\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "zig-analyzer.json", .data = "{\"lints\":{\"rules\":{\"redundant-boolean-if\":\"warning\",\"redundant-bool-comparison\":\"warning\"}}}\n" });
    const fixable = try std.testing.allocator.print(".zig-cache/tmp/{s}/fixable.zig", .{temporary.sub_path});
    defer std.testing.allocator.free(fixable);
    var fixing: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fixing.deinit();
    var only: std.EnumSet(analysis.Rule) = .empty;
    only.insert(.redundant_boolean_if);
    try std.testing.expectEqual(@as(u8, 0), try runWithWriter(io, std.testing.allocator, .{ .path = fixable, .cache = false, .fix = true, .rules = only }, &fixing.writer));
    try std.testing.expect(std.mem.find(u8, fixing.written(), "applied 1 safe edits across 1 files") != null);
    const fixed = try temporary.dir.readFileAlloc(io, "fixable.zig", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(fixed);
    try std.testing.expectEqualStrings("pub fn run(ready: bool) bool {\n    if (ready == true) {}\n    return ready;\n}\n", fixed);
}

test "check arguments name unknown rules, formats and levels" {
    const cases = [_]struct { arguments: []const u8, message: []const u8 }{
        .{ .arguments = "--rule unresolved-cal", .message = "zig-analyzer check: unknown rule 'unresolved-cal'; did you mean 'unresolved-call'?\n" },
        .{ .arguments = "--rule unresolved-call,nothing-like-this", .message = "zig-analyzer check: unknown rule 'nothing-like-this'\n" },
        .{ .arguments = "--rule", .message = "zig-analyzer check: option '--rule' requires a rule code\n" },
        .{ .arguments = "--format xml", .message = "zig-analyzer check: unknown format 'xml'; expected text, json, sarif or github\n" },
        .{ .arguments = "--fail-on fatal", .message = "zig-analyzer check: unknown level 'fatal' for '--fail-on'; expected error, warning, information, hint or never\n" },
        .{ .arguments = "--baseline", .message = "zig-analyzer check: option '--baseline' requires a file\n" },
        .{ .arguments = "a b", .message = "zig-analyzer check accepts one path\n" },
    };
    for (cases) |case| {
        var arguments = std.mem.splitScalar(u8, case.arguments, ' ');
        var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer errors.deinit();
        try std.testing.expectEqual(Command.invalid, try parseArguments(&arguments, &errors.writer));
        try std.testing.expectEqualStrings(case.message, errors.written());
    }
    var arguments = std.mem.splitScalar(u8, "--format sarif --fail-on error --fix src", ' ');
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    const options = (try parseArguments(&arguments, &errors.writer)).run;
    try std.testing.expectEqual(Format.sarif, options.format);
    try std.testing.expectEqual(FailOn.@"error", options.fail_on);
    try std.testing.expect(options.fix and options.rules == null);
    try std.testing.expectEqualStrings("src", options.path);
}

test "the fail-on level decides which findings fail the check" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "zig-analyzer.json", .data = "{\"lints\":{\"rules\":{\"redundant-boolean-if\":\"information\"}}}\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "pub fn run(ready: bool) bool {\n    return if (ready) true else false;\n}\n" });
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    for ([_]struct { fail_on: FailOn, status: u8 }{
        .{ .fail_on = .hint, .status = 1 },
        .{ .fail_on = .information, .status = 1 },
        .{ .fail_on = .warning, .status = 0 },
        .{ .fail_on = .@"error", .status = 0 },
        .{ .fail_on = .never, .status = 0 },
    }) |case| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try std.testing.expectEqual(case.status, try runWithWriter(io, std.testing.allocator, .{ .path = path, .fail_on = case.fail_on }, &output.writer));
        // The report is the same whatever fails the check.
        try std.testing.expect(std.mem.find(u8, output.written(), "information[redundant-boolean-if]") != null);
        try std.testing.expect(std.mem.endsWith(u8, output.written(), "checked 1 Zig files; 1 findings remain\n"));
    }

    // A configuration warning fails the check at `warning` but not at `error`.
    try temporary.dir.writeFile(io, .{ .sub_path = "zig-analyzer.json", .data = "{\"lints\":{\"rules\":{\"redundant-boolean-iff\":\"information\"}}}\n" });
    var warned: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer warned.deinit();
    try std.testing.expectEqual(@as(u8, 1), try runWithWriter(io, std.testing.allocator, .{ .path = path, .fail_on = .warning }, &warned.writer));
    try std.testing.expectEqual(@as(u8, 0), try runWithWriter(io, std.testing.allocator, .{ .path = path, .fail_on = .@"error" }, &warned.writer));
}

test "a structured report sends what stops the check to the error writer" {
    const io = std.testing.io;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    try std.testing.expectEqual(@as(u8, 2), try runWithWriters(io, std.testing.allocator, .{ .path = "no/such/path", .format = .json }, &output.writer, &errors.writer));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    try std.testing.expectEqualStrings("zig-analyzer check: path 'no/such/path' does not exist\n", errors.written());
}
