const std = @import("std");

const generated_source = @import("generated_source.zig");
const types = @import("types.zig");

pub const SourceFile = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: ?[]const std.zig.Token = null,
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
    if (configuration.level(.duplicate_module_import) == .off and
        configuration.level(.duplicate_c_import) == .off and
        configuration.level(.unreferenced_test_file) == .off and
        configuration.level(.conflicting_build_options) == .off and
        configuration.level(.inconsistent_import_alias) == .off and
        configuration.level(.minority_naming_style) == .off and
        configuration.level(.inconsistent_parameter_vocabulary) == .off and
        configuration.level(.inconsistent_error_set_style) == .off and
        configuration.level(.allocation_after_init) == .off and
        configuration.level(.recursive_call) == .off) return &.{};
    const indexed_files = try allocator.alloc(IndexedSourceFile, files.len);
    for (files, indexed_files) |file, *indexed_file| indexed_file.* = .{
        .path = file.path,
        .source = file.source,
        .tokens = file.tokens orelse try tokenize(allocator, file.source),
    };
    var found: std.ArrayList(Finding) = .empty;
    const imports = if (configuration.level(.duplicate_module_import) != .off or
        configuration.level(.unreferenced_test_file) != .off or
        configuration.level(.inconsistent_import_alias) != .off)
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
    std.mem.sort(Finding, found.items, {}, struct {
        fn lessThan(_: void, left: Finding, right: Finding) bool {
            if (left.file_index != right.file_index) return left.file_index < right.file_index;
            if (left.span.start != right.span.start) return left.span.start < right.span.start;
            return @intFromEnum(left.rule) < @intFromEnum(right.rule);
        }
    }.lessThan);
    return try found.toOwnedSlice(allocator);
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
    for (files, 0..) |file, file_index| {
        if (!looksLikeTestPath(file.path) or !containsTestDeclaration(file.tokens)) continue;
        var referenced = false;
        for (imports) |import| {
            if (import.file_index != file_index and std.mem.eql(u8, import.resolved_path, file.path)) {
                referenced = true;
                break;
            }
        }
        if (!referenced) for (files, 0..) |build_file, build_index| {
            if (build_index == file_index or !std.mem.eql(u8, std.fs.path.basename(build_file.path), "build.zig")) continue;
            if (sourceMentionsPath(build_file.source, file.path)) {
                referenced = true;
                break;
            }
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
            if (token.tag != .keyword_fn or foreignDeclaration(file.tokens, fn_index)) continue;
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
            if (token.tag != .keyword_fn or fn_index + 1 >= file.tokens.len or file.tokens[fn_index + 1].tag != .identifier) continue;
            const function_name = tokenText(file.source, file.tokens[fn_index + 1]);
            if (isInitializationName(function_name)) continue;
            const opening = nextTagBefore(file.tokens, fn_index + 2, .l_brace, .semicolon) orelse continue;
            const closing = matchingToken(file.tokens, opening, .l_brace, .r_brace) orelse continue;
            for (file.tokens[opening + 1 .. closing], opening + 1..) |body_token, index| {
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
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    body_start: usize,
    body_end: usize,
    inline_fn: bool,
};

fn findRecursiveCalls(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.recursive_call) == .off) return;
    var declarations: std.ArrayList(FunctionDeclaration) = .empty;
    for (files, 0..) |file, file_index| {
        if (generated_source.isTranslateCOutput(file.source)) continue;
        for (file.tokens, 0..) |token, fn_index| {
            if (token.tag != .keyword_fn or fn_index + 1 >= file.tokens.len or file.tokens[fn_index + 1].tag != .identifier) continue;
            const opening = nextTagBefore(file.tokens, fn_index + 2, .l_brace, .semicolon) orelse continue;
            const closing = matchingToken(file.tokens, opening, .l_brace, .r_brace) orelse continue;
            try declarations.append(allocator, .{
                .file_index = file_index,
                .name = tokenText(file.source, file.tokens[fn_index + 1]),
                .span = file.tokens[fn_index + 1].loc,
                .source = file.source,
                .tokens = file.tokens,
                .body_start = opening + 1,
                .body_end = closing,
                .inline_fn = fn_index > 0 and file.tokens[fn_index - 1].tag == .keyword_inline,
            });
        }
    }
    for (declarations.items, 0..) |declaration, index| {
        if (declaration.inline_fn or !callsFunction(declaration, declaration.name)) continue;
        try found.append(allocator, .{
            .file_index = declaration.file_index,
            .rule = .recursive_call,
            .span = declaration.span,
            .message = try std.fmt.allocPrint(allocator, "function '{s}' calls itself recursively; use an explicitly bounded worklist", .{declaration.name}),
        });
        _ = index;
    }
    for (declarations.items, 0..) |left, left_index| {
        if (left.inline_fn) continue;
        for (declarations.items[left_index + 1 ..]) |right| {
            if (right.inline_fn or !callsFunction(left, right.name) or !callsFunction(right, left.name)) continue;
            try found.append(allocator, .{
                .file_index = right.file_index,
                .rule = .recursive_call,
                .span = right.span,
                .message = try std.fmt.allocPrint(allocator, "mutual recursion cycle '{s} -> {s} -> {s}' has input-controlled stack depth", .{ left.name, right.name, left.name }),
            });
        }
    }
}

fn callsFunction(declaration: FunctionDeclaration, name: []const u8) bool {
    for (declaration.tokens[declaration.body_start..declaration.body_end], declaration.body_start..) |token, index| {
        if (token.tag == .identifier and tokenIs(declaration.source, token, name) and index + 1 < declaration.body_end and declaration.tokens[index + 1].tag == .l_paren and
            (index == declaration.body_start or declaration.tokens[index - 1].tag != .period)) return true;
    }
    return false;
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
