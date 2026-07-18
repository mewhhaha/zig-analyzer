const std = @import("std");

const syntax_scope = @import("../syntax_scope.zig");
const allocation_lifecycle = @import("allocation_lifecycle.zig");
const generated_source = @import("generated_source.zig");
const summaries = @import("summaries.zig");
const types = @import("types.zig");

pub const SourceFile = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: ?[]const std.zig.Token = null,
};

pub const CompilerShape = struct {
    name: []const u8,
    kind: enum { enumeration, tagged_union, structure },
    fields: []const []const u8,
};

pub const CompilerUnitFacts = struct {
    root_path: []const u8,
    shapes: []const CompilerShape,
};

pub const CompilerFacts = struct {
    units: []const CompilerUnitFacts = &.{},
    roots_complete: bool = false,
};

const IndexedSourceFile = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
};

pub const Finding = struct {
    file_index: usize,
    rule: types.Rule,
    span: std.zig.Token.Loc,
    message: []const u8,
};

const Import = struct {
    file_index: usize,
    span: std.zig.Token.Loc,
    spelling: []const u8,
    resolved_path: []const u8,
    alias: ?[]const u8 = null,
    alias_span: ?std.zig.Token.Loc = null,
};

pub fn findings(
    allocator: std.mem.Allocator,
    files: []const SourceFile,
    configuration: types.Configuration,
) ![]const Finding {
    return findingsWithCompilerFacts(allocator, files, configuration, .{});
}

pub fn findingsWithCompilerFacts(
    allocator: std.mem.Allocator,
    files: []const SourceFile,
    configuration: types.Configuration,
    compiler_facts: CompilerFacts,
) ![]const Finding {
    if (configuration.level(.duplicate_module_import) == .off and
        configuration.level(.duplicate_c_import) == .off and
        configuration.level(.unreferenced_test_file) == .off and
        configuration.level(.conflicting_build_options) == .off and
        configuration.level(.inconsistent_import_alias) == .off and
        configuration.level(.minority_naming_style) == .off and
        configuration.level(.inconsistent_parameter_vocabulary) == .off and
        configuration.level(.inconsistent_error_set_style) == .off and
        configuration.level(.allocation_after_init) == .off and
        configuration.level(.recursive_call) == .off and
        configuration.level(.import_boundary) == .off and
        configuration.level(.configuration_divergent_api) == .off and
        configuration.level(.unreachable_public_declaration) == .off and
        !allocation_lifecycle.enabled(configuration)) return &.{};
    const indexed_files = try allocator.alloc(IndexedSourceFile, files.len);
    for (files, indexed_files) |file, *indexed_file| indexed_file.* = .{
        .path = file.path,
        .source = file.source,
        .tokens = file.tokens orelse try tokenize(allocator, file.source),
    };
    var found: std.ArrayList(Finding) = .empty;
    const imports = if (configuration.level(.duplicate_module_import) != .off or
        configuration.level(.unreferenced_test_file) != .off or
        configuration.level(.inconsistent_import_alias) != .off or
        configuration.level(.import_boundary) != .off or
        configuration.level(.unreachable_public_declaration) != .off)
        try collectImports(allocator, indexed_files)
    else
        &.{};
    try findDuplicateModuleImports(allocator, imports, configuration, &found);
    try findDuplicateCImports(allocator, indexed_files, configuration, &found);
    try findUnreferencedTests(allocator, indexed_files, imports, configuration, &found);
    try findConflictingBuildOptions(allocator, indexed_files, configuration, &found);
    try findInconsistentImportAliases(allocator, indexed_files, imports, configuration, &found);
    try findMinorityNamingStyles(allocator, indexed_files, configuration, &found);
    try findInconsistentParameterVocabulary(allocator, indexed_files, configuration, &found);
    try findInconsistentErrorSetStyle(allocator, indexed_files, configuration, &found);
    try findAllocationsAfterInit(allocator, indexed_files, configuration, &found);
    try findRecursiveCalls(allocator, indexed_files, configuration, &found);
    try findImportBoundaryViolations(allocator, indexed_files, imports, configuration, &found);
    try findSummaryLifecycleDifferences(allocator, indexed_files, configuration, &found);
    try findConfigurationDivergentApis(allocator, indexed_files, configuration, compiler_facts, &found);
    try findUnreachablePublicDeclarations(allocator, indexed_files, imports, configuration, compiler_facts, &found);
    std.mem.sort(Finding, found.items, {}, struct {
        fn lessThan(_: void, left: Finding, right: Finding) bool {
            if (left.file_index != right.file_index) return left.file_index < right.file_index;
            if (left.span.start != right.span.start) return left.span.start < right.span.start;
            return @intFromEnum(left.rule) < @intFromEnum(right.rule);
        }
    }.lessThan);
    return try found.toOwnedSlice(allocator);
}

fn findSummaryLifecycleDifferences(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (!allocation_lifecycle.enabled(configuration) or files.len < 2) return;
    const sources = try allocator.alloc(summaries.Source, files.len);
    for (files, sources, 0..) |file, *source, file_index| source.* = .{
        .file_index = file_index,
        .path = file.path,
        .source = file.source,
        .tokens = file.tokens,
    };
    var summary_index = try summaries.build(allocator, sources, configuration);
    defer summary_index.deinit(allocator);

    for (files, 0..) |file, file_index| {
        if (!summary_index.hasImportedLifecycleFacts(file.source)) continue;
        var tree = try std.zig.Ast.parse(allocator, file.source, .zig);
        defer tree.deinit(allocator);
        var scope_index = try syntax_scope.Index.init(allocator, file.source, file.tokens);
        defer scope_index.deinit();
        const project_warnings = try allocation_lifecycle.warningsWithSummaries(
            allocator,
            file.source,
            &tree,
            file.tokens,
            &scope_index,
            summary_index,
        );
        const local_warnings = try allocation_lifecycle.warningsWithSyntax(
            allocator,
            file.source,
            &tree,
            file.tokens,
            &scope_index,
            configuration,
        );
        for (project_warnings) |warning| {
            if (containsLifecycleWarning(local_warnings, warning)) continue;
            try found.append(allocator, .{
                .file_index = file_index,
                .rule = warning.rule,
                .span = warning.span,
                .message = warning.message,
            });
        }
    }
}

fn containsLifecycleWarning(
    warnings: []const allocation_lifecycle.Warning,
    candidate: allocation_lifecycle.Warning,
) bool {
    for (warnings) |warning| {
        if (warning.rule == candidate.rule and warning.span.start == candidate.span.start and
            warning.span.end == candidate.span.end) return true;
    }
    return false;
}

fn findConfigurationDivergentApis(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    compiler_facts: CompilerFacts,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.configuration_divergent_api) == .off or compiler_facts.units.len < 2) return;
    var reported: std.StringHashMapUnmanaged(void) = .empty;
    for (compiler_facts.units, 0..) |left_unit, left_index| {
        for (left_unit.shapes) |left_shape| {
            for (compiler_facts.units[left_index + 1 ..]) |right_unit| {
                const right_shape = shapeNamed(right_unit.shapes, left_shape.name) orelse continue;
                if (shapesEqual(left_shape, right_shape) or reported.contains(left_shape.name)) continue;
                const name = declarationBaseName(left_shape.name);
                const location = publicDeclarationNamed(files, name) orelse continue;
                try reported.put(allocator, left_shape.name, {});
                try found.append(allocator, .{
                    .file_index = location.file_index,
                    .rule = .configuration_divergent_api,
                    .span = location.span,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "public declaration '{s}' has different compiler-resolved shapes in compile units '{s}' and '{s}'",
                        .{ name, left_unit.root_path, right_unit.root_path },
                    ),
                });
            }
        }
    }
}

fn findUnreachablePublicDeclarations(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    imports: []const Import,
    configuration: types.Configuration,
    compiler_facts: CompilerFacts,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.unreachable_public_declaration) == .off or
        compiler_facts.units.len == 0 or !compiler_facts.roots_complete) return;
    const reachable = try allocator.alloc(bool, files.len);
    @memset(reachable, false);
    for (compiler_facts.units) |unit| {
        for (files, 0..) |file, file_index| {
            if (std.mem.eql(u8, file.path, unit.root_path)) reachable[file_index] = true;
        }
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (imports) |import| {
            if (!reachable[import.file_index]) continue;
            for (files, 0..) |file, imported_index| {
                if (reachable[imported_index] or !std.mem.eql(u8, file.path, import.resolved_path)) continue;
                reachable[imported_index] = true;
                changed = true;
            }
        }
    }
    for (imports) |import| {
        if (!reachable[import.file_index] or std.mem.endsWith(u8, import.spelling, ".zig") or
            std.mem.eql(u8, import.spelling, "std") or std.mem.eql(u8, import.spelling, "builtin") or
            std.mem.eql(u8, import.spelling, "root")) continue;
        return;
    }
    for (files, 0..) |file, file_index| {
        if (reachable[file_index] or std.mem.eql(u8, std.fs.path.basename(file.path), "build.zig")) continue;
        for (file.tokens, 0..) |token, pub_index| {
            if (token.tag != .keyword_pub or pub_index + 2 >= file.tokens.len) continue;
            const name_index = if (file.tokens[pub_index + 1].tag == .keyword_fn or
                file.tokens[pub_index + 1].tag == .keyword_const or
                file.tokens[pub_index + 1].tag == .keyword_var)
                pub_index + 2
            else
                continue;
            if (file.tokens[name_index].tag != .identifier) continue;
            const name = tokenText(file.source, file.tokens[name_index]);
            try found.append(allocator, .{
                .file_index = file_index,
                .rule = .unreachable_public_declaration,
                .span = file.tokens[name_index].loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "public declaration '{s}' is reachable from none of the {d} compiler-analyzed compile units",
                    .{ name, compiler_facts.units.len },
                ),
            });
        }
    }
}

const PublicDeclarationLocation = struct { file_index: usize, span: std.zig.Token.Loc };

fn publicDeclarationNamed(files: []const IndexedSourceFile, name: []const u8) ?PublicDeclarationLocation {
    var selected: ?PublicDeclarationLocation = null;
    for (files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, index| {
            if (token.tag != .keyword_pub or index + 2 >= file.tokens.len or
                (file.tokens[index + 1].tag != .keyword_const and file.tokens[index + 1].tag != .keyword_var) or
                file.tokens[index + 2].tag != .identifier or !tokenIs(file.source, file.tokens[index + 2], name)) continue;
            if (selected != null) return null;
            selected = .{ .file_index = file_index, .span = file.tokens[index + 2].loc };
        }
    }
    return selected;
}

fn shapeNamed(shapes: []const CompilerShape, name: []const u8) ?CompilerShape {
    var selected: ?CompilerShape = null;
    for (shapes) |shape| {
        if (!std.mem.eql(u8, shape.name, name)) continue;
        if (selected != null) return null;
        selected = shape;
    }
    return selected;
}

fn shapesEqual(left: CompilerShape, right: CompilerShape) bool {
    if (left.kind != right.kind or left.fields.len != right.fields.len) return false;
    for (left.fields, right.fields) |left_field, right_field| {
        if (!std.mem.eql(u8, left_field, right_field)) return false;
    }
    return true;
}

fn declarationBaseName(declaration: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, declaration, '.') orelse return declaration;
    return declaration[separator + 1 ..];
}

fn findImportBoundaryViolations(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    imports: []const Import,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.import_boundary) == .off) return;
    for (imports) |import| {
        const source_path = files[import.file_index].path;
        for (configuration.import_boundaries) |boundary| {
            if (!pathMatchesContract(source_path, boundary.from)) continue;
            for (boundary.denied) |denied| {
                if (!pathMatchesContract(import.resolved_path, denied)) continue;
                try found.append(allocator, .{
                    .file_index = import.file_index,
                    .rule = .import_boundary,
                    .span = import.span,
                    .message = try std.fmt.allocPrint(
                        allocator,
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
    if (contract.len != 0 and std.fs.path.isSep(contract[contract.len - 1])) return true;
    return std.fs.path.isSep(path[contract.len]);
}

fn findDuplicateModuleImports(
    allocator: std.mem.Allocator,
    imports: []const Import,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.duplicate_module_import) == .off) return;
    for (imports, 0..) |current, index| {
        for (imports[0..index]) |previous| {
            if (previous.file_index != current.file_index or
                !std.mem.eql(u8, previous.resolved_path, current.resolved_path) or
                std.mem.eql(u8, previous.spelling, current.spelling)) continue;
            try found.append(allocator, .{
                .file_index = current.file_index,
                .rule = .duplicate_module_import,
                .span = current.span,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "imports '{s}' and '{s}' resolve to the same module '{s}'",
                    .{ previous.spelling, current.spelling, current.resolved_path },
                ),
            });
            break;
        }
    }
}

fn findDuplicateCImports(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.duplicate_c_import) == .off) return;
    var signatures: std.StringHashMapUnmanaged(struct { file_index: usize, span: std.zig.Token.Loc }) = .empty;
    for (files, 0..) |file, file_index| {
        if (generated_source.isTranslateCOutput(file.source)) continue;
        for (file.tokens, 0..) |token, index| {
            if (token.tag != .builtin or !tokenIs(file.source, token, "@cImport") or
                index + 1 >= file.tokens.len or file.tokens[index + 1].tag != .l_paren) continue;
            const closing = matchingToken(file.tokens, index + 1, .l_paren, .r_paren) orelse continue;
            var signature_writer: std.Io.Writer.Allocating = .init(allocator);
            for (file.source[file.tokens[index + 1].loc.end..file.tokens[closing].loc.start]) |character| {
                if (!std.ascii.isWhitespace(character)) try signature_writer.writer.writeByte(character);
            }
            const signature = try signature_writer.toOwnedSlice();
            if (signatures.get(signature)) |first| {
                if (first.file_index == file_index) continue;
                try found.append(allocator, .{
                    .file_index = file_index,
                    .rule = .duplicate_c_import,
                    .span = token.loc,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "@cImport duplicates the translation already declared in '{s}'; expose one translated namespace instead",
                        .{files[first.file_index].path},
                    ),
                });
            } else try signatures.put(allocator, signature, .{ .file_index = file_index, .span = token.loc });
        }
    }
}

fn findUnreferencedTests(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    imports: []const Import,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.unreferenced_test_file) == .off) return;
    const build_reachable = try allocator.alloc(bool, files.len);
    defer allocator.free(build_reachable);
    @memset(build_reachable, false);
    for (files, 0..) |file, file_index| {
        build_reachable[file_index] = std.mem.eql(u8, std.fs.path.basename(file.path), "build.zig");
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (files, 0..) |file, file_index| {
            if (!build_reachable[file_index]) continue;
            for (file.tokens, 0..) |token, index| {
                if (token.tag != .builtin or !tokenIs(file.source, token, "@import") or
                    index + 2 >= file.tokens.len or file.tokens[index + 1].tag != .l_paren or
                    file.tokens[index + 2].tag != .string_literal) continue;
                const spelling = stringValue(file.source, file.tokens[index + 2]) orelse continue;
                if (!std.mem.endsWith(u8, spelling, ".zig")) continue;
                const resolved_path = try resolveImportPath(allocator, file.path, spelling);
                for (files, 0..) |candidate, candidate_index| {
                    if (build_reachable[candidate_index] or !std.mem.eql(u8, candidate.path, resolved_path)) continue;
                    build_reachable[candidate_index] = true;
                    changed = true;
                }
                allocator.free(resolved_path);
            }
        }
    }
    for (files, 0..) |file, file_index| {
        if (!looksLikeTestPath(file.path) or !containsTestDeclaration(file.tokens)) continue;
        var referenced = false;
        for (imports) |import| {
            if (import.file_index != file_index and std.mem.eql(u8, import.resolved_path, file.path)) {
                referenced = true;
                break;
            }
        }
        if (!referenced) for (files, 0..) |importing_file, importing_index| {
            if (importing_index == file_index) continue;
            for (importing_file.tokens, 0..) |token, index| {
                if (token.tag != .builtin or !tokenIs(importing_file.source, token, "@import") or
                    index + 2 >= importing_file.tokens.len or importing_file.tokens[index + 1].tag != .l_paren or
                    importing_file.tokens[index + 2].tag != .string_literal) continue;
                const spelling = stringValue(importing_file.source, importing_file.tokens[index + 2]) orelse continue;
                if (!std.mem.endsWith(u8, spelling, ".zig")) continue;
                const resolved_path = try resolveImportPath(allocator, importing_file.path, spelling);
                if (std.mem.eql(u8, resolved_path, file.path)) {
                    referenced = true;
                    break;
                }
            }
            if (referenced) break;
        };
        if (!referenced) for (files, 0..) |build_file, build_index| {
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
            var directory = std.fs.path.dirname(file.path);
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
                directory = std.fs.path.dirname(candidate_directory);
            }
            if (referenced) break;
        };
        if (referenced) continue;
        try found.append(allocator, .{
            .file_index = file_index,
            .rule = .unreferenced_test_file,
            .span = .{ .start = 0, .end = @min(file.source.len, 1) },
            .message = try std.fmt.allocPrint(
                allocator,
                "test source '{s}' is not imported by another Zig file or referenced from build.zig",
                .{file.path},
            ),
        });
    }
}

fn findConflictingBuildOptions(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.conflicting_build_options) == .off) return;
    var roots: std.StringHashMapUnmanaged(struct { signature: []const u8, file_index: usize }) = .empty;
    var reported: std.StringHashMapUnmanaged(void) = .empty;
    for (files, 0..) |file, file_index| {
        if (!std.mem.eql(u8, std.fs.path.basename(file.path), "build.zig")) continue;
        for (file.tokens, 0..) |token, index| {
            if (token.tag != .identifier or !tokenIs(file.source, token, "root_source_file") or index + 6 >= file.tokens.len) continue;
            var string_index = index + 1;
            while (string_index < file.tokens.len and string_index - index < 12 and file.tokens[string_index].tag != .string_literal) : (string_index += 1) {}
            if (string_index >= file.tokens.len or string_index - index >= 12) continue;
            const root_spelling = stringValue(file.source, file.tokens[string_index]) orelse continue;
            if (!std.mem.endsWith(u8, root_spelling, ".zig")) continue;
            const root_path = try resolveImportPath(allocator, file.path, root_spelling);
            const block = enclosingInitializer(file.tokens, index) orelse continue;
            const signature = try optionSignature(allocator, file.source, file.tokens, block.opening + 1, block.closing);
            if (std.mem.eql(u8, signature, "target=<default>;optimize=<default>")) continue;
            if (roots.get(root_path)) |first| {
                if (std.mem.eql(u8, first.signature, signature)) continue;
                const conflict_key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ root_path, signature });
                if (reported.contains(conflict_key)) continue;
                try reported.put(allocator, conflict_key, {});
                try found.append(allocator, .{
                    .file_index = file_index,
                    .rule = .conflicting_build_options,
                    .span = file.tokens[string_index].loc,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "root source '{s}' is configured with both '{s}' and '{s}'; semantic results may differ between compile units",
                        .{ root_path, first.signature, signature },
                    ),
                });
            } else try roots.put(allocator, root_path, .{ .signature = signature, .file_index = file_index });
        }
    }
}

fn collectImports(allocator: std.mem.Allocator, files: []const IndexedSourceFile) ![]const Import {
    var imports: std.ArrayList(Import) = .empty;
    for (files, 0..) |file, file_index| {
        if (generated_source.isTranslateCOutput(file.source)) continue;
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
            try imports.append(allocator, .{
                .file_index = file_index,
                .span = file.tokens[index + 2].loc,
                .spelling = spelling,
                .resolved_path = if (std.mem.endsWith(u8, spelling, ".zig"))
                    try resolveImportPath(allocator, file.path, spelling)
                else
                    try allocator.dupe(u8, spelling),
                .alias = if (alias_index) |alias| tokenText(file.source, file.tokens[alias]) else null,
                .alias_span = if (alias_index) |alias| file.tokens[alias].loc else null,
            });
        }
    }
    return try imports.toOwnedSlice(allocator);
}

fn importAliasIndex(tokens: []const std.zig.Token, builtin_index: usize) ?usize {
    if (builtin_index < 3 or tokens[builtin_index - 1].tag != .equal or tokens[builtin_index - 2].tag != .identifier) return null;
    if (tokens[builtin_index - 3].tag != .keyword_const and tokens[builtin_index - 3].tag != .keyword_var) return null;
    const closing = matchingToken(tokens, builtin_index + 1, .l_paren, .r_paren) orelse return null;
    if (closing + 1 < tokens.len and tokens[closing + 1].tag == .period) return null;
    return builtin_index - 2;
}

fn findInconsistentImportAliases(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    imports: []const Import,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.inconsistent_import_alias) == .off) return;
    _ = files;
    const AliasGroup = struct { total: usize = 0, dominant_alias: ?[]const u8 = null, dominant_count: usize = 0 };
    var groups: std.StringHashMapUnmanaged(AliasGroup) = .empty;
    var alias_counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (imports) |current| {
        const alias = current.alias orelse continue;
        const group = try groups.getOrPut(allocator, current.resolved_path);
        if (!group.found_existing) group.value_ptr.* = .{};
        group.value_ptr.total += 1;
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ current.resolved_path, alias });
        const count = try alias_counts.getOrPut(allocator, key);
        if (!count.found_existing) count.value_ptr.* = 0;
        count.value_ptr.* += 1;
    }
    for (imports) |current| {
        const alias = current.alias orelse continue;
        const group = groups.getPtr(current.resolved_path).?;
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ current.resolved_path, alias });
        const count = alias_counts.get(key).?;
        if (count > group.dominant_count) {
            group.dominant_alias = alias;
            group.dominant_count = count;
        }
    }
    for (imports) |current| {
        const current_alias = current.alias orelse continue;
        const group = groups.get(current.resolved_path).?;
        if (group.total < 20 or group.dominant_count * 10 < group.total * 9 or
            group.dominant_alias == null or std.mem.eql(u8, current_alias, group.dominant_alias.?)) continue;
        try found.append(allocator, .{
            .file_index = current.file_index,
            .rule = .inconsistent_import_alias,
            .span = current.alias_span.?,
            .message = try std.fmt.allocPrint(
                allocator,
                "module '{s}' is imported as '{s}', while {d} of {d} project imports use '{s}'",
                .{ current.spelling, current_alias, group.dominant_count, group.total, group.dominant_alias.? },
            ),
        });
    }
}

const NamingKind = enum { function, type_name, constant };
const NamingStyle = enum { snake, camel, title, other };
const NamingSample = struct {
    file_index: usize,
    span: std.zig.Token.Loc,
    name: []const u8,
    kind: NamingKind,
    style: NamingStyle,
};

fn findMinorityNamingStyles(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.minority_naming_style) == .off) return;
    var samples: std.ArrayList(NamingSample) = .empty;
    for (files, 0..) |file, file_index| {
        if (generated_source.isTranslateCOutput(file.source)) continue;
        var brace_depth: usize = 0;
        for (file.tokens, 0..) |token, index| {
            switch (token.tag) {
                .l_brace => brace_depth += 1,
                .r_brace => brace_depth -|= 1,
                .keyword_fn => if (!foreignDeclaration(file.tokens, index) and index + 1 < file.tokens.len and file.tokens[index + 1].tag == .identifier) {
                    const name = tokenText(file.source, file.tokens[index + 1]);
                    try samples.append(allocator, .{ .file_index = file_index, .span = file.tokens[index + 1].loc, .name = name, .kind = .function, .style = namingStyle(name) });
                },
                .keyword_const => if (brace_depth == 0 and !foreignDeclaration(file.tokens, index) and index + 2 < file.tokens.len and file.tokens[index + 1].tag == .identifier) {
                    const name = tokenText(file.source, file.tokens[index + 1]);
                    const kind: NamingKind = if (declarationLooksLikeType(file.tokens, index)) .type_name else .constant;
                    try samples.append(allocator, .{ .file_index = file_index, .span = file.tokens[index + 1].loc, .name = name, .kind = kind, .style = namingStyle(name) });
                },
                else => {},
            }
        }
    }
    var totals: [std.meta.fields(NamingKind).len]usize = @splat(0);
    var counts: [std.meta.fields(NamingKind).len][std.meta.fields(NamingStyle).len]usize = @splat(@splat(0));
    for (samples.items) |sample| {
        totals[@intFromEnum(sample.kind)] += 1;
        counts[@intFromEnum(sample.kind)][@intFromEnum(sample.style)] += 1;
    }
    for (samples.items) |sample| {
        const total = totals[@intFromEnum(sample.kind)];
        const kind_counts = counts[@intFromEnum(sample.kind)];
        if (total < 20) continue;
        var dominant = NamingStyle.snake;
        for (std.enums.values(NamingStyle)) |style| {
            if (kind_counts[@intFromEnum(style)] > kind_counts[@intFromEnum(dominant)]) dominant = style;
        }
        const dominant_count = kind_counts[@intFromEnum(dominant)];
        if (dominant_count * 10 < total * 9 or sample.style == dominant) continue;
        try found.append(allocator, .{
            .file_index = sample.file_index,
            .rule = .minority_naming_style,
            .span = sample.span,
            .message = try std.fmt.allocPrint(
                allocator,
                "{s} name '{s}' uses {s}, while {d} of {d} project declarations use {s}",
                .{ @tagName(sample.kind), sample.name, @tagName(sample.style), dominant_count, total, @tagName(dominant) },
            ),
        });
    }
}

const ParameterSample = struct {
    file_index: usize,
    span: std.zig.Token.Loc,
    name: []const u8,
    type_name: []const u8,
};

fn findInconsistentParameterVocabulary(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.inconsistent_parameter_vocabulary) == .off) return;
    var samples: std.ArrayList(ParameterSample) = .empty;
    for (files, 0..) |file, file_index| {
        if (generated_source.isTranslateCOutput(file.source)) continue;
        for (file.tokens, 0..) |token, fn_index| {
            if (token.tag != .keyword_fn or fn_index + 2 >= file.tokens.len or
                file.tokens[fn_index + 1].tag != .identifier or file.tokens[fn_index + 2].tag != .l_paren or
                foreignDeclaration(file.tokens, fn_index)) continue;
            const opening = nextTagBefore(file.tokens, fn_index + 1, .l_paren, .semicolon) orelse continue;
            const closing = matchingToken(file.tokens, opening, .l_paren, .r_paren) orelse continue;
            var start = opening + 1;
            while (start < closing) {
                const comma = topLevelComma(file.tokens, start, closing) orelse closing;
                const colon = findTag(file.tokens, start, comma, .colon);
                if (colon) |colon_index| if (colon_index > start and file.tokens[colon_index - 1].tag == .identifier and colon_index + 1 < comma) {
                    const name = tokenText(file.source, file.tokens[colon_index - 1]);
                    if (!std.mem.eql(u8, name, "self") and !std.mem.eql(u8, name, "_")) try samples.append(allocator, .{
                        .file_index = file_index,
                        .span = file.tokens[colon_index - 1].loc,
                        .name = name,
                        .type_name = std.mem.trim(u8, file.source[file.tokens[colon_index + 1].loc.start..file.tokens[comma - 1].loc.end], " \t\r\n"),
                    });
                };
                if (comma == closing) break;
                start = comma + 1;
            }
        }
    }
    const VocabularyGroup = struct { total: usize = 0, dominant_name: ?[]const u8 = null, dominant_count: usize = 0 };
    var groups: std.StringHashMapUnmanaged(VocabularyGroup) = .empty;
    var name_counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (samples.items) |sample| {
        const group = try groups.getOrPut(allocator, sample.type_name);
        if (!group.found_existing) group.value_ptr.* = .{};
        group.value_ptr.total += 1;
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ sample.type_name, sample.name });
        const count = try name_counts.getOrPut(allocator, key);
        if (!count.found_existing) count.value_ptr.* = 0;
        count.value_ptr.* += 1;
    }
    for (samples.items) |sample| {
        const group = groups.getPtr(sample.type_name).?;
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ sample.type_name, sample.name });
        const count = name_counts.get(key).?;
        if (count > group.dominant_count) {
            group.dominant_name = sample.name;
            group.dominant_count = count;
        }
    }
    for (samples.items) |sample| {
        const group = groups.get(sample.type_name).?;
        if (group.total < 20 or group.dominant_count * 10 < group.total * 9 or group.dominant_name == null or
            std.mem.eql(u8, sample.name, group.dominant_name.?)) continue;
        try found.append(allocator, .{
            .file_index = sample.file_index,
            .rule = .inconsistent_parameter_vocabulary,
            .span = sample.span,
            .message = try std.fmt.allocPrint(allocator, "parameter '{s}' has type '{s}', for which {d} of {d} project parameters use '{s}'", .{ sample.name, sample.type_name, group.dominant_count, group.total, group.dominant_name.? }),
        });
    }
}

const ErrorStyleSample = struct { file_index: usize, span: std.zig.Token.Loc, explicit: bool };

fn findInconsistentErrorSetStyle(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.inconsistent_error_set_style) == .off) return;
    var samples: std.ArrayList(ErrorStyleSample) = .empty;
    for (files, 0..) |file, file_index| {
        if (generated_source.isTranslateCOutput(file.source)) continue;
        for (file.tokens, 0..) |token, fn_index| {
            if (token.tag != .keyword_fn or fn_index == 0 or file.tokens[fn_index - 1].tag != .keyword_pub) continue;
            const opening = nextTagBefore(file.tokens, fn_index + 1, .l_paren, .semicolon) orelse continue;
            const closing = matchingToken(file.tokens, opening, .l_paren, .r_paren) orelse continue;
            const body = nextTagBefore(file.tokens, closing + 1, .l_brace, .semicolon) orelse continue;
            const bang = findTag(file.tokens, closing + 1, body, .bang) orelse continue;
            try samples.append(allocator, .{ .file_index = file_index, .span = file.tokens[bang].loc, .explicit = bang != closing + 1 });
        }
    }
    if (samples.items.len < 20) return;
    var explicit_count: usize = 0;
    for (samples.items) |sample| {
        if (sample.explicit) explicit_count += 1;
    }
    const inferred_count = samples.items.len - explicit_count;
    const dominant_explicit = explicit_count > inferred_count;
    const dominant_count = @max(explicit_count, inferred_count);
    if (dominant_count * 10 < samples.items.len * 9) return;
    for (samples.items) |sample| {
        if (sample.explicit == dominant_explicit) continue;
        try found.append(allocator, .{
            .file_index = sample.file_index,
            .rule = .inconsistent_error_set_style,
            .span = sample.span,
            .message = try std.fmt.allocPrint(allocator, "public function uses an {s} error set, while {d} of {d} public error-returning functions use {s} sets", .{ if (sample.explicit) "explicit" else "inferred", dominant_count, samples.items.len, if (dominant_explicit) "explicit" else "inferred" }),
        });
    }
}

fn findAllocationsAfterInit(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.allocation_after_init) == .off) return;
    const allocation_methods = [_][]const u8{ "alloc", "allocWithOptions", "create", "dupe", "realloc" };
    for (files, 0..) |file, file_index| {
        if (generated_source.isTranslateCOutput(file.source)) continue;
        for (file.tokens, 0..) |token, fn_index| {
            if (token.tag != .keyword_fn or fn_index + 2 >= file.tokens.len or
                file.tokens[fn_index + 1].tag != .identifier or file.tokens[fn_index + 2].tag != .l_paren) continue;
            const function_name = tokenText(file.source, file.tokens[fn_index + 1]);
            if (isInitializationName(function_name)) continue;
            const parameters_end = matchingToken(file.tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
            const opening = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
            const closing = matchingToken(file.tokens, opening, .l_brace, .r_brace) orelse continue;
            var index = opening + 1;
            while (index < closing) : (index += 1) {
                const body_token = file.tokens[index];
                if (body_token.tag == .keyword_fn and index + 2 < closing and
                    file.tokens[index + 1].tag == .identifier and file.tokens[index + 2].tag == .l_paren)
                {
                    const nested_parameters_end = matchingToken(file.tokens, index + 2, .l_paren, .r_paren) orelse continue;
                    const nested_opening = syntax_scope.functionBodyAfterParameters(file.tokens, nested_parameters_end) orelse continue;
                    const nested_closing = matchingToken(file.tokens, nested_opening, .l_brace, .r_brace) orelse continue;
                    if (nested_closing < closing) index = nested_closing;
                    continue;
                }
                if (body_token.tag != .identifier or index < 2 or file.tokens[index - 1].tag != .period or file.tokens[index - 2].tag != .identifier) continue;
                var is_allocation = false;
                for (allocation_methods) |method| {
                    if (tokenIs(file.source, body_token, method)) is_allocation = true;
                }
                if (!is_allocation) continue;
                const receiver = tokenText(file.source, file.tokens[index - 2]);
                if (std.mem.indexOf(u8, receiver, "alloc") == null and !bindingHasAllocatorType(file, fn_index, opening, receiver)) continue;
                try found.append(allocator, .{
                    .file_index = file_index,
                    .rule = .allocation_after_init,
                    .span = body_token.loc,
                    .message = try std.fmt.allocPrint(allocator, "function '{s}' allocates through '{s}' outside a recognized initialization path", .{ function_name, receiver }),
                });
            }
        }
    }
}

const FunctionDeclaration = struct {
    file_index: usize,
    name: []const u8,
    span: std.zig.Token.Loc,
    calls: []const []const u8,
    inline_fn: bool,
};

const FunctionDeclarationsByName = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize));

fn findRecursiveCalls(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.recursive_call) == .off) return;
    var declarations: std.ArrayList(FunctionDeclaration) = .empty;
    var declarations_by_name: FunctionDeclarationsByName = .empty;
    defer {
        var declaration_indices = declarations_by_name.valueIterator();
        while (declaration_indices.next()) |indices| indices.deinit(allocator);
        declarations_by_name.deinit(allocator);
    }
    for (files, 0..) |file, file_index| {
        if (generated_source.isTranslateCOutput(file.source)) continue;
        for (file.tokens, 0..) |token, fn_index| {
            if (token.tag != .keyword_fn or fn_index + 2 >= file.tokens.len or
                file.tokens[fn_index + 1].tag != .identifier or file.tokens[fn_index + 2].tag != .l_paren) continue;
            const parameters_end = matchingToken(file.tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
            const opening = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
            const closing = matchingToken(file.tokens, opening, .l_brace, .r_brace) orelse continue;
            const name = tokenText(file.source, file.tokens[fn_index + 1]);
            try declarations.append(allocator, .{
                .file_index = file_index,
                .name = name,
                .span = file.tokens[fn_index + 1].loc,
                .calls = try collectCalledFunctions(allocator, file.source, file.tokens, opening + 1, closing),
                .inline_fn = fn_index > 0 and file.tokens[fn_index - 1].tag == .keyword_inline,
            });
            const entry = try declarations_by_name.getOrPutValue(allocator, name, .empty);
            try entry.value_ptr.append(allocator, declarations.items.len - 1);
        }
    }
    for (declarations.items) |declaration| {
        if (declaration.inline_fn or !callsFunction(declaration, declaration.name)) continue;
        try found.append(allocator, .{
            .file_index = declaration.file_index,
            .rule = .recursive_call,
            .span = declaration.span,
            .message = try std.fmt.allocPrint(allocator, "function '{s}' calls itself recursively; use an explicitly bounded worklist", .{declaration.name}),
        });
    }
    for (declarations.items, 0..) |left, left_index| {
        if (left.inline_fn) continue;
        for (left.calls) |called_name| {
            const right_indices = declarations_by_name.get(called_name) orelse continue;
            for (right_indices.items) |right_index| {
                if (right_index <= left_index) continue;
                const right = declarations.items[right_index];
                if (right.inline_fn or !callsFunction(right, left.name)) continue;
                try found.append(allocator, .{
                    .file_index = right.file_index,
                    .rule = .recursive_call,
                    .span = right.span,
                    .message = try std.fmt.allocPrint(allocator, "mutual recursion cycle '{s} -> {s} -> {s}' has input-controlled stack depth", .{ left.name, right.name, left.name }),
                });
            }
        }
    }
}

fn callsFunction(declaration: FunctionDeclaration, name: []const u8) bool {
    for (declaration.calls) |called_name| if (std.mem.eql(u8, called_name, name)) return true;
    return false;
}

fn collectCalledFunctions(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    body_start: usize,
    body_end: usize,
) ![]const []const u8 {
    var calls: std.ArrayList([]const u8) = .empty;
    var index = body_start;
    while (index < body_end) : (index += 1) {
        const token = tokens[index];
        if (token.tag == .keyword_fn and index + 2 < body_end and
            tokens[index + 1].tag == .identifier and tokens[index + 2].tag == .l_paren)
        {
            const parameters_end = matchingToken(tokens, index + 2, .l_paren, .r_paren) orelse continue;
            const body_opening = syntax_scope.functionBodyAfterParameters(tokens, parameters_end) orelse continue;
            const body_closing = matchingToken(tokens, body_opening, .l_brace, .r_brace) orelse continue;
            if (body_closing < body_end) index = body_closing;
            continue;
        }
        if (token.tag != .identifier or index + 1 >= body_end or tokens[index + 1].tag != .l_paren or
            (index > body_start and tokens[index - 1].tag == .period)) continue;
        const name = tokenText(source, token);
        var already_recorded = false;
        for (calls.items) |called_name| if (std.mem.eql(u8, called_name, name)) {
            already_recorded = true;
            break;
        };
        if (!already_recorded) try calls.append(allocator, name);
    }
    return try calls.toOwnedSlice(allocator);
}

fn bindingHasAllocatorType(file: IndexedSourceFile, start: usize, end: usize, name: []const u8) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !tokenIs(file.source, token, name) or index + 6 >= end or file.tokens[index + 1].tag != .colon) continue;
        const type_end = topLevelComma(file.tokens, index + 2, end) orelse end;
        if (std.mem.indexOf(u8, file.source[file.tokens[index + 2].loc.start..file.tokens[type_end - 1].loc.end], "Allocator") != null) return true;
    }
    return false;
}

fn isInitializationName(name: []const u8) bool {
    return std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "create") or
        std.mem.startsWith(u8, name, "init") or std.mem.startsWith(u8, name, "create");
}

fn declarationLooksLikeType(tokens: []const std.zig.Token, const_index: usize) bool {
    if (const_index + 3 >= tokens.len or tokens[const_index + 2].tag != .equal) return false;
    return switch (tokens[const_index + 3].tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque, .keyword_error => true,
        else => false,
    };
}

fn foreignDeclaration(tokens: []const std.zig.Token, index: usize) bool {
    if (index > 0 and (tokens[index - 1].tag == .keyword_extern or tokens[index - 1].tag == .keyword_export)) return true;
    return index > 1 and tokens[index - 1].tag == .string_literal and tokens[index - 2].tag == .keyword_extern;
}

fn namingStyle(name: []const u8) NamingStyle {
    if (name.len == 0) return .other;
    if (std.mem.indexOfScalar(u8, name, '_') != null) return .snake;
    if (std.ascii.isUpper(name[0])) return .title;
    var has_upper = false;
    for (name[1..]) |character| if (std.ascii.isUpper(character)) {
        has_upper = true;
        break;
    };
    return if (has_upper) .camel else .snake;
}

fn tokenText(source: []const u8, token: std.zig.Token) []const u8 {
    return source[token.loc.start..token.loc.end];
}

fn findTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    for (tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

fn nextTagBefore(tokens: []const std.zig.Token, start: usize, wanted: std.zig.Token.Tag, stop: std.zig.Token.Tag) ?usize {
    for (tokens[start..], start..) |token, index| {
        if (token.tag == stop) return null;
        if (token.tag == wanted) return index;
    }
    return null;
}

fn topLevelComma(tokens: []const std.zig.Token, start: usize, end: usize) ?usize {
    var depth: usize = 0;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) return index,
        else => {},
    };
    return null;
}

fn resolveImportPath(allocator: std.mem.Allocator, importing_path: []const u8, spelling: []const u8) ![]const u8 {
    const directory = std.fs.path.dirname(importing_path) orelse "";
    const absolute = try std.fs.path.resolve(allocator, &.{ "/", directory, spelling });
    return std.mem.trimStart(u8, absolute, "/");
}

fn looksLikeTestPath(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, basename, "_test.zig")) return true;
    var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (components.next()) |component| if (std.mem.eql(u8, component, "test") or std.mem.eql(u8, component, "tests")) return true;
    return false;
}

fn containsTestDeclaration(tokens: []const std.zig.Token) bool {
    for (tokens) |token| if (token.tag == .keyword_test) return true;
    return false;
}

fn sourceMentionsPath(source: []const u8, path: []const u8) bool {
    if (std.mem.indexOf(u8, source, path) != null) return true;
    const basename = std.fs.path.basename(path);
    return std.mem.indexOf(u8, source, basename) != null;
}

const Block = struct { opening: usize, closing: usize };

fn enclosingInitializer(tokens: []const std.zig.Token, index: usize) ?Block {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == .r_brace) depth += 1;
        if (tokens[cursor].tag != .l_brace) continue;
        if (depth != 0) {
            depth -= 1;
            continue;
        }
        const closing = matchingToken(tokens, cursor, .l_brace, .r_brace) orelse return null;
        return .{ .opening = cursor, .closing = closing };
    }
    return null;
}

fn optionSignature(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    start: usize,
    end: usize,
) ![]const u8 {
    const target = optionValue(source, tokens, start, end, "target") orelse "<default>";
    const optimize = optionValue(source, tokens, start, end, "optimize") orelse "<default>";
    return try std.fmt.allocPrint(allocator, "target={s};optimize={s}", .{ target, optimize });
}

fn optionValue(source: []const u8, tokens: []const std.zig.Token, start: usize, end: usize, name: []const u8) ?[]const u8 {
    for (tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !tokenIs(source, token, name) or index + 2 >= end or tokens[index + 1].tag != .equal) continue;
        var value_end = index + 2;
        while (value_end < end and tokens[value_end].tag != .comma) : (value_end += 1) {}
        if (value_end == index + 2) return null;
        return std.mem.trim(u8, source[tokens[index + 2].loc.start..tokens[value_end - 1].loc.end], " \t\r\n");
    }
    return null;
}

fn stringValue(source: []const u8, token: std.zig.Token) ?[]const u8 {
    const literal = source[token.loc.start..token.loc.end];
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    return literal[1 .. literal.len - 1];
}

fn tokenIs(source: []const u8, token: std.zig.Token, expected: []const u8) bool {
    return std.mem.eql(u8, source[token.loc.start..token.loc.end], expected);
}

fn matchingToken(tokens: []const std.zig.Token, opening: usize, opening_tag: std.zig.Token.Tag, closing_tag: std.zig.Token.Tag) ?usize {
    var depth: usize = 0;
    for (tokens[opening..], opening..) |token, index| {
        if (token.tag == opening_tag) depth += 1;
        if (token.tag != closing_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}

test "project findings compose imports tests c imports and build options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.duplicate_c_import)] = .information;
    configuration.levels[@intFromEnum(types.Rule.unreferenced_test_file)] = .information;
    configuration.levels[@intFromEnum(types.Rule.conflicting_build_options)] = .information;
    const files = [_]SourceFile{
        .{ .path = "src/a.zig", .source = "const one = @import(\"../shared.zig\"); const two = @import(\"../src/../shared.zig\"); const c = @cImport({ @cInclude(\"x.h\"); });" },
        .{ .path = "src/b.zig", .source = "const c = @cImport({ @cInclude(\"x.h\"); });" },
        .{ .path = "tests/orphan_test.zig", .source = "test \"orphan\" {}" },
        .{ .path = "build.zig", .source =
        \\const one = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = linux, .optimize = .Debug });
        \\const two = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = windows, .optimize = .Debug });
        },
    };
    const found = try findings(arena.allocator(), &files, configuration);
    try std.testing.expectEqual(@as(usize, 4), found.len);
}

test "test files imported from a test block are referenced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unreferenced_test_file)] = .information;
    const files = [_]SourceFile{
        .{ .path = "src/parser.zig", .source = "test { _ = @import(\"parser_test.zig\"); }" },
        .{ .path = "src/parser_test.zig", .source = "test \"parser\" {}" },
    };
    const found = try findings(arena.allocator(), &files, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .unreferenced_test_file);
}

test "build helpers may enumerate test directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unreferenced_test_file)] = .information;
    const files = [_]SourceFile{
        .{ .path = "build.zig", .source = "pub fn build(b: *Build) void { @import(\"tests/add_cases.zig\").add(b); }" },
        .{ .path = "tests/add_cases.zig", .source = "pub fn add(b: *Build) void { var dir = b.path(\"tests/cases\").openDir(.{ .iterate = true }); var iterator = dir.iterate(); _ = iterator; }" },
        .{ .path = "tests/cases/parser.zig", .source = "test \"parser\" {}" },
    };
    const found = try findings(arena.allocator(), &files, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .unreferenced_test_file);
}

test "project conventions require a strong corpus majority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const files = try allocator.alloc(SourceFile, 20);
    for (files, 0..) |*file, index| {
        const outlier = index == files.len - 1;
        const path = try std.fmt.allocPrint(allocator, "src/file{d}.zig", .{index});
        const source = if (outlier)
            try std.fmt.allocPrintSentinel(allocator, "const db = @import(\"pkg\"); pub fn snake_name(alloc: std.mem.Allocator) !void {{ _ = db; _ = alloc; }}", .{}, 0)
        else
            try std.fmt.allocPrintSentinel(allocator, "const library = @import(\"pkg\"); pub fn camelName{d}(allocator: std.mem.Allocator) Error!void {{ _ = library; _ = allocator; }}", .{index}, 0);
        file.* = .{ .path = path, .source = source };
    }
    var configuration = types.Configuration.defaults();
    const expected_rules = [_]types.Rule{
        .inconsistent_import_alias,
        .minority_naming_style,
        .inconsistent_parameter_vocabulary,
        .inconsistent_error_set_style,
    };
    for (expected_rules) |rule| configuration.levels[@intFromEnum(rule)] = .information;
    const found = try findings(allocator, files, configuration);
    for (expected_rules) |rule| {
        var seen = false;
        for (found) |finding| if (finding.rule == rule) {
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
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.allocation_after_init)] = .information;
    configuration.levels[@intFromEnum(types.Rule.recursive_call)] = .information;
    const files = [_]SourceFile{.{
        .path = "src/service.zig",
        .source = "fn work(allocator: std.mem.Allocator) !void { _ = try allocator.alloc(u8, 1); } fn walk() void { walk(); }",
    }};
    const found = try findings(arena.allocator(), &files, configuration);
    var saw_allocation = false;
    var saw_recursion = false;
    for (found) |finding| switch (finding.rule) {
        .allocation_after_init => saw_allocation = true,
        .recursive_call => saw_recursion = true,
        else => {},
    };
    try std.testing.expect(saw_allocation);
    try std.testing.expect(saw_recursion);
}

test "allocation policy attributes nested function work only to the nested function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.allocation_after_init)] = .information;
    const files = [_]SourceFile{.{
        .path = "src/factory.zig",
        .source = "fn Factory() type { return struct { fn work(allocator: std.mem.Allocator) !void { _ = try allocator.alloc(u8, 1); } }; }",
    }};
    const found = try findings(arena.allocator(), &files, configuration);
    var allocations: usize = 0;
    for (found) |finding| if (finding.rule == .allocation_after_init) {
        allocations += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, "function 'work'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), allocations);
}

test "recursive calls use the runtime body and stay inside nested functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.recursive_call)] = .information;
    const files = [_]SourceFile{.{
        .path = "src/walk.zig",
        .source = "fn walk() error{Stop}!void { return walk(); } fn Factory() type { return struct { fn inner() void { inner(); } }; }",
    }};
    const found = try findings(arena.allocator(), &files, configuration);
    var recursive_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .recursive_call) {
            recursive_count += 1;
            try std.testing.expect(std.mem.indexOf(u8, finding.message, "function 'Factory'") == null);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), recursive_count);
}

test "declared import boundaries reject matching project imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.import_boundaries = &.{.{
        .from = "src/rules",
        .denied = &.{"src/lsp_server.zig"},
    }};
    configuration.levels[@intFromEnum(types.Rule.import_boundary)] = .warning;
    const files = [_]SourceFile{.{
        .path = "src/rules/example.zig",
        .source = "const lsp = @import(\"../lsp_server.zig\");",
    }};
    const found = try findings(arena.allocator(), &files, configuration);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.import_boundary, found[0].rule);
}

test "project summaries expose leaks hidden by cross-file borrowing calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{
        .{ .path = "src/inspect.zig", .source = "pub fn inspect(bytes: []u8) void { _ = bytes.len; }" },
        .{ .path = "src/main.zig", .source = "const inspection = @import(\"inspect.zig\"); fn run(allocator: std.mem.Allocator) !void { const bytes = try allocator.alloc(u8, 4); inspection.inspect(bytes); }" },
    };
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
    try std.testing.expectEqual(@as(usize, 1), found[0].file_index);
}

test "cross-file owned returns retain allocator provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{
        .{ .path = "src/config.zig", .source = "pub fn optionValueAlloc(allocator: std.mem.Allocator) ![]u8 { return allocator.dupe(u8, \"value\"); }" },
        .{ .path = "src/main.zig", .source = "const config = @import(\"config.zig\"); const App = struct { allocator: std.mem.Allocator, fn run(self: *App) !void { const value = try config.optionValueAlloc(self.allocator); defer self.allocator.free(value); } };" },
    };
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .mismatched_allocation_release);
}

test "compiler facts report divergent APIs and unreachable public declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.configuration_divergent_api)] = .warning;
    configuration.levels[@intFromEnum(types.Rule.unreachable_public_declaration)] = .warning;
    const files = [_]SourceFile{.{
        .path = "src/api.zig",
        .source = "pub const Api = struct {}; pub fn detached() void {}",
    }};
    const compiler_facts: CompilerFacts = .{ .roots_complete = true, .units = &.{
        .{
            .root_path = "src/linux.zig",
            .shapes = &.{.{ .name = "shared.Api", .kind = .structure, .fields = &.{"linux"} }},
        },
        .{
            .root_path = "src/windows.zig",
            .shapes = &.{.{ .name = "shared.Api", .kind = .structure, .fields = &.{"windows"} }},
        },
    } };
    const found = try findingsWithCompilerFacts(arena.allocator(), &files, configuration, compiler_facts);
    var saw_divergence = false;
    var saw_unreachable = false;
    for (found) |finding| switch (finding.rule) {
        .configuration_divergent_api => saw_divergence = true,
        .unreachable_public_declaration => saw_unreachable = true,
        else => {},
    };
    try std.testing.expect(saw_divergence);
    try std.testing.expect(saw_unreachable);

    var incomplete_facts = compiler_facts;
    incomplete_facts.roots_complete = false;
    const incomplete = try findingsWithCompilerFacts(arena.allocator(), &files, configuration, incomplete_facts);
    for (incomplete) |finding| try std.testing.expect(finding.rule != .unreachable_public_declaration);
}

test "unresolved named modules keep reachability findings opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unreachable_public_declaration)] = .warning;
    const files = [_]SourceFile{
        .{ .path = "src/main.zig", .source = "const custom = @import(\"custom\"); pub fn run() void { _ = custom; }" },
        .{ .path = "src/detached.zig", .source = "pub fn detached() void {}" },
    };
    const compiler_facts: CompilerFacts = .{
        .roots_complete = true,
        .units = &.{.{ .root_path = "src/main.zig", .shapes = &.{} }},
    };
    const found = try findingsWithCompilerFacts(arena.allocator(), &files, configuration, compiler_facts);
    for (found) |finding| try std.testing.expect(finding.rule != .unreachable_public_declaration);
}
