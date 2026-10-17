const std = @import("std");
const statementStart = @import("../../syntax/tokens.zig").statementStart;
const syntax_scope = @import("../../syntax/scope.zig");
const RuleRun = @import("../context.zig").RuleRun;
const container_types = @import("../container_types.zig");
const owned_call = @import("../owned_call.zig");
const resources = @import("../resources.zig");
const summaries = @import("../summaries.zig");
const types = @import("../types.zig");
const tokenize = @import("../../syntax/tokens.zig").tokenize;
const support = @import("../test_support.zig");
const TokenRange = @import("../../syntax/tokens.zig").Range;
const IdentifierTable = syntax_scope.IdentifierTable;

pub const rules = [_]types.Rule{
    .missing_errdefer,
};

pub fn run(context: RuleRun) !void {
    try runInternal(context, null, .local);
}

pub fn runWithSummaries(context: RuleRun, summary_index: summaries.Index) !void {
    try runInternal(context, summary_index, .summaries);
}

const AnalysisPass = enum { local, summaries };

fn runInternal(context: RuleRun, summary_index: ?summaries.Index, pass: AnalysisPass) !void {
    const level = context.level(.missing_errdefer);
    if (level == .off) return;
    var lookups: Lookups = .{
        .identifiers = try context.scopes.identifiers(),
        .function_keywords = try functionKeywords(context),
    };
    defer lookups.deinit(context.allocator);

    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        if (!startsStatement(context, declaration_index)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const acquisition = try owningAcquisition(context, &lookups, declaration_index, declaration_end, summary_index, pass) orelse continue;
        // A leak in a test is reported by `std.testing.allocator` itself.
        if (context.scopes.insideTestBlock(declaration_index)) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const function_scope = functionScopeContaining(context, lookups.function_keywords, declaration_index) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        const receiver = context.source[context.tokens[acquisition.release_owner_start].loc.start..context.tokens[acquisition.release_owner_end].loc.end];
        const callable = context.source[context.tokens[acquisition.callable_start].loc.start..context.tokens[acquisition.method_index].loc.end];
        const method = context.tokenText(acquisition.method_index);
        if (acquisition.kind == .allocation and std.mem.eql(u8, callable, "std.Build.create")) continue;
        if (acquisition.kind == .allocation and acquisitionUsesNamedArena(receiver, acquisition)) continue;
        if (acquisition.kind == .allocation and std.mem.eql(u8, method, "create") and std.ascii.findIgnoreCase(receiver, "pool") != null) continue;
        if (acquisition.kind == .allocation and try declarationLooksArenaBacked(
            context,
            &lookups,
            context.tokenText(acquisition.release_owner_start),
            function_scope.opening,
            function_scope.closing,
        )) continue;
        if (acquisition.kind == .allocation and functionDocumentsArenaAllocator(
            context,
            function_scope,
            context.tokenText(acquisition.release_owner_start),
        )) continue;
        if (acquisition.kind == .allocation and try functionParameterReceivesOnlyArena(
            context,
            &lookups,
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
        if (acquisition.kind == .allocation and acquisitionUsesArenaContract(context, function_scope, acquisition)) continue;
        // 'defer pool.deinit(...)' reclaims everything the pool handed out,
        // error path included.
        if (acquisition.kind == .allocation and
            try scopeDeinitializesReceiver(context, &lookups, scope_opening, scope_end, context.tokenText(acquisition.release_owner_end))) continue;
        const fallible_index = fallibleBeforeBindingUse(
            context,
            declaration_end + 1,
            scope_end,
            binding_name,
            acquisition.kind == .network_stream,
        ) orelse try fallibleBeforePlainCleanup(
            context,
            &lookups,
            declaration_end + 1,
            scope_end,
            binding_name,
            acquisition.release,
        ) orelse continue;
        if (scopeHasErrorPathCleanup(context, binding_name, null, declaration_end + 1, fallible_index)) continue;

        const release_statement = switch (acquisition.kind) {
            .allocation => if (acquisition.release_owner_member) |member|
                try context.allocator.print("{s}.{s}.{s}({s})", .{ receiver, member, acquisition.release, binding_name })
            else
                try context.allocator.print("{s}.{s}({s})", .{ receiver, acquisition.release, binding_name }),
            .network_stream => try context.allocator.print(
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
        if (std.mem.findScalarPos(u8, context.source, semicolon_end, '\n')) |line_break| {
            edits[0] = .{
                .span = .{ .start = line_break + 1, .end = line_break + 1 },
                .replacement = try context.allocator.print("{s}errdefer {s};\n", .{ indent, release_statement }),
            };
        } else {
            edits[0] = .{
                .span = .{ .start = semicolon_end, .end = semicolon_end },
                .replacement = try context.allocator.print("\n{s}errdefer {s};", .{ indent, release_statement }),
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
            .message = try context.allocator.print(
                "owning value '{s}' from '{s}' has no errdefer release before an error path can leave the scope",
                .{ binding_name, callable },
            ),
            .related = related,
            .fixes = fixes,
        });
    }
    try findPartiallyInitializedOwnedFields(context, &lookups, summary_index, pass, level);
    try findFallibleAggregateFieldInitializers(context, &lookups, summary_index, pass, level);
    if (pass == .local) {
        try findCleanupCapableValuesBeforeInsertion(context, lookups.identifiers, level);
        try findFallibleContainerBuilders(context, &lookups, level);
        try findFallibleSliceBuilders(context, &lookups, level);
    }
}

fn findFallibleContainerBuilders(context: RuleRun, lookups: *Lookups, level: types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!declaresEmptyArrayList(context, declaration_index + 2, declaration_end)) continue;
        const function_scope = functionScopeContaining(context, lookups.function_keywords, declaration_index) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        var first_mutation: ?usize = null;
        var mutation_count: usize = 0;
        var arena_mutation_count: usize = 0;
        // An allocator held in a field (`self.a`) often belongs to a
        // long-lived owner such as an arena, so only the strictest shape counts.
        var field_allocator = false;
        for (lookups.identifiers.within(binding, declaration_end + 1, scope_end)) |binding_index| {
            if (binding_index + 3 >= scope_end or context.tokens[binding_index + 1].tag != .period or
                context.tokens[binding_index + 2].tag != .identifier or context.tokens[binding_index + 3].tag != .l_paren) continue;
            const mutation_scope = functionScopeContaining(context, lookups.function_keywords, binding_index) orelse continue;
            if (mutation_scope.declaration != function_scope.declaration) continue;
            const method = context.tokenText(binding_index + 2);
            if (!fallibleContainerMutation(method)) continue;
            const mutation_end = context.statementEnd(binding_index) orelse continue;
            if (!rangeContainsTry(context.tokens, statementStart(context.tokens, binding_index), mutation_end)) continue;
            first_mutation = first_mutation orelse binding_index;
            mutation_count += 1;
            const call_end = context.matchingToken(binding_index + 3, .l_paren, .r_paren) orelse continue;
            const allocator_argument = callArgument(context, binding_index + 4, call_end, 0) orelse continue;
            if (try callArgumentIsArenaBacked(context, lookups, allocator_argument, binding_index, 0)) arena_mutation_count += 1;
            if (allocator_argument.end - allocator_argument.start != 1) field_allocator = true;
        }
        const first = first_mutation orelse continue;
        if (context.scopes.insideTestBlock(declaration_index)) continue;
        if (arena_mutation_count == mutation_count) continue;
        if (scopeHasContainerCleanup(context, lookups.function_keywords, binding, function_scope.declaration, declaration_end + 1, first)) continue;
        const transfer = try containerStorageTransfer(
            context,
            lookups,
            binding,
            function_scope.declaration,
            first + 1,
            scope_end,
            !field_allocator,
        ) orelse continue;
        // Something must be able to fail once the list holds storage: another
        // mutation, a repetition of this one, or any later fallible operation.
        const first_end = context.statementEnd(first) orelse continue;
        if (mutation_count < 2 and !mutationCanRepeat(context, first, function_scope.opening) and
            (field_allocator or first_end >= transfer or
                firstFallibleOperation(context, first_end + 1, statementStart(context.tokens, transfer)) == null)) continue;
        try context.emit(.{
            .rule = .missing_errdefer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try context.allocator.print(
                "container '{s}' can retain its backing allocation if a later mutation fails before ownership transfer",
                .{binding},
            ),
        });
    }
}

fn findFallibleSliceBuilders(context: RuleRun, lookups: *Lookups, level: types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 5 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!declaresEmptySlice(context, declaration_index + 2, declaration_end)) continue;
        const function_scope = functionScopeContaining(context, lookups.function_keywords, declaration_index) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        var first_realloc: ?usize = null;
        // An assignment `binding = ...` puts the name right before its `=`.
        for (lookups.identifiers.within(binding, declaration_end + 1, scope_end - 1)) |binding_index| {
            const equal_index = binding_index + 1;
            if (context.tokens[equal_index].tag != .equal) continue;
            const mutation_scope = functionScopeContaining(context, lookups.function_keywords, equal_index) orelse continue;
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
        if (context.scopes.insideTestBlock(declaration_index)) continue;
        if (!mutationCanRepeat(context, first, function_scope.opening) or
            sliceHasErrorCleanup(context, lookups.function_keywords, binding, function_scope.declaration, declaration_end + 1, first) or
            !try scopeReturnsBinding(context, lookups, binding, function_scope.declaration, first + 1, scope_end)) continue;
        try context.emit(.{
            .rule = .missing_errdefer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try context.allocator.print(
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

fn sliceHasErrorCleanup(
    context: RuleRun,
    function_keywords: []const u32,
    binding: []const u8,
    function_declaration: usize,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const cleanup_scope = functionScopeContaining(context, function_keywords, defer_index) orelse continue;
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

fn scopeReturnsBinding(context: RuleRun, lookups: *Lookups, binding: []const u8, function_declaration: usize, start: usize, end: usize) !bool {
    var candidates: std.ArrayList(u32) = .empty;
    defer candidates.deinit(context.allocator);
    const statements = try lookups.returnStatements(context);
    try statements.appendHolding(context.allocator, lookups.identifiers, &candidates, binding, start, end, end);
    for (candidates.items) |return_keyword| {
        const return_index: usize = return_keyword;
        const return_scope = functionScopeContaining(context, lookups.function_keywords, return_index) orelse continue;
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
        names_array_list = names_array_list or container_types.kindOfToken(context.source, context.tokens, index) == .list;
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

fn scopeHasContainerCleanup(
    context: RuleRun,
    function_keywords: []const u32,
    binding: []const u8,
    function_declaration: usize,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_defer and token.tag != .keyword_errdefer) continue;
        const cleanup_scope = functionScopeContaining(context, function_keywords, defer_index) orelse continue;
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

/// Where the list's storage first leaves the function in `[start, end)`:
/// `list.toOwnedSlice(..)`, or with `returns_count` a `return` of the list
/// itself, alone or in an aggregate (`return list;`, `return .{ .items = list };`).
fn containerStorageTransfer(
    context: RuleRun,
    lookups: *Lookups,
    binding: []const u8,
    function_declaration: usize,
    start: usize,
    end: usize,
    returns_count: bool,
) !?usize {
    // Only a use of the name or a return whose statement holds one can transfer.
    var candidates: std.ArrayList(u32) = .empty;
    defer candidates.deinit(context.allocator);
    try candidates.appendSlice(context.allocator, lookups.identifiers.within(binding, start, end -| 3));
    if (returns_count) {
        const statements = try lookups.returnStatements(context);
        try statements.appendHolding(context.allocator, lookups.identifiers, &candidates, binding, start, end -| 1, end);
    }
    std.mem.sort(u32, candidates.items, {}, std.sort.asc(u32));
    var previous: ?u32 = null;
    for (candidates.items) |candidate| {
        if (candidate == previous) continue;
        previous = candidate;
        const index: usize = candidate;
        const transfer = if (context.tokens[index].tag == .keyword_return)
            returnHandsOnBinding(context, binding, index)
        else
            context.tokens[index + 1].tag == .period and context.tokenIs(index + 2, "toOwnedSlice") and
                context.tokens[index + 3].tag == .l_paren;
        if (!transfer) continue;
        const transfer_scope = functionScopeContaining(context, lookups.function_keywords, index) orelse continue;
        if (transfer_scope.declaration == function_declaration) return index;
    }
    return null;
}

/// The sorted `positions` in `[start, end)`.
fn positionsWithin(positions: []const u32, start: usize, end: usize) []const u32 {
    const first = std.sort.partitionPoint(u32, positions, start, positionBefore);
    return positions[first..][0..std.sort.partitionPoint(u32, positions[first..], end, positionBefore)];
}

fn positionBefore(bound: usize, position: u32) bool {
    return position < bound;
}

fn returnHandsOnBinding(context: RuleRun, binding: []const u8, return_index: usize) bool {
    const return_end = context.statementEnd(return_index) orelse return false;
    for (context.tokens[return_index + 1 .. return_end], return_index + 1..) |token, index| {
        if (token.tag != .identifier or !context.refersToBinding(index, binding)) continue;
        const next = context.tokens[index + 1].tag;
        if (next != .period and next != .l_bracket and next != .period_asterisk) return true;
    }
    return false;
}

fn findFallibleAggregateFieldInitializers(
    context: RuleRun,
    lookups: *Lookups,
    summary_index: ?summaries.Index,
    pass: AnalysisPass,
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
            const acquisition = try owningAcquisitionAfterEqual(
                context,
                lookups,
                equal_index,
                value_end,
                summary_index,
                pass,
            ) orelse continue;
            if (acquisition.kind != .allocation or !rangeContainsTry(context.tokens, value_end + 1, aggregate_end) or
                context.scopes.insideTestBlock(equal_index)) continue;
            const function_scope = functionScopeContaining(context, lookups.function_keywords, equal_index) orelse continue;
            if (acquisitionUsesArenaContract(context, function_scope, acquisition)) continue;
            const receiver = context.source[context.tokens[acquisition.release_owner_start].loc.start..context.tokens[acquisition.release_owner_end].loc.end];
            if (acquisitionUsesNamedArena(receiver, acquisition)) continue;
            const field = context.tokenText(equal_index - 1);
            const message = if (binding) |name|
                try context.allocator.print(
                    "owned field '{s}.{s}' can leak if a later aggregate field initialization fails",
                    .{ name, field },
                )
            else
                try context.allocator.print(
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
    lookups: *Lookups,
    summary_index: ?summaries.Index,
    pass: AnalysisPass,
    level: types.Level,
) !void {
    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index < 3 or context.tokens[equal_index - 1].tag != .identifier or
            context.tokens[equal_index - 2].tag != .period or context.tokens[equal_index - 3].tag != .identifier) continue;
        const owner_index = equal_index - 3;
        const owner = context.tokenText(owner_index);
        if (!locallyUndefinedBindingBefore(context, lookups.identifiers, owner, owner_index) and
            !try locallyCreatedBindingBefore(context, lookups, owner, owner_index)) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        const acquisition = try owningAcquisitionAfterEqual(
            context,
            lookups,
            equal_index,
            statement_end,
            summary_index,
            pass,
        ) orelse continue;
        if (acquisition.kind != .allocation or context.scopes.insideTestBlock(equal_index)) continue;
        const scope_opening = context.enclosingOpeningBrace(equal_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const function_scope = functionScopeContaining(context, lookups.function_keywords, equal_index) orelse continue;
        const receiver = context.source[context.tokens[acquisition.release_owner_start].loc.start..context.tokens[acquisition.release_owner_end].loc.end];
        const method = context.tokenText(acquisition.method_index);
        if (acquisitionUsesNamedArena(receiver, acquisition) or
            try declarationLooksArenaBacked(context, lookups, context.tokenText(acquisition.release_owner_start), function_scope.opening, function_scope.closing) or
            functionDocumentsArenaAllocator(context, function_scope, context.tokenText(acquisition.release_owner_start)) or
            allocatorPathIsBuildArena(context, function_scope, acquisition.release_owner_start, acquisition.release_owner_end) or
            acquisitionUsesArenaContract(context, function_scope, acquisition) or
            try scopeDeinitializesReceiver(context, lookups, scope_opening, scope_end, context.tokenText(acquisition.release_owner_end)) or
            try scopeDeinitializesReceiver(context, lookups, scope_opening, scope_end, owner)) continue;
        if (std.mem.eql(u8, method, "create") and std.ascii.findIgnoreCase(receiver, "pool") != null) continue;
        const fallible_index = fallibleBeforeBindingUse(context, statement_end + 1, scope_end, owner, false) orelse continue;
        const field = context.tokenText(equal_index - 1);
        if (scopeHasErrorPathCleanup(context, owner, field, statement_end + 1, fallible_index)) continue;
        const owned_path = context.source[context.tokens[owner_index].loc.start..context.tokens[equal_index - 1].loc.end];
        const release_statement = if (acquisition.release_owner_member) |member|
            try context.allocator.print("{s}.{s}.{s}({s})", .{ receiver, member, acquisition.release, owned_path })
        else
            try context.allocator.print("{s}.{s}({s})", .{ receiver, acquisition.release, owned_path });
        defer context.allocator.free(release_statement);
        const indent = lineIndent(context.source, context.tokens[owner_index].loc.start);
        const semicolon_end = context.tokens[statement_end].loc.end;
        const edits = try context.allocator.alloc(types.Edit, 1);
        if (std.mem.findScalarPos(u8, context.source, semicolon_end, '\n')) |line_break| {
            edits[0] = .{
                .span = .{ .start = line_break + 1, .end = line_break + 1 },
                .replacement = try context.allocator.print("{s}errdefer {s};\n", .{ indent, release_statement }),
            };
        } else {
            edits[0] = .{
                .span = .{ .start = semicolon_end, .end = semicolon_end },
                .replacement = try context.allocator.print("\n{s}errdefer {s};", .{ indent, release_statement }),
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
            .message = try context.allocator.print(
                "owned field '{s}.{s}' has no errdefer release before partial initialization can fail",
                .{ owner, field },
            ),
            .related = related,
            .fixes = fixes,
        });
    }
}

fn locallyUndefinedBindingBefore(context: RuleRun, identifiers: *const IdentifierTable, name: []const u8, before: usize) bool {
    const scope = context.enclosingOpeningBrace(before) orelse return false;
    for (identifiers.within(name, scope + 2, before)) |name_index| {
        const declaration_index = name_index - 1;
        if (context.tokens[declaration_index].tag != .keyword_var or declaration_index + 3 >= before) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= before) continue;
        for (context.tokens[declaration_index + 2 .. declaration_end], declaration_index + 2..) |candidate, index| {
            if (candidate.tag == .identifier and context.tokenIs(index, "undefined") and
                context.enclosingOpeningBrace(index) == scope) return true;
        }
    }
    return false;
}

fn locallyCreatedBindingBefore(context: RuleRun, lookups: *Lookups, name: []const u8, before: usize) !bool {
    const scope = context.enclosingOpeningBrace(before) orelse return false;
    for (lookups.identifiers.within(name, scope + 2, before)) |name_index| {
        const declaration_index = name_index - 1;
        const keyword = context.tokens[declaration_index].tag;
        if (keyword != .keyword_const and keyword != .keyword_var) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= before) continue;
        const acquisition = try owningAcquisition(context, lookups, declaration_index, declaration_end, null, .local) orelse continue;
        if (context.tokenIs(acquisition.method_index, "create")) return true;
    }
    return false;
}

fn findCleanupCapableValuesBeforeInsertion(context: RuleRun, identifiers: *const IdentifierTable, level: types.Level) !void {
    // Both lookups visit every use of a name, so each name is looked up once.
    var return_types: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    defer return_types.deinit(context.allocator);
    var cleanup_types: std.StringHashMapUnmanaged(bool) = .empty;
    defer cleanup_types.deinit(context.allocator);
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or !startsStatement(context, declaration_index)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const owner_type = try calledReturnType(context, identifiers, &return_types, declaration_index + 2, declaration_end) orelse continue;
        const releases = try cleanup_types.getOrPut(context.allocator, owner_type);
        if (!releases.found_existing) releases.value_ptr.* = typeCleanupReleasesOwnership(context, identifiers, owner_type);
        if (!releases.value_ptr.* or context.scopes.insideTestBlock(declaration_index)) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        const fallible_index = fallibleBeforeBindingUse(context, declaration_end + 1, scope_end, binding, false) orelse continue;
        const fallible_end = context.statementEnd(fallible_index) orelse continue;
        if (!callsFallibleContainerInsertion(context, statementStart(context.tokens, fallible_index), fallible_end)) continue;
        if (insertionTakesOwnershipOnFailure(
            context,
            identifiers,
            binding,
            statementStart(context.tokens, fallible_index),
            fallible_end,
        )) continue;
        const related = try singleRelatedSpan(
            context,
            fallible_index,
            "this fallible insertion leaves the value with the caller on failure",
        );
        const message = try context.allocator.print(
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
    identifiers: *const IdentifierTable,
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
        if (functionCleansParameterBeforeInsertion(context, identifiers, context.tokenText(method_index), parameter_index)) return true;
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

fn functionCleansParameterBeforeInsertion(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    function_name: []const u8,
    parameter_index: usize,
) bool {
    // `fn name` puts the name right after the keyword.
    var declaration_count: usize = 0;
    for (identifiers.all(function_name)) |name_index| {
        if (name_index > 0 and context.tokens[name_index - 1].tag == .keyword_fn) declaration_count += 1;
    }
    if (declaration_count != 1) return false;
    for (identifiers.all(function_name)) |name_index| {
        if (name_index == 0 or context.tokens[name_index - 1].tag != .keyword_fn or name_index + 1 >= context.tokens.len or
            context.tokens[name_index + 1].tag != .l_paren) continue;
        const function_index = name_index - 1;
        const parameters_end = context.matchingToken(function_index + 2, .l_paren, .r_paren) orelse continue;
        const parameter = parameterName(context, function_index + 3, parameters_end, parameter_index) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace and
            context.tokens[body_start].tag != .semicolon) : (body_start += 1)
        {}
        if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        const owned_name = parameterAlias(context, parameter, body_start + 1, body_end) orelse parameter;
        if (!scopeHasErrorPathCleanup(context, owned_name, null, body_start + 1, body_end)) continue;
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

fn calledReturnType(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    return_types: *std.StringHashMapUnmanaged(?[]const u8),
    start: usize,
    end: usize,
) !?[]const u8 {
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
    const known = try return_types.getOrPut(context.allocator, name);
    if (!known.found_existing) known.value_ptr.* = functionReturnType(context, identifiers, name);
    return known.value_ptr.*;
}

/// The last identifier between the parameters and the body of the first
/// `fn name(` in the file.
fn functionReturnType(context: RuleRun, identifiers: *const IdentifierTable, name: []const u8) ?[]const u8 {
    for (identifiers.all(name)) |name_index| {
        if (name_index == 0 or context.tokens[name_index - 1].tag != .keyword_fn or name_index + 1 >= context.tokens.len or
            context.tokens[name_index + 1].tag != .l_paren) continue;
        const fn_index = name_index - 1;
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

fn typeCleanupReleasesOwnership(context: RuleRun, identifiers: *const IdentifierTable, type_name: []const u8) bool {
    for (identifiers.all(type_name)) |type_index| {
        if (type_index == 0 or context.tokens[type_index - 1].tag != .keyword_const or type_index + 3 >= context.tokens.len or
            context.tokens[type_index + 1].tag != .equal or context.tokens[type_index + 2].tag != .keyword_struct or
            context.tokens[type_index + 3].tag != .l_brace) continue;
        const body_start = type_index + 3;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        // `fn deinit(` puts the name right after the keyword.
        for (identifiers.within("deinit", body_start + 2, body_end)) |name_index| {
            const fn_index = name_index - 1;
            if (context.tokens[fn_index].tag != .keyword_fn or fn_index + 2 >= body_end or
                context.tokens[fn_index + 2].tag != .l_paren) continue;
            const parameters_end = context.matchingToken(fn_index + 2, .l_paren, .r_paren) orelse continue;
            var cleanup_start = parameters_end + 1;
            while (cleanup_start < body_end and context.tokens[cleanup_start].tag != .l_brace) : (cleanup_start += 1) {}
            if (cleanup_start >= body_end) continue;
            const cleanup_end = context.matchingToken(cleanup_start, .l_brace, .r_brace) orelse continue;
            for ([_][]const u8{ "free", "destroy", "close", "deinit" }) |release| {
                if (identifiers.firstWithin(release, cleanup_start + 1, cleanup_end) != null) return true;
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
    release_owner_member: ?[]const u8 = null,
    method_index: usize,
    release: []const u8 = "free",
    close_argument: ?TokenRange = null,
};

fn acquisitionUsesNamedArena(receiver: []const u8, acquisition: Acquisition) bool {
    return std.ascii.findIgnoreCase(receiver, "arena") != null or
        (acquisition.release_owner_member != null and
            std.ascii.findIgnoreCase(acquisition.release_owner_member.?, "arena") != null);
}

fn owningAcquisition(
    context: RuleRun,
    lookups: *Lookups,
    declaration_index: usize,
    declaration_end: usize,
    summary_index: ?summaries.Index,
    pass: AnalysisPass,
) !?Acquisition {
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
    return owningAcquisitionAfterEqual(context, lookups, equal, declaration_end, summary_index, pass);
}

fn owningAcquisitionAfterEqual(
    context: RuleRun,
    lookups: *Lookups,
    equal: usize,
    declaration_end: usize,
    summary_index: ?summaries.Index,
    pass: AnalysisPass,
) !?Acquisition {
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
        const separator = std.mem.findScalarLast(u8, callable, '.');
        const receiver = if (separator) |position| callable[0..position] else null;
        const name = if (separator) |position| callable[position + 1 ..] else callable;
        if (known_summaries.ownedReturnCall(context.source, receiver, name)) |owned| {
            if (std.mem.eql(u8, name, "alloc") and receiver != null and
                !try receiverLooksLikeAllocator(context, lookups, equal + 2, path_end - 2)) return null;
            const owner = if (owned.allocator_parameter) |allocator_parameter| owner: {
                const argument = callArgument(context, path_end + 2, call_close, allocator_parameter) orelse return null;
                if (!identifierPathArgument(context, argument)) return null;
                break :owner argument;
            } else owner: {
                if (owned.allocator_parameter_member == null or receiver == null or path_end < equal + 4) return null;
                break :owner TokenRange{ .start = equal + 2, .end = path_end - 1 };
            };
            return .{
                .callable_start = equal + 2,
                .release_owner_start = owner.start,
                .release_owner_end = owner.end - 1,
                .release_owner_member = owned.allocator_parameter_member,
                .method_index = path_end,
                .release = owned.release,
            };
        }
    }
    if (pass == .summaries or path_end == equal + 2) return null;
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
    if ((context.tokenIs(path_end, "print") or context.tokenIs(path_end, "printSentinel")) and
        !owned_call.printReceiverIsAllocatorIndexed(context.scopes, path_end - 2)) return null;
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
    if (std.mem.eql(u8, resources.allocationRelease(context.tokenText(path_end)) orelse "", "free") and
        !try receiverLooksLikeAllocator(context, lookups, equal + 2, path_end - 2)) return null;
    if (context.tokenIs(path_end, "create") and !receiverOwnsCreatedMemory(context, equal + 2, path_end - 2)) return null;
    return .{
        .callable_start = equal + 2,
        .release_owner_start = equal + 2,
        .release_owner_end = path_end - 2,
        .method_index = path_end,
        .release = resources.allocationRelease(context.tokenText(path_end)) orelse "free",
    };
}

fn receiverOwnsCreatedMemory(context: RuleRun, start: usize, end: usize) bool {
    if (start > end) return false;
    const receiver = context.source[context.tokens[start].loc.start..context.tokens[end].loc.end];
    const roles = [_][]const u8{ "alloc", "gpa", "pool" };
    for (roles) |role| if (std.ascii.findIgnoreCase(receiver, role) != null) return true;
    return false;
}

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
        if (token.tag == .identifier and std.ascii.findIgnoreCase(context.tokenText(index), "arena") != null) return true;
    }
    return false;
}

fn receiverLooksLikeAllocator(context: RuleRun, lookups: *Lookups, receiver_start: usize, receiver_end: usize) !bool {
    const receiver_name = context.tokenText(receiver_end);
    if (std.ascii.findIgnoreCase(receiver_name, "alloc") != null or
        std.ascii.findIgnoreCase(receiver_name, "arena") != null or
        std.mem.eql(u8, receiver_name, "gpa")) return true;
    if (receiver_start != receiver_end) return false;
    return lookups.declaredAllocator(context, receiver_name);
}

fn isAllocatingMethod(name: []const u8) bool {
    return resources.allocationRelease(name) != null and !std.mem.eql(u8, name, "realloc");
}

fn declarationLooksArenaBacked(
    context: RuleRun,
    lookups: *Lookups,
    root_name: []const u8,
    scope_opening: usize,
    scope_end: usize,
) !bool {
    // The scope's `{` decides its `}`, so the answer depends on the two keys only.
    const key: ScopedName = .{ .scope = @intCast(scope_opening), .name = root_name };
    if (lookups.arena_backed.get(key)) |known| return known;
    const arena_backed = declarationLooksArenaBackedAtDepth(context, lookups.identifiers, root_name, scope_opening, scope_end, 0);
    try lookups.arena_backed.put(context.allocator, key, arena_backed);
    return arena_backed;
}

fn declarationLooksArenaBackedAtDepth(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    root_name: []const u8,
    scope_opening: usize,
    scope_end: usize,
    depth: usize,
) bool {
    if (depth == 4) return false;
    // `const name` or `var name` puts the name right after the keyword.
    for (identifiers.within(root_name, scope_opening + 2, scope_end)) |name_index| {
        const index = name_index - 1;
        const token = context.tokens[index];
        if (token.tag != .keyword_const and token.tag != .keyword_var) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[token.loc.start..context.tokens[end].loc.end];
        if (std.mem.find(u8, declaration, "ArenaAllocator") != null or
            std.mem.find(u8, declaration, "FixedBufferAllocator") != null) return true;
        // A stack buffer that falls back to an arena frees nothing on its own.
        const buffer_first = std.mem.find(u8, declaration, "BufferFirstAllocator") != null or
            std.mem.find(u8, declaration, "StackFallbackAllocator") != null or
            std.mem.find(u8, declaration, "stackFallback") != null;
        if (buffer_first and std.ascii.findIgnoreCase(declaration, "arena") != null) return true;
        var value_index = index + 2;
        while (value_index + 3 < end) : (value_index += 1) {
            if (context.tokens[value_index].tag != .identifier or context.tokens[value_index + 1].tag != .period or
                !context.tokenIs(value_index + 2, "allocator") or context.tokens[value_index + 3].tag != .l_paren) continue;
            const receiver = context.tokenText(value_index);
            if (std.mem.eql(u8, receiver, root_name)) continue;
            if (declarationLooksArenaBackedAtDepth(context, identifiers, receiver, scope_opening, scope_end, depth + 1)) return true;
        }
    }
    return false;
}

const ScopeRange = struct { declaration: usize, opening: usize, closing: usize };

/// The body of the function or test containing `target`, with its `fn` or
/// `test` keyword: the last such keyword before `target` whose body encloses
/// it. A keyword sits between its body and the brace enclosing that body, so
/// only the blocks around `target` and the tokens before each are searched.
fn functionScopeContaining(context: RuleRun, function_keywords: []const u32, target: usize) ?ScopeRange {
    var brace = context.enclosingOpeningBrace(target);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        if (closing <= target) continue;
        const lower = if (context.enclosingOpeningBrace(opening)) |parent| parent + 1 else 0;
        // The `fn` and `test` keywords in `[lower, opening)`, nearest first.
        const keywords = positionsWithin(function_keywords, lower, opening);
        var remaining = keywords.len;
        while (remaining > 0) {
            remaining -= 1;
            const declaration_index: usize = keywords[remaining];
            if (functionBodyOpening(context, declaration_index, target) != opening) continue;
            return .{ .declaration = declaration_index, .opening = opening, .closing = closing };
        }
    }
    return null;
}

/// Every `fn` and `test` keyword, in order.
fn functionKeywords(context: RuleRun) ![]const u32 {
    var keywords: std.ArrayList(u32) = .empty;
    defer keywords.deinit(context.allocator);
    for (context.tokens, 0..) |token, index| {
        if (token.tag == .keyword_fn or token.tag == .keyword_test) try keywords.append(context.allocator, @intCast(index));
    }
    return keywords.toOwnedSlice(context.allocator);
}

/// Where the body of the `fn` or `test` at `declaration_index` opens, looking
/// no further than `target` for a test or an anonymous function.
fn functionBodyOpening(context: RuleRun, declaration_index: usize, target: usize) ?usize {
    if (context.tokens[declaration_index].tag == .keyword_fn and declaration_index + 2 < target and
        context.tokens[declaration_index + 2].tag == .l_paren)
    {
        const parameters_end = context.matchingToken(declaration_index + 2, .l_paren, .r_paren) orelse return null;
        return syntax_scope.functionBodyAfterParameters(context.tokens, parameters_end);
    }
    var opening = declaration_index + 1;
    while (opening < target and context.tokens[opening].tag != .l_brace and
        context.tokens[opening].tag != .semicolon) : (opening += 1)
    {}
    return opening;
}

fn functionDocumentsArenaAllocator(context: RuleRun, function: ScopeRange, allocator_name: []const u8) bool {
    var parameter_index = function.declaration + 1;
    while (parameter_index + 1 < function.opening) : (parameter_index += 1) {
        if (context.tokenIs(parameter_index, allocator_name) and
            context.tokens[parameter_index + 1].tag == .colon) break;
    } else return false;

    var modifier_start = function.declaration;
    while (modifier_start > 0) switch (context.tokens[modifier_start - 1].tag) {
        .keyword_pub,
        .keyword_export,
        .keyword_extern,
        .keyword_inline,
        .keyword_noinline,
        => modifier_start -= 1,
        else => break,
    };
    var first_doc = modifier_start;
    while (first_doc > 0 and context.tokens[first_doc - 1].tag == .doc_comment) first_doc -= 1;
    if (first_doc == modifier_start) return false;
    const documentation = context.source[context.tokens[first_doc].loc.start..context.tokens[modifier_start].loc.start];
    return std.ascii.findIgnoreCase(documentation, "allocator should be an arena") != null;
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
    lookups: *Lookups,
    function: ScopeRange,
    parameter_name: []const u8,
    depth: usize,
) std.mem.Allocator.Error!bool {
    if (depth != 0) return parameterReceivesOnlyArena(context, lookups, function, parameter_name, depth);
    // The body's `{` decides the function, so from depth 0 the answer depends on the two keys only.
    const key: ScopedName = .{ .scope = @intCast(function.opening), .name = parameter_name };
    if (lookups.arena_parameters.get(key)) |known| return known;
    const receives = try parameterReceivesOnlyArena(context, lookups, function, parameter_name, 0);
    try lookups.arena_parameters.put(context.allocator, key, receives);
    return receives;
}

fn parameterReceivesOnlyArena(
    context: RuleRun,
    lookups: *Lookups,
    function: ScopeRange,
    parameter_name: []const u8,
    depth: usize,
) std.mem.Allocator.Error!bool {
    if (functionParameterMatchesArenaContract(context, function, parameter_name)) return true;
    if (depth == 8 or function.declaration + 2 >= function.opening or
        context.tokens[function.declaration + 1].tag != .identifier) return false;
    if (function.declaration > 0 and context.tokens[function.declaration - 1].tag == .keyword_pub) return false;
    const parameter_index = functionParameterIndex(context, function, parameter_name) orelse return false;
    const function_name = context.tokenText(function.declaration + 1);
    var found_call = false;
    for (lookups.identifiers.all(function_name)) |name_index| {
        const call_index: usize = name_index;
        if (call_index > 0 and context.tokens[call_index - 1].tag == .keyword_fn) continue;
        if (call_index + 1 >= context.tokens.len or context.tokens[call_index + 1].tag != .l_paren or
            (call_index > 0 and context.tokens[call_index - 1].tag == .period)) return false;
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse return false;
        const argument = callArgument(context, call_index + 2, call_end, parameter_index) orelse return false;
        if (!try callArgumentIsArenaBacked(context, lookups, argument, call_index, depth + 1)) return false;
        found_call = true;
    }
    return found_call;
}

fn functionParameterMatchesArenaContract(
    context: RuleRun,
    function: ScopeRange,
    parameter_name: []const u8,
) bool {
    if (function.declaration + 1 >= function.opening or
        context.tokens[function.declaration].tag != .keyword_fn or
        context.tokens[function.declaration + 1].tag != .identifier) return false;
    const function_name = context.tokenText(function.declaration + 1);
    for (context.configuration.arena_allocator_contracts) |contract| {
        const separator = std.mem.findScalar(u8, contract, '.') orelse continue;
        if (!std.mem.eql(u8, parameter_name, contract[separator + 1 ..])) continue;
        const owner_name = contract[0..separator];
        if (std.mem.eql(u8, function_name, owner_name)) return true;
    }
    return false;
}

fn functionParameterIndex(context: RuleRun, function: ScopeRange, parameter_name: []const u8) ?usize {
    var index: usize = 0;
    while (parameterName(context, function.declaration + 3, function.opening, index)) |name| : (index += 1) {
        if (std.mem.eql(u8, name, parameter_name)) return index;
    }
    return null;
}

fn callArgumentIsArenaBacked(
    context: RuleRun,
    lookups: *Lookups,
    argument: TokenRange,
    call_index: usize,
    depth: usize,
) std.mem.Allocator.Error!bool {
    if (argument.start >= argument.end) return false;
    for (context.tokens[argument.start..argument.end], argument.start..) |token, index| {
        if (token.tag == .identifier and std.ascii.findIgnoreCase(context.tokenText(index), "arena") != null) return true;
    }
    if (argument.start + 1 != argument.end or context.tokens[argument.start].tag != .identifier) return false;
    const argument_name = context.tokenText(argument.start);
    const caller = functionScopeContaining(context, lookups.function_keywords, call_index) orelse return false;
    if (try declarationLooksArenaBacked(context, lookups, argument_name, caller.opening, caller.closing)) return true;
    if (!functionParameterIsAllocator(context, caller, argument_name)) return false;
    return functionParameterReceivesOnlyArena(context, lookups, caller, argument_name, depth);
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

fn acquisitionUsesArenaContract(context: RuleRun, function: ScopeRange, acquisition: Acquisition) bool {
    const receiver_index, const member_name = if (acquisition.release_owner_member) |member|
        .{ acquisition.release_owner_start, member }
    else if (acquisition.release_owner_end > acquisition.release_owner_start and
        context.tokens[acquisition.release_owner_start].tag == .identifier and
        identifierPathArgument(context, .{
            .start = acquisition.release_owner_start,
            .end = acquisition.release_owner_end + 1,
        }))
        .{
            acquisition.release_owner_start,
            context.source[context.tokens[acquisition.release_owner_start + 2].loc.start..context.tokens[acquisition.release_owner_end].loc.end],
        }
    else
        .{ acquisition.release_owner_start, context.tokenText(acquisition.release_owner_start) };
    if (context.tokens[receiver_index].tag != .identifier) return false;
    const receiver_name = context.tokenText(receiver_index);
    const owner_type = functionParameterTypeName(context, function, receiver_name);
    const function_name = if (function.declaration + 1 < context.tokens.len and
        context.tokens[function.declaration].tag == .keyword_fn and
        context.tokens[function.declaration + 1].tag == .identifier)
        context.tokenText(function.declaration + 1)
    else
        null;

    for (context.configuration.arena_allocator_contracts) |contract| {
        const separator = std.mem.findScalar(u8, contract, '.') orelse continue;
        if (!std.mem.eql(u8, member_name, contract[separator + 1 ..])) continue;
        const owner_name = contract[0..separator];
        if (owner_type) |type_name| if (std.mem.eql(u8, owner_name, type_name)) return true;
        if (function_name) |name| if (std.mem.eql(u8, owner_name, name) and
            std.mem.eql(u8, receiver_name, member_name)) return true;
    }
    return false;
}

fn functionParameterTypeName(context: RuleRun, function: ScopeRange, parameter_name: []const u8) ?[]const u8 {
    var parameter_index = function.declaration + 1;
    while (parameter_index + 2 < function.opening) : (parameter_index += 1) {
        if (!context.tokenIs(parameter_index, parameter_name) or context.tokens[parameter_index + 1].tag != .colon) continue;
        var type_name: ?[]const u8 = null;
        var type_index = parameter_index + 2;
        while (type_index < function.opening) : (type_index += 1) {
            switch (context.tokens[type_index].tag) {
                .comma, .r_paren => break,
                .identifier => type_name = context.tokenText(type_index),
                else => {},
            }
        }
        return type_name;
    }
    return null;
}

fn scopeDeinitializesReceiver(
    context: RuleRun,
    lookups: *Lookups,
    scope_opening: usize,
    scope_end: usize,
    receiver_segment: []const u8,
) !bool {
    const key: ScopedName = .{ .scope = @intCast(scope_opening), .name = receiver_segment };
    if (lookups.deinitialized_receivers.get(key)) |known| return known;
    const bodies = try lookups.deferBodies(context, scope_opening, scope_end);
    var deinitializes = false;
    // The bodies are disjoint, so a call lies in the last one starting before it or in none.
    for (lookups.identifiers.within(receiver_segment, scope_opening + 2, scope_end)) |receiver| {
        if (context.tokens[receiver + 1].tag != .period or !context.tokenIs(receiver + 2, "deinit")) continue;
        const preceding = std.sort.partitionPoint(DeferBody, bodies, @as(usize, receiver), DeferBody.startsBefore);
        if (preceding > 0 and receiver + 2 < bodies[preceding - 1].end) {
            deinitializes = true;
            break;
        }
    }
    try lookups.deinitialized_receivers.put(context.allocator, key, deinitializes);
    return deinitializes;
}

/// Whether a `defer` or `errdefer` in `[start, scope_end)` cleans up `binding`
/// (or only its `field`, `errdefer allocator.free(owner.field)`, when given).
fn scopeHasErrorPathCleanup(context: RuleRun, binding: []const u8, field: ?[]const u8, start: usize, scope_end: usize) bool {
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
                if (argument.tag != .identifier or !context.tokenIs(argument_index, binding)) continue;
                const released_field = field orelse return true;
                if (argument_index + 2 < call_end and context.tokens[argument_index + 1].tag == .period and
                    context.tokenIs(argument_index + 2, released_field)) return true;
            }
        }
    }
    return false;
}

fn fallibleBeforePlainCleanup(
    context: RuleRun,
    lookups: *Lookups,
    start: usize,
    scope_end: usize,
    binding: []const u8,
    release: []const u8,
) !?usize {
    const scope = context.enclosingOpeningBrace(start) orelse return null;
    const enclosing = try lookups.enclosingParentheses(context);
    // A release call names the binding inside its parentheses, so it is one
    // of the calls around a use. Only a `(` opened after `start` and still
    // open at `scope_end` could hold a use past it; then every call is read.
    const open_at_end = enclosing[scope_end];
    if (open_at_end != syntax_scope.none_token and open_at_end > start) {
        for (start..scope_end) |method_index| {
            if (plainCleanupCall(context, scope, scope_end, binding, release, method_index)) |statement_start|
                return firstFallibleOperation(context, start, statement_start);
        }
        return null;
    }
    var first: ?usize = null;
    var statement_start: usize = undefined;
    for (lookups.identifiers.within(binding, start + 2, scope_end)) |use| {
        var opening = enclosing[use];
        while (opening != syntax_scope.none_token and opening > start) : (opening = enclosing[opening]) {
            const method_index = opening - 1;
            if (first != null and method_index >= first.?) continue;
            statement_start = plainCleanupCall(context, scope, scope_end, binding, release, method_index) orelse continue;
            first = method_index;
        }
    }
    if (first == null) return null;
    return firstFallibleOperation(context, start, statement_start);
}

/// Where the statement of the call at `method_index` starts when it calls
/// `release` on `binding` directly in `scope` outside any defer.
fn plainCleanupCall(
    context: RuleRun,
    scope: usize,
    scope_end: usize,
    binding: []const u8,
    release: []const u8,
    method_index: usize,
) ?usize {
    if (context.tokens[method_index].tag != .identifier or !context.tokenIs(method_index, release) or
        method_index + 1 >= scope_end or context.tokens[method_index + 1].tag != .l_paren or
        context.enclosingOpeningBrace(method_index) != scope) return null;
    const statement_start = statementStart(context.tokens, method_index);
    if (rangeContainsToken(context.tokens, statement_start, method_index, .keyword_defer) or
        rangeContainsToken(context.tokens, statement_start, method_index, .keyword_errdefer)) return null;
    const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse return null;
    if (!callArgumentsContainBinding(context, method_index + 2, call_end, binding)) return null;
    return statement_start;
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
        // The block of `if (bad) { gpa.free(copy); return error.X; }`, which
        // releases the binding itself before its error return.
        var releasing_exit_block: ?usize = null;
        for (context.tokens[cursor .. end + 1], cursor..) |chunk_token, chunk_index| {
            switch (chunk_token.tag) {
                .keyword_return => if (returnsExplicitError(context, chunk_index, end)) {
                    if (errorReturnFollowsRelease(context, binding, chunk_index)) {
                        releasing_exit_block = context.enclosingOpeningBrace(chunk_index);
                    } else error_return_index = chunk_index;
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
            if (releasing_exit_block != null and context.enclosingOpeningBrace(chunk_index) == releasing_exit_block) continue;
            const borrowed_use = bindingUseIsBorrowed(context, chunk_index, end);
            if (fallible_index != null and (borrowing_call or
                callsFallibleContainerInsertion(context, cursor, end) or
                borrowed_use)) return fallible_index;
            if (fallible_index == null and borrowed_use) continue;
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

/// Whether the error return at `return_index` follows a release of `binding`
/// in its own block, so that path leaves nothing behind.
fn errorReturnFollowsRelease(context: RuleRun, binding: []const u8, return_index: usize) bool {
    const block = context.enclosingOpeningBrace(return_index) orelse return false;
    for (context.tokens[block + 1 .. return_index], block + 1..) |token, method_index| {
        if (token.tag != .identifier or method_index + 1 >= return_index or
            context.tokens[method_index + 1].tag != .l_paren or context.enclosingOpeningBrace(method_index) != block) continue;
        const releases = context.tokenIs(method_index, "free") or context.tokenIs(method_index, "destroy") or
            context.tokenIs(method_index, "deinit");
        if (!releases) continue;
        if (method_index >= 2 and context.tokens[method_index - 1].tag == .period and
            context.tokenIs(method_index - 2, binding)) return true;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        if (callArgumentsContainBinding(context, method_index + 2, call_end, binding)) return true;
    }
    return false;
}

fn returnsExplicitError(context: RuleRun, return_index: usize, end: usize) bool {
    return return_index + 1 < end and context.tokens[return_index + 1].tag == .keyword_error;
}

fn bindingUseIsBorrowed(context: RuleRun, index: usize, end: usize) bool {
    return index + 2 < end and context.tokens[index + 1].tag == .period and
        context.tokens[index + 2].tag == .identifier and
        (index + 3 >= end or context.tokens[index + 3].tag != .l_paren);
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

/// What the passes of one run look up again and again, so that each lookup
/// visits the uses of one name instead of the whole file or scope. Every
/// part is built by its first use.
const Lookups = struct {
    identifiers: *const syntax_scope.IdentifierTable,
    /// Every `fn` and `test` keyword, in order.
    function_keywords: []const u32,
    /// The innermost `(` open at each token.
    parentheses: ?[]const u32 = null,
    return_statements: ?ReturnStatements = null,
    /// Names that some `name: T` declares with `Allocator` in `T`.
    allocator_names: ?std.StringHashMapUnmanaged(void) = null,
    /// `declarationLooksArenaBacked` by function body and name.
    arena_backed: ScopedNames = .empty,
    /// `functionParameterReceivesOnlyArena` from depth 0 by function body and parameter.
    arena_parameters: ScopedNames = .empty,
    /// `scopeDeinitializesReceiver` by scope and receiver.
    deinitialized_receivers: ScopedNames = .empty,
    /// The defers `scopeDeinitializesReceiver` reads in each scope.
    scope_defers: std.AutoHashMapUnmanaged(u32, []const DeferBody) = .empty,

    fn deinit(lookups: *Lookups, allocator: std.mem.Allocator) void {
        allocator.free(lookups.function_keywords);
        if (lookups.parentheses) |parentheses| allocator.free(parentheses);
        if (lookups.return_statements) |*statements| statements.deinit(allocator);
        if (lookups.allocator_names) |*names| names.deinit(allocator);
        lookups.arena_backed.deinit(allocator);
        lookups.arena_parameters.deinit(allocator);
        lookups.deinitialized_receivers.deinit(allocator);
        var bodies = lookups.scope_defers.valueIterator();
        while (bodies.next()) |scope_bodies| allocator.free(scope_bodies.*);
        lookups.scope_defers.deinit(allocator);
    }

    fn enclosingParentheses(lookups: *Lookups, context: RuleRun) ![]const u32 {
        if (lookups.parentheses) |parentheses| return parentheses;
        const enclosing = try context.allocator.alloc(u32, context.tokens.len);
        errdefer context.allocator.free(enclosing);
        // Paired the way the scope index pairs them, so a `(` open at a token
        // has its `)` after it or none.
        var open: std.ArrayList(u32) = .empty;
        defer open.deinit(context.allocator);
        for (context.tokens, 0..) |token, index| {
            enclosing[index] = open.last() orelse syntax_scope.none_token;
            switch (token.tag) {
                .l_paren => try open.append(context.allocator, @intCast(index)),
                .r_paren => _ = open.pop(),
                else => {},
            }
        }
        lookups.parentheses = enclosing;
        return enclosing;
    }

    /// The defers and errdefers of the scope that `scopeDeinitializesReceiver`
    /// reads: each one's body is skipped, so a defer inside it is not read.
    fn deferBodies(lookups: *Lookups, context: RuleRun, scope_opening: usize, scope_end: usize) ![]const DeferBody {
        if (lookups.scope_defers.get(@intCast(scope_opening))) |bodies| return bodies;
        var bodies: std.ArrayList(DeferBody) = .empty;
        defer bodies.deinit(context.allocator);
        var index = scope_opening + 1;
        while (index + 3 < scope_end) : (index += 1) {
            const tag = context.tokens[index].tag;
            if (tag != .keyword_defer and tag != .keyword_errdefer) continue;
            const body_end = if (context.tokens[index + 1].tag == .l_brace)
                context.matchingToken(index + 1, .l_brace, .r_brace) orelse scope_end
            else
                context.statementEnd(index + 1) orelse scope_end;
            try bodies.append(context.allocator, .{ .keyword = @intCast(index), .end = @intCast(@min(body_end, scope_end)) });
            index = @min(body_end, scope_end - 1);
        }
        const owned = try bodies.toOwnedSlice(context.allocator);
        errdefer context.allocator.free(owned);
        try lookups.scope_defers.put(context.allocator, @intCast(scope_opening), owned);
        return owned;
    }

    fn returnStatements(lookups: *Lookups, context: RuleRun) !ReturnStatements {
        if (lookups.return_statements == null) lookups.return_statements = try .init(context);
        return lookups.return_statements.?;
    }

    /// Whether some `name:` in the file has `Allocator` in its type.
    fn declaredAllocator(lookups: *Lookups, context: RuleRun, name: []const u8) !bool {
        if (lookups.allocator_names == null) {
            var names: std.StringHashMapUnmanaged(void) = .empty;
            errdefer names.deinit(context.allocator);
            for (context.tokens, 0..) |token, identifier_index| {
                if (token.tag != .identifier or identifier_index + 2 >= context.tokens.len or
                    context.tokens[identifier_index + 1].tag != .colon) continue;
                var type_index = identifier_index + 2;
                while (type_index < context.tokens.len) : (type_index += 1) {
                    switch (context.tokens[type_index].tag) {
                        .comma, .r_paren, .equal, .semicolon, .l_brace => break,
                        .identifier => if (context.tokenIs(type_index, "Allocator")) {
                            try names.put(context.allocator, context.tokenText(identifier_index), {});
                            break;
                        },
                        else => {},
                    }
                }
            }
            lookups.allocator_names = names;
        }
        return lookups.allocator_names.?.contains(name);
    }
};

/// Every `return` with the `;` ending its statement and the innermost earlier
/// return whose statement holds it.
const ReturnStatements = struct {
    keywords: []const u32,
    /// `statementEnd` of each return, or `none_token`.
    ends: []const u32,
    /// Index into `keywords` of the innermost earlier statement holding each
    /// keyword, or `none_token`.
    holders: []const u32,
    /// Whether two statements overlap without one holding the other, which
    /// only unbalanced input can do. Then no lookup trusts `holders`.
    crossing: bool,

    fn init(context: RuleRun) !ReturnStatements {
        var keywords: std.ArrayList(u32) = .empty;
        defer keywords.deinit(context.allocator);
        for (context.tokens, 0..) |token, index| {
            if (token.tag == .keyword_return) try keywords.append(context.allocator, @intCast(index));
        }
        const ends = try context.allocator.alloc(u32, keywords.items.len);
        errdefer context.allocator.free(ends);
        const holders = try context.allocator.alloc(u32, keywords.items.len);
        errdefer context.allocator.free(holders);
        var crossing = false;
        // The statements still open at the current keyword, innermost last.
        var open: std.ArrayList(u32) = .empty;
        defer open.deinit(context.allocator);
        for (keywords.items, 0..) |keyword, entry| {
            while (open.last()) |last| {
                if (ends[last] > keyword) break;
                _ = open.pop();
            }
            holders[entry] = open.last() orelse syntax_scope.none_token;
            const end = context.statementEnd(keyword) orelse {
                ends[entry] = syntax_scope.none_token;
                continue;
            };
            ends[entry] = @intCast(end);
            if (open.last()) |last| crossing = crossing or end > ends[last];
            try open.append(context.allocator, @intCast(entry));
        }
        return .{ .keywords = try keywords.toOwnedSlice(context.allocator), .ends = ends, .holders = holders, .crossing = crossing };
    }

    fn deinit(statements: *ReturnStatements, allocator: std.mem.Allocator) void {
        allocator.free(statements.keywords);
        allocator.free(statements.ends);
        allocator.free(statements.holders);
    }

    /// Appends the returns in `[start, end)` whose statements hold a use of
    /// `name` before `uses_end`, or every return there when statements cross.
    fn appendHolding(
        statements: ReturnStatements,
        allocator: std.mem.Allocator,
        identifiers: *const IdentifierTable,
        list: *std.ArrayList(u32),
        name: []const u8,
        start: usize,
        end: usize,
        uses_end: usize,
    ) !void {
        if (statements.crossing) return list.appendSlice(allocator, positionsWithin(statements.keywords, start, end));
        for (identifiers.within(name, start + 1, uses_end)) |use| {
            const preceding = std.sort.partitionPoint(u32, statements.keywords, @as(usize, use), positionBefore);
            if (preceding == 0) continue;
            // A statement holding the use holds every return between them, so
            // it is the innermost holder of the last return before the use or
            // one of that holder's own holders.
            var holder: u32 = @intCast(preceding - 1);
            while (holder != syntax_scope.none_token and
                (statements.ends[holder] == syntax_scope.none_token or statements.ends[holder] <= use)) holder = statements.holders[holder];
            while (holder != syntax_scope.none_token and statements.keywords[holder] >= start) : (holder = statements.holders[holder]) {
                if (statements.keywords[holder] < end) try list.append(allocator, statements.keywords[holder]);
            }
        }
    }
};

const ScopedName = struct { scope: u32, name: []const u8 };

const ScopedNames = std.HashMapUnmanaged(ScopedName, bool, struct {
    pub fn hash(_: @This(), key: ScopedName) u64 {
        return std.hash.Wyhash.hash(key.scope, key.name);
    }

    pub fn eql(_: @This(), left: ScopedName, right: ScopedName) bool {
        return left.scope == right.scope and std.mem.eql(u8, left.name, right.name);
    }
}, std.hash_map.default_max_load_percentage);

/// A `defer` or `errdefer` that `scopeDeinitializesReceiver` reads, with
/// the end of its body clamped to the scope.
const DeferBody = struct {
    keyword: u32,
    end: u32,

    fn startsBefore(position: usize, body: DeferBody) bool {
        return body.keyword < position;
    }
};

fn lineIndent(source: []const u8, offset: usize) []const u8 {
    const line_start = if (std.mem.findScalarLast(u8, source[0..offset], '\n')) |newline| newline + 1 else 0;
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "'buffer'") != null);
    try std.testing.expectEqualStrings("    errdefer allocator.free(buffer);\n", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "'node'") != null);
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

test "allocator print calls require error-path cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(a: std.mem.Allocator, writer: *std.Io.Writer) ![]u8 {\n" ++
        "    const text = try a.print(\"{s}\", .{\"name\"});\n" ++
        "    try writer.writeAll(text);\n" ++
        "    return text;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("    errdefer a.free(text);\n", findings[0].fixes[0].edits[0].replacement);
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "payload") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "scratch") != null);
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "buffer") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "output") != null);
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
    const findings = try support.findingsWith(arena.allocator(), runWithSummaries, summary_index, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "implicit method receiver allocators produce correct errdefer fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Store = struct { allocator: std.mem.Allocator, fn make(self: *Store) ![]u8 { return self.allocator.alloc(u8, 4); } };" ++
        "fn load(store: *Store) !void {\n    const bytes = try store.make();\n    _ = bytes.len;\n    try finish();\n}";
    const tokens = try tokenize(arena.allocator(), source);
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source, .tokens = tokens }};
    var summary_index = try summaries.build(arena.allocator(), &sources, types.Configuration.defaults());
    defer summary_index.deinit(arena.allocator());
    const findings = try support.findingsWith(arena.allocator(), runWithSummaries, summary_index, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("    errdefer store.allocator.free(bytes);\n", findings[0].fixes[0].edits[0].replacement);
}

test "nested implicit receiver allocators produce correct errdefer fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Store = struct { state: State, fn make(self: *Store) ![]u8 { return self.state.allocator.alloc(u8, 4); } };" ++
        "fn load(store: *Store) !void {\n    const bytes = try store.make();\n    _ = bytes.len;\n    try finish();\n}";
    const tokens = try tokenize(arena.allocator(), source);
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source, .tokens = tokens }};
    var summary_index = try summaries.build(arena.allocator(), &sources, types.Configuration.defaults());
    defer summary_index.deinit(arena.allocator());
    const findings = try support.findingsWith(arena.allocator(), runWithSummaries, summary_index, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("    errdefer store.state.allocator.free(bytes);\n", findings[0].fixes[0].edits[0].replacement);
}

test "owned return wrappers compose allocator paths in errdefer fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn allocate(context: Context) ![]u8 { return context.allocator.alloc(u8, 4); }" ++
        "fn make(state: State) ![]u8 { return allocate(state.context); }" ++
        "fn load(state: State) !void {\n    const bytes = try make(state);\n    _ = bytes.len;\n    try finish();\n}";
    const tokens = try tokenize(arena.allocator(), source);
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source, .tokens = tokens }};
    var summary_index = try summaries.build(arena.allocator(), &sources, types.Configuration.defaults());
    defer summary_index.deinit(arena.allocator());
    const findings = try support.findingsWith(arena.allocator(), runWithSummaries, summary_index, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("    errdefer state.context.allocator.free(bytes);\n", findings[0].fixes[0].edits[0].replacement);
}

test "arena field contracts protect summarized owned returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const RuleRun = struct { allocator: std.mem.Allocator };" ++
        "fn related(context: RuleRun) ![]u8 { return context.allocator.alloc(u8, 4); }" ++
        "fn run(context: RuleRun) !void { const spans = try related(context); try emit(spans); }";
    const tokens = try tokenize(arena.allocator(), source);
    var configuration = types.Configuration.defaults();
    configuration.arena_allocator_contracts = &.{"RuleRun.allocator"};
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source, .tokens = tokens }};
    var summary_index = try summaries.build(arena.allocator(), &sources, configuration);
    defer summary_index.deinit(arena.allocator());
    const findings = try support.findingsWith(arena.allocator(), runWithSummaries, summary_index, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "named arena fields protect summarized owned returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Builder = struct { arena: std.mem.Allocator };" ++
        "fn createText(builder: *Builder) ![]u8 { return builder.arena.alloc(u8, 4); }" ++
        "fn run(builder: *Builder) !void { const text = try createText(builder); try emit(text); }";
    const tokens = try tokenize(arena.allocator(), source);
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source, .tokens = tokens }};
    var summary_index = try summaries.build(arena.allocator(), &sources, types.Configuration.defaults());
    defer summary_index.deinit(arena.allocator());
    const findings = try support.findingsWith(arena.allocator(), runWithSummaries, summary_index, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "arena parameter contracts propagate into private allocation checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn buildLabel(allocator: std.mem.Allocator) !void { const text = try allocator.alloc(u8, 4); try emit(text); }" ++
        "pub fn render(allocator: std.mem.Allocator) !void { try buildLabel(allocator); }";
    var configuration = types.Configuration.defaults();
    configuration.arena_allocator_contracts = &.{"render.allocator"};
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "statement.name") != null);
    try std.testing.expectEqualStrings(
        "    errdefer allocator.free(statement.name);\n",
        findings[0].fixes[0].edits[0].replacement,
    );
}

test "an errdefer releasing the field path covers partial initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Epoch = struct { sources: []u8, other: []u8 };\n" ++
        "fn init(allocator: std.mem.Allocator, count: usize) !Epoch {\n" ++
        "    var epoch: Epoch = undefined;\n" ++
        "    epoch.sources = try allocator.alloc(u8, count);\n" ++
        "    errdefer allocator.free(epoch.sources);\n" ++
        "    epoch.other = try allocator.alloc(u8, count);\n" ++
        "    try check();\n" ++
        "    return epoch;\n" ++
        "}\n" ++
        "fn wrongField(allocator: std.mem.Allocator, count: usize) !Epoch {\n" ++
        "    var window: Epoch = undefined;\n" ++
        "    window.sources = try allocator.alloc(u8, count);\n" ++
        "    errdefer allocator.free(window.other);\n" ++
        "    try check();\n" ++
        "    return window;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, findings, &.{ "other", "sources" });
    try std.testing.expect(std.mem.find(u8, findings[0].message, "epoch.other") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "window.sources") != null);
}

test "missing errdefers in tests are left to the testing allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "test \"copies\" {\n" ++
        "    const allocator = std.testing.allocator;\n" ++
        "    const copy = try allocator.dupe(u8, \"name\");\n" ++
        "    try check();\n" ++
        "    allocator.free(copy);\n" ++
        "}\n";
    try support.expectRules(try findingsFor(arena.allocator(), source), &.{});
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
    try std.testing.expect(std.mem.find(u8, findings[1].message, "object.label") != null);
    try std.testing.expect(std.mem.find(u8, findings[2].message, "object.payload") != null);
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
        if (std.mem.find(u8, finding.message, "later aggregate field") != null) aggregate_field_count += 1;
        if (std.mem.find(u8, finding.message, "container insertion") != null) insertion_count += 1;
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "backing allocation") != null);
}

test "container builders returned whole or in an aggregate need cleanup before the transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn whole(gpa: std.mem.Allocator) !std.ArrayList(u8) {" ++
        "var list: std.ArrayList(u8) = .empty; try list.append(gpa, 1); try list.append(gpa, 2); return list; }" ++
        "fn wrapped(gpa: std.mem.Allocator) !Holder {" ++
        "var list: std.ArrayList(u8) = .empty; try list.append(gpa, 1); try list.append(gpa, 2); return .{ .list = list }; }" ++
        "fn later(gpa: std.mem.Allocator) !std.ArrayList(u8) {" ++
        "var list: std.ArrayList(u8) = .empty; try list.append(gpa, 1); try validate(); return list; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 3), findings.len);
    for (findings) |finding| try std.testing.expect(std.mem.find(u8, finding.message, "backing allocation") != null);
}

test "a single growth with nothing fallible after it needs no container cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn single(gpa: std.mem.Allocator) !std.ArrayList(u8) {" ++
        "var list: std.ArrayList(u8) = .empty; try list.append(gpa, 1); return list; }" ++
        "fn length(gpa: std.mem.Allocator) !usize {" ++
        "var list: std.ArrayList(u8) = .empty; defer list.deinit(gpa); try list.append(gpa, 1); try list.append(gpa, 2); return list.items.len; }" ++
        // An owner's allocator field is often an arena; only `toOwnedSlice` counts for it.
        "fn owned(self: *Graph) !std.ArrayList(u8) {" ++
        "var list: std.ArrayList(u8) = .empty; try list.append(self.a, 1); try list.append(self.a, 2); return list; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "an error return after releasing the value by hand does not leak it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const clean: [:0]const u8 =
        "fn copy(gpa: std.mem.Allocator, text: []const u8) ![]u8 { const owned = try gpa.dupe(u8, text);" ++
        "if (owned.len > 8) { gpa.free(owned); return error.TooLong; } return owned; }";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), clean)).len);
    const leaking: [:0]const u8 =
        "fn copy(gpa: std.mem.Allocator, text: []const u8) ![]u8 { const owned = try gpa.dupe(u8, text);" ++
        "if (owned.len > 8) { gpa.free(owned); return error.TooLong; } try validate(); return owned; }";
    try std.testing.expectEqual(@as(usize, 1), (try findingsFor(arena.allocator(), leaking)).len);
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "backing allocation") != null);
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
        if (std.mem.find(u8, finding.message, "slice builder") != null) builder_count += 1;
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
    for (findings) |finding| try std.testing.expect(std.mem.find(u8, finding.message, "slice builder") == null);
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
        if (std.mem.find(u8, finding.message, "aggregate field") != null) aggregate_field_count += 1;
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "statement") != null);
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

test "documented arena allocator contracts survive public function modifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "/// The allocator should be an arena because returned pointers share its lifetime.\n" ++
        "pub fn build(alloc: std.mem.Allocator) ![]u8 { const bytes = try alloc.alloc(u8, 8);" ++
        "_ = bytes.len; try finish(); return bytes; }";
    const found = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "container documentation does not suppress function error cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "//! The allocator should be an arena for module-owned scratch functions.\n" ++
        "pub fn build(alloc: std.mem.Allocator) ![]u8 { const bytes = try alloc.alloc(u8, 8);" ++
        "_ = bytes.len; try finish(); return bytes; }";
    const found = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.missing_errdefer, found[0].rule);
}

test "the enclosing function scope matches a scan of every earlier function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 =
        \\const top = .{ .value = 1 };
        \\const Outer = struct {
        \\    fn method(callback: *const fn (u8) void, options: struct { flag: bool }) enum { a, b } {
        \\        while (@TypeOf(callback) == fn (u8) void) { callback(1); }
        \\        comptime { _ = options; }
        \\        const Inner = struct { fn deep() void { if (true) { return; } } };
        \\        _ = Inner;
        \\        return .a;
        \\    }
        \\};
        \\test "case" { const local = 1; _ = local; }
        \\test named { { _ = fn () void; } }
        \\fn last() u8 { return 0; }
        \\
    ;
    const tokens = try tokenize(allocator, source);
    var syntax = try @import("../context.zig").Syntax.init(allocator, source, tokens);
    var found: std.ArrayList(types.Finding) = .empty;
    const context = syntax.ruleRun(allocator, types.Configuration.defaults(), &found);
    const keywords = try functionKeywords(context);
    for (0..tokens.len) |target| {
        var expected: ?ScopeRange = null;
        for (tokens[0..target], 0..) |token, declaration_index| {
            if (token.tag != .keyword_fn and token.tag != .keyword_test) continue;
            const body_opening = functionBodyOpening(context, declaration_index, target) orelse continue;
            if (body_opening >= target or tokens[body_opening].tag != .l_brace) continue;
            const body_closing = context.matchingToken(body_opening, .l_brace, .r_brace) orelse continue;
            if (target < body_closing) expected = .{ .declaration = declaration_index, .opening = body_opening, .closing = body_closing };
        }
        try std.testing.expectEqual(expected, functionScopeContaining(context, keywords, target));
    }
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, types.Configuration.defaults());
}

test "plain releases nested in another call and returns nested in a return are found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn nested(allocator: std.mem.Allocator) !void { const bytes = try allocator.alloc(u8, 4); try check(); allocator.free(keep(bytes)); }
        \\fn deferred(allocator: std.mem.Allocator) !void { const owned = try allocator.alloc(u8, 4); defer allocator.free(owned); try check(); }
        \\fn returned(a: std.mem.Allocator, flag: bool) !std.ArrayList(u8) {
        \\    var list: std.ArrayList(u8) = .empty;
        \\    try list.append(a, 1);
        \\    if (flag) return error.Bad;
        \\    try list.append(a, 2);
        \\    return .{ .items = list.items, .capacity = blk: {
        \\        if (flag) return list;
        \\        break :blk list.capacity;
        \\    } };
        \\}
        \\fn check() !void {}
        \\fn keep(bytes: []u8) []u8 { return bytes; }
    ;
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("bytes", source[findings[0].span.start..findings[0].span.end]);
    try std.testing.expectEqualStrings("list", source[findings[1].span.start..findings[1].span.end]);
}
