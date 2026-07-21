const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;

const Resource = struct { acquisition: []const u8, release: []const u8 };

const resources = [_]Resource{
    .{ .acquisition = "openFile", .release = "close" },
    .{ .acquisition = "createFile", .release = "close" },
    .{ .acquisition = "openFileAbsolute", .release = "close" },
    .{ .acquisition = "createFileAbsolute", .release = "close" },
    .{ .acquisition = "openDir", .release = "close" },
    .{ .acquisition = "openDirAbsolute", .release = "close" },
    .{ .acquisition = "openIterableDir", .release = "close" },
    .{ .acquisition = "spawn", .release = "join" },
    .{ .acquisition = "init", .release = "deinit" },
    .{ .acquisition = "initCapacity", .release = "deinit" },
};

pub fn run(context: RuleRun) !void {
    try findReassignedCleanupBindings(context);
    try findErrorOnlyResourceCleanup(context);
    try findUncheckedAllocationSizes(context);
}

fn findReassignedCleanupBindings(context: RuleRun) !void {
    const level = context.level(.defer_uses_reassigned_binding);
    if (level == .off) return;
    for (context.tokens, 0..) |token, defer_index| {
        if (token.tag != .keyword_defer) continue;
        const scope_opening = context.enclosingOpeningBrace(defer_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const defer_end = context.statementEnd(defer_index) orelse continue;
        const cleanup_binding = cleanupBinding(context, defer_index + 1, defer_end) orelse continue;
        for (context.tokens[defer_end + 1 .. scope_end], defer_end + 1..) |candidate, index| {
            if (candidate.tag != .identifier or !context.tokenIs(index, cleanup_binding) or index + 1 >= scope_end or
                !context.refersToBinding(index, cleanup_binding) or context.tokens[index + 1].tag != .equal or
                context.enclosingOpeningBrace(index) != scope_opening) continue;
            if (index > 0 and (context.tokens[index - 1].tag == .keyword_const or
                context.tokens[index - 1].tag == .keyword_var)) continue;
            const assignment_end = context.statementEnd(index) orelse continue;
            if (replacementConsumesOriginal(context, cleanup_binding, index + 2, assignment_end) or
                replacementRestoresWriterList(context, cleanup_binding, defer_end + 1, index, index + 2, assignment_end) or
                replacementRelinquishesOwnership(context, cleanup_binding, defer_end + 1, index, index + 2, assignment_end) or
                releasedBeforeReplacement(context, cleanup_binding, defer_end + 1, index)) continue;
            try context.emit(.{
                .rule = .defer_uses_reassigned_binding,
                .level = level,
                .span = candidate.loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "binding '{s}' is reassigned after deferred cleanup captures it; cleanup will target the replacement and may leak the original value",
                    .{cleanup_binding},
                ),
            });
            break;
        }
    }
}

fn replacementRestoresWriterList(
    context: RuleRun,
    name: []const u8,
    search_start: usize,
    assignment_index: usize,
    replacement_start: usize,
    replacement_end: usize,
) bool {
    var writer_name: ?[]const u8 = null;
    for (context.tokens[replacement_start..replacement_end], replacement_start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "toArrayList") or index < 2 or
            context.tokens[index - 1].tag != .period or context.tokens[index - 2].tag != .identifier) continue;
        writer_name = context.tokenText(index - 2);
        break;
    }
    const expected_writer = writer_name orelse return false;
    for (context.tokens[search_start..assignment_index], search_start..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, "fromArrayList") or
            method_index == 0 or context.tokens[method_index - 1].tag != .period or method_index + 1 >= assignment_index or
            context.tokens[method_index + 1].tag != .l_paren) continue;
        var equal_index = method_index;
        while (equal_index > search_start and context.tokens[equal_index].tag != .equal and
            context.tokens[equal_index].tag != .semicolon) : (equal_index -= 1)
        {}
        if (context.tokens[equal_index].tag != .equal or equal_index < 2 or
            context.tokens[equal_index - 1].tag != .identifier or !context.tokenIs(equal_index - 1, expected_writer) or
            (context.tokens[equal_index - 2].tag != .keyword_var and context.tokens[equal_index - 2].tag != .keyword_const)) continue;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end >= assignment_index) continue;
        for (context.tokens[method_index + 2 .. call_end], method_index + 2..) |argument, argument_index| {
            if (argument.tag == .ampersand and argument_index + 1 < call_end and
                context.tokens[argument_index + 1].tag == .identifier and context.tokenIs(argument_index + 1, name)) return true;
        }
    }
    return false;
}

fn replacementRelinquishesOwnership(
    context: RuleRun,
    name: []const u8,
    search_start: usize,
    assignment_index: usize,
    replacement_start: usize,
    replacement_end: usize,
) bool {
    if (replacement_start + 1 >= replacement_end or context.tokens[replacement_start].tag != .period) return false;
    const resets_to_empty = context.tokens[replacement_start + 1].tag == .identifier and
        context.tokenIs(replacement_start + 1, "empty") or
        replacement_start + 2 < replacement_end and context.tokens[replacement_start + 1].tag == .l_brace and
            context.tokens[replacement_start + 2].tag == .r_brace;
    if (!resets_to_empty) return false;
    for (context.tokens[search_start..assignment_index], search_start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > search_start and context.tokens[index - 1].tag == .equal) return true;
        var opening = index;
        while (opening > search_start and index - opening < 16) {
            opening -= 1;
            if (context.tokens[opening].tag == .l_paren) break;
            if (context.tokens[opening].tag == .semicolon or context.tokens[opening].tag == .l_brace) break;
        }
        if (context.tokens[opening].tag != .l_paren or opening == 0 or
            context.tokens[opening - 1].tag != .identifier) continue;
        if (std.mem.indexOf(u8, context.tokenText(opening - 1), "Owned") != null) return true;
    }
    return false;
}

fn replacementConsumesOriginal(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    var names_original = false;
    var transfers_allocation = false;
    const transfer_methods = [_][]const u8{ "realloc", "reallocAdvanced", "remap" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, name)) names_original = true;
        for (transfer_methods) |method| {
            if (context.tokenIs(index, method)) transfers_allocation = true;
        }
    }
    return names_original and transfers_allocation;
}

fn releasedBeforeReplacement(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    const methods = [_][]const u8{ "free", "destroy", "close", "deinit", "join", "detach", "unlock" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        var cleanup_method = false;
        for (methods) |method| {
            if (context.tokenIs(index, method)) cleanup_method = true;
        }
        if (!cleanup_method) continue;
        if (index >= 2 and context.tokens[index - 1].tag == .period and context.tokenIs(index - 2, name)) return true;
        if (releaseReferencesBinding(context, name, index, end)) return true;
    }
    return false;
}

fn cleanupBinding(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    const methods = [_][]const u8{ "free", "destroy", "close", "deinit", "join", "detach", "unlock" };
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier) continue;
        var cleanup_method = false;
        for (methods) |method| {
            if (context.tokenIs(method_index, method)) cleanup_method = true;
        }
        if (!cleanup_method) continue;
        if (method_index >= 2 and context.tokens[method_index - 1].tag == .period and
            context.tokens[method_index - 2].tag == .identifier and
            (context.tokenIs(method_index, "close") or context.tokenIs(method_index, "deinit") or
                context.tokenIs(method_index, "join") or context.tokenIs(method_index, "detach") or
                context.tokenIs(method_index, "unlock")))
        {
            const receiver_index = method_index - 2;
            const capture_receiver = receiver_index > start and context.tokens[receiver_index - 1].tag == .pipe or
                receiver_index > start + 1 and context.tokens[receiver_index - 1].tag == .asterisk and
                    context.tokens[receiver_index - 2].tag == .pipe;
            if (!capture_receiver) return context.tokenText(receiver_index);
        }
        if (method_index + 2 >= end or context.tokens[method_index + 1].tag != .l_paren) continue;
        const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        for (context.tokens[method_index + 2 .. @min(closing, end)], method_index + 2..) |argument, argument_index| {
            if (argument.tag == .identifier) return context.tokenText(argument_index);
        }
    }
    return null;
}

fn findErrorOnlyResourceCleanup(context: RuleRun) !void {
    const level = context.level(.resource_cleanup_on_error_only);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const resource = acquiredResource(context, declaration_index + 3, declaration_end) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        var error_cleanup = false;
        var normal_cleanup = false;
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |_, index| {
            if (!context.tokenIs(index, resource.release)) continue;
            const statement_start = precedingStatementKeyword(context.tokens, index);
            if (!releaseReferencesBinding(context, binding_name, index, scope_end)) continue;
            if (statement_start == .keyword_errdefer) error_cleanup = true else normal_cleanup = true;
        }
        if (!error_cleanup or normal_cleanup or
            bindingTransferred(context, binding_name, resource.release, declaration_end + 1, scope_end)) continue;
        try context.emit(.{
            .rule = .resource_cleanup_on_error_only,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "resource '{s}' is cleaned up by errdefer only; a successful return leaves {s} unhandled unless ownership is transferred",
                .{ binding_name, resource.release },
            ),
        });
    }
}

fn bindingTransferred(context: RuleRun, name: []const u8, release: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index > start and
            context.tokens[index - 1].tag == .equal) return true;
        if (token.tag == .keyword_return) {
            const return_end = context.statementEnd(index) orelse continue;
            for (context.tokens[index + 1 .. @min(return_end, end)], index + 1..) |return_token, return_index| {
                if (return_token.tag == .identifier and context.tokenIs(return_index, name)) return true;
            }
        }
        if (token.tag == .l_paren and index > start and context.tokens[index - 1].tag == .identifier and
            !context.tokenIs(index - 1, release))
        {
            const closing = context.matchingToken(index, .l_paren, .r_paren) orelse continue;
            if (closing >= end) continue;
            for (index + 1..closing) |argument_index| {
                if (context.refersToBinding(argument_index, name)) return true;
            }
        }
    }
    return false;
}

fn acquiredResource(context: RuleRun, start: usize, end: usize) ?Resource {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        for (resources) |resource| {
            if (!context.tokenIs(index, resource.acquisition)) continue;
            if ((std.mem.eql(u8, resource.acquisition, "init") or std.mem.eql(u8, resource.acquisition, "initCapacity")) and
                !containsManagedType(context, start, index)) continue;
            return resource;
        }
    }
    return null;
}

fn containsManagedType(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{ "ArrayList", "ArrayHashMap", "AutoHashMap", "StringHashMap", "ArenaAllocator", "GeneralPurposeAllocator" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        for (names) |name| if (context.tokenIs(index, name)) return true;
    }
    return false;
}

fn precedingStatementKeyword(tokens: []const std.zig.Token, index: usize) std.zig.Token.Tag {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_defer, .keyword_errdefer => return tokens[cursor].tag,
            .semicolon, .l_brace, .r_brace => return .invalid,
            else => {},
        }
    }
    return .invalid;
}

fn releaseReferencesBinding(context: RuleRun, name: []const u8, method_index: usize, end: usize) bool {
    if (method_index >= 2 and context.tokens[method_index - 1].tag == .period and context.tokenIs(method_index - 2, name)) return true;
    if (method_index + 1 >= end or context.tokens[method_index + 1].tag != .l_paren) return false;
    const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse return false;
    for (context.tokens[method_index + 2 .. @min(closing, end)], method_index + 2..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

fn findUncheckedAllocationSizes(context: RuleRun) !void {
    const level = context.level(.allocation_size_overflow);
    if (level == .off) return;
    const Method = struct { name: []const u8, length_from_end: usize = 1 };
    const methods = [_]Method{
        .{ .name = "alloc" },
        .{ .name = "allocSentinel", .length_from_end = 2 },
        .{ .name = "alignedAlloc" },
        .{ .name = "realloc" },
    };
    for (context.tokens, 0..) |token, method_index| {
        if (token.tag != .identifier or method_index == 0 or method_index + 1 >= context.tokens.len or
            context.tokens[method_index - 1].tag != .period or context.tokens[method_index + 1].tag != .l_paren) continue;
        var allocation_method: ?Method = null;
        for (methods) |method| {
            if (context.tokenIs(method_index, method.name)) allocation_method = method;
        }
        const method = allocation_method orelse continue;
        const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        const length_argument = argumentFromEnd(context.tokens, method_index + 2, closing, method.length_from_end) orelse continue;
        if (uncheckedCapacityGrowth(context, length_argument, method_index)) |growth_index| {
            try context.emit(.{
                .rule = .allocation_size_overflow,
                .level = level,
                .span = context.tokens[growth_index].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "allocation capacity passed to {s} is grown with unchecked multiplication; validate overflow before growing",
                    .{context.tokenText(method_index)},
                ),
            });
            continue;
        }
        const length = declaredAllocationLength(context, length_argument, method_index) orelse length_argument;
        var multiplication_index: ?usize = null;
        var addition_index: ?usize = null;
        var has_runtime_name = false;
        for (context.tokens[length.start..length.end], length.start..) |argument_token, argument_index| {
            if (argument_token.tag == .asterisk) multiplication_index = argument_index;
            if (argument_token.tag == .plus) addition_index = argument_index;
            if (argument_token.tag == .identifier and identifierIsRuntimeBound(context, argument_index, method_index)) {
                has_runtime_name = true;
            }
        }
        const operation = if (multiplication_index != null and has_runtime_name)
            "multiplication"
        else if (addition_index) |operator_index|
            if (rangeHasRuntimeName(context, length.start, operator_index, method_index) and
                rangeHasRuntimeName(context, operator_index + 1, length.end, method_index))
                "addition"
            else
                continue
        else
            continue;
        if (multiplication_index != null and multiplicationFitsMinimumUsize(context, length, method_index)) continue;
        try context.emit(.{
            .rule = .allocation_size_overflow,
            .level = level,
            .span = context.tokens[length.start].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "allocation length passed to {s} uses unchecked runtime {s}; validate overflow before allocating",
                .{ context.tokenText(method_index), operation },
            ),
        });
    }
}

fn uncheckedCapacityGrowth(context: RuleRun, argument: ArgumentRange, before: usize) ?usize {
    if (argument.start + 1 != argument.end or context.tokens[argument.start].tag != .identifier) return null;
    const body_start = containingRuntimeBodyStart(context, before) orelse return null;
    const capacity = context.tokenText(argument.start);
    var growth_index: ?usize = null;
    for (context.tokens[body_start + 1 .. before], body_start + 1..) |_, index| {
        if (context.tokenIs(index, "@mulWithOverflow") or context.tokenIs(index, "maxInt")) return null;
        if (index + 2 >= before or !context.tokenIs(index, capacity) or
            context.tokens[index + 1].tag != .asterisk_equal) continue;
        const factor = context.tokenText(index + 2);
        const value = std.fmt.parseInt(usize, factor, 0) catch continue;
        if (value > 1) growth_index = index;
    }
    return growth_index;
}

fn declaredAllocationLength(context: RuleRun, argument: ArgumentRange, before: usize) ?ArgumentRange {
    if (argument.start + 1 != argument.end or context.tokens[argument.start].tag != .identifier) return null;
    const name = context.tokenText(argument.start);
    var index = before;
    while (index > 1) {
        index -= 1;
        if (!context.tokenIs(index, name) or context.tokens[index - 1].tag != .keyword_const or
            index + 1 >= before or context.tokens[index + 1].tag != .equal) continue;
        const declaration_scope_end = context.enclosingScopeEnd(index) orelse continue;
        if (declaration_scope_end < before) continue;
        const declaration_end = context.statementEnd(index - 1) orelse continue;
        if (declaration_end >= before or index + 2 >= declaration_end) continue;
        return .{ .start = index + 2, .end = declaration_end };
    }
    return null;
}

fn rangeHasRuntimeName(context: RuleRun, start: usize, end: usize, before: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and identifierIsRuntimeBound(context, index, before)) return true;
    }
    return false;
}

fn multiplicationFitsMinimumUsize(context: RuleRun, expression: ArgumentRange, before: usize) bool {
    const text = context.source[context.tokens[expression.start].loc.start..context.tokens[expression.end - 1].loc.end];
    if (std.mem.indexOf(u8, text, "@as(usize") == null and
        std.mem.indexOf(u8, text, "@as( usize") == null) return false;

    var total_bits: usize = 0;
    var factor_count: usize = 0;
    for (context.tokens[expression.start..expression.end], expression.start..) |token, index| {
        if (token.tag != .identifier or !identifierIsRuntimeBound(context, index, before)) continue;
        const bits = unsignedBindingBits(context, context.tokenText(index), before) orelse return false;
        total_bits += bits;
        factor_count += 1;
    }
    return factor_count >= 2 and total_bits <= 32;
}

fn unsignedBindingBits(context: RuleRun, name: []const u8, before: usize) ?usize {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, name)) continue;
        if (index + 2 < before and context.tokens[index + 1].tag == .colon) {
            return unsignedTypeBits(context.tokenText(index + 2));
        }
        if (index == 0 or (context.tokens[index - 1].tag != .keyword_const and
            context.tokens[index - 1].tag != .keyword_var) or index + 1 >= before or
            context.tokens[index + 1].tag != .equal) continue;
        const declaration_end = context.statementEnd(index - 1) orelse continue;
        var value_index = index + 2;
        while (value_index + 2 < declaration_end) : (value_index += 1) {
            if (context.tokens[value_index].tag == .builtin and context.tokenIs(value_index, "@as") and
                context.tokens[value_index + 1].tag == .l_paren)
            {
                return unsignedTypeBits(context.tokenText(value_index + 2));
            }
        }
    }
    return null;
}

fn unsignedTypeBits(name: []const u8) ?usize {
    if (name.len < 2 or name[0] != 'u') return null;
    return std.fmt.parseInt(usize, name[1..], 10) catch null;
}

const ArgumentRange = struct { start: usize, end: usize };

fn argumentFromEnd(tokens: []const std.zig.Token, start: usize, end: usize, from_end: usize) ?ArgumentRange {
    var arguments: [8]ArgumentRange = undefined;
    var argument_count: usize = 0;
    var depth: usize = 0;
    var argument_start = start;
    for (tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (argument_count == arguments.len) return null;
                arguments[argument_count] = .{ .start = argument_start, .end = index };
                argument_count += 1;
                argument_start = index + 1;
            },
            else => {},
        }
    }
    if (argument_start < end) {
        if (argument_count == arguments.len) return null;
        arguments[argument_count] = .{ .start = argument_start, .end = end };
        argument_count += 1;
    }
    if (from_end == 0 or from_end > argument_count) return null;
    return arguments[argument_count - from_end];
}

fn identifierIsRuntimeBound(context: RuleRun, identifier_index: usize, use_index: usize) bool {
    const body_start = containingRuntimeBodyStart(context, use_index) orelse return false;
    const name = context.tokenText(identifier_index);
    for (context.tokens[body_start + 1 .. use_index], body_start + 1..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > body_start + 1 and
            (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var))
        {
            if (context.tokens[index - 1].tag == .keyword_const and declarationValueIsComptime(context, index)) continue;
            return true;
        }
        if (index > body_start and context.tokens[index - 1].tag == .pipe) return true;
        if (index > body_start + 1 and context.tokens[index - 1].tag == .asterisk and context.tokens[index - 2].tag == .pipe) return true;
    }

    var cursor = body_start;
    while (cursor > 0 and context.tokens[cursor].tag != .keyword_fn) : (cursor -= 1) {}
    if (context.tokens[cursor].tag != .keyword_fn) return false;
    for (context.tokens[cursor..body_start], cursor..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index + 2 >= body_start or
            context.tokens[index + 1].tag != .colon) continue;
        // A comptime parameter (explicit keyword or a 'type' parameter) is
        // resolved before runtime and cannot overflow a size computation.
        if (index > 0 and context.tokens[index - 1].tag == .keyword_comptime) continue;
        if (context.tokenIs(index + 2, "type")) continue;
        return true;
    }
    return false;
}

fn declarationValueIsComptime(context: RuleRun, name_index: usize) bool {
    const end = context.statementEnd(name_index) orelse return false;
    var index = name_index + 1;
    while (index < end and context.tokens[index].tag != .equal) : (index += 1) {}
    if (index + 1 >= end) return false;

    const value_start = index + 1;
    if (value_start + 1 < end and context.tokens[value_start].tag == .identifier and
        context.tokens[value_start + 1].tag == .l_paren)
    {
        const call_end = context.matchingToken(value_start + 1, .l_paren, .r_paren) orelse return false;
        if (call_end + 1 != end) return false;

        var returns_type = false;
        for (context.tokens[0..name_index], 0..) |token, function_index| {
            if (token.tag != .keyword_fn or function_index + 2 >= name_index or
                context.tokens[function_index + 1].tag != .identifier or
                !context.tokenIs(function_index + 1, context.tokenText(value_start))) continue;
            const parameters_end = context.matchingToken(function_index + 2, .l_paren, .r_paren) orelse continue;
            if (parameters_end + 1 < name_index and context.tokenIs(parameters_end + 1, "type")) {
                returns_type = true;
                break;
            }
        }
        if (returns_type) {
            for (context.tokens[value_start + 2 .. call_end]) |token| switch (token.tag) {
                .number_literal,
                .char_literal,
                .string_literal,
                .plus,
                .minus,
                .asterisk,
                .slash,
                .percent,
                .comma,
                .l_paren,
                .r_paren,
                => {},
                else => return false,
            };
            return true;
        }
    }

    for (context.tokens[index + 1 .. end]) |token| {
        switch (token.tag) {
            .number_literal, .char_literal, .string_literal, .plus, .minus, .asterisk, .slash, .percent, .l_paren, .r_paren => {},
            else => return false,
        }
    }
    return true;
}

fn containingRuntimeBodyStart(context: RuleRun, use_index: usize) ?usize {
    var candidate: ?usize = null;
    for (context.tokens[0..use_index], 0..) |token, index| {
        if (token.tag != .keyword_fn and token.tag != .keyword_test) continue;
        for (context.tokens[index + 1 .. use_index], index + 1..) |following, body_start| {
            if (following.tag != .l_brace) continue;
            const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse break;
            if (body_end > use_index) candidate = body_start;
            break;
        }
    }
    return candidate;
}

test "cleanup lifetime and allocation size mistakes warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(a: anytype, count: usize) !void { var file = try a.openFile(\"x\", .{}); errdefer file.close(); var bytes = try a.alloc(u8, count * 4); defer a.free(bytes); bytes = try a.alloc(u8, 2); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 3), findings.items.len);
}

test "realloc transfers the original allocation into the replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(a: anytype) !void { var bytes = try a.alloc(u8, 1); defer a.free(bytes); bytes = try a.realloc(bytes, 2); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "advanced realloc and moved empty resources preserve deferred cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn grow(a: anytype) !void { var bytes = try a.alloc(u8, 1); defer a.free(bytes); bytes = try a.reallocAdvanced(bytes, 2, 0); }" ++
        "fn move(owner: anytype, a: anytype) void { var stack = acquire(); defer stack.deinit(a); owner.stack = stack; stack = .{}; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    for (findings.items) |finding| try std.testing.expect(finding.rule != .defer_uses_reassigned_binding);
}

test "cleanup reassignment ignores ownership moves and shadow declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn transfer(a: anytype, supplied: ?[]u8) void {" ++
        "var ranges = acquire(); defer ranges.deinit(a);" ++
        "const result = takeOwned(ranges); ranges = .empty; _ = result;" ++
        "const owned_path = supplied; defer if (owned_path) |path| a.free(path);" ++
        "const path = supplied orelse return; _ = path;" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    for (findings.items) |finding| try std.testing.expect(finding.rule != .defer_uses_reassigned_binding);
}

test "clearing a deferred binding without transferring it still warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn leak(a: anytype) void { var ranges = acquire(); defer ranges.deinit(a); ranges = .empty; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(types.Rule.defer_uses_reassigned_binding, findings.items[0].rule);
}

test "assigning a same-named field does not reassign the deferred binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(owner: anytype, allocator: anytype) !void { var syntax = try parse(); defer syntax.deinit(allocator); owner.syntax = syntax; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    for (findings.items) |finding| try std.testing.expect(finding.rule != .defer_uses_reassigned_binding);
}

test "allocating writers restore their array list before deferred cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn render(allocator: std.mem.Allocator) !void {" ++
        "var output: std.ArrayList(u8) = .empty;" ++
        "defer output.deinit(allocator);" ++
        "var output_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &output);" ++
        "defer output = output_writer.toArrayList();" ++
        "try output_writer.writer.writeAll(\"done\");" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    for (findings.items) |finding| try std.testing.expect(finding.rule != .defer_uses_reassigned_binding);
}

test "constant allocation products are not runtime overflow risks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "const KiB = 1024; fn run(a: anytype) !void { const bytes = try a.alloc(u8, 64 * KiB); defer a.free(bytes); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "allocSentinel checks the length rather than the sentinel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(a: anytype, count: usize) !void { const bytes = try a.allocSentinel(u8, count * 2, 0); defer a.free(bytes); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(types.Rule.allocation_size_overflow, findings.items[0].rule);
}

test "user methods named alloc are not allocator calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "const Slab = struct { pub fn alloc(self: *Slab) *u8 { return self.value; } value: *u8 };";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    for (findings.items) |finding| try std.testing.expect(finding.rule != .allocation_size_overflow);
}

test "appending a resource to a container transfers ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn add(self: anytype, dir: anytype, gpa: anytype) !void { var file = try dir.openFile(\"x\", .{}); errdefer file.close(); try self.files.append(gpa, file); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "locally declared literal factors are not runtime overflow risks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(a: anytype) !void { const w = 640; const h = 480; const bytes = try a.alloc(u8, w * h); defer a.free(bytes); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "literal string lengths are not runtime overflow risks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "test \"input\" { const line = \"hello\"; const repeat = 4_000; const bytes = try std.testing.allocator.alloc(u8, line.len * repeat); defer std.testing.allocator.free(bytes); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "constants from locally instantiated types are not runtime overflow risks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn Block(comptime size: usize) type { return struct { pub const byte_size = size; }; } fn run(a: anytype) !void { const B = Block(64); const bytes = try a.alloc(u8, 3 * B.byte_size / 2); defer a.free(bytes); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "runtime const values and mutable literals still require checked allocation multiplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(a: anytype) !void { const width = loadWidth(); var height = 4; const first = try a.alloc(u8, width * 2); defer a.free(first); const second = try a.alloc(u8, height * 2); defer a.free(second); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    var allocation_findings: usize = 0;
    for (findings.items) |finding| if (finding.rule == .allocation_size_overflow) {
        allocation_findings += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), allocation_findings);
}

test "realloc checks a locally declared runtime length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn grow(a: anytype, bytes: []u8) ![]u8 { const new_len = bytes.len * 2; return a.realloc(bytes, new_len); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    var allocation_findings: usize = 0;
    for (findings.items) |finding| if (finding.rule == .allocation_size_overflow) {
        allocation_findings += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), allocation_findings);
}

test "realloc does not chase mutable or constant declared lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn grow(a: anytype, first: []u8, second: []u8) !void {" ++
        "var runtime_len = first.len * 2; first = try a.realloc(first, runtime_len);" ++
        "const fixed_len = 16 * 2; second = try a.realloc(second, fixed_len); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    for (findings.items) |finding| try std.testing.expect(finding.rule != .allocation_size_overflow);
}

test "allocation lengths ignore declarations from closed sibling scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn grow(a: anytype, bytes: []u8, new_len: usize, inspect: bool) ![]u8 {" ++
        "if (inspect) { const new_len = loadWidth() * 2; consume(new_len); }" ++
        "return a.realloc(bytes, new_len); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    for (findings.items) |finding| try std.testing.expect(finding.rule != .allocation_size_overflow);
}

test "realloc capacity loops require checked growth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn ensure(a: anytype, bytes: []u8, needed: usize) ![]u8 {" ++
        "var capacity = if (bytes.len == 0) 8 else bytes.len * 2;" ++
        "while (capacity < needed) capacity *= 2; return a.realloc(bytes, capacity); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    var allocation_findings: usize = 0;
    for (findings.items) |finding| if (finding.rule == .allocation_size_overflow) {
        allocation_findings += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), allocation_findings);
}

test "guarded realloc capacity growth stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn ensure(a: anytype, bytes: []u8, needed: usize) ![]u8 { var capacity = bytes.len;" ++
        "while (capacity < needed) { if (capacity > std.math.maxInt(usize) / 2) return error.Overflow; capacity *= 2; }" ++
        "return a.realloc(bytes, capacity); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    for (findings.items) |finding| try std.testing.expect(finding.rule != .allocation_size_overflow);
}

test "adding independent runtime lengths before allocation reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn join(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !void {" ++
        "const combined = try allocator.alloc(u8, left.len + right.len); defer allocator.free(combined); }" ++
        "fn extend(allocator: std.mem.Allocator, bytes: []const u8) !void {" ++
        "const extended = try allocator.alloc(u8, bytes.len + 1); defer allocator.free(extended); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    var allocation_findings: usize = 0;
    for (findings.items) |finding| if (finding.rule == .allocation_size_overflow) {
        allocation_findings += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), allocation_findings);
}

test "widened narrow factors that fit usize do not report overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(a: anytype, raw_width: usize, raw_height: usize) !void {" ++
        "const width = @as(u16, @intCast(raw_width)); const height = @as(u16, @intCast(raw_height));" ++
        "const bytes = try a.alloc(u8, @as(usize, @intCast(width)) * height); defer a.free(bytes); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    for (findings.items) |finding| try std.testing.expect(finding.rule != .allocation_size_overflow);
}

test "comptime parameters do not make allocation sizes runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn decode(a: anytype, comptime Word: type) !void { const bytes = try a.alloc(Word, 4 * maxInt(Word)); defer a.free(bytes); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "defer loop captures do not bind later declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn run(values: anytype) !void { defer for (values) |*it| it.close(); var it = try Iterator.init(); defer it.close(); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
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
