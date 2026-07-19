const std = @import("std");
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
        ) orelse continue;

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
    if (!summaries_only) try findCleanupCapableValuesBeforeInsertion(context, level);
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
            scopeDeinitializesReceiver(context, scope_opening, scope_end, context.tokenText(acquisition.release_owner_end))) continue;
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
        try context.emit(.{
            .rule = .missing_errdefer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "cleanup-capable value '{s}' is not released if its container insertion fails",
                .{binding},
            ),
            .related = try singleRelatedSpan(
                context,
                fallible_index,
                "this fallible insertion leaves the value with the caller on failure",
            ),
        });
    }
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
    var called_name: ?[]const u8 = null;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and index + 1 < end and context.tokens[index + 1].tag == .l_paren and
            (index == start or context.tokens[index - 1].tag != .period))
        {
            called_name = context.tokenText(index);
            break;
        }
    }
    const name = called_name orelse return null;
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
    return .{
        .callable_start = equal + 2,
        .release_owner_start = equal + 2,
        .release_owner_end = path_end - 2,
        .method_index = path_end,
        .release = owned_call.releaseForMethod(context.tokenText(path_end)) orelse "free",
    };
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
    for (context.tokens[scope_opening + 1 .. scope_end], scope_opening + 1..) |token, index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            index + 1 >= context.tokens.len or
            !context.tokenIs(index + 1, root_name)) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[token.loc.start..context.tokens[end].loc.end];
        if (std.mem.indexOf(u8, declaration, "ArenaAllocator") != null or
            std.mem.indexOf(u8, declaration, "FixedBufferAllocator") != null or
            std.mem.indexOf(u8, declaration, ".allocator()") != null) return true;
    }
    return false;
}

const ScopeRange = struct { declaration: usize, opening: usize, closing: usize };

fn functionScopeContaining(context: RuleRun, target: usize) ?ScopeRange {
    var selected: ?ScopeRange = null;
    for (context.tokens[0..target], 0..) |token, declaration_index| {
        if (token.tag != .keyword_fn and token.tag != .keyword_test) continue;
        var body_opening = declaration_index + 1;
        while (body_opening < target and context.tokens[body_opening].tag != .l_brace and
            context.tokens[body_opening].tag != .semicolon) : (body_opening += 1)
        {}
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
