const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const owned_call = @import("owned_call.zig");
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findReallocFallbackLeaks(context);
    try findOptionalOwnershipOverwrites(context);
    try findOptionalBindingOverwritesInLoops(context);
    try findShortenedAllocationReturns(context);
    try findDiscardedOwnedRemovals(context);
    try findPartialOwnershipTransfers(context);
}

fn findOptionalBindingOverwritesInLoops(context: RuleRun) !void {
    const level = context.level(.overwritten_owning_value);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 5 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .colon or
            context.tokens[declaration_index + 3].tag != .question_mark or context.tokens[declaration_index + 4].tag != .identifier) continue;
        const binding = context.tokenText(declaration_index + 1);
        const owner_type = context.tokenText(declaration_index + 4);
        if (!typeHasCleanupMethod(context, owner_type)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        var index = declaration_end + 1;
        while (index + 3 < scope_end) : (index += 1) {
            if (!context.tokenIs(index, binding) or context.tokens[index + 1].tag != .equal) continue;
            const assignment_end = context.statementEnd(index) orelse continue;
            if (!rangeCallsMethod(context, "init", index + 2, assignment_end)) continue;
            const loop = loopContaining(context, index) orelse continue;
            if (!rangeContainsTag(context.tokens, assignment_end + 1, loop.end, .keyword_continue)) continue;
            if (rangeReleasesOptionalBinding(context, binding, loop.start + 1, index)) continue;
            try context.emit(.{
                .rule = .overwritten_owning_value,
                .level = level,
                .span = context.tokens[index].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "loop assignment can replace owned optional '{s}' before its previous value is cleaned up",
                    .{binding},
                ),
            });
        }
    }
}

const LoopRange = struct { start: usize, end: usize };

fn loopContaining(context: RuleRun, target: usize) ?LoopRange {
    var selected: ?LoopRange = null;
    for (context.tokens[0..target], 0..) |token, while_index| {
        if (token.tag != .keyword_while) continue;
        var body_start = while_index + 1;
        while (body_start < target and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= target) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (target < body_end) selected = .{ .start = body_start, .end = body_end };
    }
    return selected;
}

fn typeHasCleanupMethod(context: RuleRun, type_name: []const u8) bool {
    const container = typeContainer(context, type_name) orelse return false;
    for (context.tokens[container.start + 1 .. container.end], container.start + 1..) |token, function_index| {
        if (token.tag == .keyword_fn and function_index + 1 < container.end and
            context.tokenIs(function_index + 1, "deinit")) return true;
    }
    return false;
}

fn rangeContainsTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) bool {
    for (tokens[start..end]) |token| if (token.tag == tag) return true;
    return false;
}

fn rangeReleasesOptionalBinding(context: RuleRun, binding: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |_, capture_index| {
        if (!context.tokenIs(capture_index, binding) or capture_index + 4 >= end or
            context.tokens[capture_index + 1].tag != .r_paren or context.tokens[capture_index + 2].tag != .pipe or
            context.tokens[capture_index + 3].tag != .identifier or context.tokens[capture_index + 4].tag != .pipe) continue;
        const capture = context.tokenText(capture_index + 3);
        if (rangeCallsPathMethod(context, capture, "deinit", capture_index + 5, end)) return true;
    }
    return false;
}

fn findReallocFallbackLeaks(context: RuleRun) !void {
    const level = context.level(.unreleased_allocation);
    if (level == .off) return;
    for (context.tokens, 0..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, "realloc") or
            method_index < 2 or context.tokens[method_index - 1].tag != .period or
            context.tokens[method_index - 2].tag != .identifier or method_index + 1 >= context.tokens.len or
            context.tokens[method_index + 1].tag != .l_paren) continue;
        const allocator_name = context.tokenText(method_index - 2);
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        const original = firstBareArgument(context, method_index + 2, call_end) orelse continue;
        var catch_index = call_end + 1;
        while (catch_index < context.tokens.len and catch_index - call_end < 5 and
            context.tokens[catch_index].tag != .keyword_catch) : (catch_index += 1)
        {}
        if (catch_index >= context.tokens.len or context.tokens[catch_index].tag != .keyword_catch) continue;
        var body_open = catch_index + 1;
        while (body_open < context.tokens.len and body_open - catch_index < 6 and
            context.tokens[body_open].tag != .l_brace) : (body_open += 1)
        {}
        if (body_open >= context.tokens.len or context.tokens[body_open].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        const replacement = allocatedBinding(context, allocator_name, body_open + 1, body_end) orelse continue;
        if (!rangeReturnsBinding(context, replacement, body_open + 1, body_end) or
            rangeReleasesBinding(context, original, body_open + 1, body_end)) continue;
        try context.emit(.{
            .rule = .unreleased_allocation,
            .level = level,
            .span = context.tokens[method_index].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "realloc fallback returns replacement '{s}' without releasing original allocation '{s}' after realloc fails",
                .{ replacement, original },
            ),
        });
    }
}

fn findOptionalOwnershipOverwrites(context: RuleRun) !void {
    const level = context.level(.overwritten_owning_value);
    if (level == .off) return;
    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index < 3 or context.tokens[equal_index - 1].tag != .identifier or
            context.tokens[equal_index - 2].tag != .period or context.tokens[equal_index - 3].tag != .identifier) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        if (!rangeAllocates(context, equal_index + 1, statement_end)) continue;
        const base_name = context.tokenText(equal_index - 3);
        const field_name = context.tokenText(equal_index - 1);
        const owner_type = bindingTypeNameBefore(context, base_name, equal_index) orelse continue;
        if (!cleanupIncludesField(context, owner_type, field_name)) continue;
        const branch_open = context.enclosingOpeningBrace(equal_index) orelse continue;
        const capture = optionalFieldCapture(
            context,
            base_name,
            field_name,
            branch_open,
        ) orelse continue;
        if (rangeReleasesBinding(context, capture, branch_open + 1, equal_index)) continue;
        try context.emit(.{
            .rule = .overwritten_owning_value,
            .level = level,
            .span = context.tokens[equal_index - 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "assignment replaces non-null owned field '{s}.{s}' without releasing captured allocation '{s}'",
                .{ base_name, field_name, capture },
            ),
        });
    }
}

fn findShortenedAllocationReturns(context: RuleRun) !void {
    const level = context.level(.mismatched_allocation_release);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!rangeCallsMethod(context, "alloc", declaration_index + 2, declaration_end)) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        var index = declaration_end + 1;
        while (index + 3 < scope_end) : (index += 1) {
            if (!context.tokenIs(index, binding) or context.tokens[index + 1].tag != .l_bracket) continue;
            const slice_end = context.matchingToken(index + 1, .l_bracket, .r_bracket) orelse continue;
            if (slice_end >= scope_end or !containsRange(context, index + 2, slice_end) or
                fullAllocationSlice(context, binding, index + 2, slice_end)) continue;
            const statement_start = statementStart(context.tokens, index);
            if (!rangeStartsWith(context.tokens, statement_start, index, .keyword_return) and
                !rangeStartsWith(context.tokens, statement_start, index, .keyword_break)) continue;
            const producer = enclosingFunctionName(context, declaration_index) orelse continue;
            if (!returnedValueIsFreed(context, producer)) continue;
            try context.emit(.{
                .rule = .mismatched_allocation_release,
                .level = level,
                .span = context.tokens[index].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "allocation '{s}' is returned as a shortened slice, so ordinary allocator.free receives the wrong allocation length",
                    .{binding},
                ),
            });
            break;
        }
    }
}

fn enclosingFunctionName(context: RuleRun, declaration_index: usize) ?[]const u8 {
    for (context.tokens[0..declaration_index], 0..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index + 1 >= declaration_index or
            context.tokens[function_index + 1].tag != .identifier) continue;
        var body_start = function_index + 2;
        while (body_start < declaration_index and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= declaration_index) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (declaration_index < body_end) return context.tokenText(function_index + 1);
    }
    return null;
}

fn returnedValueIsFreed(context: RuleRun, producer: []const u8) bool {
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!rangeCallsFunction(context, producer, declaration_index + 2, declaration_end)) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        if (rangeReleasesBinding(context, context.tokenText(declaration_index + 1), declaration_end + 1, scope_end)) return true;
    }
    return false;
}

fn rangeCallsFunction(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index + 1 < end and
            context.tokens[index + 1].tag == .l_paren and (index == start or context.tokens[index - 1].tag != .period)) return true;
    }
    return false;
}

fn findDiscardedOwnedRemovals(context: RuleRun) !void {
    const level = context.level(.unreleased_allocation);
    if (level == .off) return;
    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or !context.tokenIs(equal_index - 1, "_")) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        const removal = methodCallInRange(context, &.{ "swapRemove", "orderedRemove" }, equal_index + 1, statement_end) orelse continue;
        const field = receiverFieldBeforeMethod(context, removal) orelse continue;
        const element_type = arrayListElementType(context, removal, field) orelse continue;
        const owned_field = sliceFieldOfType(context, element_type) orelse continue;
        if (!containerCleansElementField(context, removal, owned_field)) continue;
        if (removedFieldReleasedBefore(context, field, owned_field, removal)) continue;
        try context.emit(.{
            .rule = .unreleased_allocation,
            .level = level,
            .span = context.tokens[removal].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "discarding {s}'s removed '{s}' value drops owned field '{s}' without cleanup",
                .{ context.tokenText(removal), element_type, owned_field },
            ),
        });
    }
}

fn removedFieldReleasedBefore(context: RuleRun, sequence_field: []const u8, owned_field: []const u8, removal_index: usize) bool {
    const start = removal_index -| 40;
    for (context.tokens[start..removal_index], start..) |token, free_index| {
        if (token.tag != .identifier or !context.tokenIs(free_index, "free")) continue;
        const statement_end = context.statementEnd(free_index) orelse continue;
        if (statement_end > removal_index) continue;
        var saw_sequence = false;
        var saw_owned_field = false;
        for (context.tokens[free_index + 1 .. statement_end], free_index + 1..) |argument, index| {
            if (argument.tag != .identifier) continue;
            if (context.tokenIs(index, sequence_field)) saw_sequence = true;
            if (context.tokenIs(index, owned_field)) saw_owned_field = true;
        }
        if (saw_sequence and saw_owned_field) return true;
    }
    return false;
}

fn findPartialOwnershipTransfers(context: RuleRun) !void {
    const level = context.level(.partial_ownership_transfer);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const callee = calledFunction(context, declaration_index + 2, declaration_end) orelse continue;
        const return_type = functionReturnType(context, callee) orelse continue;
        const owner_scope = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        var index = declaration_end + 1;
        while (index + 2 < scope_end) : (index += 1) {
            if (context.tokens[index].tag != .keyword_return or context.enclosingOpeningBrace(index) != owner_scope) continue;
            const return_end = context.statementEnd(index) orelse continue;
            const transferred_field = bindingFieldInRange(context, binding, index + 1, return_end) orelse continue;
            if (!cleanupIncludesField(context, return_type, transferred_field)) continue;
            const omitted_field = cleanupFieldOtherThan(context, return_type, transferred_field) orelse continue;
            if (rangeCallsPathMethod(context, binding, "deinit", declaration_end + 1, index)) continue;
            try context.emit(.{
                .rule = .partial_ownership_transfer,
                .level = level,
                .span = context.tokens[index].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "return transfers '{s}.{s}' but drops owner '{s}' without cleaning its remaining field '{s}'",
                    .{ binding, transferred_field, binding, omitted_field },
                ),
            });
            break;
        }
    }
}

fn cleanupIncludesField(context: RuleRun, type_name: []const u8, field_name: []const u8) bool {
    const container = typeContainer(context, type_name) orelse return false;
    for (context.tokens[container.start + 1 .. container.end], container.start + 1..) |token, self_index| {
        if (token.tag != .identifier or !context.tokenIs(self_index, "self") or self_index + 2 >= container.end or
            context.tokens[self_index + 1].tag != .period or !context.tokenIs(self_index + 2, field_name)) continue;
        const statement_start = statementStart(context.tokens, self_index);
        const statement_end = @min(context.statementEnd(self_index) orelse continue, container.end);
        if (rangeCallsRelease(context, statement_start, statement_end)) return true;
    }
    return false;
}

fn firstBareArgument(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    if (start >= end or context.tokens[start].tag != .identifier) return null;
    var index = start + 1;
    while (index < end and context.tokens[index].tag != .comma) : (index += 1) {}
    return if (index == start + 1) context.tokenText(start) else null;
}

fn allocatedBinding(context: RuleRun, allocator_name: []const u8, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= end or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end <= end and
            rangeCallsPathMethod(context, allocator_name, "alloc", declaration_index + 2, declaration_end))
        {
            return context.tokenText(declaration_index + 1);
        }
    }
    return null;
}

fn rangeAllocates(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index == 0 or context.tokens[index - 1].tag != .period) continue;
        if (owned_call.releaseForMethod(context.tokenText(index)) != null and !context.tokenIs(index, "realloc")) return true;
    }
    return false;
}

fn rangeReturnsBinding(context: RuleRun, binding: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_return and index + 1 < end and context.tokenIs(index + 1, binding)) return true;
    }
    return false;
}

fn rangeRefersTo(context: RuleRun, binding: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, binding) and
            (index == 0 or context.tokens[index - 1].tag != .period)) return true;
    }
    return false;
}

fn rangeReleasesBinding(context: RuleRun, binding: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or (!context.tokenIs(method_index, "free") and
            !context.tokenIs(method_index, "destroy") and !context.tokenIs(method_index, "deinit"))) continue;
        const statement_end = context.statementEnd(method_index) orelse continue;
        if (statement_end <= end and rangeRefersTo(context, binding, method_index + 1, statement_end)) return true;
    }
    return false;
}

fn rangeCallsMethod(context: RuleRun, method: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, method) and index > 0 and
            context.tokens[index - 1].tag == .period and index + 1 < end and context.tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

fn optionalFieldCapture(context: RuleRun, base: []const u8, field: []const u8, body_open: usize) ?[]const u8 {
    const start = body_open -| 16;
    var saw_field = false;
    for (context.tokens[start..body_open], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, base) and index + 2 < body_open and
            context.tokens[index + 1].tag == .period and context.tokenIs(index + 2, field)) saw_field = true;
        if (saw_field and token.tag == .pipe and index + 2 < body_open and
            context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .pipe)
        {
            return context.tokenText(index + 1);
        }
    }
    return null;
}

fn containsRange(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| if (token.tag == .ellipsis2) return true;
    return false;
}

fn fullAllocationSlice(context: RuleRun, binding: []const u8, start: usize, end: usize) bool {
    var range_index: ?usize = null;
    for (context.tokens[start..end], start..) |token, index| if (token.tag == .ellipsis2) {
        range_index = index;
        break;
    };
    const range = range_index orelse return false;
    if (range + 1 == end) return true;
    return range + 4 == end and context.tokenIs(range + 1, binding) and
        context.tokens[range + 2].tag == .period and context.tokenIs(range + 3, "len");
}

fn statementStart(tokens: []const std.zig.Token, index: usize) usize {
    var cursor = index;
    while (cursor > 0) : (cursor -= 1) switch (tokens[cursor - 1].tag) {
        .semicolon, .l_brace, .r_brace => break,
        else => {},
    };
    return cursor;
}

fn rangeStartsWith(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) bool {
    for (tokens[start..end]) |token| if (token.tag == tag) return true;
    return false;
}

fn methodCallInRange(context: RuleRun, methods: []const []const u8, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        for (methods) |method| if (context.tokenIs(index, method)) return index;
    }
    return null;
}

fn receiverFieldBeforeMethod(context: RuleRun, method_index: usize) ?[]const u8 {
    if (method_index < 2 or context.tokens[method_index - 1].tag != .period or
        context.tokens[method_index - 2].tag != .identifier) return null;
    return context.tokenText(method_index - 2);
}

fn arrayListElementType(context: RuleRun, removal_index: usize, field_name: []const u8) ?[]const u8 {
    const function_body = context.enclosingOpeningBrace(removal_index) orelse return null;
    const container_start = context.enclosingOpeningBrace(function_body) orelse return null;
    const container_end = context.matchingToken(container_start, .l_brace, .r_brace) orelse return null;
    for (context.tokens[container_start + 1 .. container_end], container_start + 1..) |token, field_index| {
        if (token.tag != .identifier or !context.tokenIs(field_index, field_name) or field_index + 6 >= container_end or
            context.enclosingOpeningBrace(field_index) != container_start or
            context.tokens[field_index + 1].tag != .colon) continue;
        for (context.tokens[field_index + 2 .. @min(field_index + 12, container_end)], field_index + 2..) |candidate, index| {
            if (candidate.tag == .identifier and context.tokenIs(index, "ArrayList") and index + 2 < container_end and
                context.tokens[index + 1].tag == .l_paren and context.tokens[index + 2].tag == .identifier)
            {
                return context.tokenText(index + 2);
            }
        }
    }
    return null;
}

fn sliceFieldOfType(context: RuleRun, type_name: []const u8) ?[]const u8 {
    const container = typeContainer(context, type_name) orelse return null;
    for (context.tokens[container.start + 1 .. container.end], container.start + 1..) |token, field_index| {
        if (token.tag != .identifier or field_index + 3 >= container.end or context.tokens[field_index + 1].tag != .colon or
            context.tokens[field_index + 2].tag != .l_bracket or context.tokens[field_index + 3].tag != .r_bracket) continue;
        return context.tokenText(field_index);
    }
    return null;
}

const TokenRange = struct { start: usize, end: usize };

fn typeContainer(context: RuleRun, type_name: []const u8) ?TokenRange {
    for (context.tokens, 0..) |token, name_index| {
        if (token.tag != .identifier or !context.tokenIs(name_index, type_name) or name_index == 0 or
            context.tokens[name_index - 1].tag != .keyword_const) continue;
        var opening = name_index + 1;
        while (opening < context.tokens.len and opening - name_index < 8 and context.tokens[opening].tag != .l_brace) : (opening += 1) {}
        if (opening >= context.tokens.len or context.tokens[opening].tag != .l_brace) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        return .{ .start = opening, .end = closing };
    }
    return null;
}

fn containerCleansElementField(context: RuleRun, removal_index: usize, field_name: []const u8) bool {
    const function_body = context.enclosingOpeningBrace(removal_index) orelse return false;
    const container_start = context.enclosingOpeningBrace(function_body) orelse return false;
    const container_end = context.matchingToken(container_start, .l_brace, .r_brace) orelse return false;
    for (context.tokens[container_start + 1 .. container_end], container_start + 1..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, "free") or method_index + 1 >= context.tokens.len or
            context.tokens[method_index + 1].tag != .l_paren) continue;
        const end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        for (context.tokens[method_index + 2 .. end], method_index + 2..) |argument, index| {
            if (argument.tag == .identifier and context.tokenIs(index, field_name) and index > 0 and
                context.tokens[index - 1].tag == .period) return true;
        }
    }
    return false;
}

fn bindingTypeNameBefore(context: RuleRun, binding: []const u8, before: usize) ?[]const u8 {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, binding) or index + 2 >= before or context.tokens[index + 1].tag != .colon) continue;
        var type_name: ?[]const u8 = null;
        var type_index = index + 2;
        while (type_index < before) : (type_index += 1) {
            switch (context.tokens[type_index].tag) {
                .identifier => {
                    if (!context.tokenIs(type_index, "const")) type_name = context.tokenText(type_index);
                },
                .comma, .r_paren, .equal, .semicolon => break,
                else => {},
            }
        }
        return type_name;
    }
    return null;
}

fn calledFunction(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and index + 1 < end and context.tokens[index + 1].tag == .l_paren and
            (index == 0 or context.tokens[index - 1].tag != .period)) return context.tokenText(index);
    }
    return null;
}

fn functionReturnType(context: RuleRun, name: []const u8) ?[]const u8 {
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 2 >= context.tokens.len or !context.tokenIs(fn_index + 1, name) or
            context.tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = context.matchingToken(fn_index + 2, .l_paren, .r_paren) orelse continue;
        var body_open = parameters_end + 1;
        var selected: ?[]const u8 = null;
        while (body_open < context.tokens.len and context.tokens[body_open].tag != .l_brace) : (body_open += 1) {
            if (context.tokens[body_open].tag == .asterisk) return null;
            if (context.tokens[body_open].tag == .identifier) selected = context.tokenText(body_open);
        }
        return selected;
    }
    return null;
}

fn bindingFieldInRange(context: RuleRun, binding: []const u8, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, binding) and index + 2 < end and
            context.tokens[index + 1].tag == .period and context.tokens[index + 2].tag == .identifier)
        {
            return context.tokenText(index + 2);
        }
    }
    return null;
}

fn cleanupFieldOtherThan(context: RuleRun, type_name: []const u8, transferred: []const u8) ?[]const u8 {
    const container = typeContainer(context, type_name) orelse return null;
    for (context.tokens[container.start + 1 .. container.end], container.start + 1..) |token, self_index| {
        if (token.tag != .identifier or !context.tokenIs(self_index, "self") or self_index + 2 >= container.end or
            context.tokens[self_index + 1].tag != .period or context.tokens[self_index + 2].tag != .identifier) continue;
        const statement_start = statementStart(context.tokens, self_index);
        const statement_end = @min(context.statementEnd(self_index) orelse continue, container.end);
        if (!rangeCallsRelease(context, statement_start, statement_end)) continue;
        const field = context.tokenText(self_index + 2);
        if (!std.mem.eql(u8, field, transferred)) return field;
    }
    return null;
}

fn rangeCallsRelease(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, "free") or context.tokenIs(index, "deinit") or context.tokenIs(index, "destroy")) return true;
    }
    return false;
}

fn rangeCallsPathMethod(context: RuleRun, binding: []const u8, method: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (context.tokenIs(index, binding) and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, method) and context.tokens[index + 3].tag == .l_paren) return true;
    }
    return false;
}

test "ownership edge cases retain every allocation contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Record = struct { payload: ?[]u8, fn deinit(self: Record, a: anytype) void { if (self.payload) |payload| a.free(payload); } };" ++
        "const Row = struct { name: []u8 }; const Registry = struct { rows: std.ArrayList(Row), " ++
        "fn deinit(self: *Registry, a: anytype) void { for (self.rows.items) |row| a.free(row.name); } " ++
        "fn remove(self: *Registry, i: usize) void { _ = self.rows.swapRemove(i); } };" ++
        "fn resize(a: anytype, bytes: []u8, n: usize) ![]u8 { return a.realloc(bytes, n) catch { " ++
        "const replacement = try a.alloc(u8, n); @memcpy(replacement[0..bytes.len], bytes); return replacement; }; }" ++
        "fn short(a: anytype, n: usize) ![]u8 { var records = try a.alloc(u8, 8); return records[0..n]; }" ++
        "fn consume(a: anytype, n: usize) !void { const records = try short(a, n); defer a.free(records); }" ++
        "fn overwrite(a: anytype, record: *Record) !void { if (record.payload) |payload| { record.payload = try a.dupe(u8, payload); } }";
    const findings = try findingsFor(arena.allocator(), source);
    var leaks: usize = 0;
    var mismatches: usize = 0;
    var overwrites: usize = 0;
    for (findings) |finding| switch (finding.rule) {
        .unreleased_allocation => leaks += 1,
        .mismatched_allocation_release => mismatches += 1,
        .overwritten_owning_value => overwrites += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), leaks);
    try std.testing.expectEqual(@as(usize, 1), mismatches);
    try std.testing.expectEqual(@as(usize, 1), overwrites);
}

test "retry loops cannot overwrite an owned optional without cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Owned = struct { bytes: []u8, fn init(a: anytype) !Owned { return .{ .bytes = try a.alloc(u8, 1) }; }" ++
        "fn deinit(self: *Owned, a: anytype) void { a.free(self.bytes); } };" ++
        "fn retry(a: anytype, attempts: usize) !Owned { var pending: ?Owned = null; var i: usize = 0;" ++
        "while (i < attempts) : (i += 1) { pending = try Owned.init(a); if (i + 1 == attempts) return pending.?; continue; }" ++
        "return error.Exhausted; }";
    const found = try findingsFor(arena.allocator(), source);
    var warning_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .overwritten_owning_value) warning_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "transferring one field does not drop the rest of an owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Packet = struct { header: Header, body: ?[]u8, fn deinit(self: Packet) void { self.header.deinit(); a.free(self.body.?); } };" ++
        "fn create() !Packet { return make(); } fn transfer() !Part { const packet = try create(); return .{ .bytes = packet.body.? }; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.partial_ownership_transfer, findings[0].rule);
}

test "realloc fallback leaks do not require reading the original allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn resize(a: anytype, original: []u8, input: []const u8, n: usize) ![]u8 { " ++
        "return a.realloc(original, n) catch { const replacement = try a.alloc(u8, n); " ++
        "@memcpy(replacement[0..input.len], input); return replacement; }; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, findings[0].rule);
}

test "realloc fallback ownership requires one allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn resize(buffer: *Buffer, allocator: anytype, original: []u8, n: usize) ![]u8 { " ++
        "return buffer.realloc(original, n) catch { const replacement = try allocator.alloc(u8, n); " ++
        "return replacement; }; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "pointer-returning accessors and cleaned removed fields retain ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Row = struct { name: []u8 }; const Registry = struct { rows: std.ArrayList(Row), " ++
        "fn deinit(self: *Registry, a: anytype) void { for (self.rows.items) |row| a.free(row.name); } " ++
        "fn remove(self: *Registry, a: anytype, i: usize) void { a.free(self.rows.items[i].name); _ = self.rows.swapRemove(i); } };" ++
        "const Stack = struct { contexts: []Context, fn deinit(self: *Stack) void { free(self.contexts); } }; " ++
        "fn getStack() *Stack { return global_stack; } fn current() Context { const stack = getStack(); return stack.contexts[0]; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "discarded removals use their containing type's field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const OwnedRow = struct { name: []u8 }; const ValueRow = struct { id: usize }; " ++
        "const Decoy = struct { rows: std.ArrayList(OwnedRow) }; " ++
        "const Registry = struct { rows: std.ArrayList(ValueRow), owner: OwnedRow, " ++
        "fn deinit(self: *Registry, a: anytype) void { a.free(self.owner.name); } " ++
        "fn remove(self: *Registry, i: usize) void { _ = self.rows.swapRemove(i); } };";
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

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
