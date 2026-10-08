const std = @import("std");

const analysis = @import("../analysis.zig");
const compile_units = @import("../compiler/compile_units.zig");
const compiler_session = @import("../compiler/session.zig");
const project_rules = @import("../rules/project.zig");
const text_edits = @import("../syntax/text_edits.zig");
const check_cache = @import("check_cache.zig");
const project_config = @import("config.zig");
const imported_deprecations = @import("imported_deprecations.zig");
const module_sites = @import("module_sites.zig");
const tokenize = @import("../syntax/tokens.zig").tokenize;

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

pub const Options = struct {
    path: []const u8 = ".",
    fix: bool = false,
    cache: bool = true,
};

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

const Summary = struct {
    files_checked: usize = 0,
    files_changed: usize = 0,
    edits_applied: usize = 0,
    findings: usize = 0,
};

const FileCheckResult = struct {
    output: ?[]u8 = null,
    summary: Summary = .{},
    failure: ?anyerror = null,
};

const ProjectCheckResult = struct {
    output: ?[]u8 = null,
    findings: usize = 0,
    failure: ?anyerror = null,
};

const ReportedFinding = struct {
    rule: analysis.Rule,
    level: analysis.Level,
    span: std.zig.Token.Loc,
    message: []const u8,
};

const SourceLocator = struct {
    source: []const u8,
    line_starts: []const usize,

    fn init(allocator: std.mem.Allocator, source: []const u8) !SourceLocator {
        const line_starts = try allocator.alloc(usize, std.mem.countScalar(u8, source, '\n') + 1);
        line_starts[0] = 0;
        var line_count: usize = 1;
        for (source, 0..) |byte, offset| {
            if (byte != '\n') continue;
            line_starts[line_count] = offset + 1;
            line_count += 1;
        }
        return .{ .source = source, .line_starts = line_starts };
    }

    fn location(locator: SourceLocator, offset: usize) SourceLocation {
        const bounded_offset = @min(offset, locator.source.len);
        var lower: usize = 0;
        var upper = locator.line_starts.len;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            if (locator.line_starts[middle] <= bounded_offset)
                lower = middle + 1
            else
                upper = middle;
        }
        const line_index = lower - 1;
        const column_source = locator.source[locator.line_starts[line_index]..bounded_offset];
        return .{
            .line = line_index + 1,
            .column = (std.unicode.utf8CountCodepoints(column_source) catch column_source.len) + 1,
        };
    }
};

const LoadedFile = struct {
    relative_path: []const u8,
    source: ?[:0]const u8,
    tokens: []const std.zig.Token,
    read_error: ?anyerror,
};

const ScanRoot = struct {
    dir: std.Io.Dir,
    absolute_path: []const u8,
    /// Owns the analyzer's per-project state (see `project_config`).
    project_root: []const u8 = "",
    display_path: []const u8,
    single_file: ?[]const u8,

    fn deinit(root: *ScanRoot, io: std.Io) void {
        root.dir.close(io);
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options) !u8 {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const exit_code = try runWithWriter(io, allocator, options, &file_writer.interface);
    try file_writer.interface.flush();
    return exit_code;
}

fn runWithWriter(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    writer: *std.Io.Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root = openScanRoot(io, arena, options.path) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.print("zig-analyzer check: path '{s}' does not exist\n", .{options.path});
            return 2;
        },
        error.NotZigFile => {
            try writer.print("zig-analyzer check: path '{s}' is not a Zig source file\n", .{options.path});
            return 2;
        },
        else => {
            try writer.print("zig-analyzer check: could not access '{s}': {t}\n", .{ options.path, err });
            return 2;
        },
    };
    defer root.deinit(io);

    var configurations = project_config.Store.init(io, arena);
    const project = try configurations.forDirectory(root.absolute_path);
    root.project_root = project.root;
    const configuration = project.configuration;
    var cache = if (options.cache) check_cache.Cache.init(io, root.dir, configuration) else check_cache.Cache{};
    defer cache.deinit(io);
    var summary: Summary = .{};
    if (project.new_warning) |warning| {
        try writer.print("{s}: warning[configuration]: {s}\n", .{ options.path, warning });
        summary.findings += 1;
    }

    const relative_paths = collectZigPaths(io, arena, root, configuration) catch |err| {
        try writer.print("zig-analyzer check: could not scan '{s}': {t}\n", .{ options.path, err });
        return 2;
    };
    const loaded_files = try loadFiles(io, arena, root, relative_paths);
    for (loaded_files) |loaded_file| {
        const source = loaded_file.source orelse continue;
        if (!analysis.isTranslateCOutput(source)) continue;
        const display_path = try displayPath(arena, root, loaded_file.relative_path);
        try writer.print("{s}: information[generated-source]: skipped translate-c output\n", .{display_path});
    }
    const file_results = try arena.alloc(FileCheckResult, loaded_files.len);
    for (file_results) |*result| result.* = .{};
    defer for (file_results) |result| if (result.output) |output| allocator.free(output);
    var project_result: ProjectCheckResult = .{};
    defer if (project_result.output) |output| allocator.free(output);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var concurrency_available = true;
    group.concurrent(io, checkProjectTask, .{
        io,
        allocator,
        root,
        loaded_files,
        configuration,
        cache,
        &project_result,
    }) catch {
        concurrency_available = false;
        checkProjectTask(io, allocator, root, loaded_files, configuration, cache, &project_result);
    };
    for (loaded_files, file_results) |loaded_file, *result| {
        if (concurrency_available) {
            group.concurrent(io, checkFileTask, .{ io, allocator, root, loaded_file, configuration, options.fix, cache, result }) catch {
                concurrency_available = false;
                checkFileTask(io, allocator, root, loaded_file, configuration, options.fix, cache, result);
            };
        } else {
            checkFileTask(io, allocator, root, loaded_file, configuration, options.fix, cache, result);
        }
    }
    try group.await(io);
    if (project_result.failure) |failure| return failure;
    if (project_result.output) |output| try writer.writeAll(output);
    summary.findings += project_result.findings;
    for (file_results) |result| {
        if (result.failure) |failure| return failure;
        if (result.output) |output| try writer.writeAll(output);
        summary.files_checked += result.summary.files_checked;
        summary.files_changed += result.summary.files_changed;
        summary.edits_applied += result.summary.edits_applied;
        summary.findings += result.summary.findings;
    }

    if (options.fix) {
        try writer.print("applied {d} safe edits across {d} files\n", .{ summary.edits_applied, summary.files_changed });
    }
    try writer.print("checked {d} Zig files; {d} findings remain\n", .{ summary.files_checked, summary.findings });
    return if (summary.findings == 0) 0 else 1;
}

fn checkProjectTask(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    loaded_files: []const LoadedFile,
    configuration: analysis.Configuration,
    cache: check_cache.Cache,
    result: *ProjectCheckResult,
) void {
    var project_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer project_arena_state.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    var summary: Summary = .{};
    reportProjectFindings(
        io,
        project_arena_state.allocator(),
        root,
        loaded_files,
        configuration,
        cache,
        &output.writer,
        &summary,
    ) catch |err| {
        output.deinit();
        result.failure = err;
        return;
    };
    result.output = output.toOwnedSlice() catch |err| {
        output.deinit();
        result.failure = err;
        return;
    };
    result.findings = summary.findings;
}

fn reportProjectFindings(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    loaded_files: []const LoadedFile,
    configuration: analysis.Configuration,
    cache: check_cache.Cache,
    writer: *std.Io.Writer,
    summary: *Summary,
) !void {
    var files: std.ArrayList(project_rules.SourceFile) = .empty;
    defer files.deinit(allocator);
    for (loaded_files) |loaded_file| {
        const source = loaded_file.source orelse continue;
        try files.append(allocator, .{
            .path = loaded_file.relative_path,
            .source = source,
            .tokens = loaded_file.tokens,
        });
    }
    try reportImportedDeprecations(io, allocator, root, files.items, configuration, writer, summary);
    try reportMissingModuleMembers(io, allocator, root, files.items, configuration, writer, summary);
    const cache_sources = try allocator.alloc(check_cache.ProjectSource, files.items.len);
    for (files.items, cache_sources) |file, *cache_source| cache_source.* = .{
        .path = file.path,
        .source = file.source,
    };
    const source_locators = try allocator.alloc(?SourceLocator, files.items.len);
    @memset(source_locators, null);
    if (!project_rules.needsCompilerFacts(configuration)) if (try cache.loadProject(io, allocator, cache_sources)) |cached| {
        for (cached) |finding| {
            const file = files.items[finding.file_index];
            if (source_locators[finding.file_index] == null) {
                source_locators[finding.file_index] = try SourceLocator.init(allocator, file.source);
            }
            const display_path = try displayPath(allocator, root, file.path);
            errdefer if (!std.mem.eql(u8, root.display_path, ".")) allocator.free(display_path);
            const location = source_locators[finding.file_index].?.location(finding.start);
            try writer.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
                display_path,
                location.line,
                location.column,
                @tagName(finding.level),
                finding.rule.code(),
                finding.message,
            });
            summary.findings += 1;
        }
        return;
    };
    const compiler_facts = try collectCompilerFacts(io, allocator, root, loaded_files, configuration, writer);
    const findings = try project_rules.findingsWithCompilerFacts(allocator, files.items, configuration, compiler_facts);
    defer project_rules.freeFindings(allocator, findings);
    var records: std.ArrayList(check_cache.ProjectRecord) = .empty;
    defer records.deinit(allocator);
    const suppressions = try allocator.alloc(?analysis.Suppressions, files.items.len);
    defer {
        for (suppressions) |table| if (table) |present| present.deinit(allocator);
        allocator.free(suppressions);
    }
    @memset(suppressions, null);
    for (findings) |entry| {
        const finding = entry.finding;
        const file = files.items[entry.file_index];
        if (suppressions[entry.file_index] == null) {
            suppressions[entry.file_index] = try analysis.Suppressions.init(allocator, file.source);
        }
        if (suppressions[entry.file_index].?.isSuppressed(finding.rule, finding.span.start)) continue;
        try records.append(allocator, .{
            .file_index = entry.file_index,
            .rule = finding.rule,
            .level = finding.level,
            .start = finding.span.start,
            .end = finding.span.end,
            .message = finding.message,
        });
        if (source_locators[entry.file_index] == null) {
            source_locators[entry.file_index] = try SourceLocator.init(allocator, file.source);
        }
        const display_path = try displayPath(allocator, root, file.path);
        errdefer if (!std.mem.eql(u8, root.display_path, ".")) allocator.free(display_path);
        const location = source_locators[entry.file_index].?.location(finding.span.start);
        try writer.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
            display_path,
            location.line,
            location.column,
            @tagName(finding.level),
            finding.rule.code(),
            finding.message,
        });
        summary.findings += 1;
    }
    if (!project_rules.needsCompilerFacts(configuration)) try cache.storeProject(io, allocator, cache_sources, records.items);
}

/// `unresolved_member` findings for names a file reads from its imports. The
/// members come from the imported files, so this runs beside the other
/// cross-file checks instead of in the per-file (cached) pass; the language
/// server reports the same findings through the same rule.
fn reportMissingModuleMembers(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    files: []const project_rules.SourceFile,
    configuration: analysis.Configuration,
    writer: *std.Io.Writer,
    summary: *Summary,
) !void {
    if (configuration.level(.unresolved_member) == .off) return;
    var cache: module_sites.Cache = .init(allocator);
    defer cache.deinit();
    const resolver: module_sites.Resolver = .{ .io = io, .cache = &cache, .discover_build = true };
    for (files) |file| {
        if (analysis.isTranslateCOutput(file.source)) continue;
        var scratch: std.heap.ArenaAllocator = .init(allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const absolute_path = try std.Io.Dir.path.resolveAlloc(arena, &.{ root.absolute_path, file.path });
        const modules = try resolver.fileModules(arena, .{ .path = absolute_path, .source = file.source, .tokens = file.tokens.? });
        const found = try analysis.moduleMemberFindings(
            arena,
            file.source,
            file.tokens.?,
            project_config.configurationForPath(configuration, file.path),
            modules,
        );
        if (found.len == 0) continue;
        const locator = try SourceLocator.init(arena, file.source);
        const display = try displayPath(arena, root, file.path);
        for (found) |finding| {
            const location = locator.location(finding.span.start);
            try writer.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
                display, location.line, location.column, @tagName(finding.level), finding.rule.code(), finding.message,
            });
            summary.findings += 1;
        }
    }
}

fn reportImportedDeprecations(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    files: []const project_rules.SourceFile,
    configuration: analysis.Configuration,
    writer: *std.Io.Writer,
    summary: *Summary,
) !void {
    if (configuration.level(.deprecated_declaration) == .off) return;
    var imported: imported_deprecations.ImportedDeprecations = undefined;
    imported.init(io, allocator);
    defer imported.deinit();
    const paths = try allocator.alloc([]const u8, files.len);
    var initialized: usize = 0;
    defer {
        for (paths[0..initialized]) |path| allocator.free(path);
        allocator.free(paths);
    }
    for (files, paths) |file, *path| {
        path.* = try std.Io.Dir.path.resolveAlloc(allocator, &.{ root.absolute_path, file.path });
        initialized += 1;
        try imported.addSource(.{ .path = path.*, .source = file.source, .tokens = file.tokens });
    }
    for (files, paths) |file, path| {
        var found: std.ArrayList(analysis.Finding) = .empty;
        defer found.deinit(allocator);
        try imported.check(.{ .path = path, .source = file.source, .tokens = file.tokens.? }, configuration, &found);
        if (found.items.len == 0) continue;
        const locator = try SourceLocator.init(allocator, file.source);
        defer allocator.free(locator.line_starts);
        const display = try displayPath(allocator, root, file.path);
        defer if (!std.mem.eql(u8, root.display_path, ".")) allocator.free(display);
        for (found.items) |finding| {
            const location = locator.location(finding.span.start);
            try writer.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
                display, location.line, location.column, @tagName(finding.level), finding.rule.code(), finding.message,
            });
            summary.findings += 1;
        }
    }
}

fn collectCompilerFacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    loaded_files: []const LoadedFile,
    configuration: analysis.Configuration,
    writer: *std.Io.Writer,
) !project_rules.CompilerFacts {
    if (!project_rules.needsCompilerFacts(configuration)) return .{};
    var public_type_names = try collectPublicTypeNames(allocator, loaded_files);
    defer public_type_names.deinit(allocator);

    var units: std.ArrayList(project_rules.CompilerUnitFacts) = .empty;
    var roots_complete = true;
    for (loaded_files) |loaded_file| {
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(loaded_file.relative_path), "build.zig")) continue;
        const build_path = try std.Io.Dir.path.join(allocator, &.{ root.absolute_path, loaded_file.relative_path });
        const build_directory = std.Io.Dir.path.dirname(build_path) orelse root.absolute_path;
        const graph = (try compile_units.buildGraph(io, build_directory, .discover)) orelse continue;
        defer graph.release();
        for (try graph.takeNotices(allocator)) |notice| {
            try writer.print("{s}: information[compiler-backend]: {s}\n", .{ loaded_file.relative_path, notice.text });
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
                    const display = try displayPath(allocator, root, relative_root);
                    try writer.print("{s}: information[compiler-backend]: no compiler facts for this compile unit: {t}\n", .{ display, err });
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

fn openScanRoot(io: std.Io, allocator: std.mem.Allocator, requested_path: []const u8) !ScanRoot {
    const absolute_path = try std.Io.Dir.cwd().realPathFileAlloc(io, requested_path, allocator);
    const stat = try std.Io.Dir.cwd().statFile(io, absolute_path, .{});
    if (stat.kind == .directory) {
        return .{
            .dir = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = true }),
            .absolute_path = absolute_path,
            .display_path = requested_path,
            .single_file = null,
        };
    }
    if (stat.kind != .file or !std.mem.endsWith(u8, absolute_path, ".zig")) return error.NotZigFile;

    const parent_path = std.Io.Dir.path.dirname(absolute_path) orelse return error.NotZigFile;
    return .{
        .dir = try std.Io.Dir.openDirAbsolute(io, parent_path, .{}),
        .absolute_path = parent_path,
        .display_path = std.Io.Dir.path.dirname(requested_path) orelse ".",
        .single_file = std.Io.Dir.path.basename(absolute_path),
    };
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
            if (!skipDirectory(entry.basename) and !pathIsExcluded(entry.path, configuration.check_excludes)) {
                try walker.enter(io, entry);
            }
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (pathIsExcluded(entry.path, configuration.check_excludes)) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    return try paths.toOwnedSlice(allocator);
}

fn loadFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    relative_paths: []const []const u8,
) ![]const LoadedFile {
    const loaded_files = try allocator.alloc(LoadedFile, relative_paths.len);
    for (relative_paths, loaded_files) |relative_path, *loaded_file| {
        const source = root.dir.readFileAllocOptions(
            io,
            relative_path,
            allocator,
            .limited(max_source_size),
            .of(u8),
            0,
        ) catch |err| {
            loaded_file.* = .{
                .relative_path = relative_path,
                .source = null,
                .tokens = &.{},
                .read_error = err,
            };
            continue;
        };
        loaded_file.* = .{
            .relative_path = relative_path,
            .source = source,
            .tokens = try tokenize(allocator, source),
            .read_error = null,
        };
    }
    return loaded_files;
}

fn pathIsExcluded(path: []const u8, exclusions: []const []const u8) bool {
    for (exclusions) |exclusion| {
        if (!pathHasPrefix(path, exclusion)) continue;
        if (path.len == exclusion.len or isPathSeparator(path[exclusion.len])) return true;
    }
    return false;
}

fn pathHasPrefix(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    for (path[0..prefix.len], prefix) |path_character, prefix_character| {
        if (path_character == prefix_character) continue;
        if (!isPathSeparator(path_character) or !isPathSeparator(prefix_character)) return false;
    }
    return true;
}

fn isPathSeparator(character: u8) bool {
    return character == '/' or character == '\\';
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

fn checkFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    loaded_file: LoadedFile,
    configuration: analysis.Configuration,
    fix: bool,
    cache: check_cache.Cache,
    writer: *std.Io.Writer,
    summary: *Summary,
) !void {
    var file_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer file_arena_state.deinit();
    const file_arena = file_arena_state.allocator();

    const display_path = try displayPath(file_arena, root, loaded_file.relative_path);
    const source = loaded_file.source orelse {
        try writer.print("{s}: error[io]: could not read file: {t}\n", .{ display_path, loaded_file.read_error.? });
        summary.findings += 1;
        return;
    };
    var checked_tokens = loaded_file.tokens;
    summary.files_checked += 1;
    const file_configuration = project_config.configurationForPath(configuration, loaded_file.relative_path);

    var checked_source: [:0]const u8 = source;
    if (fix) {
        const findings = try analysis.findingsWith(file_arena, source, file_configuration, .{ .tokens = loaded_file.tokens });
        const edits = try text_edits.safeFixAll(file_arena, findings);
        if (edits.len != 0) {
            const fixed_source = try text_edits.apply(file_arena, source, edits);
            if (!std.mem.eql(u8, source, fixed_source)) {
                var replaced = true;
                replaceFile(io, root.dir, loaded_file.relative_path, fixed_source) catch |err| {
                    try writer.print("{s}: error[io]: could not apply fixes: {t}\n", .{ display_path, err });
                    summary.findings += 1;
                    replaced = false;
                };
                if (replaced) {
                    summary.files_changed += 1;
                    summary.edits_applied += edits.len;
                    checked_source = fixed_source;
                    checked_tokens = try tokenize(file_arena, fixed_source);
                }
            }
        }
    }

    if (try analysis.suppressionWarning(file_arena, checked_source)) |warning| {
        try writer.print("{s}:1:1: warning[configuration]: {s}\n", .{ display_path, warning });
        summary.findings += 1;
    }

    const reported = try reportedFindings(
        io,
        file_arena,
        checked_source,
        checked_tokens,
        loaded_file.relative_path,
        file_configuration,
        cache,
    );
    const source_locator = if (reported.len == 0) null else try SourceLocator.init(file_arena, checked_source);
    for (reported) |finding| {
        const location = source_locator.?.location(finding.span.start);
        try writer.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
            display_path,
            location.line,
            location.column,
            @tagName(finding.level),
            finding.rule.code(),
            finding.message,
        });
    }
    summary.findings += reported.len;
}

fn checkFileTask(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: ScanRoot,
    loaded_file: LoadedFile,
    configuration: analysis.Configuration,
    fix: bool,
    cache: check_cache.Cache,
    result: *FileCheckResult,
) void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    checkFile(io, allocator, root, loaded_file, configuration, fix, cache, &output.writer, &result.summary) catch |err| {
        output.deinit();
        result.failure = err;
        return;
    };
    result.output = output.toOwnedSlice() catch |err| {
        output.deinit();
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
) ![]const ReportedFinding {
    if (try cache.load(io, allocator, path, source)) |cached| {
        const reported = try allocator.alloc(ReportedFinding, cached.len);
        for (cached, reported) |finding, *reported_finding| reported_finding.* = .{
            .rule = finding.rule,
            .level = finding.level,
            .span = .{ .start = finding.start, .end = finding.end },
            .message = finding.message,
        };
        return reported;
    }
    var reported: std.ArrayList(ReportedFinding) = .empty;
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    defer tree.deinit(allocator);
    const native_findings = try analysis.findingsWith(allocator, source, configuration, .{ .tokens = tokens, .tree = &tree });
    for (native_findings) |finding| try reported.append(allocator, .{
        .rule = finding.rule,
        .level = finding.level,
        .span = finding.span,
        .message = finding.message,
    });
    if (try analysis.fileNameFinding(allocator, &tree, path, configuration)) |finding| {
        try reported.append(allocator, .{
            .rule = finding.rule,
            .level = finding.level,
            .span = finding.span,
            .message = finding.message,
        });
    }

    std.mem.sort(ReportedFinding, reported.items, {}, struct {
        fn lessThan(_: void, left: ReportedFinding, right: ReportedFinding) bool {
            if (left.span.start != right.span.start) return left.span.start < right.span.start;
            return @backingInt(left.rule) < @backingInt(right.rule);
        }
    }.lessThan);
    const sorted = try reported.toOwnedSlice(allocator);
    const records = try allocator.alloc(check_cache.Record, sorted.len);
    for (sorted, records) |finding, *record| record.* = .{
        .rule = finding.rule,
        .level = finding.level,
        .start = finding.span.start,
        .end = finding.span.end,
        .message = finding.message,
    };
    try cache.store(io, allocator, path, source, records);
    return sorted;
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

const SourceLocation = struct { line: usize, column: usize };

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
        .data = "{\"lints\":{\"correctness\":\"off\",\"style\":\"warning\"}}\n",
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
