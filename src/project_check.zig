const std = @import("std");
const analysis = @import("analysis.zig");
const check_cache = @import("check_cache.zig");
const project_rules = @import("rules/project.zig");

const max_source_size = 64 * 1024 * 1024;
const max_configuration_size = 1024 * 1024;

pub const Options = struct {
    path: []const u8 = ".",
    fix: bool = false,
    cache: bool = true,
};

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

const ReportedFinding = struct {
    rule: analysis.Rule,
    level: analysis.Level,
    span: std.zig.Token.Loc,
    message: []const u8,
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

    const configuration = try loadConfiguration(io, arena, root.absolute_path);
    var cache = if (options.cache) check_cache.Cache.init(io, root.dir, configuration) else check_cache.Cache{};
    defer cache.deinit(io);
    var summary: Summary = .{};
    if (configuration.warning) |warning| {
        try writer.print("{s}: warning[configuration]: {s}\n", .{ options.path, warning });
        summary.findings += 1;
    }

    const relative_paths = collectZigPaths(io, arena, root, configuration) catch |err| {
        try writer.print("zig-analyzer check: could not scan '{s}': {t}\n", .{ options.path, err });
        return 2;
    };
    const loaded_files = try loadFiles(io, arena, root, relative_paths);
    if (loaded_files.len > 1) {
        try reportProjectFindings(arena, root, loaded_files, configuration, writer, &summary);
    }
    const file_results = try arena.alloc(FileCheckResult, loaded_files.len);
    for (file_results) |*result| result.* = .{};
    defer for (file_results) |result| if (result.output) |output| allocator.free(output);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var concurrency_available = true;
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

fn reportProjectFindings(
    allocator: std.mem.Allocator,
    root: ScanRoot,
    loaded_files: []const LoadedFile,
    configuration: analysis.Configuration,
    writer: *std.Io.Writer,
    summary: *Summary,
) !void {
    var files: std.ArrayList(project_rules.SourceFile) = .empty;
    for (loaded_files) |loaded_file| {
        const source = loaded_file.source orelse continue;
        try files.append(allocator, .{
            .path = loaded_file.relative_path,
            .source = source,
            .tokens = loaded_file.tokens,
        });
    }
    const findings = try project_rules.findings(allocator, files.items, configuration);
    for (findings) |finding| {
        const file = files.items[finding.file_index];
        if (analysis.isSuppressed(file.source, finding.rule, finding.span.start)) continue;
        const level = configuration.level(finding.rule);
        if (level == .off) continue;
        const display_path = try displayPath(allocator, root, file.path);
        const location = sourceLocation(file.source, finding.span.start);
        try writer.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
            display_path,
            location.line,
            location.column,
            @tagName(level),
            finding.rule.code(),
            finding.message,
        });
        summary.findings += 1;
    }
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

    const parent_path = std.fs.path.dirname(absolute_path) orelse return error.NotZigFile;
    return .{
        .dir = try std.Io.Dir.openDirAbsolute(io, parent_path, .{}),
        .absolute_path = parent_path,
        .display_path = std.fs.path.dirname(requested_path) orelse ".",
        .single_file = std.fs.path.basename(absolute_path),
    };
}

fn loadConfiguration(
    io: std.Io,
    allocator: std.mem.Allocator,
    scan_root: []const u8,
) !analysis.Configuration {
    var directory_path = scan_root;
    while (true) {
        const configuration_path = try std.fs.path.join(allocator, &.{ directory_path, "zig-analyzer.json" });
        const source = std.Io.Dir.cwd().readFileAlloc(
            io,
            configuration_path,
            allocator,
            .limited(max_configuration_size),
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                var configuration = analysis.Configuration.defaults();
                configuration.warning = try std.fmt.allocPrint(
                    allocator,
                    "could not read {s}: {t}",
                    .{ configuration_path, err },
                );
                return configuration;
            },
        };
        if (source) |configuration_source| return try analysis.parseConfiguration(allocator, configuration_source);

        const parent_path = std.fs.path.dirname(directory_path) orelse return analysis.Configuration.defaults();
        if (std.mem.eql(u8, parent_path, directory_path)) return analysis.Configuration.defaults();
        directory_path = parent_path;
    }
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

    var checked_source: [:0]const u8 = source;
    if (fix) {
        const findings = try analysis.findingsWithTokens(file_arena, source, loaded_file.tokens, configuration);
        const edits = try safeFixAllEdits(file_arena, findings);
        if (edits.len != 0) {
            const fixed_source = try applyEdits(file_arena, source, edits);
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
        configuration,
        cache,
    );
    for (reported) |finding| {
        const location = sourceLocation(checked_source, finding.span.start);
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
    if (cache.load(io, allocator, path, source)) |cached| {
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
    const native_findings = try analysis.findingsWithTokens(allocator, source, tokens, configuration);
    for (native_findings) |finding| try reported.append(allocator, .{
        .rule = finding.rule,
        .level = finding.level,
        .span = finding.span,
        .message = finding.message,
    });
    if (try analysis.fileNameFinding(allocator, source, path, configuration)) |finding| {
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
            return @intFromEnum(left.rule) < @intFromEnum(right.rule);
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
    cache.store(io, allocator, path, source, records);
    return sorted;
}

fn safeFixAllEdits(allocator: std.mem.Allocator, findings: []const analysis.Finding) ![]const analysis.Edit {
    var candidates: std.ArrayList(analysis.Edit) = .empty;
    for (findings) |finding| {
        for (finding.fixes) |fix| {
            if (fix.fix_all) try candidates.appendSlice(allocator, fix.edits);
        }
    }
    std.mem.sort(analysis.Edit, candidates.items, {}, struct {
        fn lessThan(_: void, left: analysis.Edit, right: analysis.Edit) bool {
            if (left.span.start != right.span.start) return left.span.start < right.span.start;
            return left.span.end < right.span.end;
        }
    }.lessThan);

    var accepted: std.ArrayList(analysis.Edit) = .empty;
    for (candidates.items) |edit| {
        if (accepted.items.len != 0) {
            const previous = accepted.items[accepted.items.len - 1];
            if (edit.span.start < previous.span.end) continue;
            if (std.meta.eql(edit.span, previous.span) and std.mem.eql(u8, edit.replacement, previous.replacement)) continue;
        }
        try accepted.append(allocator, edit);
    }
    return try accepted.toOwnedSlice(allocator);
}

fn applyEdits(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    edits: []const analysis.Edit,
) ![:0]const u8 {
    var fixed: std.ArrayList(u8) = .empty;
    var source_offset: usize = 0;
    for (edits) |edit| {
        std.debug.assert(source_offset <= edit.span.start);
        std.debug.assert(edit.span.end <= source.len);
        try fixed.appendSlice(allocator, source[source_offset..edit.span.start]);
        try fixed.appendSlice(allocator, edit.replacement);
        source_offset = edit.span.end;
    }
    try fixed.appendSlice(allocator, source[source_offset..]);
    return try fixed.toOwnedSliceSentinel(allocator, 0);
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
    return try std.fs.path.join(allocator, &.{ root.display_path, relative_path });
}

const SourceLocation = struct { line: usize, column: usize };

fn sourceLocation(source: []const u8, offset: usize) SourceLocation {
    const bounded_offset = @min(offset, source.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..bounded_offset], '\n')) |newline| newline + 1 else 0;
    const column_source = source[line_start..bounded_offset];
    const column = std.unicode.utf8CountCodepoints(column_source) catch column_source.len;
    return .{
        .line = std.mem.countScalar(u8, source[0..bounded_offset], '\n') + 1,
        .column = column + 1,
    };
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
    }
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

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
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
    try std.testing.expect(std.mem.indexOf(u8, ignored, "var dependency") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "unresolved-call") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "fixtureCall") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "checked 1 Zig files") != null);
}

test "concurrent checks preserve sorted deterministic output" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "fn b() void { missingB(); }\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "fn a() void { missingA(); }\n" });
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);

    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &first.writer);
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    _ = try runWithWriter(io, std.testing.allocator, .{ .path = path, .cache = false }, &second.writer);

    try std.testing.expectEqualStrings(first.writer.buffered(), second.writer.buffered());
    const first_a = std.mem.indexOf(u8, first.writer.buffered(), "a.zig") orelse return error.TestUnexpectedResult;
    const first_b = std.mem.indexOf(u8, first.writer.buffered(), "b.zig") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_a < first_b);
}

test "check exclusions reject parent paths" {
    const configuration = try analysis.parseConfiguration(std.testing.allocator,
        \\{"check":{"exclude":["../fixtures"]}}
    );
    defer std.testing.allocator.free(configuration.warning.?);
    try std.testing.expect(std.mem.indexOf(u8, configuration.warning.?, "../fixtures") != null);
}

test "check reports UTF-8 source locations without modifying explicit fixes" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "main.zig",
        .data = "const label = \"😀\"; missing();\n",
    });

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/main.zig", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const exit_code = try runWithWriter(io, std.testing.allocator, .{ .path = path, .fix = true }, &output.writer);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), ":1:20: error[unresolved-call]") != null);
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

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
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
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "applied 1 safe edits across 1 files") != null);
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

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const exit_code = try runWithWriter(io, std.testing.allocator, .{ .path = path }, &output.writer);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "duplicate-module-import") != null);
}
