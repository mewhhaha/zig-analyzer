//! The whole-project rule engine: runs the rules that need several files at
//! once. `ownership` carries the cross-file summary engine; the other modules
//! under `project/` are independent consistency lints that share only the
//! `ProjectRun` context.
const std = @import("std");
const catalog = @import("catalog.zig");
const allocation_after_init = @import("project/allocation_after_init.zig");
const build_options = @import("project/build_options.zig");
const conventions = @import("project/conventions.zig");
const import_graph = @import("project/import_graph.zig");
const literal_boolean_argument = @import("project/literal_boolean_argument.zig");
const ownership = @import("project/ownership.zig");
const public_api = @import("project/public_api.zig");
const recursive_call = @import("project/recursive_call.zig");
const run_module = @import("project/run.zig");
const support = @import("test_support.zig");
const tokenize = @import("../syntax/tokens.zig").tokenize;
const types = @import("types.zig");

pub const SourceFile = run_module.SourceFile;
pub const CompilerShape = run_module.CompilerShape;
pub const CompilerUnitFacts = run_module.CompilerUnitFacts;
pub const CompilerFacts = run_module.CompilerFacts;
pub const Finding = run_module.Finding;
pub const freeFindings = run_module.freeFindings;

/// Rules only whole-project analysis can report.
pub const rules = ownership.rules ++ import_graph.rules ++ build_options.rules ++ conventions.rules ++
    literal_boolean_argument.rules ++ allocation_after_init.rules ++ recursive_call.rules ++ public_api.rules;

/// Rules a file-local engine owns and this module re-runs with cross-file
/// summaries, adding findings that need a callee in another file.
pub const refines = ownership.refines;

/// Rules whose proof walks the import graph.
const graph_rules = import_graph.rules ++ [_]types.Rule{.unreachable_public_declaration};

/// Whether an enabled rule needs facts from the patched compiler.
pub fn needsCompilerFacts(configuration: types.Configuration) bool {
    for (rules) |rule| {
        if (catalog.entry(rule).needs == .compiler and configuration.level(rule) != .off) return true;
    }
    return false;
}

fn enabled(configuration: types.Configuration) bool {
    return configuration.anyEnabled(&rules) or configuration.anyEnabled(&refines);
}

pub fn findings(
    allocator: std.mem.Allocator,
    files: []const SourceFile,
    configuration: types.Configuration,
) ![]const Finding {
    return findingsWithCompilerFacts(allocator, files, configuration, .{});
}

/// Analyzes `files` as one project. Scratch work happens in an arena the call
/// owns, so any `allocator` is safe; the returned findings, with their
/// messages and fixes, are copied to `allocator` and released by
/// `freeFindings`.
pub fn findingsWithCompilerFacts(
    allocator: std.mem.Allocator,
    files: []const SourceFile,
    configuration: types.Configuration,
    compiler_facts: CompilerFacts,
) ![]const Finding {
    if (!enabled(configuration)) return &.{};
    var scratch_arena: std.heap.ArenaAllocator = .init(allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const project_files = try scratch.alloc(run_module.File, files.len);
    for (files, project_files) |file, *project_file| {
        project_file.* = run_module.newFile(file, file.tokens orelse try tokenize(scratch, file.source));
    }
    const syntaxes = try scratch.alloc(?@import("context.zig").Syntax, files.len);
    @memset(syntaxes, null);
    var found: std.ArrayList(Finding) = .empty;
    errdefer freeFindings(allocator, found.items);
    const run: run_module.ProjectRun = .{
        .allocator = scratch,
        .results = allocator,
        .files = project_files,
        .configuration = configuration,
        .compiler_facts = compiler_facts,
        .findings = &found,
        .syntaxes = syntaxes,
    };

    const imports = if (configuration.anyEnabled(&graph_rules)) try import_graph.collectImports(run) else &.{};
    try import_graph.findDuplicateModuleImports(run, imports);
    try import_graph.findUnreferencedTests(run, imports);
    try build_options.find(run);
    try import_graph.findInconsistentImportAliases(run, imports);
    try conventions.findMinorityNamingStyles(run);
    try conventions.findInconsistentParameterVocabulary(run);
    try conventions.findInconsistentErrorSetStyle(run);
    try literal_boolean_argument.find(run);
    try allocation_after_init.find(run);
    try recursive_call.find(run);
    try import_graph.findImportBoundaryViolations(run, imports);
    try ownership.run(run);
    try public_api.findConfigurationDivergentApis(run);
    try public_api.findUnreachablePublicDeclarations(run, imports);
    std.mem.sort(Finding, found.items, {}, struct {
        fn lessThan(_: void, left: Finding, right: Finding) bool {
            if (left.file_index != right.file_index) return left.file_index < right.file_index;
            if (left.finding.span.start != right.finding.span.start) return left.finding.span.start < right.finding.span.start;
            return @backingInt(left.finding.rule) < @backingInt(right.finding.rule);
        }
    }.lessThan);
    return try found.toOwnedSlice(allocator);
}

test "project findings compose imports tests and build options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{ .unreferenced_test_file, .conflicting_build_options }, .information);
    const files = [_]SourceFile{
        .{ .path = "src/a.zig", .source = "const one = @import(\"../shared.zig\"); const two = @import(\"../src/../shared.zig\");" },
        .{ .path = "src/b.zig", .source = "const one = 1;" },
        .{ .path = "tests/orphan_test.zig", .source = "test \"orphan\" {}" },
        .{ .path = "build.zig", .source =
        \\const one = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = linux, .optimize = .Debug });
        \\const two = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = windows, .optimize = .Debug });
        },
    };
    const found = try findings(arena.allocator(), &files, configuration);
    try std.testing.expectEqual(@as(usize, 3), found.len);
}

test "project conventions require a strong corpus majority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const files = try allocator.alloc(SourceFile, 20);
    for (files, 0..) |*file, index| {
        const outlier = index == files.len - 1;
        const path = try allocator.print("src/file{d}.zig", .{index});
        const source = if (outlier)
            try allocator.printSentinel("const db = @import(\"pkg\"); pub fn snake_name(alloc: std.mem.Allocator) !void {{ _ = db; _ = alloc; }}", .{}, 0)
        else
            try allocator.printSentinel("const library = @import(\"pkg\"); pub fn camelName{d}(allocator: std.mem.Allocator) Error!void {{ _ = library; _ = allocator; }}", .{index}, 0);
        file.* = .{ .path = path, .source = source };
    }
    var configuration = types.Configuration.defaults();
    const expected_rules = [_]types.Rule{
        .inconsistent_import_alias,
        .minority_naming_style,
        .inconsistent_parameter_vocabulary,
        .inconsistent_error_set_style,
    };
    for (expected_rules) |rule| configuration.levels[@backingInt(rule)] = .information;
    const found = try findings(allocator, files, configuration);
    for (expected_rules) |rule| {
        var seen = false;
        for (found) |finding| if (finding.finding.rule == rule) {
            seen = true;
            break;
        };
        if (!seen) std.debug.print("missing project convention test finding {s}\n", .{rule.code()});
        try std.testing.expect(seen);
    }
}

test "disciplined project rules report direct allocation and recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{ .allocation_after_init, .recursive_call }, .information);
    const files = [_]SourceFile{.{
        .path = "src/service.zig",
        .source = "fn work(allocator: std.mem.Allocator) !void { _ = try allocator.alloc(u8, 1); } fn walk() void { walk(); }",
    }};
    const found = try findings(arena.allocator(), &files, configuration);
    var saw_allocation = false;
    var saw_recursion = false;
    for (found) |finding| switch (finding.finding.rule) {
        .allocation_after_init => saw_allocation = true,
        .recursive_call => saw_recursion = true,
        else => {},
    };
    try std.testing.expect(saw_allocation);
    try std.testing.expect(saw_recursion);
}

test "partial ownership transfer runs when it is the only enabled project rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    @memset(&configuration.levels, .off);
    configuration.levels[@backingInt(types.Rule.partial_ownership_transfer)] = .warning;
    const files = [_]SourceFile{.{
        .path = "src/cache.zig",
        .source = "const Entry = struct { key: []u8 };" ++
            "const Cache = struct { allocator: std.mem.Allocator, entries: []Entry," ++
            "fn add(self: *Cache, key: []const u8) !void { const entry = Entry{ .key = try self.allocator.dupe(u8, key) };" ++
            "_ = entry; }" ++
            "fn remove(self: *Cache, index: usize) !void { const result = self.entries[index];" ++
            "for (index..self.entries.len - 1) |position| self.entries[position] = self.entries[position + 1];" ++
            "self.entries = try self.allocator.realloc(self.entries, self.entries.len - 1);" ++
            "self.allocator.free(result.key); } };",
    }};
    const found = try findings(arena.allocator(), &files, configuration);
    try std.testing.expect(found.len > 0);
    for (found) |finding| try std.testing.expectEqual(types.Rule.partial_ownership_transfer, finding.finding.rule);
}

test "findings are copied out of the scratch arena" {
    const configuration = support.only(&.{ .recursive_call, .literal_boolean_argument }, .warning);
    const files = [_]SourceFile{.{
        .path = "src/walk.zig",
        .source = "fn walk(a: u8, flag: bool) void { _ = a; _ = flag; walk(1, true); }",
    }};
    const found = try findings(std.testing.allocator, &files, configuration);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    for (found) |entry| try std.testing.expectEqual(types.Level.warning, entry.finding.level);
}
