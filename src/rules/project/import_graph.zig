//! The module import graph of the project: the imports every file declares, and the rules that read them (duplicate imports, alias conventions, declared boundaries, unreferenced test files).
const std = @import("std");
const run_module = @import("run.zig");
const ProjectRun = run_module.ProjectRun;
const types = @import("../types.zig");
const project = @import("../project.zig");
const support = @import("../test_support.zig");
const majority = @import("majority.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const tokenText = tokens_util.tokenText;
const tokenIs = tokens_util.tokenIs;
const matchingToken = tokens_util.matchingToken;

pub const rules = [_]types.Rule{
    .duplicate_module_import,
    .unreferenced_test_file,
    .inconsistent_import_alias,
    .import_boundary,
};

pub const Import = struct {
    file_index: usize,
    span: std.zig.Token.Loc,
    spelling: []const u8,
    resolved_path: []const u8,
    alias: ?[]const u8 = null,
    alias_span: ?std.zig.Token.Loc = null,
};

pub fn findImportBoundaryViolations(
    run: ProjectRun,
    imports: []const Import,
) !void {
    if (run.configuration.level(.import_boundary) == .off) return;
    for (imports) |import| {
        const source_path = run.files[import.file_index].path;
        for (run.configuration.import_boundaries) |boundary| {
            if (!pathMatchesContract(source_path, boundary.from)) continue;
            for (boundary.denied) |denied| {
                if (!pathMatchesContract(import.resolved_path, denied)) continue;
                try run.report(.{
                    .file_index = import.file_index,
                    .rule = .import_boundary,
                    .span = import.span,
                    .message = try run.allocator.print(
                        "source '{s}' may not import '{s}' because contract '{s}' denies '{s}'",
                        .{ source_path, import.resolved_path, boundary.from, denied },
                    ),
                });
                break;
            }
        }
    }
}

fn pathMatchesContract(path: []const u8, contract: []const u8) bool {
    if (!std.mem.startsWith(u8, path, contract)) return false;
    if (path.len == contract.len) return true;
    if (contract.len != 0 and std.Io.Dir.path.isSep(contract[contract.len - 1])) return true;
    return std.Io.Dir.path.isSep(path[contract.len]);
}

pub fn findDuplicateModuleImports(
    run: ProjectRun,
    imports: []const Import,
) !void {
    if (run.configuration.level(.duplicate_module_import) == .off) return;
    for (imports, 0..) |current, index| {
        for (imports[0..index]) |previous| {
            if (previous.file_index != current.file_index or
                !std.mem.eql(u8, previous.resolved_path, current.resolved_path) or
                std.mem.eql(u8, previous.spelling, current.spelling)) continue;
            try run.report(.{
                .file_index = current.file_index,
                .rule = .duplicate_module_import,
                .span = current.span,
                .message = try run.allocator.print(
                    "imports '{s}' and '{s}' resolve to the same module '{s}'",
                    .{ previous.spelling, current.spelling, current.resolved_path },
                ),
            });
            break;
        }
    }
}

pub fn findUnreferencedTests(
    run: ProjectRun,
    imports: []const Import,
) !void {
    if (run.configuration.level(.unreferenced_test_file) == .off) return;
    const build_reachable = try run.allocator.alloc(bool, run.files.len);
    defer run.allocator.free(build_reachable);
    @memset(build_reachable, false);
    for (run.files, 0..) |file, file_index| {
        build_reachable[file_index] = std.mem.eql(u8, std.Io.Dir.path.basename(file.path), "build.zig");
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (run.files, 0..) |file, file_index| {
            if (!build_reachable[file_index]) continue;
            for (file.tokens, 0..) |token, index| {
                if (token.tag != .builtin or !tokenIs(file.source, token, "@import") or
                    index + 2 >= file.tokens.len or file.tokens[index + 1].tag != .l_paren or
                    file.tokens[index + 2].tag != .string_literal) continue;
                const spelling = stringValue(file.source, file.tokens[index + 2]) orelse continue;
                if (!std.mem.endsWith(u8, spelling, ".zig")) continue;
                const resolved_path = try resolveImportPath(run.allocator, file.path, spelling);
                for (run.files, 0..) |candidate, candidate_index| {
                    if (build_reachable[candidate_index] or !std.mem.eql(u8, candidate.path, resolved_path)) continue;
                    build_reachable[candidate_index] = true;
                    changed = true;
                }
                run.allocator.free(resolved_path);
            }
        }
    }
    for (run.files, 0..) |file, file_index| {
        if (!looksLikeTestPath(file.path) or !containsTestDeclaration(file.tokens)) continue;
        var referenced = false;
        for (imports) |import| {
            if (import.file_index != file_index and std.mem.eql(u8, import.resolved_path, file.path)) {
                referenced = true;
                break;
            }
        }
        if (!referenced) for (run.files, 0..) |importing_file, importing_index| {
            if (importing_index == file_index) continue;
            for (importing_file.tokens, 0..) |token, index| {
                if (token.tag != .builtin or !tokenIs(importing_file.source, token, "@import") or
                    index + 2 >= importing_file.tokens.len or importing_file.tokens[index + 1].tag != .l_paren or
                    importing_file.tokens[index + 2].tag != .string_literal) continue;
                const spelling = stringValue(importing_file.source, importing_file.tokens[index + 2]) orelse continue;
                if (!std.mem.endsWith(u8, spelling, ".zig")) continue;
                const resolved_path = try resolveImportPath(run.allocator, importing_file.path, spelling);
                if (std.mem.eql(u8, resolved_path, file.path)) {
                    referenced = true;
                    break;
                }
            }
            if (referenced) break;
        };
        if (!referenced) for (run.files, 0..) |build_file, build_index| {
            if (build_index == file_index or !build_reachable[build_index]) continue;
            if (sourceMentionsPath(build_file.source, file.path)) {
                referenced = true;
                break;
            }
            var enumerates_directory = false;
            for (build_file.tokens) |token| {
                if (token.tag == .identifier and tokenIs(build_file.source, token, "iterate")) {
                    enumerates_directory = true;
                    break;
                }
            }
            if (!enumerates_directory) continue;
            var directory = std.Io.Dir.path.dirname(file.path);
            while (directory) |candidate_directory| {
                for (build_file.tokens) |token| {
                    if (token.tag != .string_literal) continue;
                    const spelling = stringValue(build_file.source, token) orelse continue;
                    if (std.mem.eql(u8, spelling, candidate_directory)) {
                        referenced = true;
                        break;
                    }
                }
                if (referenced) break;
                directory = std.Io.Dir.path.dirname(candidate_directory);
            }
            if (referenced) break;
        };
        if (referenced) continue;
        try run.report(.{
            .file_index = file_index,
            .rule = .unreferenced_test_file,
            .span = .{ .start = 0, .end = @min(file.source.len, 1) },
            .message = try run.allocator.print(
                "test source '{s}' is not imported by another Zig file or referenced from build.zig",
                .{file.path},
            ),
        });
    }
}

pub fn collectImports(run: ProjectRun) ![]const Import {
    var imports: std.ArrayList(Import) = .empty;
    errdefer imports.deinit(run.allocator);
    for (run.files, 0..) |file, file_index| {
        if (file.generated) continue;
        var brace_depth: usize = 0;
        for (file.tokens, 0..) |token, index| {
            if (token.tag == .l_brace) {
                brace_depth += 1;
                continue;
            }
            if (token.tag == .r_brace) {
                brace_depth -|= 1;
                continue;
            }
            if (brace_depth != 0) continue;
            if (token.tag != .builtin or !tokenIs(file.source, token, "@import") or index + 2 >= file.tokens.len or
                file.tokens[index + 1].tag != .l_paren or file.tokens[index + 2].tag != .string_literal) continue;
            const spelling = stringValue(file.source, file.tokens[index + 2]) orelse continue;
            const alias_index = importAliasIndex(file.tokens, index);
            try imports.append(run.allocator, .{
                .file_index = file_index,
                .span = file.tokens[index + 2].loc,
                .spelling = spelling,
                .resolved_path = if (std.mem.endsWith(u8, spelling, ".zig"))
                    try resolveImportPath(run.allocator, file.path, spelling)
                else
                    try run.allocator.dupe(u8, spelling),
                .alias = if (alias_index) |alias| tokenText(file.source, file.tokens[alias]) else null,
                .alias_span = if (alias_index) |alias| file.tokens[alias].loc else null,
            });
        }
    }
    return try imports.toOwnedSlice(run.allocator);
}

fn importAliasIndex(tokens: []const std.zig.Token, builtin_index: usize) ?usize {
    if (builtin_index < 3 or tokens[builtin_index - 1].tag != .equal or tokens[builtin_index - 2].tag != .identifier) return null;
    if (tokens[builtin_index - 3].tag != .keyword_const and tokens[builtin_index - 3].tag != .keyword_var) return null;
    const closing = matchingToken(tokens, builtin_index + 1, .l_paren, .r_paren) orelse return null;
    if (closing + 1 < tokens.len and tokens[closing + 1].tag == .period) return null;
    return builtin_index - 2;
}

pub fn findInconsistentImportAliases(
    run: ProjectRun,
    imports: []const Import,
) !void {
    if (run.configuration.level(.inconsistent_import_alias) == .off) return;
    var aliases: majority.Tally = .{};
    for (imports) |current| {
        const alias = current.alias orelse continue;
        try aliases.add(run.allocator, current.resolved_path, alias);
    }
    for (imports) |current| {
        const current_alias = current.alias orelse continue;
        const group = aliases.lookup(current.resolved_path);
        if (!group.isMinority(current_alias)) continue;
        try run.report(.{
            .file_index = current.file_index,
            .rule = .inconsistent_import_alias,
            .span = current.alias_span.?,
            .message = try run.allocator.print(
                "module '{s}' is imported as '{s}', while {d} of {d} project imports use '{s}'",
                .{ current.spelling, current_alias, group.dominant_count, group.total, group.dominant.? },
            ),
        });
    }
}

pub fn resolveImportPath(allocator: std.mem.Allocator, importing_path: []const u8, spelling: []const u8) ![]const u8 {
    const directory = std.Io.Dir.path.dirname(importing_path) orelse "";
    const absolute = try std.Io.Dir.path.resolveAlloc(allocator, &.{ "/", directory, spelling });
    return std.mem.trimStart(u8, absolute, "/");
}

fn looksLikeTestPath(path: []const u8) bool {
    const basename = std.Io.Dir.path.basename(path);
    if (std.mem.endsWith(u8, basename, "_test.zig")) return true;
    var components = std.mem.splitScalar(u8, path, std.Io.Dir.path.sep);
    while (components.next()) |component| if (std.mem.eql(u8, component, "test") or std.mem.eql(u8, component, "tests")) return true;
    return false;
}

fn containsTestDeclaration(tokens: []const std.zig.Token) bool {
    for (tokens) |token| if (token.tag == .keyword_test) return true;
    return false;
}

fn sourceMentionsPath(source: []const u8, path: []const u8) bool {
    if (std.mem.find(u8, source, path) != null) return true;
    const basename = std.Io.Dir.path.basename(path);
    return std.mem.find(u8, source, basename) != null;
}

pub fn stringValue(source: []const u8, token: std.zig.Token) ?[]const u8 {
    const literal = source[token.loc.start..token.loc.end];
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    return literal[1 .. literal.len - 1];
}

test "test files imported from a test block are referenced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.unreferenced_test_file}, .information);
    const files = [_]project.SourceFile{
        .{ .path = "src/parser.zig", .source = "test { _ = @import(\"parser_test.zig\"); }" },
        .{ .path = "src/parser_test.zig", .source = "test \"parser\" {}" },
    };
    const found = try project.findings(arena.allocator(), &files, configuration);
    for (found) |finding| try std.testing.expect(finding.finding.rule != .unreferenced_test_file);
}

test "build helpers may enumerate test directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.unreferenced_test_file}, .information);
    const files = [_]project.SourceFile{
        .{ .path = "build.zig", .source = "pub fn build(b: *Build) void { @import(\"tests/add_cases.zig\").add(b); }" },
        .{ .path = "tests/add_cases.zig", .source = "pub fn add(b: *Build) void { var dir = b.path(\"tests/cases\").openDir(.{ .iterate = true }); var iterator = dir.iterate(); _ = iterator; }" },
        .{ .path = "tests/cases/parser.zig", .source = "test \"parser\" {}" },
    };
    const found = try project.findings(arena.allocator(), &files, configuration);
    for (found) |finding| try std.testing.expect(finding.finding.rule != .unreferenced_test_file);
}

test "declared import boundaries reject matching project imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.import_boundaries = &.{.{
        .from = "src/rules",
        .denied = &.{"src/lsp_server.zig"},
    }};
    configuration.levels[@backingInt(types.Rule.import_boundary)] = .warning;
    const files = [_]project.SourceFile{.{
        .path = "src/rules/example.zig",
        .source = "const lsp = @import(\"../lsp_server.zig\");",
    }};
    const found = try project.findings(arena.allocator(), &files, configuration);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.import_boundary, found[0].finding.rule);
}
