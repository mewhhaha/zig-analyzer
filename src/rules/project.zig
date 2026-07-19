const std = @import("std");

const syntax_scope = @import("../syntax_scope.zig");
const allocation_lifecycle = @import("allocation_lifecycle.zig");
const generated_source = @import("generated_source.zig");
const missing_errdefer = @import("missing_errdefer.zig");
const owned_call = @import("owned_call.zig");
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
    if (!enabled(configuration)) return &.{};
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

fn enabled(configuration: types.Configuration) bool {
    return !(configuration.level(.duplicate_module_import) == .off and
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
        configuration.level(.missing_errdefer) == .off and
        configuration.level(.discarded_read_count) == .off and
        configuration.level(.discarded_write_count) == .off and
        configuration.level(.invalidated_element_pointer) == .off and
        configuration.level(.invalidated_container_view) == .off and
        configuration.level(.iterator_invalidated_during_loop) == .off and
        configuration.level(.local_storage_escape) == .off and
        configuration.level(.incomplete_owned_field_cleanup) == .off and
        !allocation_lifecycle.enabled(configuration));
}

fn findSummaryLifecycleDifferences(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (!allocation_lifecycle.enabled(configuration) and configuration.level(.missing_errdefer) == .off and
        configuration.level(.discarded_read_count) == .off and configuration.level(.discarded_write_count) == .off and
        configuration.level(.invalidated_element_pointer) == .off and configuration.level(.invalidated_container_view) == .off and
        configuration.level(.iterator_invalidated_during_loop) == .off and
        configuration.level(.local_storage_escape) == .off and configuration.level(.incomplete_owned_field_cleanup) == .off) return;
    const sources = try allocator.alloc(summaries.Source, files.len);
    for (files, sources, 0..) |file, *source, file_index| source.* = .{
        .file_index = file_index,
        .path = file.path,
        .source = file.source,
        .tokens = file.tokens,
    };
    var summary_index = try summaries.build(allocator, sources, configuration);
    defer summary_index.deinit(allocator);

    try findIncompleteOwnedFieldCleanup(allocator, files, configuration, summary_index, found);

    for (files, 0..) |file, file_index| {
        if (configuration.level(.missing_errdefer) != .off) {
            var summary_findings: std.ArrayList(types.Finding) = .empty;
            try missing_errdefer.runWithSummaries(.{
                .allocator = allocator,
                .source = file.source,
                .tokens = file.tokens,
                .configuration = configuration,
                .findings = &summary_findings,
            }, summary_index);
            for (summary_findings.items) |finding| try found.append(allocator, .{
                .file_index = file_index,
                .rule = finding.rule,
                .span = finding.span,
                .message = finding.message,
            });
        }
        try findDiscardedSummaryIo(allocator, file, file_index, configuration, summary_index, found);
        try findBorrowedReturnInvalidations(allocator, file, file_index, configuration, summary_index, found);
        try findSummaryContainerInvalidations(allocator, file, file_index, configuration, summary_index, found);
        try findEscapingLocalStorage(allocator, file, file_index, configuration, summary_index, found);
        if (!allocation_lifecycle.enabled(configuration)) continue;
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

const PathRange = struct { start: usize, end: usize };

fn findSummaryContainerInvalidations(
    allocator: std.mem.Allocator,
    file: IndexedSourceFile,
    file_index: usize,
    configuration: types.Configuration,
    summary_index: summaries.Index,
    found: *std.ArrayList(Finding),
) !void {
    const pointer_level = configuration.level(.invalidated_element_pointer);
    const iterator_level = configuration.level(.iterator_invalidated_during_loop);
    if (pointer_level == .off and iterator_level == .off) return;

    for (file.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = statementEnd(file.tokens, declaration_index) orelse continue;
        const scope_end = enclosingScopeEnd(file.tokens, declaration_index) orelse continue;
        const binding = tokenText(file.source, file.tokens[declaration_index + 1]);

        if (pointer_level != .off) {
            if (borrowedElementPath(file, declaration_index + 2, declaration_end)) |path| {
                if (firstSummarizedMutation(file, summary_index, path, declaration_end + 1, scope_end)) |mutation| {
                    if (bindingUsedAfter(file, binding, mutation.method_index + 1, scope_end)) {
                        try found.append(allocator, .{
                            .file_index = file_index,
                            .rule = .invalidated_element_pointer,
                            .span = file.tokens[declaration_index + 1].loc,
                            .message = try std.fmt.allocPrint(
                                allocator,
                                "pointer '{s}' is used after helper '{s}' mutates its backing container",
                                .{ binding, mutation.method },
                            ),
                        });
                    }
                }
            }
        }

        if (iterator_level == .off) continue;
        const iterated_path = iteratorReceiverPath(file, declaration_index + 2, declaration_end) orelse continue;
        const mutation = firstSummarizedMutation(file, summary_index, iterated_path, declaration_end + 1, scope_end) orelse continue;
        if (!iteratorActiveAt(file, binding, mutation.method_index, declaration_end + 1, scope_end)) continue;
        try found.append(allocator, .{
            .file_index = file_index,
            .rule = .iterator_invalidated_during_loop,
            .span = file.tokens[mutation.method_index].loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "helper '{s}' mutates the map while iterator '{s}' is active",
                .{ mutation.method, binding },
            ),
        });
    }
}

fn borrowedElementPath(file: IndexedSourceFile, start: usize, end: usize) ?PathRange {
    for (file.tokens[start..end], start..) |token, address_index| {
        if (token.tag != .ampersand or address_index + 3 >= end) continue;
        var items_index = address_index + 1;
        while (items_index + 1 < end) : (items_index += 1) {
            if (tokenIs(file.source, file.tokens[items_index], "items") and
                file.tokens[items_index - 1].tag == .period and file.tokens[items_index + 1].tag == .l_bracket)
            {
                return .{ .start = address_index + 1, .end = items_index - 2 };
            }
        }
    }
    return null;
}

fn iteratorReceiverPath(file: IndexedSourceFile, start: usize, end: usize) ?PathRange {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (!tokenIs(file.source, token, "iterator") or method_index < start + 2 or
            file.tokens[method_index - 1].tag != .period or method_index + 1 >= end or
            file.tokens[method_index + 1].tag != .l_paren) continue;
        var path_start = method_index - 2;
        while (path_start >= start + 2 and file.tokens[path_start - 1].tag == .period and
            file.tokens[path_start - 2].tag == .identifier) path_start -= 2;
        return .{ .start = path_start, .end = method_index - 2 };
    }
    return null;
}

const SummaryMutation = struct { method_index: usize, method: []const u8 };

fn firstSummarizedMutation(
    file: IndexedSourceFile,
    summary_index: summaries.Index,
    expected_path: PathRange,
    start: usize,
    end: usize,
) ?SummaryMutation {
    for (file.tokens[start..end], start..) |token, opening| {
        if (token.tag != .l_paren or opening == 0 or file.tokens[opening - 1].tag != .identifier or
            (opening >= 2 and file.tokens[opening - 2].tag == .period)) continue;
        const closing = matchingToken(file.tokens, opening, .l_paren, .r_paren) orelse continue;
        if (closing >= end) continue;
        const method = tokenText(file.source, file.tokens[opening - 1]);
        const mutation = summary_index.containerMutationCall(file.source, null, method) orelse continue;
        const argument = callArgumentRange(file.tokens, opening + 1, closing, mutation.parameter) orelse continue;
        if (!mutationArgumentMatchesPath(file, argument, mutation.field, expected_path)) continue;
        return .{ .method_index = opening - 1, .method = method };
    }
    return null;
}

fn callArgumentRange(tokens: []const std.zig.Token, start: usize, end: usize, wanted: usize) ?PathRange {
    var parameter: usize = 0;
    var argument_start = start;
    var depth: usize = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const at_end = index == end;
        if (!at_end) switch (tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (tokens[index].tag != .comma or depth != 0)) continue;
        if (parameter == wanted) return .{ .start = argument_start, .end = index - 1 };
        parameter += 1;
        argument_start = index + 1;
    }
    return null;
}

fn mutationArgumentMatchesPath(
    file: IndexedSourceFile,
    argument: PathRange,
    field: []const u8,
    expected: PathRange,
) bool {
    var argument_start = argument.start;
    if (argument_start <= argument.end and file.tokens[argument_start].tag == .ampersand) argument_start += 1;
    const argument_count = if (argument_start <= argument.end) argument.end - argument_start + 1 else 0;
    const expected_count = expected.end - expected.start + 1;
    const field_tokens: usize = if (field.len == 0) 0 else 2;
    if (argument_count + field_tokens != expected_count) return false;
    for (0..argument_count) |offset| {
        if (!std.mem.eql(
            u8,
            tokenText(file.source, file.tokens[argument_start + offset]),
            tokenText(file.source, file.tokens[expected.start + offset]),
        )) return false;
    }
    if (field.len == 0) return true;
    return file.tokens[expected.start + argument_count].tag == .period and
        tokenIs(file.source, file.tokens[expected.start + argument_count + 1], field);
}

fn iteratorActiveAt(file: IndexedSourceFile, iterator: []const u8, mutation: usize, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, while_index| {
        if (token.tag != .keyword_while or while_index >= mutation) continue;
        var body_start = while_index + 1;
        while (body_start < mutation and file.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= mutation) continue;
        const body_end = matchingToken(file.tokens, body_start, .l_brace, .r_brace) orelse continue;
        if (mutation >= body_end) continue;
        var index = while_index + 1;
        while (index + 3 < body_start) : (index += 1) {
            if (tokenIs(file.source, file.tokens[index], iterator) and file.tokens[index + 1].tag == .period and
                tokenIs(file.source, file.tokens[index + 2], "next") and file.tokens[index + 3].tag == .l_paren) return true;
        }
    }
    return false;
}

const Call = struct {
    opening: usize,
    closing: usize,
    name_index: usize,
    receiver_index: ?usize,
};

fn findDiscardedSummaryIo(
    allocator: std.mem.Allocator,
    file: IndexedSourceFile,
    file_index: usize,
    configuration: types.Configuration,
    summary_index: summaries.Index,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.discarded_read_count) == .off and configuration.level(.discarded_write_count) == .off) return;
    for (file.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or file.tokens[equal_index - 1].tag != .identifier or
            !tokenIs(file.source, file.tokens[equal_index - 1], "_")) continue;
        const statement_end = statementEnd(file.tokens, equal_index) orelse continue;
        const call = outerCall(file.tokens, equal_index + 1, statement_end) orelse continue;
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
        const partial_io = summary_index.partialIoReturnCall(file.source, receiver, name);
        if (partial_io == .none or directPartialIoMethod(name)) continue;
        const rule: types.Rule = if (partial_io == .read) .discarded_read_count else .discarded_write_count;
        const level = configuration.level(rule);
        if (level == .off) continue;
        try found.append(allocator, .{
            .file_index = file_index,
            .rule = rule,
            .span = file.tokens[call.name_index].loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "discarding {s}'s summarized partial-{s} count loses how much data was transferred",
                .{ name, if (partial_io == .read) "read" else "write" },
            ),
        });
    }
}

fn directPartialIoMethod(name: []const u8) bool {
    const methods = [_][]const u8{ "read", "readVec", "readSliceShort", "pread", "readv", "preadv", "write" };
    for (methods) |method| if (std.mem.eql(u8, name, method)) return true;
    return false;
}

fn findBorrowedReturnInvalidations(
    allocator: std.mem.Allocator,
    file: IndexedSourceFile,
    file_index: usize,
    configuration: types.Configuration,
    summary_index: summaries.Index,
    found: *std.ArrayList(Finding),
) !void {
    for (file.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = statementEnd(file.tokens, declaration_index) orelse continue;
        const equal_index = findTokenTag(file.tokens, declaration_index + 2, declaration_end, .equal) orelse continue;
        const call = firstCall(file.tokens, equal_index + 1, declaration_end) orelse continue;
        const receiver_index = call.receiver_index orelse continue;
        const receiver = tokenText(file.source, file.tokens[receiver_index]);
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const borrowed = summary_index.borrowedReturnCall(file.source, receiver, name) orelse continue;
        if (borrowed.parameter != 0) continue;
        const scope_end = enclosingScopeEnd(file.tokens, declaration_index) orelse continue;
        const invalidation = firstBorrowInvalidation(
            file,
            summary_index,
            receiver,
            borrowed.field,
            declaration_end + 1,
            scope_end,
        ) orelse continue;
        const binding = tokenText(file.source, file.tokens[declaration_index + 1]);
        if (!bindingUsedAfter(file, binding, invalidation.method_index + 1, scope_end)) continue;
        const rule: types.Rule = if (borrowed.kind == .pointer) .invalidated_element_pointer else .invalidated_container_view;
        const level = configuration.level(rule);
        if (level == .off) continue;
        try found.append(allocator, .{
            .file_index = file_index,
            .rule = rule,
            .span = file.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "{s} '{s}' returned by {s} borrows from '{s}{s}{s}' and is used after {s}",
                .{
                    if (borrowed.kind == .pointer) "pointer" else "view",
                    binding,
                    name,
                    receiver,
                    if (borrowed.field.len == 0) "" else ".",
                    borrowed.field,
                    invalidation.method,
                },
            ),
        });
    }
}

const BorrowInvalidation = struct { method_index: usize, method: []const u8 };

fn firstBorrowInvalidation(
    file: IndexedSourceFile,
    summary_index: summaries.Index,
    receiver: []const u8,
    field: []const u8,
    start: usize,
    end: usize,
) ?BorrowInvalidation {
    const methods = [_][]const u8{
        "append",
        "appendSlice",
        "insert",
        "resize",
        "ensureTotalCapacity",
        "ensureUnusedCapacity",
        "addOne",
        "addManyAsArray",
        "orderedRemove",
        "swapRemove",
        "clearAndFree",
        "clearRetainingCapacity",
    };
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], receiver)) continue;
        var method_index = index + 2;
        if (file.tokens[index + 1].tag != .period) continue;
        const direct_field_mutation = field.len != 0 and index + 5 < end and
            tokenIs(file.source, file.tokens[index + 2], field) and file.tokens[index + 3].tag == .period;
        if (direct_field_mutation) {
            method_index = index + 4;
        }
        if (file.tokens[method_index].tag != .identifier or method_index + 1 >= end or
            file.tokens[method_index + 1].tag != .l_paren) continue;
        const method = tokenText(file.source, file.tokens[method_index]);
        if (field.len == 0 or direct_field_mutation) {
            for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) {
                return .{ .method_index = method_index, .method = method };
            };
        }
        if (method_index != index + 2) continue;
        const mutation = summary_index.containerMutationCall(file.source, receiver, method) orelse continue;
        if (mutation.parameter == 0 and std.mem.eql(u8, mutation.field, field)) {
            return .{ .method_index = method_index, .method = method };
        }
    }
    return null;
}

fn bindingUsedAfter(file: IndexedSourceFile, binding: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !tokenIs(file.source, token, binding) or
            (index > 0 and file.tokens[index - 1].tag == .period)) continue;
        if (index + 1 < end and file.tokens[index + 1].tag == .equal) return false;
        return true;
    }
    return false;
}

fn findEscapingLocalStorage(
    allocator: std.mem.Allocator,
    file: IndexedSourceFile,
    file_index: usize,
    configuration: types.Configuration,
    summary_index: summaries.Index,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.local_storage_escape);
    if (level == .off) return;
    for (file.tokens, 0..) |token, array_declaration| {
        if (token.tag != .keyword_var or array_declaration + 5 >= file.tokens.len or
            file.tokens[array_declaration + 1].tag != .identifier or file.tokens[array_declaration + 2].tag != .colon or
            file.tokens[array_declaration + 3].tag != .l_bracket or file.tokens[array_declaration + 4].tag != .number_literal or
            file.tokens[array_declaration + 5].tag != .r_bracket) continue;
        const array_end = statementEnd(file.tokens, array_declaration) orelse continue;
        const scope_end = enclosingScopeEnd(file.tokens, array_declaration) orelse continue;
        const array_name = tokenText(file.source, file.tokens[array_declaration + 1]);
        for (file.tokens[array_end + 1 .. scope_end], array_end + 1..) |candidate, alias_declaration| {
            if ((candidate.tag != .keyword_const and candidate.tag != .keyword_var) or
                alias_declaration + 3 >= scope_end or file.tokens[alias_declaration + 1].tag != .identifier) continue;
            const alias_end = statementEnd(file.tokens, alias_declaration) orelse continue;
            if (!rangeBorrowsArray(file, array_name, alias_declaration + 2, alias_end)) continue;
            const alias = tokenText(file.source, file.tokens[alias_declaration + 1]);
            const escaped = escapingCallResult(file, summary_index, alias, alias_end + 1, scope_end) orelse continue;
            if (!bindingRetained(file, escaped.binding, escaped.declaration_end + 1, scope_end)) continue;
            try found.append(allocator, .{
                .file_index = file_index,
                .rule = .local_storage_escape,
                .span = file.tokens[escaped.argument_index].loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "'{s}' aliases local array '{s}' and is retained by {s} beyond that storage's safe lifetime",
                    .{ alias, array_name, escaped.callable },
                ),
            });
        }
    }
}

fn rangeBorrowsArray(file: IndexedSourceFile, name: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag == .ampersand and index + 1 < end and tokenIs(file.source, file.tokens[index + 1], name)) return true;
        if (token.tag != .identifier or !tokenIs(file.source, token, name) or index + 1 >= end or
            file.tokens[index + 1].tag != .l_bracket) continue;
        const closing = matchingToken(file.tokens, index + 1, .l_bracket, .r_bracket) orelse continue;
        if (closing > end) continue;
        for (file.tokens[index + 2 .. closing]) |slice_token| if (slice_token.tag == .ellipsis2) return true;
    }
    return false;
}

const EscapingCall = struct {
    binding: []const u8,
    declaration_end: usize,
    argument_index: usize,
    callable: []const u8,
};

fn escapingCallResult(
    file: IndexedSourceFile,
    summary_index: summaries.Index,
    alias: []const u8,
    start: usize,
    end: usize,
) ?EscapingCall {
    for (file.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= end or
            file.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = statementEnd(file.tokens, declaration_index) orelse continue;
        const equal_index = findTokenTag(file.tokens, declaration_index + 2, declaration_end, .equal) orelse continue;
        const call = firstCall(file.tokens, equal_index + 1, declaration_end) orelse continue;
        const argument = exactArgument(file, call, alias) orelse continue;
        const callable_start = call.receiver_index orelse call.name_index;
        const callable = file.source[file.tokens[callable_start].loc.start..file.tokens[call.name_index].loc.end];
        if (!summary_index.parameterEscapesForCall(file.source, callable, argument.parameter)) continue;
        return .{
            .binding = tokenText(file.source, file.tokens[declaration_index + 1]),
            .declaration_end = declaration_end,
            .argument_index = argument.token_index,
            .callable = callable,
        };
    }
    return null;
}

const Argument = struct { parameter: usize, token_index: usize };

fn exactArgument(file: IndexedSourceFile, call: Call, name: []const u8) ?Argument {
    var parameter: usize = 0;
    var argument_start = call.opening + 1;
    var depth: usize = 0;
    var index = argument_start;
    while (index <= call.closing) : (index += 1) {
        const at_end = index == call.closing;
        const tag = file.tokens[index].tag;
        if (!at_end) switch (tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (tag != .comma or depth != 0)) continue;
        if (argument_start + 1 == index and file.tokens[argument_start].tag == .identifier and
            tokenIs(file.source, file.tokens[argument_start], name)) return .{ .parameter = parameter, .token_index = argument_start };
        parameter += 1;
        argument_start = index + 1;
    }
    return null;
}

fn bindingRetained(file: IndexedSourceFile, binding: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_return) {
            const return_end = statementEnd(file.tokens, index) orelse continue;
            if (rangeRefersToBinding(file, binding, index + 1, @min(return_end, end))) return true;
        }
        if (token.tag != .l_paren or index == 0 or file.tokens[index - 1].tag != .identifier) continue;
        const method = tokenText(file.source, file.tokens[index - 1]);
        if (!std.mem.eql(u8, method, "append") and !std.mem.eql(u8, method, "put") and
            !std.mem.eql(u8, method, "insert")) continue;
        const closing = matchingToken(file.tokens, index, .l_paren, .r_paren) orelse continue;
        if (closing >= end) continue;
        if (rangeRefersToBinding(file, binding, index + 1, closing)) return true;
    }
    return false;
}

fn rangeRefersToBinding(file: IndexedSourceFile, name: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and tokenIs(file.source, token, name) and
            (index == 0 or file.tokens[index - 1].tag != .period)) return true;
    }
    return false;
}

fn firstCall(tokens: []const std.zig.Token, start: usize, end: usize) ?Call {
    for (tokens[start..end], start..) |token, opening| {
        if (token.tag != .l_paren or opening == 0 or tokens[opening - 1].tag != .identifier) continue;
        const closing = matchingToken(tokens, opening, .l_paren, .r_paren) orelse continue;
        if (closing > end) continue;
        return .{
            .opening = opening,
            .closing = closing,
            .name_index = opening - 1,
            .receiver_index = if (opening >= 3 and tokens[opening - 2].tag == .period and
                tokens[opening - 3].tag == .identifier) opening - 3 else null,
        };
    }
    return null;
}

fn outerCall(tokens: []const std.zig.Token, start: usize, end: usize) ?Call {
    const call = firstCall(tokens, start, end) orelse return null;
    return if (call.closing + 1 == end) call else null;
}

fn findTokenTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    for (tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

fn statementEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[start..], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => {
                if (brace_depth == 0) return null;
                brace_depth -= 1;
            },
            .semicolon => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index,
            else => {},
        }
    }
    return null;
}

fn enclosingScopeEnd(tokens: []const std.zig.Token, index: usize) ?usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => depth += 1,
            .l_brace => {
                if (depth == 0) return matchingToken(tokens, cursor, .l_brace, .r_brace);
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
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

const OwnedFieldEvidence = struct {
    file_index: usize,
    type_name: []const u8,
    field_name: []const u8,
    span: std.zig.Token.Loc,
};

const OwnedBinding = struct {
    name: []const u8,
};

fn findIncompleteOwnedFieldCleanup(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    summary_index: summaries.Index,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.incomplete_owned_field_cleanup);
    if (level == .off and configuration.level(.unreleased_allocation) == .off and
        configuration.level(.overwritten_owning_value) == .off) return;
    var evidence: std.ArrayList(OwnedFieldEvidence) = .empty;
    for (files, 0..) |file, file_index| {
        try collectOwnedFieldEvidence(allocator, file, file_index, summary_index, &evidence);
    }
    try findIncompleteOwnedElementCleanup(allocator, files, configuration, evidence.items, found);
    try findDroppedOwnedElements(allocator, files, configuration, evidence.items, found);
    try findOwnedElementOverwrites(allocator, files, configuration, summary_index, evidence.items, found);
    try findAliasedOwnedElementOverwrites(allocator, files, configuration, summary_index, evidence.items, found);
    if (level == .off) return;
    for (files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, declaration_index| {
            if (token.tag != .keyword_const or declaration_index + 4 >= file.tokens.len or
                file.tokens[declaration_index + 1].tag != .identifier or file.tokens[declaration_index + 2].tag != .equal or
                file.tokens[declaration_index + 3].tag != .keyword_struct or file.tokens[declaration_index + 4].tag != .l_brace) continue;
            const type_name = tokenText(file.source, file.tokens[declaration_index + 1]);
            var owned_count: usize = 0;
            for (evidence.items) |field| if (field.file_index == file_index and std.mem.eql(u8, field.type_name, type_name)) {
                owned_count += 1;
            };
            if (owned_count < 2) continue;
            const container_end = matchingToken(file.tokens, declaration_index + 4, .l_brace, .r_brace) orelse continue;
            const cleanup = cleanupMethod(file, declaration_index + 5, container_end) orelse continue;
            var released_count: usize = 0;
            for (evidence.items) |field| {
                if (field.file_index != file_index or !std.mem.eql(u8, field.type_name, type_name)) continue;
                if (fieldReleased(file, cleanup, field.field_name)) released_count += 1;
            }
            if (released_count == 0 or released_count == owned_count) continue;
            for (evidence.items) |field| {
                if (field.file_index != file_index or !std.mem.eql(u8, field.type_name, type_name) or
                    fieldReleased(file, cleanup, field.field_name)) continue;
                try found.append(allocator, .{
                    .file_index = file_index,
                    .rule = .incomplete_owned_field_cleanup,
                    .span = field.span,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "cleanup for '{s}' releases {d} of {d} proven owned fields but omits '{s}'",
                        .{ type_name, released_count, owned_count, field.field_name },
                    ),
                });
            }
        }
    }
}

fn collectOwnedFieldEvidence(
    allocator: std.mem.Allocator,
    file: IndexedSourceFile,
    file_index: usize,
    summary_index: summaries.Index,
    evidence: *std.ArrayList(OwnedFieldEvidence),
) !void {
    for (file.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 2 >= file.tokens.len or file.tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(file.tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
        const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const body_end = matchingToken(file.tokens, body_start, .l_brace, .r_brace) orelse continue;
        var owned_bindings: std.ArrayList(OwnedBinding) = .empty;
        for (file.tokens[body_start + 1 .. body_end], body_start + 1..) |candidate, declaration_index| {
            if ((candidate.tag != .keyword_const and candidate.tag != .keyword_var) or declaration_index + 3 >= body_end or
                file.tokens[declaration_index + 1].tag != .identifier) continue;
            const declaration_end = statementEnd(file.tokens, declaration_index) orelse continue;
            const equal_index = findTokenTag(file.tokens, declaration_index + 2, declaration_end, .equal) orelse continue;
            const call = firstCall(file.tokens, equal_index + 1, declaration_end) orelse continue;
            const name = tokenText(file.source, file.tokens[call.name_index]);
            const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
            if (!callReturnsOwned(file.source, summary_index, receiver, name)) continue;
            try owned_bindings.append(allocator, .{ .name = tokenText(file.source, file.tokens[declaration_index + 1]) });
        }
        if (owned_bindings.items.len == 0) continue;
        if (functionReturnType(file, parameters_end + 1, body_start)) |type_name| {
            for (file.tokens[body_start + 1 .. body_end], body_start + 1..) |candidate, return_index| {
                if (candidate.tag != .keyword_return) continue;
                const return_end = statementEnd(file.tokens, return_index) orelse continue;
                try collectAggregateOwnedFields(
                    allocator,
                    file,
                    file_index,
                    type_name,
                    return_index + 1,
                    return_end,
                    owned_bindings.items,
                    evidence,
                );
            }
        }
        for (file.tokens[body_start + 1 .. body_end], body_start + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or
                (!tokenIs(file.source, candidate, "append") and !tokenIs(file.source, candidate, "appendAssumeCapacity")) or
                method_index < 2 or file.tokens[method_index - 1].tag != .period or
                file.tokens[method_index - 2].tag != .identifier or method_index + 1 >= body_end or
                file.tokens[method_index + 1].tag != .l_paren) continue;
            const element_type = sequenceElementType(file, tokenText(file.source, file.tokens[method_index - 2])) orelse continue;
            const call_end = matchingToken(file.tokens, method_index + 1, .l_paren, .r_paren) orelse continue;
            try collectAggregateOwnedFields(
                allocator,
                file,
                file_index,
                element_type,
                method_index + 2,
                call_end,
                owned_bindings.items,
                evidence,
            );
        }
    }
}

fn collectAggregateOwnedFields(
    allocator: std.mem.Allocator,
    file: IndexedSourceFile,
    file_index: usize,
    type_name: []const u8,
    start: usize,
    end: usize,
    owned_bindings: []const OwnedBinding,
    evidence: *std.ArrayList(OwnedFieldEvidence),
) !void {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (file.tokens[index].tag != .period or file.tokens[index + 1].tag != .identifier or
            file.tokens[index + 2].tag != .equal or file.tokens[index + 3].tag != .identifier) continue;
        const binding = tokenText(file.source, file.tokens[index + 3]);
        var owned = false;
        for (owned_bindings) |known| if (std.mem.eql(u8, known.name, binding)) {
            owned = true;
        };
        if (!owned) continue;
        if (aggregateBindingFieldCount(file, binding, start, end) != 1) continue;
        const field_name = tokenText(file.source, file.tokens[index + 1]);
        var duplicate = false;
        for (evidence.items) |known| if (known.file_index == file_index and
            std.mem.eql(u8, known.type_name, type_name) and std.mem.eql(u8, known.field_name, field_name))
        {
            duplicate = true;
        };
        if (!duplicate) try evidence.append(allocator, .{
            .file_index = file_index,
            .type_name = type_name,
            .field_name = field_name,
            .span = file.tokens[index + 1].loc,
        });
    }
}

fn aggregateBindingFieldCount(file: IndexedSourceFile, binding: []const u8, start: usize, end: usize) usize {
    var count: usize = 0;
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (file.tokens[index].tag == .period and file.tokens[index + 1].tag == .identifier and
            file.tokens[index + 2].tag == .equal and tokenIs(file.source, file.tokens[index + 3], binding)) count += 1;
    }
    return count;
}

fn sequenceElementType(file: IndexedSourceFile, field_name: []const u8) ?[]const u8 {
    var selected: ?[]const u8 = null;
    for (file.tokens, 0..) |token, field_index| {
        if (token.tag != .identifier or !tokenIs(file.source, token, field_name) or
            field_index + 4 >= file.tokens.len or file.tokens[field_index + 1].tag != .colon) continue;
        const field_end = fieldTypeEnd(file.tokens, field_index + 2);
        for (file.tokens[field_index + 2 .. field_end], field_index + 2..) |candidate, type_index| {
            if (candidate.tag != .identifier or
                (!tokenIs(file.source, candidate, "ArrayList") and !tokenIs(file.source, candidate, "ArrayListUnmanaged")) or
                type_index + 2 >= field_end or file.tokens[type_index + 1].tag != .l_paren or
                file.tokens[type_index + 2].tag != .identifier) continue;
            const element_type = tokenText(file.source, file.tokens[type_index + 2]);
            if (selected) |known| {
                if (!std.mem.eql(u8, known, element_type)) return null;
            } else {
                selected = element_type;
            }
        }
    }
    return selected;
}

fn fieldTypeEnd(tokens: []const std.zig.Token, start: usize) usize {
    var depth: usize = 0;
    var index = start;
    while (index < tokens.len) : (index += 1) switch (tokens[index].tag) {
        .l_paren, .l_bracket => depth += 1,
        .r_paren, .r_bracket => depth -|= 1,
        .comma, .equal => if (depth == 0) return index,
        .l_brace, .r_brace, .semicolon => if (depth == 0) return index,
        else => {},
    };
    return tokens.len;
}

fn findIncompleteOwnedElementCleanup(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    evidence: []const OwnedFieldEvidence,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.incomplete_owned_field_cleanup);
    if (level == .off) return;
    for (files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, declaration_index| {
            if (token.tag != .keyword_const or declaration_index + 4 >= file.tokens.len or
                file.tokens[declaration_index + 1].tag != .identifier or file.tokens[declaration_index + 2].tag != .equal or
                file.tokens[declaration_index + 3].tag != .keyword_struct or file.tokens[declaration_index + 4].tag != .l_brace) continue;
            const container_end = matchingToken(file.tokens, declaration_index + 4, .l_brace, .r_brace) orelse continue;
            for (file.tokens[declaration_index + 5 .. container_end], declaration_index + 5..) |field_token, field_index| {
                if (field_token.tag != .identifier or field_index + 1 >= container_end or
                    file.tokens[field_index + 1].tag != .colon) continue;
                const sequence_field = tokenText(file.source, field_token);
                const element_type = sequenceElementType(file, sequence_field) orelse continue;
                if (!hasOwnedFieldEvidence(evidence, file_index, element_type)) continue;
                try findSequenceCleanupOmissions(
                    allocator,
                    file,
                    file_index,
                    declaration_index + 5,
                    container_end,
                    sequence_field,
                    element_type,
                    evidence,
                    found,
                );
            }
        }
    }
}

fn findSequenceCleanupOmissions(
    allocator: std.mem.Allocator,
    file: IndexedSourceFile,
    file_index: usize,
    container_start: usize,
    container_end: usize,
    sequence_field: []const u8,
    element_type: []const u8,
    evidence: []const OwnedFieldEvidence,
    found: *std.ArrayList(Finding),
) !void {
    for (file.tokens[container_start..container_end], container_start..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 2 >= container_end or file.tokens[fn_index + 1].tag != .identifier or
            file.tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(file.tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
        const receiver = firstParameterName(file, fn_index + 3, parameters_end) orelse continue;
        const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const body_end = matchingToken(file.tokens, body_start, .l_brace, .r_brace) orelse continue;
        if (body_end > container_end) continue;
        const drop = sequenceDropCall(file, receiver, sequence_field, body_start + 1, body_end) orelse continue;
        if (cleanupDelegatesToAnotherMethod(file, receiver, sequence_field, body_start + 1, body_end)) continue;
        const capture = sequenceElementCapture(file, receiver, sequence_field, body_start + 1, body_end);
        if (capture) |element| {
            if (elementCleanupIsOpaque(file, element, body_start + 1, body_end)) continue;
        }
        for (evidence) |owned_field| {
            if (owned_field.file_index != file_index or !std.mem.eql(u8, owned_field.type_name, element_type)) continue;
            if (capture) |element| {
                if (elementFieldReleased(file, element, owned_field.field_name, body_start + 1, body_end)) continue;
                if (optionalElementFieldReleased(file, element, owned_field.field_name, body_start + 1, body_end)) continue;
            }
            try found.append(allocator, .{
                .file_index = file_index,
                .rule = .incomplete_owned_field_cleanup,
                .span = file.tokens[drop].loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "{s} drops '{s}' elements without releasing proven owned field '{s}'",
                    .{ tokenText(file.source, file.tokens[drop]), element_type, owned_field.field_name },
                ),
            });
        }
    }
}

fn firstParameterName(file: IndexedSourceFile, start: usize, end: usize) ?[]const u8 {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and index + 1 < end and file.tokens[index + 1].tag == .colon) {
            return tokenText(file.source, token);
        }
    }
    return null;
}

fn sequenceDropCall(
    file: IndexedSourceFile,
    receiver: []const u8,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) ?usize {
    const methods = [_][]const u8{ "deinit", "clearRetainingCapacity", "clearAndFree" };
    var index = start;
    while (index + 6 < end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], receiver) or file.tokens[index + 1].tag != .period or
            !tokenIs(file.source, file.tokens[index + 2], sequence_field) or file.tokens[index + 3].tag != .period or
            file.tokens[index + 4].tag != .identifier or file.tokens[index + 5].tag != .l_paren) continue;
        for (methods) |method| if (tokenIs(file.source, file.tokens[index + 4], method)) return index + 4;
    }
    return null;
}

fn cleanupDelegatesToAnotherMethod(
    file: IndexedSourceFile,
    receiver: []const u8,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) bool {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], receiver) or file.tokens[index + 1].tag != .period or
            file.tokens[index + 2].tag != .identifier or file.tokens[index + 3].tag != .l_paren) continue;
        if (!tokenIs(file.source, file.tokens[index + 2], sequence_field)) return true;
    }
    return false;
}

fn sequenceElementCapture(
    file: IndexedSourceFile,
    receiver: []const u8,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) ?[]const u8 {
    var index = start;
    while (index + 7 < end) : (index += 1) {
        if (file.tokens[index].tag != .keyword_for or file.tokens[index + 1].tag != .l_paren) continue;
        const condition_end = matchingToken(file.tokens, index + 1, .l_paren, .r_paren) orelse continue;
        var names_sequence = false;
        var condition = index + 2;
        while (condition + 4 < condition_end) : (condition += 1) {
            if (tokenIs(file.source, file.tokens[condition], receiver) and file.tokens[condition + 1].tag == .period and
                tokenIs(file.source, file.tokens[condition + 2], sequence_field) and file.tokens[condition + 3].tag == .period and
                tokenIs(file.source, file.tokens[condition + 4], "items")) names_sequence = true;
        }
        if (!names_sequence or condition_end + 3 >= end or file.tokens[condition_end + 1].tag != .pipe) continue;
        const capture_index = if (file.tokens[condition_end + 2].tag == .asterisk) condition_end + 3 else condition_end + 2;
        if (capture_index + 1 >= end or file.tokens[capture_index].tag != .identifier or
            file.tokens[capture_index + 1].tag != .pipe) continue;
        return tokenText(file.source, file.tokens[capture_index]);
    }
    return null;
}

fn elementCleanupIsOpaque(file: IndexedSourceFile, element: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (!tokenIs(file.source, token, element)) continue;
        if (index + 3 < end and file.tokens[index + 1].tag == .period and
            tokenIs(file.source, file.tokens[index + 2], "deinit") and file.tokens[index + 3].tag == .l_paren) return true;
        if (index > start and file.tokens[index - 1].tag == .l_paren and
            (index + 1 >= end or file.tokens[index + 1].tag != .period) and
            (index < 2 or file.tokens[index - 2].tag != .identifier or
                (!tokenIs(file.source, file.tokens[index - 2], "free") and !tokenIs(file.source, file.tokens[index - 2], "destroy")))) return true;
    }
    return false;
}

fn elementFieldReleased(
    file: IndexedSourceFile,
    element: []const u8,
    field: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy")) or
            method_index + 1 >= end or file.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = matchingToken(file.tokens, method_index + 1, .l_paren, .r_paren) orelse continue;
        var index = method_index + 2;
        while (index + 2 < call_end) : (index += 1) {
            if (tokenIs(file.source, file.tokens[index], element) and file.tokens[index + 1].tag == .period and
                tokenIs(file.source, file.tokens[index + 2], field)) return true;
        }
    }
    return false;
}

fn optionalElementFieldReleased(
    file: IndexedSourceFile,
    element: []const u8,
    field: []const u8,
    start: usize,
    end: usize,
) bool {
    var capture: ?[]const u8 = null;
    var index = start;
    while (index + 6 < end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], element) or file.tokens[index + 1].tag != .period or
            !tokenIs(file.source, file.tokens[index + 2], field) or file.tokens[index + 3].tag != .r_paren or
            file.tokens[index + 4].tag != .pipe or file.tokens[index + 5].tag != .identifier or
            file.tokens[index + 6].tag != .pipe) continue;
        capture = tokenText(file.source, file.tokens[index + 5]);
        break;
    }
    const binding = capture orelse return false;
    for (file.tokens[start..end], start..) |token, release_index| {
        if (tokenIs(file.source, token, binding) and release_index + 3 < end and
            file.tokens[release_index + 1].tag == .period and tokenIs(file.source, file.tokens[release_index + 2], "deinit") and
            file.tokens[release_index + 3].tag == .l_paren) return true;
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy")) or
            release_index + 1 >= end or file.tokens[release_index + 1].tag != .l_paren) continue;
        const call_end = matchingToken(file.tokens, release_index + 1, .l_paren, .r_paren) orelse continue;
        for (file.tokens[release_index + 2 .. @min(call_end, end)], release_index + 2..) |argument, argument_index| {
            if (argument.tag == .identifier and tokenIs(file.source, file.tokens[argument_index], binding)) return true;
        }
    }
    return false;
}

fn hasOwnedFieldEvidence(evidence: []const OwnedFieldEvidence, file_index: usize, type_name: []const u8) bool {
    for (evidence) |field| if (field.file_index == file_index and std.mem.eql(u8, field.type_name, type_name)) return true;
    return false;
}

fn findDroppedOwnedElements(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    evidence: []const OwnedFieldEvidence,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.unreleased_allocation);
    if (level == .off) return;
    for (files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, equal_index| {
            if (token.tag != .equal or equal_index == 0 or !tokenIs(file.source, file.tokens[equal_index - 1], "_")) continue;
            const statement_end = statementEnd(file.tokens, equal_index) orelse continue;
            for (file.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, method_index| {
                if (candidate.tag != .identifier or
                    (!tokenIs(file.source, candidate, "swapRemove") and !tokenIs(file.source, candidate, "orderedRemove")) or
                    method_index < 2 or file.tokens[method_index - 1].tag != .period or file.tokens[method_index - 2].tag != .identifier) continue;
                const element_type = sequenceElementType(file, tokenText(file.source, file.tokens[method_index - 2])) orelse continue;
                for (evidence) |owned_field| {
                    if (owned_field.file_index != file_index or !std.mem.eql(u8, owned_field.type_name, element_type)) continue;
                    if (elementFieldReleasedBeforeRemoval(file, owned_field.field_name, method_index)) continue;
                    try found.append(allocator, .{
                        .file_index = file_index,
                        .rule = .unreleased_allocation,
                        .span = candidate.loc,
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "discarding removed '{s}' drops proven owned field '{s}'",
                            .{ element_type, owned_field.field_name },
                        ),
                    });
                }
            }
        }
    }
}

fn elementFieldReleasedBeforeRemoval(file: IndexedSourceFile, field_name: []const u8, removal_index: usize) bool {
    const scope_start = enclosingScopeStart(file.tokens, removal_index) orelse return false;
    for (file.tokens[scope_start + 1 .. removal_index], scope_start + 1..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy")) or
            method_index + 1 >= removal_index or file.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = matchingToken(file.tokens, method_index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end >= removal_index) continue;
        var index = method_index + 2;
        while (index + 1 < call_end) : (index += 1) {
            if (file.tokens[index].tag == .period and tokenIs(file.source, file.tokens[index + 1], field_name)) return true;
        }
    }
    return false;
}

fn enclosingScopeStart(tokens: []const std.zig.Token, index: usize) ?usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => depth += 1,
            .l_brace => {
                if (depth == 0) return cursor;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

fn findOwnedElementOverwrites(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    summary_index: summaries.Index,
    evidence: []const OwnedFieldEvidence,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.overwritten_owning_value);
    if (level == .off) return;
    for (files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, equal_index| {
            if (token.tag != .equal or equal_index < 6) continue;
            const field_index = equal_index - 1;
            if (file.tokens[field_index].tag != .identifier or file.tokens[field_index - 1].tag != .period) continue;
            const items_index = findItemsBefore(file, field_index, equal_index -| 16) orelse continue;
            if (items_index < 2 or file.tokens[items_index - 1].tag != .period or file.tokens[items_index - 2].tag != .identifier) continue;
            const sequence_field = tokenText(file.source, file.tokens[items_index - 2]);
            const element_type = sequenceElementType(file, sequence_field) orelse continue;
            const field_name = tokenText(file.source, file.tokens[field_index]);
            if (!ownedFieldIsProven(evidence, file_index, element_type, field_name)) continue;
            const statement_end = statementEnd(file.tokens, equal_index) orelse continue;
            const scope_start = enclosingScopeStart(file.tokens, equal_index) orelse continue;
            if (!assignmentAcquiresOwned(file, summary_index, equal_index + 1, statement_end, scope_start + 1)) continue;
            if (rangeReleasesElementField(file, sequence_field, field_name, scope_start + 1, equal_index)) continue;
            try found.append(allocator, .{
                .file_index = file_index,
                .rule = .overwritten_owning_value,
                .span = file.tokens[field_index].loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "assignment replaces proven owned field '{s}.{s}' without releasing its previous allocation",
                    .{ element_type, field_name },
                ),
            });
        }
    }
}

fn findAliasedOwnedElementOverwrites(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    summary_index: summaries.Index,
    evidence: []const OwnedFieldEvidence,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.overwritten_owning_value);
    if (level == .off) return;
    for (files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, declaration_index| {
            if (token.tag != .keyword_const or declaration_index + 4 >= file.tokens.len or
                file.tokens[declaration_index + 1].tag != .identifier or file.tokens[declaration_index + 2].tag != .equal or
                file.tokens[declaration_index + 3].tag != .ampersand) continue;
            const declaration_end = statementEnd(file.tokens, declaration_index) orelse continue;
            const items_index = findItemsBefore(file, declaration_end, declaration_index + 3) orelse continue;
            if (items_index < 2 or file.tokens[items_index - 1].tag != .period or
                file.tokens[items_index - 2].tag != .identifier) continue;
            const sequence_field = tokenText(file.source, file.tokens[items_index - 2]);
            const element_type = sequenceElementType(file, sequence_field) orelse continue;
            const alias = tokenText(file.source, file.tokens[declaration_index + 1]);
            const scope_end = enclosingScopeEnd(file.tokens, declaration_index) orelse continue;
            var equal_index = declaration_end + 1;
            while (equal_index + 2 < scope_end) : (equal_index += 1) {
                if (file.tokens[equal_index].tag != .equal or file.tokens[equal_index - 1].tag != .identifier or
                    file.tokens[equal_index - 2].tag != .period or !tokenIs(file.source, file.tokens[equal_index - 3], alias)) continue;
                const field_index = equal_index - 1;
                const field_name = tokenText(file.source, file.tokens[field_index]);
                if (!ownedFieldIsProven(evidence, file_index, element_type, field_name)) continue;
                const statement_end = statementEnd(file.tokens, equal_index) orelse continue;
                if (!assignmentAcquiresOwned(file, summary_index, equal_index + 1, statement_end, declaration_end + 1)) continue;
                if (rangeReleasesAliasedField(file, alias, field_name, declaration_end + 1, equal_index)) continue;
                try found.append(allocator, .{
                    .file_index = file_index,
                    .rule = .overwritten_owning_value,
                    .span = file.tokens[field_index].loc,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "assignment through alias '{s}' replaces proven owned field '{s}.{s}' without releasing its previous allocation",
                        .{ alias, element_type, field_name },
                    ),
                });
            }
        }
    }
}

fn assignmentAcquiresOwned(
    file: IndexedSourceFile,
    summary_index: summaries.Index,
    start: usize,
    end: usize,
    declaration_start: usize,
) bool {
    if (firstCall(file.tokens, start, end)) |call| {
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
        if (callReturnsOwned(file.source, summary_index, receiver, name)) return true;
    }
    if (start + 1 != end or file.tokens[start].tag != .identifier) return false;
    const binding = tokenText(file.source, file.tokens[start]);
    const assignment_scope = enclosingScopeStart(file.tokens, start) orelse return false;
    for (file.tokens[declaration_start..start], declaration_start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 1 >= start or
            !tokenIs(file.source, file.tokens[declaration_index + 1], binding)) continue;
        const declaration_scope = enclosingScopeStart(file.tokens, declaration_index) orelse continue;
        if (declaration_scope != assignment_scope) continue;
        const declaration_end = statementEnd(file.tokens, declaration_index) orelse continue;
        if (declaration_end >= start) continue;
        const call = firstCall(file.tokens, declaration_index + 2, declaration_end) orelse continue;
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
        if (callReturnsOwned(file.source, summary_index, receiver, name)) return true;
    }
    return false;
}

fn rangeReleasesAliasedField(
    file: IndexedSourceFile,
    alias: []const u8,
    field_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy")) or
            method_index + 1 >= end or file.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = matchingToken(file.tokens, method_index + 1, .l_paren, .r_paren) orelse continue;
        var index = method_index + 2;
        while (index + 2 < @min(call_end, end)) : (index += 1) {
            if (tokenIs(file.source, file.tokens[index], alias) and file.tokens[index + 1].tag == .period and
                tokenIs(file.source, file.tokens[index + 2], field_name)) return true;
        }
    }
    return false;
}

fn callReturnsOwned(
    source: []const u8,
    summary_index: summaries.Index,
    receiver: ?[]const u8,
    name: []const u8,
) bool {
    if (summary_index.ownedReturnCall(source, receiver, name) != null) return true;
    if (owned_call.releaseForMethod(name) == null or std.mem.eql(u8, name, "realloc")) return false;
    const owner = receiver orelse return false;
    return std.ascii.indexOfIgnoreCase(owner, "alloc") != null or std.mem.eql(u8, owner, "gpa");
}

fn findItemsBefore(file: IndexedSourceFile, end: usize, start: usize) ?usize {
    var index = end;
    while (index > start) {
        index -= 1;
        if (tokenIs(file.source, file.tokens[index], "items")) return index;
        if (file.tokens[index].tag == .semicolon or file.tokens[index].tag == .l_brace) return null;
    }
    return null;
}

fn ownedFieldIsProven(
    evidence: []const OwnedFieldEvidence,
    file_index: usize,
    type_name: []const u8,
    field_name: []const u8,
) bool {
    for (evidence) |field| if (field.file_index == file_index and
        std.mem.eql(u8, field.type_name, type_name) and std.mem.eql(u8, field.field_name, field_name)) return true;
    return false;
}

fn rangeReleasesElementField(
    file: IndexedSourceFile,
    sequence_field: []const u8,
    field_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy"))) continue;
        const statement_end = statementEnd(file.tokens, method_index) orelse continue;
        var saw_sequence = false;
        var saw_field = false;
        for (file.tokens[method_index + 1 .. @min(statement_end, end)], method_index + 1..) |argument, index| {
            if (argument.tag != .identifier) continue;
            if (tokenIs(file.source, argument, sequence_field)) saw_sequence = true;
            if (tokenIs(file.source, file.tokens[index], field_name)) saw_field = true;
        }
        if (saw_sequence and saw_field) return true;
    }
    return false;
}

fn functionReturnType(file: IndexedSourceFile, start: usize, end: usize) ?[]const u8 {
    var selected: ?[]const u8 = null;
    for (file.tokens[start..end]) |token| {
        if (token.tag == .identifier) selected = tokenText(file.source, token);
    }
    return selected;
}

const CleanupMethod = struct {
    receiver: []const u8,
    body_start: usize,
    body_end: usize,
};

fn cleanupMethod(file: IndexedSourceFile, start: usize, end: usize) ?CleanupMethod {
    for (file.tokens[start..end], start..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 3 >= end or file.tokens[fn_index + 1].tag != .identifier or
            !tokenIs(file.source, file.tokens[fn_index + 1], "deinit") or file.tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(file.tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
        var receiver: ?[]const u8 = null;
        for (file.tokens[fn_index + 3 .. parameters_end], fn_index + 3..) |parameter, index| {
            if (parameter.tag == .identifier and index + 1 < parameters_end and file.tokens[index + 1].tag == .colon) {
                receiver = tokenText(file.source, parameter);
                break;
            }
        }
        const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const body_end = matchingToken(file.tokens, body_start, .l_brace, .r_brace) orelse continue;
        return .{ .receiver = receiver orelse continue, .body_start = body_start, .body_end = body_end };
    }
    return null;
}

fn fieldReleased(file: IndexedSourceFile, cleanup: CleanupMethod, field: []const u8) bool {
    var index = cleanup.body_start + 1;
    while (index + 2 < cleanup.body_end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], cleanup.receiver) or file.tokens[index + 1].tag != .period or
            !tokenIs(file.source, file.tokens[index + 2], field)) continue;
        if (optionalFieldCaptureReleased(file, cleanup, index)) return true;
        if (index + 4 < cleanup.body_end and file.tokens[index + 3].tag == .period and
            (tokenIs(file.source, file.tokens[index + 4], "deinit") or tokenIs(file.source, file.tokens[index + 4], "close"))) return true;
        var cursor = index;
        while (cursor > cleanup.body_start and index - cursor < 6) {
            cursor -= 1;
            if (file.tokens[cursor].tag == .identifier and
                (tokenIs(file.source, file.tokens[cursor], "free") or tokenIs(file.source, file.tokens[cursor], "destroy"))) return true;
            if (file.tokens[cursor].tag == .semicolon or file.tokens[cursor].tag == .l_brace) break;
        }
    }
    return false;
}

fn optionalFieldCaptureReleased(file: IndexedSourceFile, cleanup: CleanupMethod, field_index: usize) bool {
    var capture_open = field_index + 3;
    while (capture_open < cleanup.body_end and capture_open - field_index < 8 and
        file.tokens[capture_open].tag != .pipe) : (capture_open += 1)
    {}
    if (capture_open + 2 >= cleanup.body_end or file.tokens[capture_open].tag != .pipe) return false;
    const capture_index = if (file.tokens[capture_open + 1].tag == .asterisk) capture_open + 2 else capture_open + 1;
    if (capture_index + 1 >= cleanup.body_end or file.tokens[capture_index].tag != .identifier or
        file.tokens[capture_index + 1].tag != .pipe) return false;
    const capture = tokenText(file.source, file.tokens[capture_index]);
    const branch_start = capture_index + 2;
    const branch_end = if (branch_start < cleanup.body_end and file.tokens[branch_start].tag == .l_brace)
        matchingToken(file.tokens, branch_start, .l_brace, .r_brace) orelse cleanup.body_end
    else
        @min(statementEnd(file.tokens, branch_start) orelse cleanup.body_end, cleanup.body_end);
    for (file.tokens[branch_start..branch_end], branch_start..) |token, index| {
        if (!tokenIs(file.source, token, capture)) continue;
        if (index + 2 < branch_end and file.tokens[index + 1].tag == .period and file.tokens[index + 2].tag == .identifier and
            (tokenIs(file.source, file.tokens[index + 2], "deinit") or tokenIs(file.source, file.tokens[index + 2], "close"))) return true;
        var cursor = index;
        while (cursor > branch_start and index - cursor < 6) {
            cursor -= 1;
            if (file.tokens[cursor].tag == .identifier and
                (tokenIs(file.source, file.tokens[cursor], "free") or tokenIs(file.source, file.tokens[cursor], "destroy"))) return true;
            if (file.tokens[cursor].tag == .semicolon or file.tokens[cursor].tag == .l_brace) break;
        }
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

test "owned helper returns require errdefer before later failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/main.zig",
        .source = "fn makeMessage(allocator: std.mem.Allocator, text: []const u8) ![]u8 { return allocator.dupe(u8, text); }" ++
            "fn assemble(allocator: std.mem.Allocator) ![]u8 {" ++
            "const prefix = try makeMessage(allocator, \"prefix\");" ++
            "const suffix = try makeMessage(allocator, \"suffix\");" ++
            "errdefer allocator.free(prefix);" ++
            "const result = try allocator.alloc(u8, prefix.len + suffix.len);" ++
            "allocator.free(prefix); allocator.free(suffix); return result; }",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var missing_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_errdefer) {
        missing_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), missing_count);
}

test "project summaries preserve partial IO contracts through wrappers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/main.zig",
        .source = "const Socket = struct { stream: Stream, fn send(self: *Socket, bytes: []const u8) !usize { return self.stream.write(bytes); } };" ++
            "fn run(socket: *Socket, bytes: []const u8) !void { _ = try socket.send(bytes); }",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var discarded_count: usize = 0;
    for (found) |finding| if (finding.rule == .discarded_write_count) {
        discarded_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), discarded_count);
}

test "borrowed helper returns are invalidated with their receiver field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/main.zig",
        .source = "const Catalog = struct { records: List, " ++
            "fn find(self: *Catalog, index: usize) *Record { return &self.records.items[index]; } " ++
            "fn view(self: *Catalog) []Record { return self.records.items[0..]; } " ++
            "fn remove(self: *Catalog) void { _ = self.records.orderedRemove(0); } };" ++
            "fn run(catalog: *Catalog) !void {" ++
            "const record = catalog.find(0); try catalog.records.append(a, .{}); use(record);" ++
            "const view = catalog.view(); _ = catalog.records.orderedRemove(0); consume(view);" ++
            "const second = catalog.view(); catalog.remove(); return consume(second); }",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var pointer_count: usize = 0;
    var view_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .invalidated_element_pointer => pointer_count += 1,
        .invalidated_container_view => view_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), pointer_count);
    try std.testing.expectEqual(@as(usize, 2), view_count);
}

test "container mutation summaries invalidate direct pointers and active iterators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/main.zig",
        .source = "fn grow(values: *List) !void { try values.ensureTotalCapacity(a, 64); }" ++
            "fn add(map: *Map) !void { try map.put(2, 2); }" ++
            "fn run(values: *List, map: *Map) !void { const borrowed = &values.items[0];" ++
            "try grow(&values); use(borrowed); var iterator = map.iterator();" ++
            "while (iterator.next()) |_| { try add(&map); } }",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var pointer_count: usize = 0;
    var iterator_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .invalidated_element_pointer => pointer_count += 1,
        .iterator_invalidated_during_loop => iterator_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), pointer_count);
    try std.testing.expectEqual(@as(usize, 1), iterator_count);
}

test "escaped local views retained in aggregates report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/main.zig",
        .source = "const Entry = struct { text: []const u8 };" ++
            "fn parse(raw: []const u8) Entry { return .{ .text = raw }; }" ++
            "fn load(allocator: anytype, source: []const u8) ![]Entry {" ++
            "var entries = List.empty; var buffer: [64]u8 = undefined; @memcpy(buffer[0..source.len], source);" ++
            "const input = buffer[0..source.len]; const entry = parse(input); try entries.append(allocator, entry); return entries.items; }",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var escape_count: usize = 0;
    for (found) |finding| if (finding.rule == .local_storage_escape) {
        escape_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), escape_count);
}

test "borrowed local views and unretained aggregate results stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/main.zig",
        .source = "const Entry = struct { text: []const u8 };" ++
            "fn length(raw: []const u8) usize { return raw.len; }" ++
            "fn parse(raw: []const u8) Entry { return .{ .text = raw }; }" ++
            "fn load() void { var buffer: [64]u8 = undefined; const input = buffer[0..];" ++
            "const scalar = std.math.cast(u8, buffer[0]) orelse return;" ++
            "const size = length(input); const entry = parse(input); use(scalar, size, entry); }",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .local_storage_escape);
}

test "cleanup methods release every proven owned field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/main.zig",
        .source = "const Record = struct { title: []u8, payload: []u8, allocator: std.mem.Allocator, " ++
            "fn deinit(self: Record) void { self.allocator.free(self.title); } };" ++
            "fn make(allocator: std.mem.Allocator, text: []const u8) ![]u8 { return allocator.dupe(u8, text); }" ++
            "fn makeRecord(allocator: std.mem.Allocator) !Record {" ++
            "const title = try make(allocator, \"title\"); const payload = try make(allocator, \"payload\");" ++
            "return .{ .title = title, .payload = payload, .allocator = allocator }; }",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .incomplete_owned_field_cleanup) {
        cleanup_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "owned field evidence remains separate for same-named types in different files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "const Record = struct { first: []u8, second: []u8, allocator: std.mem.Allocator, " ++
        "fn deinit(self: Record) void { self.allocator.free(self.first); } };" ++
        "fn copy(allocator: std.mem.Allocator, text: []const u8) ![]u8 { return allocator.dupe(u8, text); }" ++
        "fn make(allocator: std.mem.Allocator) !Record { const first = try copy(allocator, \"a\");" ++
        "const second = try copy(allocator, \"b\"); return .{ .first = first, .second = second, .allocator = allocator }; }";
    const files = [_]SourceFile{
        .{ .path = "src/first.zig", .source = source },
        .{ .path = "src/second.zig", .source = source },
    };
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .incomplete_owned_field_cleanup) {
        cleanup_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), cleanup_count);
}

test "container cleanup preserves every proven owned element field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/cache.zig",
        .source = "const Entry = struct { key: []u8, value: []u8 };" ++
            "const Cache = struct { allocator: std.mem.Allocator, entries: std.ArrayListUnmanaged(Entry) = .empty," ++
            "fn add(self: *Cache, key: []const u8, value: []const u8) !void {" ++
            "const owned_key = try self.allocator.dupe(u8, key); const owned_value = try self.allocator.dupe(u8, value);" ++
            "try self.entries.append(self.allocator, .{ .key = owned_key, .value = owned_value }); }" ++
            "fn deinit(self: *Cache) void { for (self.entries.items) |entry| self.allocator.free(entry.key);" ++
            "self.entries.deinit(self.allocator); }" ++
            "fn clear(self: *Cache) void { for (self.entries.items) |entry| self.allocator.free(entry.key);" ++
            "self.entries.clearRetainingCapacity(); } };",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .incomplete_owned_field_cleanup) {
        cleanup_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, "value") != null);
    };
    try std.testing.expectEqual(@as(usize, 2), cleanup_count);
}

test "complete element cleanup and delegated cleanup remain opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/cache.zig",
        .source = "const Entry = struct { key: []u8, value: []u8 };" ++
            "const Cache = struct { allocator: std.mem.Allocator, entries: std.ArrayListUnmanaged(Entry) = .empty," ++
            "fn add(self: *Cache, key: []const u8, value: []const u8) !void {" ++
            "const owned_key = try self.allocator.dupe(u8, key); const owned_value = try self.allocator.dupe(u8, value);" ++
            "try self.entries.append(self.allocator, .{ .key = owned_key, .value = owned_value }); }" ++
            "fn clear(self: *Cache) void { for (self.entries.items) |*entry| { self.allocator.free(entry.key);" ++
            "self.allocator.free(entry.value); } self.entries.clearRetainingCapacity(); }" ++
            "fn deinit(self: *Cache) void { self.clear(); self.entries.deinit(self.allocator); } };",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .incomplete_owned_field_cleanup);
}

test "owning elements cleared outside a cleanup-named method report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/connection.zig",
        .source = "const Packet = struct { bytes: []u8 };" ++
            "const Connection = struct { allocator: std.mem.Allocator, pending: std.ArrayListUnmanaged(Packet) = .empty," ++
            "fn enqueue(self: *Connection, payload: []const u8) !void { const copy = try self.allocator.dupe(u8, payload);" ++
            "try self.pending.append(self.allocator, .{ .bytes = copy }); }" ++
            "fn flush(self: *Connection) void { for (self.pending.items) |packet| consume(packet.bytes);" ++
            "self.pending.clearRetainingCapacity(); } };",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .incomplete_owned_field_cleanup) {
        cleanup_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, "bytes") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "optional owning element fields released through captures stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/pool.zig",
        .source = "const Object = struct {}; const Slot = struct { object: ?*Object = null };" ++
            "const Pool = struct { allocator: std.mem.Allocator, slots: std.ArrayListUnmanaged(Slot) = .empty," ++
            "fn add(self: *Pool) !void { const object = try self.allocator.create(Object);" ++
            "try self.slots.append(self.allocator, .{ .object = object }); }" ++
            "fn deinit(self: *Pool) void { for (self.slots.items) |slot| { if (slot.object) |object| {" ++
            "self.allocator.destroy(object); } } self.slots.deinit(self.allocator); } };",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .incomplete_owned_field_cleanup);
}

test "optional owned field captures count as cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/record.zig",
        .source = "const Record = struct { first: ?[]u8, second: ?[]u8, allocator: std.mem.Allocator," ++
            "fn deinit(self: Record) void { if (self.first) |first| self.allocator.free(first);" ++
            "if (self.second) |second| self.allocator.free(second); } };" ++
            "fn make(allocator: std.mem.Allocator) !Record { const first = try allocator.dupe(u8, \"a\");" ++
            "const second = try allocator.dupe(u8, \"b\"); return .{ .first = first, .second = second, .allocator = allocator }; }",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .incomplete_owned_field_cleanup);
}

test "several fields aliasing one allocation do not invent several owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/aliases.zig",
        .source = "const Aliases = struct { view: []const u8, owned: ?[]u8," ++
            "fn deinit(self: Aliases, allocator: std.mem.Allocator) void {" ++
            "if (self.owned) |owned| allocator.free(owned); } };" ++
            "fn make(allocator: std.mem.Allocator) !Aliases { const bytes = try allocator.dupe(u8, \"a\");" ++
            "return .{ .view = bytes, .owned = bytes }; }",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .incomplete_owned_field_cleanup);
}

test "overwriting and discarding proven owned element fields report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/cache.zig",
        .source = "const Entry = struct { key: []u8, value: []u8 };" ++
            "const Cache = struct { allocator: std.mem.Allocator, entries: std.ArrayListUnmanaged(Entry) = .empty," ++
            "fn add(self: *Cache, key: []const u8, value: []const u8) !void {" ++
            "const owned_key = try self.allocator.dupe(u8, key); const owned_value = try self.allocator.dupe(u8, value);" ++
            "try self.entries.append(self.allocator, .{ .key = owned_key, .value = owned_value }); }" ++
            "fn replace(self: *Cache, index: usize, value: []const u8) !void {" ++
            "self.entries.items[index].value = try self.allocator.dupe(u8, value); }" ++
            "fn safeReplace(self: *Cache, index: usize, value: []const u8) !void {" ++
            "self.allocator.free(self.entries.items[index].value);" ++
            "self.entries.items[index].value = try self.allocator.dupe(u8, value); }" ++
            "fn remove(self: *Cache, index: usize) void { _ = self.entries.swapRemove(index); } };",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var overwrite_count: usize = 0;
    var removal_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .overwritten_owning_value => overwrite_count += 1,
        .unreleased_allocation => if (std.mem.indexOf(u8, finding.message, "removed 'Entry'") != null) {
            removal_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), overwrite_count);
    try std.testing.expectEqual(@as(usize, 2), removal_count);
}

test "overwriting a proven owned element field through an alias reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{.{
        .path = "src/scheduler.zig",
        .source = "const Task = struct { label: []u8 };" ++
            "const Scheduler = struct { allocator: std.mem.Allocator, tasks: std.ArrayListUnmanaged(Task) = .empty," ++
            "fn add(self: *Scheduler, label: []const u8) !void { const owned = try self.allocator.dupe(u8, label);" ++
            "try self.tasks.append(self.allocator, .{ .label = owned }); }" ++
            "fn replace(self: *Scheduler, index: usize, label: []const u8) !void {" ++
            "const task = &self.tasks.items[index]; const replacement = try self.allocator.dupe(u8, label);" ++
            "task.label = replacement; }" ++
            "fn safeReplace(self: *Scheduler, index: usize, label: []const u8) !void {" ++
            "const task = &self.tasks.items[index]; const replacement = try self.allocator.dupe(u8, label);" ++
            "self.allocator.free(task.label); task.label = replacement; } };",
    }};
    const found = try findings(arena.allocator(), &files, types.Configuration.defaults());
    var overwrite_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .overwritten_owning_value) overwrite_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), overwrite_count);
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
