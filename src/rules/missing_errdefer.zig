const std = @import("std");
const syntax_scope = @import("../syntax_scope.zig");
const RuleRun = @import("context.zig").RuleRun;
const owned_call = @import("owned_call.zig");
const summaries = @import("summaries.zig");
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try runInternal(context, null, false);
}

pub fn runWithSummaries(context: RuleRun, summary_index: summaries.Index) !void {
    try runInternal(context, summary_index, true);
}

fn runInternal(context: RuleRun, summary_index: ?summaries.Index, summaries_only: bool) !void {
    const level = context.level(.missing_errdefer);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        if (!startsStatement(context, declaration_index)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const acquisition = owningAcquisition(context, declaration_index, declaration_end, summary_index, summaries_only) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const function_scope = functionScopeContaining(context, declaration_index) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        const receiver = context.source[context.tokens[acquisition.release_owner_start].loc.start..context.tokens[acquisition.release_owner_end].loc.end];
        const callable = context.source[context.tokens[acquisition.callable_start].loc.start..context.tokens[acquisition.method_index].loc.end];
        const method = context.tokenText(acquisition.method_index);
        if (acquisition.kind == .allocation and std.mem.eql(u8, callable, "std.Build.create")) continue;
        if (acquisition.kind == .allocation and std.ascii.indexOfIgnoreCase(receiver, "arena") != null) continue;
        if (acquisition.kind == .allocation and std.mem.eql(u8, method, "create") and std.ascii.indexOfIgnoreCase(receiver, "pool") != null) continue;
        if (acquisition.kind == .allocation and declarationLooksArenaBacked(
            context,
            context.tokenText(acquisition.release_owner_start),
            function_scope.opening,
            function_scope.closing,
        )) continue;
        if (acquisition.kind == .allocation and functionDocumentsArenaAllocator(
            context,
            function_scope,
            context.tokenText(acquisition.release_owner_start),
        )) continue;
        if (acquisition.kind == .allocation and functionParameterReceivesOnlyArena(
            context,
            function_scope,
            context.tokenText(acquisition.release_owner_start),
            0,
        )) continue;
        if (acquisition.kind == .allocation and allocatorPathIsBuildArena(
            context,
            function_scope,
            acquisition.release_owner_start,
            acquisition.release_owner_end,
        )) continue;
        // 'defer pool.deinit(...)' reclaims everything the pool handed out,
        // error path included.
        if (acquisition.kind == .allocation and scopeDeinitializesReceiver(context, scope_opening, scope_end, context.tokenText(acquisition.release_owner_end))) continue;
        const fallible_index = fallibleBeforeBindingUse(
            context,
            declaration_end + 1,
            scope_end,
            binding_name,
            acquisition.kind == .network_stream,
        ) orelse fallibleBeforePlainCleanup(
            context,
            declaration_end + 1,
            scope_end,
            binding_name,
            acquisition.release,
        ) orelse continue;
        if (scopeHasErrorPathCleanup(context, binding_name, declaration_end + 1, fallible_index)) continue;

        const release_statement = switch (acquisition.kind) {
            .allocation => try std.fmt.allocPrint(context.allocator, "{s}.{s}({s})", .{ receiver, acquisition.release, binding_name }),
            .network_stream => try std.fmt.allocPrint(
                context.allocator,
                "{s}.close({s})",
                .{
                    binding_name,
                    context.source[context.tokens[acquisition.close_argument.?.start].loc.start..context.tokens[acquisition.close_argument.?.end - 1].loc.end],
                },
            ),
        };
        const indent = lineIndent(context.source, context.tokens[declaration_index].loc.start);
        const semicolon_end = context.tokens[declaration_end].loc.end;
        const edits = try context.allocator.alloc(types.Edit, 1);
        if (std.mem.indexOfScalarPos(u8, context.source, semicolon_end, '\n')) |line_break| {
            edits[0] = .{
                .span = .{ .start = line_break + 1, .end = line_break + 1 },
                .replacement = try std.fmt.allocPrint(context.allocator, "{s}errdefer {s};\n", .{ indent, release_statement }),
            };
        } else {
            edits[0] = .{
                .span = .{ .start = semicolon_end, .end = semicolon_end },
                .replacement = try std.fmt.allocPrint(context.allocator, "\n{s}errdefer {s};", .{ indent, release_statement }),
            };
        }
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Add an errdefer release after the acquisition",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
        };
        const related = try context.allocator.alloc(types.RelatedSpan, 1);
        related[0] = .{
            .span = context.tokens[fallible_index].loc,
            .message = try context.allocator.dupe(
                u8,
                if (context.tokens[fallible_index].tag == .keyword_return)
                    "this error return leaks the owning value"
                else
                    "this fallible operation leaks the owning value when it fails",
            ),
        };
        try context.emit(.{
            .rule = .missing_errdefer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "owning value '{s}' from '{s}' has no errdefer release before an error path can leave the scope",
                .{ binding_name, callable },
            ),
            .related = related,
            .fixes = fixes,
        });
    }
    try findPartiallyInitializedOwnedFields(context, summary_index, summaries_only, level);
    try findFallibleAggregateFieldInitializers(context, summary_index, summaries_only, level);
    if (!summaries_only) {
        try findCleanupCapableValuesBeforeInsertion(context, level);
        try findFallibleContainerBuilders(context, level);
        try findFallibleSliceBuilders(context, level);
    }
}

fn findFallibleContainerBuilders(context: RuleRun, level: types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!declaresEmptyArrayList(context, declaration_index + 2, declaration_end)) continue;
        const function_scope = functionScopeContaining(context, declaration_index) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        var first_mutation: ?usize = null;
        var mutation_count: usize = 0;
        var arena_mutation_count: usize = 0;
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |candidate, binding_index| {
            if (candidate.tag != .identifier or !context.tokenIs(binding_index, binding) or
                binding_index + 3 >= scope_end or context.tokens[binding_index + 1].tag != .period or
                context.tokens[binding_index + 2].tag != .identifier or context.tokens[binding_index + 3].tag != .l_paren) continue;
            const mutation_scope = functionScopeContaining(context, binding_index) orelse continue;
            if (mutation_scope.declaration != function_scope.declaration) continue;
            const method = context.tokenText(binding_index + 2);
            if (!fallibleContainerMutation(method)) continue;
            const mutation_end = context.statementEnd(binding_index) orelse continue;
            if (!rangeContainsTry(context.tokens, statementStart(context.tokens, binding_index), mutation_end)) continue;
            first_mutation = first_mutation orelse binding_index;
            mutation_count += 1;
            const call_end = context.matchingToken(binding_index + 3, .l_paren, .r_paren) orelse continue;
            const allocator_argument = callArgument(context, binding_index + 4, call_end, 0) orelse continue;
            if (callArgumentIsArenaBacked(context, allocator_argument, binding_index, 0)) arena_mutation_count += 1;
        }
        const first = first_mutation orelse continue;
        if (mutation_count < 2 and !mutationCanRepeat(context, first, function_scope.opening)) continue;
        if (arena_mutation_count == mutation_count) continue;
        if (scopeHasContainerCleanup(context, binding, function_scope.declaration, declaration_end + 1, first)) continue;
        if (!scopeTransfersContainerStorage(context, binding, function_scope.declaration, first + 1, scope_end)) continue;
        try context.emit(.{
            .rule = .missing_errdefer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "container '{s}' can retain its backing allocation if a later mutation fails before ownership transfer",
                .{binding},
            ),
        });
    }
}

fn findFallibleSliceBuilders(context: RuleRun, level: types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 5 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!declaresEmptySlice(context, declaration_index + 2, declaration_end)) continue;
        const function_scope = functionScopeContaining(context, declaration_index) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        var first_realloc: ?usize = null;
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |candidate, equal_index| {
            if (candidate.tag != .equal or equal_index == 0 or !context.tokenIs(equal_index - 1, binding)) continue;
            const mutation_scope = functionScopeContaining(context, equal_index) orelse continue;
            if (mutation_scope.declaration != function_scope.declaration) continue;
            const assignment_end = context.statementEnd(equal_index) orelse continue;
            if (!rangeContainsTry(context.tokens, statementStart(context.tokens, equal_index), assignment_end)) continue;
            for (context.tokens[equal_index + 1 .. assignment_end], equal_index + 1..) |method, method_index| {
                if (method.tag != .identifier or !context.tokenIs(method_index, "realloc") or
                    method_index + 1 >= assignment_end or context.tokens[method_index + 1].tag != .l_paren) continue;
                const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
                var consumes_binding = false;
                for (context.tokens[method_index + 2 .. @min(call_end, assignment_end)], method_index + 2..) |argument, argument_index| {
                    if (argument.tag == .identifier and context.tokenIs(argument_index, binding)) consumes_binding = true;
                }
                if (consumes_binding) first_realloc = first_realloc orelse equal_index;
            }
        }
        const first = first_realloc orelse continue;
        if (!mutationCanRepeat(context, first, function_scope.opening) or
            sliceHasErrorCleanup(context, binding, function_scope.declaration, declaration_end + 1, first) or
            !scopeReturnsBinding(context, binding, function_scope.declaration, first + 1, scope_end)) continue;
        try context.emit(.{
            .rule = .missing_errdefer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "slice builder '{s}' can retain its reallocated storage if a later loop iteration fails",
                .{binding},
            ),
        });
    }
}

fn declaresEmptySlice(context: RuleRun, start: usize, end: usize) bool {
    var names_slice = false;
    var names_empty_literal = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .l_bracket and index + 1 < end and context.tokens[index + 1].tag == .r_bracket) names_slice = true;
        if (token.tag == .ampersand and index + 3 < end and context.tokens[index + 1].tag == .period and
            context.tokens[index + 2].tag == .l_brace and context.tokens[index + 3].tag == .r_brace) names_empty_literal = true;
    }
    return names_slice and names_empty_literal;
}

fn sliceHasErrorCleanup(context: RuleRun, binding: []const u8, function_declaration: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const cleanup_scope = functionScopeContaining(context, defer_index) orelse continue;
        if (cleanup_scope.declaration != function_declaration) continue;
        const defer_end = context.statementEnd(defer_index) orelse continue;
        for (context.tokens[defer_index + 1 .. @min(defer_end, end)], defer_index + 1..) |candidate, index| {
            if (candidate.tag != .identifier or !context.tokenIs(index, "free") or
                index + 1 >= defer_end or context.tokens[index + 1].tag != .l_paren) continue;
            const call_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
            for (context.tokens[index + 2 .. @min(call_end, defer_end)], index + 2..) |argument, argument_index| {
                if (argument.tag == .identifier and context.tokenIs(argument_index, binding)) return true;
            }
        }
    }
    return false;
}

fn scopeReturnsBinding(context: RuleRun, binding: []const u8, function_declaration: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, return_index| {
        if (token.tag != .keyword_return) continue;
        const return_scope = functionScopeContaining(context, return_index) orelse continue;
        if (return_scope.declaration != function_declaration) continue;
        const return_end = context.statementEnd(return_index) orelse continue;
        for (context.tokens[return_index + 1 .. @min(return_end, end)], return_index + 1..) |value, value_index| {
            if (value.tag == .identifier and context.tokenIs(value_index, binding)) return true;
        }
    }
    return false;
}

fn mutationCanRepeat(context: RuleRun, mutation_index: usize, function_opening: usize) bool {
    const direct_start = statementStart(context.tokens, mutation_index);
    for (context.tokens[direct_start..mutation_index]) |token| {
        if (token.tag == .keyword_for or token.tag == .keyword_while) return true;
    }
    var scope = context.enclosingOpeningBrace(mutation_index);
    while (scope) |opening| {
        if (opening == function_opening) return false;
        const scope_statement = statementStart(context.tokens, opening);
        for (context.tokens[scope_statement..opening]) |token| {
            if (token.tag == .keyword_for or token.tag == .keyword_while) return true;
        }
        if (opening == 0) break;
        scope = context.enclosingOpeningBrace(opening - 1);
    }
    return false;
}

fn declaresEmptyArrayList(context: RuleRun, start: usize, end: usize) bool {
    var names_array_list = false;
    var names_empty = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        names_array_list = names_array_list or context.tokenIs(index, "ArrayList") or context.tokenIs(index, "ArrayListUnmanaged");
        names_empty = names_empty or context.tokenIs(index, "empty");
    }
    return names_array_list and names_empty;
}

fn fallibleContainerMutation(method: []const u8) bool {
    const methods = [_][]const u8{
        "addManyAsArray",
        "addOne",
        "append",
        "appendNTimes",
        "appendSlice",
        "ensureTotalCapacity",
        "ensureUnusedCapacity",
        "insert",
        "resize",
    };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return true;
    return false;
}

fn scopeHasContainerCleanup(context: RuleRun, binding: []const u8, function_declaration: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_defer and token.tag != .keyword_errdefer) continue;
        const cleanup_scope = functionScopeContaining(context, defer_index) orelse continue;
        if (cleanup_scope.declaration != function_declaration) continue;
        const statement_end = context.statementEnd(defer_index) orelse continue;
        var index = defer_index + 1;
        while (index + 3 < @min(statement_end + 1, end)) : (index += 1) {
            if (context.tokenIs(index, binding) and context.tokens[index + 1].tag == .period and
                context.tokenIs(index + 2, "deinit") and context.tokens[index + 3].tag == .l_paren) return true;
        }
    }
    return false;
}

fn scopeTransfersContainerStorage(context: RuleRun, binding: []const u8, function_declaration: usize, start: usize, end: usize) bool {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (context.tokenIs(index, binding) and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, "toOwnedSlice") and context.tokens[index + 3].tag == .l_paren)
        {
            const transfer_scope = functionScopeContaining(context, index) orelse continue;
            if (transfer_scope.declaration == function_declaration) return true;
        }
    }
    return false;
}

fn findFallibleAggregateFieldInitializers(
    context: RuleRun,
    summary_index: ?summaries.Index,
    summaries_only: bool,
    level: types.Level,
) !void {
    for (context.tokens, 0..) |token, aggregate_open| {
        if (token.tag != .l_brace) continue;
        const binding: ?[]const u8 = if (aggregate_open >= 4 and context.tokens[aggregate_open - 1].tag == .identifier and
            context.tokens[aggregate_open - 2].tag == .equal and context.tokens[aggregate_open - 3].tag == .identifier and
            (context.tokens[aggregate_open - 4].tag == .keyword_const or context.tokens[aggregate_open - 4].tag == .keyword_var))
            context.tokenText(aggregate_open - 3)
        else if (aggregate_open > 0 and context.tokens[aggregate_open - 1].tag == .period)
            null
        else
            continue;
        const aggregate_end = context.matchingToken(aggregate_open, .l_brace, .r_brace) orelse continue;
        for (context.tokens[aggregate_open + 1 .. aggregate_end], aggregate_open + 1..) |candidate, equal_index| {
            if (candidate.tag != .equal or equal_index < aggregate_open + 2 or
                context.tokens[equal_index - 1].tag != .identifier or context.tokens[equal_index - 2].tag != .period) continue;
            if (context.enclosingOpeningBrace(equal_index) != aggregate_open) continue;
            const value_end = aggregateFieldValueEnd(context.tokens, equal_index + 1, aggregate_end);
            const acquisition = owningAcquisitionAfterEqual(
                context,
                equal_index,
                value_end,
                summary_index,
                summaries_only,
            ) orelse continue;
            if (acquisition.kind != .allocation or !rangeContainsTry(context.tokens, value_end + 1, aggregate_end)) continue;
            const receiver = context.source[context.tokens[acquisition.release_owner_start].loc.start..context.tokens[acquisition.release_owner_end].loc.end];
            if (std.ascii.indexOfIgnoreCase(receiver, "arena") != null) continue;
            const field = context.tokenText(equal_index - 1);
            const message = if (binding) |name|
                try std.fmt.allocPrint(
                    context.allocator,
                    "owned field '{s}.{s}' can leak if a later aggregate field initialization fails",
                    .{ name, field },
                )
            else
                try std.fmt.allocPrint(
                    context.allocator,
                    "owned aggregate field '{s}' can leak if a later field initialization fails",
                    .{field},
                );
            try context.emit(.{
                .rule = .missing_errdefer,
                .level = level,
                .span = context.tokens[equal_index - 1].loc,
                .message = message,
            });
        }
    }
}

fn aggregateFieldValueEnd(tokens: []const std.zig.Token, start: usize, end: usize) usize {
    var parentheses: usize = 0;
    var brackets: usize = 0;
    var braces: usize = 0;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren => parentheses += 1,
        .r_paren => parentheses -|= 1,
        .l_bracket => brackets += 1,
        .r_bracket => brackets -|= 1,
        .l_brace => braces += 1,
        .r_brace => braces -|= 1,
        .comma => if (parentheses == 0 and brackets == 0 and braces == 0) return index,
        else => {},
    };
    return end;
}

fn rangeContainsTry(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    if (start >= end) return false;
    for (tokens[start..end]) |token| if (token.tag == .keyword_try) return true;
    return false;
}

fn findPartiallyInitializedOwnedFields(
    context: RuleRun,
    summary_index: ?summaries.Index,
    summaries_only: bool,
    level: types.Level,
) !void {
    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index < 3 or context.tokens[equal_index - 1].tag != .identifier or
            context.tokens[equal_index - 2].tag != .period or context.tokens[equal_index - 3].tag != .identifier) continue;
        const owner_index = equal_index - 3;
        const owner = context.tokenText(owner_index);
        if (!locallyUndefinedBindingBefore(context, owner, owner_index) and
            !locallyCreatedBindingBefore(context, owner, owner_index)) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        const acquisition = owningAcquisitionAfterEqual(
            context,
            equal_index,
            statement_end,
            summary_index,
            summaries_only,
        ) orelse continue;
        if (acquisition.kind != .allocation) continue;
        const scope_opening = context.enclosingOpeningBrace(equal_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const function_scope = functionScopeContaining(context, equal_index) orelse continue;
        const receiver = context.source[context.tokens[acquisition.release_owner_start].loc.start..context.tokens[acquisition.release_owner_end].loc.end];
        const method = context.tokenText(acquisition.method_index);
        if (std.ascii.indexOfIgnoreCase(receiver, "arena") != null or
            declarationLooksArenaBacked(context, context.tokenText(acquisition.release_owner_start), function_scope.opening, function_scope.closing) or
            functionDocumentsArenaAllocator(context, function_scope, context.tokenText(acquisition.release_owner_start)) or
            allocatorPathIsBuildArena(context, function_scope, acquisition.release_owner_start, acquisition.release_owner_end) or
            scopeDeinitializesReceiver(context, scope_opening, scope_end, context.tokenText(acquisition.release_owner_end)) or
            scopeDeinitializesReceiver(context, scope_opening, scope_end, owner)) continue;
        if (std.mem.eql(u8, method, "create") and std.ascii.indexOfIgnoreCase(receiver, "pool") != null) continue;
        const fallible_index = fallibleBeforeBindingUse(context, statement_end + 1, scope_end, owner, false) orelse continue;
        const field = context.tokenText(equal_index - 1);
        const owned_path = context.source[context.tokens[owner_index].loc.start..context.tokens[equal_index - 1].loc.end];
        const release_statement = try std.fmt.allocPrint(
            context.allocator,
            "{s}.{s}({s})",
            .{ receiver, acquisition.release, owned_path },
        );
        defer context.allocator.free(release_statement);
        const indent = lineIndent(context.source, context.tokens[owner_index].loc.start);
        const semicolon_end = context.tokens[statement_end].loc.end;
        const edits = try context.allocator.alloc(types.Edit, 1);
        if (std.mem.indexOfScalarPos(u8, context.source, semicolon_end, '\n')) |line_break| {
            edits[0] = .{
                .span = .{ .start = line_break + 1, .end = line_break + 1 },
                .replacement = try std.fmt.allocPrint(context.allocator, "{s}errdefer {s};\n", .{ indent, release_statement }),
            };
        } else {
            edits[0] = .{
                .span = .{ .start = semicolon_end, .end = semicolon_end },
                .replacement = try std.fmt.allocPrint(context.allocator, "\n{s}errdefer {s};", .{ indent, release_statement }),
            };
        }
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Add an errdefer release after the field acquisition",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
        };
        const related = try context.allocator.alloc(types.RelatedSpan, 1);
        related[0] = .{
            .span = context.tokens[fallible_index].loc,
            .message = try context.allocator.dupe(u8, "this fallible operation can abandon the partially initialized owner"),
        };
        try context.emit(.{
            .rule = .missing_errdefer,
            .level = level,
            .span = context.tokens[equal_index - 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "owned field '{s}.{s}' has no errdefer release before partial initialization can fail",
                .{ owner, field },
            ),
            .related = related,
            .fixes = fixes,
        });
    }
}

fn locallyUndefinedBindingBefore(context: RuleRun, name: []const u8, before: usize) bool {
    const scope = context.enclosingOpeningBrace(before) orelse return false;
    for (context.tokens[scope + 1 .. before], scope + 1..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 3 >= before or
            !context.tokenIs(declaration_index + 1, name)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= before) continue;
        for (context.tokens[declaration_index + 2 .. declaration_end], declaration_index + 2..) |candidate, index| {
            if (candidate.tag == .identifier and context.tokenIs(index, "undefined") and
                context.enclosingOpeningBrace(index) == scope) return true;
        }
    }
    return false;
}

fn locallyCreatedBindingBefore(context: RuleRun, name: []const u8, before: usize) bool {
    const scope = context.enclosingOpeningBrace(before) orelse return false;
    for (context.tokens[scope + 1 .. before], scope + 1..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 1 >= before or
            !context.tokenIs(declaration_index + 1, name)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= before) continue;
        const acquisition = owningAcquisition(context, declaration_index, declaration_end, null, false) orelse continue;
        if (context.tokenIs(acquisition.method_index, "create")) return true;
    }
    return false;
}

fn findCleanupCapableValuesBeforeInsertion(context: RuleRun, level: types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or !startsStatement(context, declaration_index)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const owner_type = calledReturnType(context, declaration_index + 2, declaration_end) orelse continue;
        if (!typeCleanupReleasesOwnership(context, owner_type)) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        const fallible_index = fallibleBeforeBindingUse(context, declaration_end + 1, scope_end, binding, false) orelse continue;
        const fallible_end = context.statementEnd(fallible_index) orelse continue;
        if (!callsFallibleContainerInsertion(context, statementStart(context.tokens, fallible_index), fallible_end)) continue;
        if (insertionTakesOwnershipOnFailure(
            context,
            binding,
            statementStart(context.tokens, fallible_index),
            fallible_end,
        )) continue;
        const related = try singleRelatedSpan(
            context,
            fallible_index,
            "this fallible insertion leaves the value with the caller on failure",
        );
        const message = try std.fmt.allocPrint(
            context.allocator,
            "cleanup-capable value '{s}' is not released if its container insertion fails",
            .{binding},
        );
        errdefer context.allocator.free(message);
        try context.emit(.{
            .rule = .missing_errdefer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = message,
            .related = related,
        });
    }
}

fn insertionTakesOwnershipOnFailure(
    context: RuleRun,
    binding: []const u8,
    statement_start: usize,
    statement_end: usize,
) bool {
    for (context.tokens[statement_start..statement_end], statement_start..) |token, method_index| {
        if (token.tag != .identifier or method_index + 1 >= statement_end or
            context.tokens[method_index + 1].tag != .l_paren or
            (!context.tokenIs(method_index, "append") and !context.tokenIs(method_index, "insert") and
                !context.tokenIs(method_index, "put"))) continue;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        const argument_index = bareArgumentIndex(context, binding, method_index + 2, call_end) orelse continue;
        const parameter_index = argument_index + @intFromBool(method_index > 0 and context.tokens[method_index - 1].tag == .period);
        if (functionCleansParameterBeforeInsertion(context, context.tokenText(method_index), parameter_index)) return true;
    }
    return false;
}

fn bareArgumentIndex(context: RuleRun, binding: []const u8, start: usize, end: usize) ?usize {
    var argument_index: usize = 0;
    var segment_start = start;
    var depth: usize = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const at_end = index == end;
        if (!at_end) switch (context.tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (context.tokens[index].tag != .comma or depth != 0)) continue;
        if (segment_start + 1 == index and context.tokenIs(segment_start, binding)) return argument_index;
        argument_index += 1;
        segment_start = index + 1;
    }
    return null;
}

fn functionCleansParameterBeforeInsertion(context: RuleRun, function_name: []const u8, parameter_index: usize) bool {
    var declaration_count: usize = 0;
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag == .keyword_fn and function_index + 1 < context.tokens.len and
            context.tokenIs(function_index + 1, function_name)) declaration_count += 1;
    }
    if (declaration_count != 1) return false;
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index + 2 >= context.tokens.len or
            !context.tokenIs(function_index + 1, function_name) or context.tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = context.matchingToken(function_index + 2, .l_paren, .r_paren) orelse continue;
        const parameter = parameterName(context, function_index + 3, parameters_end, parameter_index) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace and
            context.tokens[body_start].tag != .semicolon) : (body_start += 1)
        {}
        if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        const owned_name = parameterAlias(context, parameter, body_start + 1, body_end) orelse parameter;
        if (!scopeHasErrorPathCleanup(context, owned_name, body_start + 1, body_end)) continue;
        if (callsFallibleContainerInsertionWithBinding(context, owned_name, body_start + 1, body_end)) return true;
    }
    return false;
}

fn parameterName(context: RuleRun, start: usize, end: usize, wanted: usize) ?[]const u8 {
    var parameter_index: usize = 0;
    var segment_start = start;
    var depth: usize = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const at_end = index == end;
        if (!at_end) switch (context.tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (context.tokens[index].tag != .comma or depth != 0)) continue;
        if (parameter_index == wanted) {
            for (context.tokens[segment_start..index], segment_start..) |candidate, name_index| {
                if (candidate.tag == .identifier and name_index + 1 < index and
                    context.tokens[name_index + 1].tag == .colon) return context.tokenText(name_index);
            }
            return null;
        }
        parameter_index += 1;
        segment_start = index + 1;
    }
    return null;
}

fn parameterAlias(context: RuleRun, parameter: []const u8, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= end or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal or
            !context.tokenIs(declaration_index + 3, parameter)) continue;
        return context.tokenText(declaration_index + 1);
    }
    return null;
}

fn callsFallibleContainerInsertionWithBinding(context: RuleRun, binding: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or method_index + 1 >= end or context.tokens[method_index + 1].tag != .l_paren or
            (!context.tokenIs(method_index, "append") and !context.tokenIs(method_index, "insert") and
                !context.tokenIs(method_index, "put"))) continue;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        if (bareArgumentIndex(context, binding, method_index + 2, call_end) != null) return true;
    }
    return false;
}

fn statementStart(tokens: []const std.zig.Token, index: usize) usize {
    var start = index;
    while (start > 0) {
        switch (tokens[start - 1].tag) {
            .semicolon, .l_brace, .r_brace => break,
            else => start -= 1,
        }
    }
    return start;
}

fn calledReturnType(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    var equal_index = start;
    while (equal_index < end and context.tokens[equal_index].tag != .equal) : (equal_index += 1) {}
    if (equal_index == end) return null;
    var call_index = equal_index + 1;
    while (call_index < end) : (call_index += 1) switch (context.tokens[call_index].tag) {
        .keyword_try, .keyword_nosuspend => {},
        else => break,
    };
    if (call_index + 1 >= end or context.tokens[call_index].tag != .identifier) return null;
    const name = context.tokenText(call_index);
    if (context.tokens[call_index + 1].tag == .l_brace) return name;
    if (context.tokens[call_index + 1].tag != .l_paren) return null;
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 2 >= context.tokens.len or
            !context.tokenIs(fn_index + 1, name) or context.tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = context.matchingToken(fn_index + 2, .l_paren, .r_paren) orelse continue;
        var body_start = parameters_end + 1;
        var return_type: ?[]const u8 = null;
        while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {
            if (context.tokens[body_start].tag == .identifier) return_type = context.tokenText(body_start);
        }
        return return_type;
    }
    return null;
}

fn typeCleanupReleasesOwnership(context: RuleRun, type_name: []const u8) bool {
    for (context.tokens, 0..) |token, type_index| {
        if (token.tag != .identifier or !context.tokenIs(type_index, type_name) or type_index == 0 or
            context.tokens[type_index - 1].tag != .keyword_const or type_index + 3 >= context.tokens.len or
            context.tokens[type_index + 1].tag != .equal or context.tokens[type_index + 2].tag != .keyword_struct or
            context.tokens[type_index + 3].tag != .l_brace) continue;
        const body_start = type_index + 3;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        for (context.tokens[body_start + 1 .. body_end], body_start + 1..) |candidate, fn_index| {
            if (candidate.tag != .keyword_fn or fn_index + 2 >= body_end or
                !context.tokenIs(fn_index + 1, "deinit") or context.tokens[fn_index + 2].tag != .l_paren) continue;
            const parameters_end = context.matchingToken(fn_index + 2, .l_paren, .r_paren) orelse continue;
            var cleanup_start = parameters_end + 1;
            while (cleanup_start < body_end and context.tokens[cleanup_start].tag != .l_brace) : (cleanup_start += 1) {}
            if (cleanup_start >= body_end) continue;
            const cleanup_end = context.matchingToken(cleanup_start, .l_brace, .r_brace) orelse continue;
            for (context.tokens[cleanup_start + 1 .. cleanup_end], cleanup_start + 1..) |cleanup_token, method_index| {
                if (cleanup_token.tag == .identifier and
                    (context.tokenIs(method_index, "free") or context.tokenIs(method_index, "destroy") or
                        context.tokenIs(method_index, "close") or context.tokenIs(method_index, "deinit"))) return true;
            }
        }
    }
    return false;
}

fn singleRelatedSpan(context: RuleRun, index: usize, message: []const u8) ![]const types.RelatedSpan {
    const related = try context.allocator.alloc(types.RelatedSpan, 1);
    related[0] = .{ .span = context.tokens[index].loc, .message = try context.allocator.dupe(u8, message) };
    return related;
}

// `const` also appears inside pointer and slice types ("[]const u8"), where the
// following identifier is the pointee type, not a binding.
fn startsStatement(context: RuleRun, index: usize) bool {
    if (index == 0) return true;
    return switch (context.tokens[index - 1].tag) {
        .semicolon, .l_brace, .r_brace, .keyword_pub, .keyword_comptime, .keyword_export => true,
        else => false,
    };
}

const Acquisition = struct {
    kind: enum { allocation, network_stream } = .allocation,
    callable_start: usize,
    release_owner_start: usize,
    release_owner_end: usize,
    method_index: usize,
    release: []const u8 = "free",
    close_argument: ?TokenRange = null,
};

fn owningAcquisition(
    context: RuleRun,
    declaration_index: usize,
    declaration_end: usize,
    summary_index: ?summaries.Index,
    summaries_only: bool,
) ?Acquisition {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var equal_index: ?usize = null;
    var index = declaration_index + 2;
    while (index < declaration_end) : (index += 1) {
        switch (context.tokens[index].tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .equal => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                equal_index = index;
            },
            else => {},
        }
        if (equal_index != null) break;
    }
    const equal = equal_index orelse return null;
    return owningAcquisitionAfterEqual(context, equal, declaration_end, summary_index, summaries_only);
}

fn owningAcquisitionAfterEqual(
    context: RuleRun,
    equal: usize,
    declaration_end: usize,
    summary_index: ?summaries.Index,
    summaries_only: bool,
) ?Acquisition {
    if (equal + 4 >= declaration_end or context.tokens[equal + 1].tag != .keyword_try or
        context.tokens[equal + 2].tag != .identifier) return null;
    var path_end = equal + 2;
    while (path_end + 2 < declaration_end and context.tokens[path_end + 1].tag == .period and
        context.tokens[path_end + 2].tag == .identifier) path_end += 2;
    if (path_end + 1 >= declaration_end or context.tokens[path_end + 1].tag != .l_paren) return null;
    const call_close = context.matchingToken(path_end + 1, .l_paren, .r_paren) orelse return null;
    if (call_close + 1 != declaration_end) return null;
    const callable = context.source[context.tokens[equal + 2].loc.start..context.tokens[path_end].loc.end];
    if (summary_index) |known_summaries| {
        const separator = std.mem.lastIndexOfScalar(u8, callable, '.');
        const receiver = if (separator) |position| callable[0..position] else null;
        const name = if (separator) |position| callable[position + 1 ..] else callable;
        if (known_summaries.ownedReturnCall(context.source, receiver, name)) |owned| {
            if (std.mem.eql(u8, name, "alloc") and receiver != null and
                !receiverLooksLikeAllocator(context, equal + 2, path_end - 2)) return null;
            const allocator_parameter = owned.allocator_parameter orelse return null;
            const argument = callArgument(context, path_end + 2, call_close, allocator_parameter) orelse return null;
            if (!identifierPathArgument(context, argument)) return null;
            return .{
                .callable_start = equal + 2,
                .release_owner_start = argument.start,
                .release_owner_end = argument.end - 1,
                .method_index = path_end,
                .release = owned.release,
            };
        }
    }
    if (summaries_only or path_end == equal + 2) return null;
    if (std.mem.eql(u8, callable, "std.Io.net.IpAddress.connect")) {
        const io_argument = callArgument(context, path_end + 2, call_close, 1) orelse return null;
        return .{
            .kind = .network_stream,
            .callable_start = equal + 2,
            .release_owner_start = equal + 2,
            .release_owner_end = path_end - 2,
            .method_index = path_end,
            .release = "close",
            .close_argument = io_argument,
        };
    }
    const standard_allocator_argument = owned_call.standardAllocatorArgument(callable);
    if (!isAllocatingMethod(context.tokenText(path_end)) and standard_allocator_argument == null) return null;
    if (argumentsReferenceArena(context, path_end + 2, call_close)) return null;
    if (standard_allocator_argument) |argument_index| {
        const argument = callArgument(context, path_end + 2, call_close, argument_index) orelse return null;
        if (!identifierPathArgument(context, argument)) return null;
        return .{
            .callable_start = equal + 2,
            .release_owner_start = argument.start,
            .release_owner_end = argument.end - 1,
            .method_index = path_end,
            .release = owned_call.releaseForCallable(callable) orelse "free",
        };
    }
    if (std.mem.eql(u8, owned_call.releaseForMethod(context.tokenText(path_end)) orelse "", "free") and
        !receiverLooksLikeAllocator(context, equal + 2, path_end - 2)) return null;
    if (context.tokenIs(path_end, "create") and !receiverOwnsCreatedMemory(context, equal + 2, path_end - 2)) return null;
    return .{
        .callable_start = equal + 2,
        .release_owner_start = equal + 2,
        .release_owner_end = path_end - 2,
        .method_index = path_end,
        .release = owned_call.releaseForMethod(context.tokenText(path_end)) orelse "free",
    };
}

fn receiverOwnsCreatedMemory(context: RuleRun, start: usize, end: usize) bool {
    if (start > end) return false;
    const receiver = context.source[context.tokens[start].loc.start..context.tokens[end].loc.end];
    const roles = [_][]const u8{ "alloc", "gpa", "pool" };
    for (roles) |role| if (std.ascii.indexOfIgnoreCase(receiver, role) != null) return true;
    return false;
}

const TokenRange = struct { start: usize, end: usize };

fn identifierPathArgument(context: RuleRun, argument: TokenRange) bool {
    if (argument.start >= argument.end or context.tokens[argument.start].tag != .identifier) return false;
    var index = argument.start + 1;
    while (index < argument.end) : (index += 2) {
        if (index + 1 >= argument.end or context.tokens[index].tag != .period or
            context.tokens[index + 1].tag != .identifier) return false;
    }
    return true;
}

fn callArgument(context: RuleRun, start: usize, end: usize, expected_index: usize) ?TokenRange {
    var argument_index: usize = 0;
    var argument_start = start;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .comma => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                if (argument_index == expected_index) return .{ .start = argument_start, .end = index };
                argument_index += 1;
                argument_start = index + 1;
            },
            else => {},
        }
    }
    if (argument_index != expected_index or argument_start >= end) return null;
    return .{ .start = argument_start, .end = end };
}

fn argumentsReferenceArena(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and std.ascii.indexOfIgnoreCase(context.tokenText(index), "arena") != null) return true;
    }
    return false;
}

fn receiverLooksLikeAllocator(context: RuleRun, receiver_start: usize, receiver_end: usize) bool {
    const receiver_name = context.tokenText(receiver_end);
    if (std.ascii.indexOfIgnoreCase(receiver_name, "alloc") != null or
        std.ascii.indexOfIgnoreCase(receiver_name, "arena") != null or
        std.mem.eql(u8, receiver_name, "gpa")) return true;
    if (receiver_start != receiver_end) return false;
    for (context.tokens, 0..) |token, identifier_index| {
        if (token.tag != .identifier or !context.tokenIs(identifier_index, receiver_name) or
            identifier_index + 2 >= context.tokens.len or context.tokens[identifier_index + 1].tag != .colon) continue;
        var type_index = identifier_index + 2;
        while (type_index < context.tokens.len) : (type_index += 1) {
            switch (context.tokens[type_index].tag) {
                .comma, .r_paren, .equal, .semicolon, .l_brace => break,
                .identifier => if (context.tokenIs(type_index, "Allocator")) return true,
                else => {},
            }
        }
    }
    return false;
}

fn isAllocatingMethod(name: []const u8) bool {
    return owned_call.releaseForMethod(name) != null and !std.mem.eql(u8, name, "realloc");
}

fn declarationLooksArenaBacked(
    context: RuleRun,
    root_name: []const u8,
    scope_opening: usize,
    scope_end: usize,
) bool {
    return declarationLooksArenaBackedAtDepth(context, root_name, scope_opening, scope_end, 0);
}

fn declarationLooksArenaBackedAtDepth(
    context: RuleRun,
    root_name: []const u8,
    scope_opening: usize,
    scope_end: usize,
    depth: usize,
) bool {
    if (depth == 4) return false;
    for (context.tokens[scope_opening + 1 .. scope_end], scope_opening + 1..) |token, index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            index + 1 >= context.tokens.len or
            !context.tokenIs(index + 1, root_name)) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[token.loc.start..context.tokens[end].loc.end];
        if (std.mem.indexOf(u8, declaration, "ArenaAllocator") != null or
            std.mem.indexOf(u8, declaration, "FixedBufferAllocator") != null) return true;
        var value_index = index + 2;
        while (value_index + 3 < end) : (value_index += 1) {
            if (context.tokens[value_index].tag != .identifier or context.tokens[value_index + 1].tag != .period or
                !context.tokenIs(value_index + 2, "allocator") or context.tokens[value_index + 3].tag != .l_paren) continue;
            const receiver = context.tokenText(value_index);
            if (std.mem.eql(u8, receiver, root_name)) continue;
            if (declarationLooksArenaBackedAtDepth(context, receiver, scope_opening, scope_end, depth + 1)) return true;
        }
    }
    return false;
}

const ScopeRange = struct { declaration: usize, opening: usize, closing: usize };

fn functionScopeContaining(context: RuleRun, target: usize) ?ScopeRange {
    var selected: ?ScopeRange = null;
    for (context.tokens[0..target], 0..) |token, declaration_index| {
        if (token.tag != .keyword_fn and token.tag != .keyword_test) continue;
        const body_opening = if (token.tag == .keyword_fn and declaration_index + 2 < target and
            context.tokens[declaration_index + 2].tag == .l_paren)
        body: {
            const parameters_end = context.matchingToken(declaration_index + 2, .l_paren, .r_paren) orelse continue;
            break :body syntax_scope.functionBodyAfterParameters(context.tokens, parameters_end) orelse continue;
        } else body: {
            var opening = declaration_index + 1;
            while (opening < target and context.tokens[opening].tag != .l_brace and
                context.tokens[opening].tag != .semicolon) : (opening += 1)
            {}
            break :body opening;
        };
        if (body_opening >= target or context.tokens[body_opening].tag != .l_brace) continue;
        const body_closing = context.matchingToken(body_opening, .l_brace, .r_brace) orelse continue;
        if (target < body_closing) selected = .{
            .declaration = declaration_index,
            .opening = body_opening,
            .closing = body_closing,
        };
    }
    return selected;
}

fn functionDocumentsArenaAllocator(context: RuleRun, function: ScopeRange, allocator_name: []const u8) bool {
    var parameter_index = function.declaration + 1;
    while (parameter_index + 1 < function.opening) : (parameter_index += 1) {
        if (context.tokenIs(parameter_index, allocator_name) and
            context.tokens[parameter_index + 1].tag == .colon) break;
    } else return false;

    var first_doc = function.declaration;
    while (first_doc > 0 and (context.tokens[first_doc - 1].tag == .doc_comment or
        context.tokens[first_doc - 1].tag == .container_doc_comment)) first_doc -= 1;
    if (first_doc == function.declaration) return false;
    const documentation = context.source[context.tokens[first_doc].loc.start..context.tokens[function.declaration].loc.start];
    return std.ascii.indexOfIgnoreCase(documentation, "allocator should be an arena") != null;
}

fn functionParameterIsAllocator(context: RuleRun, function: ScopeRange, parameter_name: []const u8) bool {
    var index = function.declaration + 1;
    while (index + 2 < function.opening) : (index += 1) {
        if (!context.tokenIs(index, parameter_name) or context.tokens[index + 1].tag != .colon) continue;
        var type_index = index + 2;
        while (type_index < function.opening and context.tokens[type_index].tag != .comma and
            context.tokens[type_index].tag != .r_paren) : (type_index += 1)
        {
            if (context.tokens[type_index].tag == .identifier and context.tokenIs(type_index, "Allocator")) return true;
        }
        return false;
    }
    return false;
}

fn functionParameterReceivesOnlyArena(
    context: RuleRun,
    function: ScopeRange,
    parameter_name: []const u8,
    depth: usize,
) bool {
    if (depth == 8 or function.declaration + 2 >= function.opening or
        context.tokens[function.declaration + 1].tag != .identifier) return false;
    if (function.declaration > 0 and context.tokens[function.declaration - 1].tag == .keyword_pub) return false;
    const parameter_index = functionParameterIndex(context, function, parameter_name) orelse return false;
    const function_name = context.tokenText(function.declaration + 1);
    var found_call = false;
    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or !context.tokenIs(call_index, function_name)) continue;
        if (call_index > 0 and context.tokens[call_index - 1].tag == .keyword_fn) continue;
        if (call_index + 1 >= context.tokens.len or context.tokens[call_index + 1].tag != .l_paren or
            (call_index > 0 and context.tokens[call_index - 1].tag == .period)) return false;
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse return false;
        const argument = callArgument(context, call_index + 2, call_end, parameter_index) orelse return false;
        if (!callArgumentIsArenaBacked(context, argument, call_index, depth + 1)) return false;
        found_call = true;
    }
    return found_call;
}

fn functionParameterIndex(context: RuleRun, function: ScopeRange, parameter_name: []const u8) ?usize {
    var index: usize = 0;
    while (parameterName(context, function.declaration + 3, function.opening, index)) |name| : (index += 1) {
        if (std.mem.eql(u8, name, parameter_name)) return index;
    }
    return null;
}

fn callArgumentIsArenaBacked(context: RuleRun, argument: TokenRange, call_index: usize, depth: usize) bool {
    if (argument.start >= argument.end) return false;
    for (context.tokens[argument.start..argument.end], argument.start..) |token, index| {
        if (token.tag == .identifier and std.ascii.indexOfIgnoreCase(context.tokenText(index), "arena") != null) return true;
    }
    if (argument.start + 1 != argument.end or context.tokens[argument.start].tag != .identifier) return false;
    const argument_name = context.tokenText(argument.start);
    const caller = functionScopeContaining(context, call_index) orelse return false;
    if (declarationLooksArenaBacked(context, argument_name, caller.opening, caller.closing)) return true;
    if (!functionParameterIsAllocator(context, caller, argument_name)) return false;
    return functionParameterReceivesOnlyArena(context, caller, argument_name, depth);
}

fn allocatorPathIsBuildArena(
    context: RuleRun,
    function: ScopeRange,
    path_start: usize,
    path_end: usize,
) bool {
    if (path_end != path_start + 2 or context.tokens[path_start].tag != .identifier or
        context.tokens[path_start + 1].tag != .period or !context.tokenIs(path_start + 2, "allocator")) return false;
    const receiver = context.tokenText(path_start);
    var index = function.declaration + 1;
    while (index + 4 < function.opening) : (index += 1) {
        if (!context.tokenIs(index, receiver) or context.tokens[index + 1].tag != .colon) continue;
        var type_index = index + 2;
        while (type_index + 2 < function.opening and context.tokens[type_index].tag != .comma and
            context.tokens[type_index].tag != .r_paren) : (type_index += 1)
        {
            if (context.tokenIs(type_index, "std") and context.tokens[type_index + 1].tag == .period and
                context.tokenIs(type_index + 2, "Build")) return true;
        }
        return false;
    }
    return false;
}

fn scopeDeinitializesReceiver(context: RuleRun, scope_opening: usize, scope_end: usize, receiver_segment: []const u8) bool {
    var index = scope_opening + 1;
    while (index + 3 < scope_end) : (index += 1) {
        const tag = context.tokens[index].tag;
        if (tag != .keyword_defer and tag != .keyword_errdefer) continue;
        const body_end = if (context.tokens[index + 1].tag == .l_brace)
            context.matchingToken(index + 1, .l_brace, .r_brace) orelse scope_end
        else
            context.statementEnd(index + 1) orelse scope_end;
        var body_index = index + 1;
        while (body_index + 2 < @min(body_end, scope_end)) : (body_index += 1) {
            if (context.tokens[body_index].tag == .identifier and
                context.tokenIs(body_index, receiver_segment) and
                context.tokens[body_index + 1].tag == .period and
                context.tokenIs(body_index + 2, "deinit")) return true;
        }
        index = @min(body_end, scope_end - 1);
    }
    return false;
}

fn scopeHasErrorPathCleanup(context: RuleRun, binding: []const u8, start: usize, scope_end: usize) bool {
    const scope = context.enclosingOpeningBrace(start) orelse return false;
    for (context.tokens[start..scope_end], start..) |token, defer_index| {
        if ((token.tag != .keyword_defer and token.tag != .keyword_errdefer) or
            context.enclosingOpeningBrace(defer_index) != scope or
            defer_index + 1 >= scope_end or context.tokens[defer_index + 1].tag == .keyword_if) continue;
        const body_end = if (defer_index + 1 < scope_end and context.tokens[defer_index + 1].tag == .l_brace)
            context.matchingToken(defer_index + 1, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(defer_index + 1) orelse continue;
        for (context.tokens[defer_index + 1 .. @min(body_end, scope_end)], defer_index + 1..) |candidate, index| {
            if (candidate.tag != .identifier or !context.tokenIs(index, binding)) continue;
            if (index + 2 < body_end and context.tokens[index + 1].tag == .period and
                context.tokens[index + 2].tag == .identifier)
            {
                const method = context.tokenText(index + 2);
                if (std.mem.eql(u8, method, "deinit") or std.mem.eql(u8, method, "close") or
                    std.mem.eql(u8, method, "release")) return true;
            }
        }
        for (context.tokens[defer_index + 1 .. @min(body_end, scope_end)], defer_index + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or
                (!context.tokenIs(method_index, "free") and !context.tokenIs(method_index, "destroy")) or
                method_index + 1 >= body_end or context.tokens[method_index + 1].tag != .l_paren) continue;
            const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
            for (context.tokens[method_index + 2 .. @min(call_end, body_end)], method_index + 2..) |argument, argument_index| {
                if (argument.tag == .identifier and context.tokenIs(argument_index, binding)) return true;
            }
        }
    }
    return false;
}

fn fallibleBeforePlainCleanup(
    context: RuleRun,
    start: usize,
    scope_end: usize,
    binding: []const u8,
    release: []const u8,
) ?usize {
    const scope = context.enclosingOpeningBrace(start) orelse return null;
    for (context.tokens[start..scope_end], start..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, release) or
            method_index + 1 >= scope_end or context.tokens[method_index + 1].tag != .l_paren or
            context.enclosingOpeningBrace(method_index) != scope) continue;
        const statement_start = statementStart(context.tokens, method_index);
        if (rangeContainsToken(context.tokens, statement_start, method_index, .keyword_defer) or
            rangeContainsToken(context.tokens, statement_start, method_index, .keyword_errdefer)) continue;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        if (!callArgumentsContainBinding(context, method_index + 2, call_end, binding)) continue;
        return firstFallibleOperation(context, start, statement_start);
    }
    return null;
}

fn rangeContainsToken(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) bool {
    if (start >= end) return false;
    for (tokens[start..end]) |token| if (token.tag == tag) return true;
    return false;
}

fn callArgumentsContainBinding(context: RuleRun, start: usize, end: usize, binding: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, binding)) return true;
    }
    return false;
}

fn firstFallibleOperation(context: RuleRun, start: usize, end: usize) ?usize {
    var index = start;
    while (index < end) : (index += 1) {
        if (context.tokens[index].tag == .keyword_fn) {
            var body_start = index + 1;
            while (body_start < end and context.tokens[body_start].tag != .l_brace and
                context.tokens[body_start].tag != .semicolon) : (body_start += 1)
            {}
            if (body_start < end and context.tokens[body_start].tag == .l_brace) {
                index = context.matchingToken(body_start, .l_brace, .r_brace) orelse return null;
                continue;
            }
        }
        if (context.tokens[index].tag == .keyword_try or
            (context.tokens[index].tag == .keyword_return and returnsExplicitError(context, index, end))) return index;
    }
    return null;
}

fn fallibleBeforeBindingUse(
    context: RuleRun,
    start: usize,
    scope_end: usize,
    binding: []const u8,
    allow_writer_view: bool,
) ?usize {
    var cursor = start;
    while (cursor < scope_end) {
        const end = context.statementEnd(cursor) orelse return null;
        if (end >= scope_end) return null;
        const borrowing_call = callsBorrowingBufferMethod(context, cursor, end);
        var fallible_index: ?usize = null;
        var error_return_index: ?usize = null;
        for (context.tokens[cursor .. end + 1], cursor..) |chunk_token, chunk_index| {
            switch (chunk_token.tag) {
                .keyword_return => if (returnsExplicitError(context, chunk_index, end)) {
                    error_return_index = chunk_index;
                },
                // A nested function declaration's body does not execute here, so a
                // 'try' inside it is not a fallible operation on this path.
                .keyword_fn => return null,
                .keyword_try => if (fallible_index == null) {
                    fallible_index = chunk_index;
                },
                else => {},
            }
        }
        for (context.tokens[cursor .. end + 1], cursor..) |chunk_token, chunk_index| {
            if (chunk_token.tag != .identifier or !context.tokenIs(chunk_index, binding)) continue;
            if (error_return_index != null) continue;
            if (fallible_index != null and (borrowing_call or
                callsFallibleContainerInsertion(context, cursor, end) or
                bindingUseIsBorrowed(context, chunk_index, end))) return fallible_index;
            if (allow_writer_view and callsMethod(context, cursor, end, "writer")) continue;
            if (borrowing_call) continue;
            return null;
        }
        if (error_return_index) |found| return found;
        if (fallible_index) |found| return found;
        cursor = end + 1;
    }
    return null;
}

fn returnsExplicitError(context: RuleRun, return_index: usize, end: usize) bool {
    return return_index + 1 < end and context.tokens[return_index + 1].tag == .keyword_error;
}

fn bindingUseIsBorrowed(context: RuleRun, index: usize, end: usize) bool {
    return index + 2 < end and context.tokens[index + 1].tag == .period and
        context.tokens[index + 2].tag == .identifier;
}

fn callsMethod(context: RuleRun, start: usize, end: usize, expected: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, expected) and
            index + 1 < end and context.tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

fn callsBorrowingBufferMethod(context: RuleRun, start: usize, end: usize) bool {
    const borrowing_methods = [_][]const u8{
        "read",
        "readAll",
        "readAtLeast",
        "readNoEof",
        "readPositional",
        "write",
        "writeAll",
        "writeStreamingAll",
        "print",
        "createFile",
        "openFile",
        "deleteFile",
        "rename",
    };
    for (borrowing_methods) |method| if (callsMethod(context, start, end, method)) return true;
    return false;
}

fn callsFallibleContainerInsertion(context: RuleRun, start: usize, end: usize) bool {
    const insertion_methods = [_][]const u8{ "append", "appendSlice", "put", "insert" };
    for (insertion_methods) |method| if (callsMethod(context, start, end, method)) return true;
    return false;
}

fn lineIndent(source: []const u8, offset: usize) []const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |newline| newline + 1 else 0;
    var end = line_start;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    return source[line_start..end];
}

test "allocation followed by another fallible operation without errdefer leaks on the error path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    const node = try allocator.create(u32);\n" ++
        "    try fill(buffer, node);\n" ++
        "}\n" ++
        "fn init(allocator: std.mem.Allocator) !void {\n" ++
        "    const node = try allocator.create(u32);\n" ++
        "    const extra = try allocator.alloc(u8, 2);\n" ++
        "    use(node, extra);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'buffer'") != null);
    try std.testing.expectEqualStrings("    errdefer allocator.free(buffer);\n", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "'node'") != null);
    try std.testing.expectEqualStrings("    errdefer allocator.destroy(node);\n", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expect(!findings[0].fixes[0].fix_all);
}

test "released transferred arena-backed and final allocations stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn released(allocator: std.mem.Allocator) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    errdefer allocator.free(buffer);\n" ++
        "    const extra = try allocator.alloc(u8, 4);\n" ++
        "    defer allocator.free(extra);\n" ++
        "    try flush(buffer, extra);\n" ++
        "}\n" ++
        "fn stored(gpa: std.mem.Allocator, sink: *Sink) !void {\n" ++
        "    const owned = try gpa.dupe(u8, \"name\");\n" ++
        "    sink.value = owned;\n" ++
        "    try sink.commit();\n" ++
        "}\n" ++
        "fn scratch(gpa: std.mem.Allocator) !void {\n" ++
        "    var arena_state = std.heap.ArenaAllocator.init(gpa);\n" ++
        "    defer arena_state.deinit();\n" ++
        "    const scratch_allocator = arena_state.allocator();\n" ++
        "    const scratch_bytes = try scratch_allocator.alloc(u8, 4);\n" ++
        "    const more = try scratch_allocator.alloc(u8, 4);\n" ++
        "    try consume(scratch_bytes, more);\n" ++
        "}\n" ++
        "fn last(allocator: std.mem.Allocator) ![]u8 {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    return buffer;\n" ++
        "}\n" ++
        "fn block(allocator: std.mem.Allocator) !void {\n" ++
        "    const pair = try allocator.alloc(u8, 2);\n" ++
        "    defer {\n" ++
        "        allocator.free(pair);\n" ++
        "    }\n" ++
        "    try flush(pair, pair);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "allocator parameters fed only by an arena stay clean through private calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn main() !void { var arena_state = std.heap.ArenaAllocator.init(gpa); defer arena_state.deinit();" ++
        "const arena_allocator = arena_state.allocator(); try render(arena_allocator); }" ++
        "fn render(allocator: std.mem.Allocator) !void { try tokenize(allocator); }" ++
        "fn tokenize(allocator: std.mem.Allocator) !void { const source = try allocator.dupeZ(u8, \"text\"); try write(source); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "public allocator parameters retain their cleanup contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn main() !void { var arena_state = std.heap.ArenaAllocator.init(gpa); defer arena_state.deinit();" ++
        "try render(arena_state.allocator()); }" ++
        "pub fn render(allocator: std.mem.Allocator) !void { const source = try allocator.dupeZ(u8, \"text\"); try write(source); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "allocations reclaimed by a deferred pool deinit stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: std.mem.Allocator) !void {\n" ++
        "    var pool: MemoryPool = .empty;\n" ++
        "    defer pool.deinit(a);\n" ++
        "    const first = try pool.create(a);\n" ++
        "    const second = try pool.create(a);\n" ++
        "    use(first, second);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "pool-owned allocations do not require individual error cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn start(self: anytype) !void {\n" ++
        "    const completion = try self.completion_pool.create(self.allocator);\n" ++
        "    try self.socket.bind();\n" ++
        "    use(completion);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a try inside a nested function declaration is not a fallible operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    const Helper = struct {\n" ++
        "        fn fill() !void { try refill(); }\n" ++
        "    };\n" ++
        "    Helper.fill() catch {};\n" ++
        "    allocator.free(buffer);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a multiline typed acquisition with errdefer on the next line stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(gpa: std.mem.Allocator, options: Options) !void {\n" ++
        "    const exe_path: []const u8 = try gpa.dupe(\n" ++
        "        u8,\n" ++
        "        options.prebuilt orelse fallback.?,\n" ++
        "    );\n" ++
        "    errdefer gpa.free(exe_path);\n" ++
        "    try shell.exec(exe_path);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "standard allocation helpers require error-path cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator, parts: []const []const u8) !void {\n" ++
        "    const joined = try std.mem.concat(allocator, u8, parts);\n" ++
        "    _ = try writer.write(joined);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("    errdefer allocator.free(joined);\n", findings[0].fixes[0].edits[0].replacement);
}

test "standard allocation helpers preserve allocator field provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(self: *State) !void {\n" ++
        "    const path = try std.fmt.allocPrint(self.allocator, \"{s}\", .{self.name});\n" ++
        "    _ = try self.writer.write(path);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("    errdefer self.allocator.free(path);\n", findings[0].fixes[0].edits[0].replacement);
}

test "standard build allocator fields are arena backed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn configure(b: *std.Build, flags: *Flags) !void {\n" ++
        "    const define = try std.fmt.allocPrint(b.allocator, \"-D{s}\", .{\"DEBUG\"});\n" ++
        "    try flags.append(b.allocator, define);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "fallible reads borrow their destination allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn readFrame(reader: anytype, allocator: std.mem.Allocator, length: usize) ![]u8 {\n" ++
        "    const payload = try allocator.alloc(u8, length);\n" ++
        "    try reader.readNoEof(payload);\n" ++
        "    return payload;\n" ++
        "}\n" ++
        "fn readCopy(file: anytype, io: anytype, allocator: std.mem.Allocator) ![]u8 {\n" ++
        "    const scratch = try allocator.alloc(u8, 1024);\n" ++
        "    const length = try file.readPositional(io, &.{scratch}, 0);\n" ++
        "    return try allocator.dupe(u8, scratch[0..length]);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "scratch") != null);
}

test "plain cleanup after a fallible operation does not protect the error path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn copyStream(allocator: std.mem.Allocator, reader: anytype, writer: anytype) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 16);\n" ++
        "    var view = buffer;\n" ++
        "    while (view.len > 0) {\n" ++
        "        const count = try reader.read(view);\n" ++
        "        try writer.writeAll(view[0..count]);\n" ++
        "        view = view[count..];\n" ++
        "    }\n" ++
        "    allocator.free(buffer);\n" ++
        "}\n" ++
        "fn main(allocator: std.mem.Allocator) !void {\n" ++
        "    const output = try allocator.alloc(u8, 64);\n" ++
        "    var writer = Writer{ .output = output };\n" ++
        "    try writer.flush();\n" ++
        "    allocator.free(output);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "output") != null);
}

test "a deferred cleanup block protects allocations before later errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn collect(allocator: std.mem.Allocator) !void { const values = try allocator.alloc(Value, 4);" ++
        "defer { for (values) |*value| value.deinit(allocator); defer allocator.free(values); } try write(values); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a deferred cleanup block protects summarized owned returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn collect(allocator: std.mem.Allocator) ![]Value { return allocator.alloc(Value, 4); }" ++
        "fn run(allocator: std.mem.Allocator) !void { const values = try collect(allocator);" ++
        "defer { for (values) |*value| value.deinit(allocator); allocator.free(values); } try write(values); }";
    const tokens = try tokenize(arena.allocator(), source);
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source, .tokens = tokens }};
    var summary_index = try summaries.build(arena.allocator(), &sources, types.Configuration.defaults());
    defer summary_index.deinit(arena.allocator());
    var findings: std.ArrayList(types.Finding) = .empty;
    try runWithSummaries(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    }, summary_index);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "owned values need cleanup before early errors and fallible insertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn enqueue(allocator: std.mem.Allocator, jobs: *Jobs, closed: bool) !void {\n" ++
        "    const copy = try allocator.dupe(u8, \"job\");\n" ++
        "    if (closed) return error.QueueClosed;\n" ++
        "    try jobs.append(allocator, copy);\n" ++
        "}\n" ++
        "fn insert(allocator: std.mem.Allocator, jobs: *Jobs) !void {\n" ++
        "    const copy = try allocator.dupe(u8, \"job\");\n" ++
        "    try jobs.append(allocator, copy);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("    errdefer allocator.free(copy);\n", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("    errdefer allocator.free(copy);\n", findings[1].fixes[0].edits[0].replacement);
}

test "partially initialized owned fields need error cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Statement = struct { name: []u8, value: usize };\n" ++
        "fn parse(allocator: std.mem.Allocator) !Statement {\n" ++
        "    var statement: Statement = undefined;\n" ++
        "    statement.name = try allocator.dupe(u8, \"name\");\n" ++
        "    statement.value = try parseValue();\n" ++
        "    return statement;\n" ++
        "}\n" ++
        "fn update(self: *Owner, allocator: std.mem.Allocator) !void {\n" ++
        "    self.name = try allocator.dupe(u8, \"name\");\n" ++
        "    try finish();\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "statement.name") != null);
    try std.testing.expectEqualStrings(
        "    errdefer allocator.free(statement.name);\n",
        findings[0].fixes[0].edits[0].replacement,
    );
}

test "partially initialized created objects need field cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Object = struct { label: []u8, payload: []u8 };\n" ++
        "fn insert(allocator: std.mem.Allocator, objects: *Objects) !void {\n" ++
        "    const object = try allocator.create(Object);\n" ++
        "    object.label = try allocator.dupe(u8, \"label\");\n" ++
        "    object.payload = try allocator.dupe(u8, \"payload\");\n" ++
        "    try objects.append(allocator, object);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "object.label") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[2].message, "object.payload") != null);
}

test "fallible aggregate fields need cleanup before later field initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Contact = struct { name: []u8, email: []u8, phone: []u8, " ++
        "fn deinit(self: Contact, allocator: std.mem.Allocator) void { allocator.free(self.name); allocator.free(self.email); allocator.free(self.phone); } };\n" ++
        "fn add(allocator: std.mem.Allocator, contacts: *List, input: Input) !void {\n" ++
        "    const contact = Contact{\n" ++
        "        .name = try allocator.dupe(u8, input.name),\n" ++
        "        .email = try allocator.dupe(u8, input.email),\n" ++
        "        .phone = try allocator.dupe(u8, input.phone),\n" ++
        "    };\n" ++
        "    try contacts.append(allocator, contact);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    var aggregate_field_count: usize = 0;
    var insertion_count: usize = 0;
    for (findings) |finding| {
        if (std.mem.indexOf(u8, finding.message, "later aggregate field") != null) aggregate_field_count += 1;
        if (std.mem.indexOf(u8, finding.message, "container insertion") != null) insertion_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), aggregate_field_count);
    try std.testing.expectEqual(@as(usize, 1), insertion_count);
}

test "fallible container builders need cleanup before ownership transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn encode(allocator: std.mem.Allocator, first: []const u8, second: []const u8) ![]u8 {" ++
        "var bytes: std.ArrayList(u8) = .empty; try bytes.appendSlice(allocator, first);" ++
        "try bytes.appendSlice(allocator, second); return bytes.toOwnedSlice(allocator); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "backing allocation") != null);
}

test "container builders with early error cleanup stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn encode(allocator: std.mem.Allocator, first: []const u8, second: []const u8) ![]u8 {" ++
        "var bytes: std.ArrayList(u8) = .empty; errdefer bytes.deinit(allocator);" ++
        "try bytes.appendSlice(allocator, first); try bytes.appendSlice(allocator, second);" ++
        "return bytes.toOwnedSlice(allocator); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "arena-backed container builders do not need individual cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn encode(arena_allocator: std.mem.Allocator, first: []const u8, second: []const u8) ![]u8 {" ++
        "var bytes: std.ArrayList(u8) = .empty; try bytes.appendSlice(arena_allocator, first);" ++
        "try bytes.appendSlice(arena_allocator, second); return bytes.toOwnedSlice(arena_allocator); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "debug allocators do not suppress container builder cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn main() !void { var debug_allocator: std.heap.DebugAllocator(.{}) = .init;" ++
        "const allocator = debug_allocator.allocator(); _ = try encode(allocator, \"a\", \"b\"); }" ++
        "fn encode(allocator: std.mem.Allocator, first: []const u8, second: []const u8) ![]u8 {" ++
        "var bytes: std.ArrayList(u8) = .empty; try bytes.appendSlice(allocator, first);" ++
        "try bytes.appendSlice(allocator, second); return bytes.toOwnedSlice(allocator); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "single non-repeating container mutation stays below conservative builder threshold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn encode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {" ++
        "var output: std.ArrayList(u8) = .empty; try output.appendSlice(allocator, bytes);" ++
        "return output.toOwnedSlice(allocator); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "nested function mutations do not change an outer builder summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn encode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {" ++
        "var bytes: std.ArrayList(u8) = .empty; const Nested = struct {" ++
        "fn fill(a: std.mem.Allocator, input: []const u8) !void { var bytes: std.ArrayList(u8) = .empty;" ++
        "try bytes.appendSlice(a, input); try bytes.appendSlice(a, input); bytes.clearAndFree(a); } }; _ = Nested;" ++
        "try bytes.appendSlice(allocator, input); return bytes.toOwnedSlice(allocator); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "an enclosing runtime loop does not make a nested function mutation repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(parts: []const []const u8) void { for (parts) |_| { const Local = struct {" ++
        "fn encode(allocator: std.mem.Allocator, input: []const u8) ![]u8 { var output: std.ArrayList(u8) = .empty;" ++
        "try output.appendSlice(allocator, input); return output.toOwnedSlice(allocator); } }; _ = Local; } }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "container mutation in a loop needs cleanup before ownership transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn encode(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {" ++
        "var output: std.ArrayList(u8) = .empty;" ++
        "for (parts) |part| try output.appendSlice(allocator, part);" ++
        "return output.toOwnedSlice(allocator); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "backing allocation") != null);
}

test "reallocated slice builders need error cleanup across loop iterations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn encode(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {" ++
        "var output: []u8 = &.{}; for (parts) |part| {" ++
        "output = try allocator.realloc(output, output.len + part.len); try validate(part); }" ++
        "return output; }";
    const findings = try findingsFor(arena.allocator(), source);
    var builder_count: usize = 0;
    for (findings) |finding| {
        if (std.mem.indexOf(u8, finding.message, "slice builder") != null) builder_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), builder_count);
}

test "reallocated slice builders with errdefer stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn encode(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {" ++
        "var output: []u8 = &.{}; errdefer allocator.free(output); for (parts) |part| {" ++
        "output = try allocator.realloc(output, output.len + part.len); try validate(part); }" ++
        "return output; }";
    const findings = try findingsFor(arena.allocator(), source);
    for (findings) |finding| try std.testing.expect(std.mem.indexOf(u8, finding.message, "slice builder") == null);
}

test "anonymous fallible aggregate fields need cleanup before later fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(allocator: std.mem.Allocator, input: Input) !Record { return .{" ++
        ".name = try allocator.dupe(u8, input.name), .value = try allocator.dupe(u8, input.value) }; }" ++
        "fn add(allocator: std.mem.Allocator, list: *List, input: Input) !void { try list.append(allocator, .{" ++
        ".name = try allocator.dupe(u8, input.name), .value = try allocator.dupe(u8, input.value) }); }";
    const findings = try findingsFor(arena.allocator(), source);
    var aggregate_field_count: usize = 0;
    for (findings) |finding| {
        if (std.mem.indexOf(u8, finding.message, "aggregate field") != null) aggregate_field_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), aggregate_field_count);
}

test "cleanup capable aggregates need error cleanup before insertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Statement = struct { name: []u8, fn deinit(self: Statement, allocator: anytype) void { allocator.free(self.name); } };\n" ++
        "fn parseStatement() !Statement { return undefined; }\n" ++
        "fn parseFile(allocator: anytype, statements: anytype) !void {\n" ++
        "    const statement = parseStatement() catch return;\n" ++
        "    try statements.append(allocator, statement);\n" ++
        "}\n" ++
        "fn safe(allocator: anytype, statements: anytype) !void {\n" ++
        "    const statement = parseStatement() catch return;\n" ++
        "    errdefer statement.deinit(allocator);\n" ++
        "    try statements.append(allocator, statement);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "statement") != null);
}

test "block initializers do not inherit a nested call return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Statement = struct { name: []u8, fn deinit(self: Statement, allocator: anytype) void { allocator.free(self.name); } };" ++
        "fn parseStatement() !Statement { return undefined; }" ++
        "fn parseBorrowed(list: anytype) !void { const name = block: { break :block try source.getName(); }; try list.append(name); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "insertion wrappers may consume values on both success and failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Registry = struct { sessions: List, allocator: std.mem.Allocator," ++
        "fn append(self: *Registry, session: Session) !void { var owned_session = session;" ++
        "errdefer owned_session.deinit(self.allocator); try self.sessions.append(self.allocator, owned_session); } };" ++
        "fn start(registry: *Registry) !void { const session = try startSession(); try registry.append(session); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "an unrelated arena allocator does not hide error paths in other functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator, fail: bool) !void {" ++
        "const bytes = try allocator.alloc(u8, 8);" ++
        "if (fail) return error.Failed;" ++
        "allocator.free(bytes);" ++
        "}" ++
        "test { var arena = std.heap.ArenaAllocator.init(std.testing.allocator);" ++
        "defer arena.deinit(); const allocator = arena.allocator(); _ = allocator; }";
    const found = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.missing_errdefer, found[0].rule);
}

test "an arena allocator declared outside a loop covers loop allocations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "test { var local_arena = std.heap.ArenaAllocator.init(std.testing.allocator);" ++
        "defer local_arena.deinit(); const allocator = local_arena.allocator(); var i: usize = 0;" ++
        "while (i < 2) : (i += 1) { const bytes = try allocator.alloc(u8, 8); try consume(bytes); } }";
    const found = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "returned network streams require error-path cleanup before fallible writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn connect(io: std.Io, address: std.Io.net.IpAddress) !std.Io.net.Stream {\n" ++
        "    const stream = try std.Io.net.IpAddress.connect(&address, io, .{});\n" ++
        "    var stream_writer = stream.writer(io, &.{});\n" ++
        "    try stream_writer.interface.writeAll(\"request\");\n" ++
        "    return stream;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("    errdefer stream.close(io);\n", findings[0].fixes[0].edits[0].replacement);
}

test "dupe on a non-allocator receiver does not invent allocator provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn complete(tuple_info: anytype, arena_allocator: std.mem.Allocator, ip: anytype) !void {\n" ++
        "    const tuple_types = try tuple_info.types.dupe(arena_allocator, ip);\n" ++
        "    try render(tuple_types);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "alloc on an unproven custom receiver does not invent allocator provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn exercise(bm: anytype, buffer: []u8) !void { const value = try bm.alloc(u8, buffer, 1);" ++
        "try std.testing.expect(value.len == 1); }";
    const found = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "external create methods do not imply caller-owned memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn register(display: *Display) !void { const manager = try protocol.Manager.create(display); try publish(manager); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "constructors passed an arena do not require individual error cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(context: anytype) !void {\n" ++
        "    const node = try ZigTag.node.create(context.state.arena, .{});\n" ++
        "    try render(node);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "storage allocators existing errdefers and owner errdefers stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn root(allocator: std.mem.Allocator) !void { var arena_state = std.heap.ArenaAllocator.init(allocator);" ++
        "defer arena_state.deinit(); _ = try parse(arena_state.allocator()); }" ++
        "fn parse(storage: std.mem.Allocator) ![]u8 { const bytes = try storage.alloc(u8, 4); try fill(bytes); return bytes; }" ++
        "fn create(allocator: std.mem.Allocator) !void { var object = try Object.create(allocator);" ++
        "errdefer object.deinit(); try object.load(); }" ++
        "fn init(allocator: std.mem.Allocator) !*Owner { const self = try allocator.create(Owner);" ++
        "errdefer self.deinit(); self.values = try allocator.alloc(u8, 4); try finish(self); return self; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "standard build creation is owned by the build graph arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(graph: *std.Build.Graph) !void { const builder = try std.Build.create(.{ .graph = graph }); try configure(builder); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "documented arena allocator contracts do not require individual error cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "/// The allocator should be an arena because returned pointers share its lifetime.\n" ++
        "fn build(alloc: std.mem.Allocator) ![]u8 { const bytes = try alloc.alloc(u8, 8);" ++
        "try consume(bytes); return bytes; }";
    const found = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "missing errdefer diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator) !void {\n" ++
        "    // zig-analyzer: disable-next-line missing-errdefer\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    const node = try allocator.create(u32);\n" ++
        "    try fill(buffer, node);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
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
