const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const rule_types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findInvalidatedPointers(context);
    try findMutatedIteration(context);
    try findInvalidatedMapEntryPointers(context);
    try findStaleIndexMaps(context);
}

fn findInvalidatedPointers(context: RuleRun) !void {
    const level = context.level(.invalidated_element_pointer);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!containsKnownContainer(context, declaration_index + 3, declaration_end)) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const container_name = context.tokenText(declaration_index + 1);
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |candidate, pointer_declaration| {
            if ((candidate.tag != .keyword_const and candidate.tag != .keyword_var) or pointer_declaration + 8 >= scope_end or
                context.tokens[pointer_declaration + 1].tag != .identifier or
                context.tokens[pointer_declaration + 2].tag != .equal or
                context.tokens[pointer_declaration + 3].tag != .ampersand or
                !context.tokenIs(pointer_declaration + 4, container_name) or
                context.tokens[pointer_declaration + 5].tag != .period or
                !context.tokenIs(pointer_declaration + 6, "items") or
                context.tokens[pointer_declaration + 7].tag != .l_bracket) continue;
            const pointer_end = context.statementEnd(pointer_declaration) orelse continue;
            const invalidation = firstInvalidation(context, container_name, pointer_end + 1, scope_end, scope_opening) orelse continue;
            const pointer_name = context.tokenText(pointer_declaration + 1);
            if (!usedAfter(context, pointer_name, invalidation.index + 1, scope_end)) continue;
            try context.emit(.{
                .rule = .invalidated_element_pointer,
                .level = level,
                .span = context.tokens[pointer_declaration + 1].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "pointer '{s}' into '{s}.items' is used after {s}, which may move the container's backing allocation",
                    .{ pointer_name, container_name, invalidation.method },
                ),
            });
        }
    }
    try findFieldElementPointers(context, level);
}

fn findFieldElementPointers(context: RuleRun, level: rule_types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 8 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal or
            context.tokens[declaration_index + 3].tag != .ampersand) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const items_index = itemsField(context, declaration_index + 4, declaration_end) orelse continue;
        const path_start = declaration_index + 4;
        const path_end = items_index - 2;
        if (path_start == path_end and declaredKnownContainerBefore(
            context,
            context.tokenText(path_start),
            declaration_index,
        )) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const invalidation = firstPathInvalidation(context, path_start, path_end, declaration_end + 1, scope_end) orelse continue;
        const pointer_name = context.tokenText(declaration_index + 1);
        if (!usedAfter(context, pointer_name, invalidation.index + 1, scope_end)) continue;
        const path = context.source[context.tokens[path_start].loc.start..context.tokens[path_end].loc.end];
        try context.emit(.{
            .rule = .invalidated_element_pointer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "pointer '{s}' into '{s}.items' is used after {s}, which invalidates or may move the referenced element",
                .{ pointer_name, path, invalidation.method },
            ),
        });
    }
}

fn declaredKnownContainerBefore(context: RuleRun, name: []const u8, before: usize) bool {
    for (context.tokens[0..before], 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 3 >= before or !context.tokenIs(declaration_index + 1, name) or
            context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end < before and containsKnownContainer(context, declaration_index + 3, declaration_end)) return true;
    }
    return false;
}

fn itemsField(context: RuleRun, start: usize, end: usize) ?usize {
    var index = start;
    while (index + 1 < end) : (index += 1) {
        if (!context.tokenIs(index, "items") or index == start or context.tokens[index - 1].tag != .period or
            context.tokens[index + 1].tag != .l_bracket) continue;
        var cursor = start;
        while (cursor < index - 1) : (cursor += 1) {
            const expected: std.zig.Token.Tag = if ((cursor - start) % 2 == 0) .identifier else .period;
            if (context.tokens[cursor].tag != expected) return null;
        }
        return index;
    }
    return null;
}

fn firstPathInvalidation(
    context: RuleRun,
    path_start: usize,
    path_end: usize,
    start: usize,
    end: usize,
) ?Mutation {
    const methods = [_][]const u8{
        "append",
        "appendNTimes",
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
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, context.tokenText(path_start))) continue;
        var cursor = index;
        while (cursor <= path_end - path_start + index and cursor < end) : (cursor += 1) {
            const expected = context.source[context.tokens[path_start + cursor - index].loc.start..context.tokens[path_start + cursor - index].loc.end];
            if (!std.mem.eql(u8, context.tokenText(cursor), expected)) break;
        } else {
            if (cursor + 2 >= end or context.tokens[cursor].tag != .period or
                context.tokens[cursor + 1].tag != .identifier or context.tokens[cursor + 2].tag != .l_paren) continue;
            const method = context.tokenText(cursor + 1);
            for (methods) |candidate| {
                if (std.mem.eql(u8, method, candidate)) return .{ .index = cursor + 1, .method = method };
            }
        }
    }
    return null;
}

fn findMutatedIteration(context: RuleRun) !void {
    const level = context.level(.iterator_invalidated_during_loop);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 7 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal or
            context.tokens[declaration_index + 3].tag != .identifier or context.tokens[declaration_index + 4].tag != .period or
            !context.tokenIs(declaration_index + 5, "iterator") or context.tokens[declaration_index + 6].tag != .l_paren or
            context.tokens[declaration_index + 7].tag != .r_paren) continue;
        const map_name = context.tokenText(declaration_index + 3);
        const iterator_name = context.tokenText(declaration_index + 1);
        const declaration_scope = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(declaration_scope, .l_brace, .r_brace) orelse continue;
        for (context.tokens[declaration_index + 8 .. scope_end], declaration_index + 8..) |candidate, while_index| {
            if (candidate.tag != .keyword_while or while_index + 1 >= scope_end or context.tokens[while_index + 1].tag != .l_paren) continue;
            const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
            if (!containsMethodCall(context, iterator_name, "next", while_index + 2, condition_end)) continue;
            var body_start = condition_end + 1;
            while (body_start < scope_end and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
            if (body_start >= scope_end) continue;
            const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
            const mutation = firstMapMutation(context, map_name, body_start + 1, body_end) orelse continue;
            try context.emit(.{
                .rule = .iterator_invalidated_during_loop,
                .level = level,
                .span = context.tokens[mutation.index].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "{s} mutates map '{s}' while iterator '{s}' is active; the next iteration may use invalid iterator state",
                    .{ mutation.method, map_name, iterator_name },
                ),
            });
        }
    }
}

const Mutation = struct { index: usize, method: []const u8 };

fn firstInvalidation(context: RuleRun, name: []const u8, start: usize, end: usize, scope: usize) ?Mutation {
    const methods = [_][]const u8{ "append", "appendNTimes", "appendSlice", "insert", "resize", "ensureTotalCapacity", "ensureUnusedCapacity", "addOne", "addManyAsArray", "orderedRemove", "swapRemove" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or context.enclosingOpeningBrace(index) != scope or
            index + 3 >= end or context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
            context.tokens[index + 3].tag != .l_paren) continue;
        const method = context.tokenText(index + 2);
        for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return .{ .index = index, .method = method };
    }
    return null;
}

fn firstMapMutation(context: RuleRun, name: []const u8, start: usize, end: usize) ?Mutation {
    const methods = [_][]const u8{ "put", "putNoClobber", "fetchPut", "getOrPut", "remove", "clearAndFree", "clearRetainingCapacity", "rehash" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index + 3 >= end or
            context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
            context.tokens[index + 3].tag != .l_paren) continue;
        const method = context.tokenText(index + 2);
        var mutates = false;
        for (methods) |candidate| {
            if (std.mem.eql(u8, method, candidate)) mutates = true;
        }
        if (!mutates or mutationExitsLoop(context, index, end)) continue;
        return .{ .index = index + 2, .method = method };
    }
    return null;
}

fn mutationExitsLoop(context: RuleRun, mutation_index: usize, body_end: usize) bool {
    const statement_end = context.statementEnd(mutation_index) orelse return false;
    var cursor = statement_end + 1;
    if (cursor >= body_end) return false;
    if (context.tokens[cursor].tag != .keyword_break and context.tokens[cursor].tag != .keyword_return) return false;
    const exit_end = context.statementEnd(cursor) orelse return false;
    cursor = exit_end + 1;
    while (cursor < body_end) : (cursor += 1) {
        if (context.tokens[cursor].tag != .r_brace and context.tokens[cursor].tag != .semicolon) return false;
    }
    return true;
}

fn containsKnownContainer(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{ "ArrayList", "ArrayHashMap", "AutoHashMap", "StringHashMap" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        for (names) |name| if (context.tokenIs(index, name)) return true;
    }
    return false;
}

fn containsMethodCall(context: RuleRun, receiver: []const u8, method: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (context.tokenIs(index, receiver) and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, method) and context.tokens[index + 3].tag == .l_paren) return true;
    }
    return false;
}

fn usedAfter(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index + 1 < end and context.tokens[index + 1].tag == .equal) return false;
        return true;
    }
    return false;
}

fn findInvalidatedMapEntryPointers(context: RuleRun) !void {
    const level = context.level(.invalidated_element_pointer);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 6 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const lookup_index = mapLookupInRange(context, declaration_index + 3, declaration_end) orelse continue;
        const path_end = lookup_index - 2;
        const path_start = receiverPathStart(context, path_end, declaration_index + 3);
        if (path_start > path_end) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const mutation = mapPathMutation(context, path_start, path_end, declaration_end + 1, scope_end) orelse continue;
        const pointer_name = context.tokenText(declaration_index + 1);
        if (!usedAfter(context, pointer_name, mutation.index + 1, scope_end)) continue;
        const path = context.source[context.tokens[path_start].loc.start..context.tokens[path_end].loc.end];
        try context.emit(.{
            .rule = .invalidated_element_pointer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "map entry pointer '{s}' from '{s}' is used after {s}, which may rehash and invalidate it",
                .{ pointer_name, path, mutation.method },
            ),
        });
    }
}

fn findStaleIndexMaps(context: RuleRun) !void {
    const level = context.level(.stale_index_map);
    if (level == .off) return;
    for (context.tokens, 0..) |token, removal_index| {
        if (token.tag != .identifier or (!context.tokenIs(removal_index, "swapRemove") and
            !context.tokenIs(removal_index, "orderedRemove"))) continue;
        const sequence_field = selfFieldBeforeMethod(context, removal_index) orelse continue;
        const function_body = functionBodyContaining(context, removal_index) orelse continue;
        const type_body = context.enclosingOpeningBrace(function_body) orelse continue;
        const type_end = context.matchingToken(type_body, .l_brace, .r_brace) orelse continue;
        if (!fieldHasType(context, sequence_field, "ArrayList", type_body + 1, type_end)) continue;
        const function_end = context.matchingToken(function_body, .l_brace, .r_brace) orelse continue;
        if (indexMapField(context, sequence_field, type_body + 1, type_end)) |index_field| {
            if (pathMutated(context, index_field, removal_index + 1, function_end)) continue;
            try context.emit(.{
                .rule = .stale_index_map,
                .level = level,
                .span = token.loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "{s} changes indices in '{s}' without updating sibling index map '{s}'",
                    .{ context.tokenText(removal_index), sequence_field, index_field },
                ),
            });
            continue;
        }
        if (!context.tokenIs(removal_index, "orderedRemove")) continue;
        const reference_field = sequenceIndexElementField(context, sequence_field, type_body + 1, type_end) orelse continue;
        const removed_index = singleIdentifierArgument(context, removal_index) orelse continue;
        if (selfReferencesRepaired(
            context,
            reference_field,
            removed_index,
            removal_index + 1,
            function_end,
        )) continue;
        try context.emit(.{
            .rule = .stale_index_map,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "orderedRemove changes indices in '{s}' without removing and reindexing references stored in element field '{s}'",
                .{ sequence_field, reference_field },
            ),
        });
    }
}

fn mapLookupInRange(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and (context.tokenIs(index, "getEntry") or context.tokenIs(index, "getPtr") or
            context.tokenIs(index, "getOrPut")) and
            index > start and context.tokens[index - 1].tag == .period and index + 1 < end and
            context.tokens[index + 1].tag == .l_paren) return index;
    }
    return null;
}

fn functionBodyContaining(context: RuleRun, target_index: usize) ?usize {
    var selected: ?usize = null;
    for (context.tokens[0..target_index], 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        var body_start = function_index + 1;
        while (body_start < target_index and context.tokens[body_start].tag != .l_brace and
            context.tokens[body_start].tag != .semicolon) : (body_start += 1)
        {}
        if (body_start >= target_index or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (target_index < body_end) selected = body_start;
    }
    return selected;
}

fn receiverPathStart(context: RuleRun, path_end: usize, lower_bound: usize) usize {
    var start = path_end;
    while (start >= lower_bound + 2 and context.tokens[start - 1].tag == .period and
        context.tokens[start - 2].tag == .identifier) start -= 2;
    return start;
}

fn mapPathMutation(context: RuleRun, path_start: usize, path_end: usize, start: usize, end: usize) ?Mutation {
    const methods = [_][]const u8{ "put", "putNoClobber", "fetchPut", "getOrPut", "rehash", "ensureTotalCapacity" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !samePath(context, path_start, path_end, index, end)) continue;
        const method_index = index + (path_end - path_start) + 2;
        if (method_index + 1 >= end or context.tokens[method_index - 1].tag != .period or
            context.tokens[method_index + 1].tag != .l_paren) continue;
        for (methods) |method| {
            if (context.tokenIs(method_index, method)) return .{ .index = method_index, .method = method };
        }
    }
    if (path_start == path_end) {
        const alias = pointerAliasForPath(context, context.tokenText(path_start), start, end) orelse return null;
        for (context.tokens[start..end], start..) |token, index| {
            if (token.tag != .identifier or !context.tokenIs(index, alias) or index + 3 >= end or
                context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
                context.tokens[index + 3].tag != .l_paren) continue;
            for (methods) |method| if (context.tokenIs(index + 2, method)) {
                return .{ .index = index + 2, .method = method };
            };
        }
    }
    return null;
}

fn pointerAliasForPath(context: RuleRun, path: []const u8, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 4 >= end or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal or
            context.tokens[declaration_index + 3].tag != .ampersand or !context.tokenIs(declaration_index + 4, path)) continue;
        return context.tokenText(declaration_index + 1);
    }
    return null;
}

fn samePath(context: RuleRun, expected_start: usize, expected_end: usize, candidate_start: usize, end: usize) bool {
    const token_count = expected_end - expected_start + 1;
    if (candidate_start + token_count > end) return false;
    for (0..token_count) |offset| {
        const expected = context.source[context.tokens[expected_start + offset].loc.start..context.tokens[expected_start + offset].loc.end];
        if (!std.mem.eql(u8, expected, context.tokenText(candidate_start + offset))) return false;
    }
    return true;
}

fn selfFieldBeforeMethod(context: RuleRun, method_index: usize) ?[]const u8 {
    if (method_index < 4 or context.tokens[method_index - 1].tag != .period or
        context.tokens[method_index - 2].tag != .identifier or context.tokens[method_index - 3].tag != .period or
        !context.tokenIs(method_index - 4, "self")) return null;
    return context.tokenText(method_index - 2);
}

fn fieldHasType(context: RuleRun, field: []const u8, type_name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, field_index| {
        if (token.tag != .identifier or !context.tokenIs(field_index, field) or field_index + 2 >= end or
            context.tokens[field_index + 1].tag != .colon) continue;
        const field_end = fieldTypeEnd(context.tokens, field_index + 2, end);
        for (context.tokens[field_index + 2 .. field_end], field_index + 2..) |type_token, index| {
            if (type_token.tag == .identifier and context.tokenIs(index, type_name)) return true;
        }
    }
    return false;
}

fn indexMapField(context: RuleRun, sequence_field: []const u8, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, field_index| {
        if (token.tag != .identifier or field_index + 2 >= end or context.tokens[field_index + 1].tag != .colon) continue;
        const field_end = fieldTypeEnd(context.tokens, field_index + 2, end);
        var saw_map = false;
        var saw_usize = false;
        for (context.tokens[field_index + 2 .. field_end], field_index + 2..) |type_token, index| {
            if (type_token.tag != .identifier) continue;
            const name = context.tokenText(index);
            if (std.mem.indexOf(u8, name, "HashMap") != null) saw_map = true;
            if (std.mem.eql(u8, name, "usize")) saw_usize = true;
        }
        if (saw_map and saw_usize) {
            const map_field = context.tokenText(field_index);
            if (mapStoresSequenceIndex(context, map_field, sequence_field, start, end)) return map_field;
        }
    }
    return null;
}

fn mapStoresSequenceIndex(
    context: RuleRun,
    map_field: []const u8,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) bool {
    var index = start;
    while (index + 5 < end) : (index += 1) {
        if (!context.tokenIs(index, "self") or context.tokens[index + 1].tag != .period or
            !context.tokenIs(index + 2, map_field) or context.tokens[index + 3].tag != .period or
            (!context.tokenIs(index + 4, "put") and !context.tokenIs(index + 4, "putNoClobber")) or
            context.tokens[index + 5].tag != .l_paren) continue;
        const call_end = context.matchingToken(index + 5, .l_paren, .r_paren) orelse continue;
        var argument_index = index + 6;
        while (argument_index + 4 < call_end) : (argument_index += 1) {
            const has_self = context.tokenIs(argument_index, "self") and context.tokens[argument_index + 1].tag == .period;
            const field_index = argument_index + @as(usize, if (has_self) 2 else 0);
            if (field_index + 2 < call_end and context.tokenIs(field_index, sequence_field) and
                context.tokens[field_index + 1].tag == .period and context.tokenIs(field_index + 2, "items")) return true;
        }
    }
    return false;
}

fn fieldTypeEnd(tokens: []const std.zig.Token, start: usize, end: usize) usize {
    var nesting: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index].tag) {
            .l_paren, .l_bracket => nesting += 1,
            .r_paren, .r_bracket => nesting -|= 1,
            .comma => if (nesting == 0) return index,
            .equal, .semicolon, .l_brace => if (nesting == 0) return index,
            else => {},
        }
    }
    return end;
}

fn pathMutated(context: RuleRun, field: []const u8, start: usize, end: usize) bool {
    const methods = [_][]const u8{ "put", "putNoClobber", "fetchPut", "getOrPut", "clearRetainingCapacity", "clearAndFree" };
    var index = start;
    while (index + 5 < end) : (index += 1) {
        if (!context.tokenIs(index, "self") or context.tokens[index + 1].tag != .period or
            !context.tokenIs(index + 2, field) or context.tokens[index + 3].tag != .period or
            context.tokens[index + 4].tag != .identifier or context.tokens[index + 5].tag != .l_paren) continue;
        for (methods) |method| if (context.tokenIs(index + 4, method)) return true;
    }
    return false;
}

fn sequenceIndexElementField(context: RuleRun, sequence_field: []const u8, start: usize, end: usize) ?[]const u8 {
    var self_index = start;
    while (self_index + 5 < end) : (self_index += 1) {
        if (!context.tokenIs(self_index, "self") or context.tokens[self_index + 1].tag != .period or
            !context.tokenIs(self_index + 2, sequence_field) or context.tokens[self_index + 3].tag != .period or
            !context.tokenIs(self_index + 4, "items") or context.tokens[self_index + 5].tag != .l_bracket) continue;
        const bracket_end = context.matchingToken(self_index + 5, .l_bracket, .r_bracket) orelse continue;
        if (bracket_end + 5 >= end or context.tokens[bracket_end + 1].tag != .period or
            context.tokens[bracket_end + 2].tag != .identifier or context.tokens[bracket_end + 3].tag != .period or
            !context.tokenIs(bracket_end + 4, "append") or context.tokens[bracket_end + 5].tag != .l_paren) continue;
        const call_end = context.matchingToken(bracket_end + 5, .l_paren, .r_paren) orelse continue;
        const value_index = lastSingleIdentifierArgument(context, bracket_end + 6, call_end) orelse continue;
        if (!valueHasSequenceBound(
            context,
            context.tokenText(value_index),
            sequence_field,
            bracket_end + 4,
        )) continue;
        return context.tokenText(bracket_end + 2);
    }
    return null;
}

fn lastSingleIdentifierArgument(context: RuleRun, start: usize, end: usize) ?usize {
    var argument_start = start;
    var depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            argument_start = index + 1;
        },
        else => {},
    };
    return if (argument_start + 1 == end and context.tokens[argument_start].tag == .identifier)
        argument_start
    else
        null;
}

fn valueHasSequenceBound(
    context: RuleRun,
    value_name: []const u8,
    sequence_field: []const u8,
    before: usize,
) bool {
    const function_body = functionBodyContaining(context, before) orelse return false;
    for (context.tokens[function_body + 1 .. before], function_body + 1..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 1 >= before or context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end >= before or !rangeContainsName(context, value_name, if_index + 2, condition_end) or
            !rangeContainsSequenceLength(context, sequence_field, if_index + 2, condition_end) or
            !rangeContainsComparison(context, if_index + 2, condition_end)) continue;
        const guard_end = @min(context.statementEnd(if_index) orelse before, before);
        if (rangeTerminates(context, condition_end + 1, guard_end)) return true;
    }
    return false;
}

fn rangeContainsSequenceLength(context: RuleRun, sequence_field: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 6 < end) : (index += 1) {
        if (context.tokenIs(index, "self") and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, sequence_field) and context.tokens[index + 3].tag == .period and
            context.tokenIs(index + 4, "items") and context.tokens[index + 5].tag == .period and
            context.tokenIs(index + 6, "len")) return true;
    }
    return false;
}

fn rangeContainsComparison(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| switch (token.tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        => return true,
        else => {},
    };
    return false;
}

fn rangeContainsName(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

fn rangeTerminates(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| switch (token.tag) {
        .keyword_return, .keyword_break, .keyword_continue, .keyword_unreachable => return true,
        else => {},
    };
    return false;
}

fn singleIdentifierArgument(context: RuleRun, method_index: usize) ?[]const u8 {
    if (method_index + 3 >= context.tokens.len or context.tokens[method_index + 1].tag != .l_paren or
        context.tokens[method_index + 2].tag != .identifier or context.tokens[method_index + 3].tag != .r_paren) return null;
    return context.tokenText(method_index + 2);
}

fn selfReferencesRepaired(
    context: RuleRun,
    reference_field: []const u8,
    removed_index: []const u8,
    start: usize,
    end: usize,
) bool {
    if (callsOpaqueSelfRepair(context, removed_index, start, end)) return true;
    if (referenceFieldCleared(context, reference_field, start, end)) return true;
    return comparesReferenceWithRemovedIndex(context, reference_field, removed_index, .equal_equal, start, end) and
        referenceFieldRemoval(context, reference_field, start, end) and
        comparesReferenceWithRemovedIndex(context, reference_field, removed_index, .angle_bracket_right, start, end) and
        decrementsReference(context, start, end);
}

fn callsOpaqueSelfRepair(context: RuleRun, removed_index: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (!context.tokenIs(index, "self") or context.tokens[index + 1].tag != .period or
            context.tokens[index + 2].tag != .identifier or context.tokens[index + 3].tag != .l_paren) continue;
        const call_end = context.matchingToken(index + 3, .l_paren, .r_paren) orelse continue;
        if (call_end < end and rangeContainsName(context, removed_index, index + 4, call_end)) return true;
    }
    return false;
}

fn referenceFieldCleared(context: RuleRun, reference_field: []const u8, start: usize, end: usize) bool {
    const methods = [_][]const u8{ "clearRetainingCapacity", "clearAndFree" };
    for (context.tokens[start..end], start..) |token, field_index| {
        if (token.tag != .identifier or !context.tokenIs(field_index, reference_field) or
            field_index + 3 >= end or context.tokens[field_index + 1].tag != .period or
            context.tokens[field_index + 2].tag != .identifier or context.tokens[field_index + 3].tag != .l_paren) continue;
        for (methods) |method| if (context.tokenIs(field_index + 2, method)) return true;
    }
    return false;
}

fn comparesReferenceWithRemovedIndex(
    context: RuleRun,
    reference_field: []const u8,
    removed_index: []const u8,
    comparison: std.zig.Token.Tag,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, comparison_index| {
        if (token.tag != comparison or comparison_index == start or comparison_index + 1 >= end) continue;
        if (storedIndexOperand(context, reference_field, comparison_index - 1, start) and
            context.tokenIs(comparison_index + 1, removed_index)) return true;
        if (context.tokenIs(comparison_index - 1, removed_index) and
            storedIndexOperand(context, reference_field, comparison_index + 1, start)) return true;
    }
    return false;
}

fn storedIndexOperand(context: RuleRun, reference_field: []const u8, operand_index: usize, start: usize) bool {
    const tag = context.tokens[operand_index].tag;
    if (tag == .identifier or tag == .asterisk or tag == .period_asterisk) return true;
    if (tag != .r_bracket) return false;
    const receiver_start = @max(start, operand_index -| 16);
    for (context.tokens[receiver_start..operand_index], receiver_start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, reference_field)) return true;
    }
    return false;
}

fn referenceFieldRemoval(context: RuleRun, reference_field: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or (!context.tokenIs(method_index, "orderedRemove") and
            !context.tokenIs(method_index, "swapRemove")) or method_index < start + 2 or
            context.tokens[method_index - 1].tag != .period or
            !context.tokenIs(method_index - 2, reference_field)) continue;
        return true;
    }
    return false;
}

fn decrementsReference(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .minus_equal and index + 1 < end and
            context.tokens[index + 1].tag == .number_literal and context.tokenIs(index + 1, "1")) return true;
    }
    return false;
}

test "element pointers and active map iterators are invalidated by mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn list(allocator: anytype) !void { var values = std.ArrayList(u8).empty; const first = &values.items[0]; try values.append(allocator, 1); use(first); }\n" ++
        "fn map() !void { var values = std.AutoHashMap(u8, u8).init(a); var iterator = values.iterator(); while (iterator.next()) |_| { try values.put(1, 2); } }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 2), findings.items.len);
}

test "refreshing the element pointer after mutation is not a stale use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn list(allocator: anytype) !void { var values = std.ArrayList(u8).empty; var first = &values.items[0]; try values.append(allocator, 1); first = &values.items[0]; use(first); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "removing an entry and immediately leaving the loop is safe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn evict() !void { var values = std.AutoHashMap(u8, u8).init(a); var iterator = values.iterator(); while (iterator.next()) |entry| { if (match(entry)) { _ = values.remove(1); break; } } }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "getOrPut during iteration invalidates the iterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn map() !void { var values = std.AutoHashMap(u8, u8).init(a); var iterator = values.iterator(); while (iterator.next()) |_| { _ = try values.getOrPut(1); } }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, findings.items[0].message, "getOrPut") != null);
}

test "returning a field element pointer after removal reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn begin(self: *Queue) ?*Job {\n" ++
        "    const job = &self.jobs.items[0];\n" ++
        "    _ = self.jobs.orderedRemove(0);\n" ++
        "    return job;\n" ++
        "}\n";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
}

test "returning an element pointer from a container parameter after growth reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn first(list: *std.ArrayList(u8), allocator: anytype) !*u8 {\n" ++
        "    const element = &list.items[0];\n" ++
        "    try list.appendNTimes(allocator, 1, 2);\n" ++
        "    return element;\n" ++
        "}\n";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(types.Rule.invalidated_element_pointer, findings.items[0].rule);
}

test "map entry pointers expire when a later insertion can rehash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn update(registry: *Registry) !usize { const entry = registry.by_name.getEntry(\"old\") orelse return 0; try registry.by_name.put(\"new\", 1); return entry.value_ptr.*; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(types.Rule.invalidated_element_pointer, findings.items[0].rule);
}

test "map entry pointers expire when an alias mutates the map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(map: anytype) !void { const entry = map.getEntry(\"a\") orelse return;" ++
        "const alias = &map; try alias.put(\"b\", 2); consume(entry.value_ptr); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(rule_types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = rule_types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(rule_types.Rule.invalidated_element_pointer, findings.items[0].rule);
}

test "parallel index maps must be updated after sequence removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "const Registry = struct { rows: std.ArrayList(Row), by_name: std.StringHashMapUnmanaged(usize), " ++
        "fn add(self: *Registry, name: []const u8) !void { try self.by_name.put(name, self.rows.items.len); try self.rows.append(.{}); } " ++
        "fn remove(self: *Registry, index: usize) void { _ = self.rows.swapRemove(index); } };";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(types.Rule.stale_index_map, findings.items[0].rule);
}

test "removing only the deleted key does not reindex a swap-removed element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Registry = struct { rows: std.ArrayList(Row), positions: std.AutoHashMap(u32, usize)," ++
        "fn add(self: *Registry, key: u32) !void { try self.positions.put(key, self.rows.items.len); try self.rows.append(.{}); }" ++
        "fn remove(self: *Registry, key: u32) void { const index = self.positions.get(key) orelse return;" ++
        "_ = self.rows.swapRemove(index); _ = self.positions.remove(key); } };";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(rule_types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = rule_types.Configuration.defaults(), .findings = &findings });
    var warning_count: usize = 0;
    for (findings.items) |finding| {
        if (finding.rule == .stale_index_map) warning_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "nested removal and getOrPut entries retain container invalidation facts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "const Catalog = struct { records: std.ArrayList([]u8), positions: std.StringHashMap(usize), " ++
        "fn remove(self: *Catalog, key: []const u8) void { if (self.positions.get(key)) |index| { _ = self.records.swapRemove(index); } } " ++
        "fn cache(self: *Catalog, key: []const u8) !void { const entry = try self.positions.getOrPut(key); " ++
        "entry.value_ptr.* = self.records.items.len; try self.positions.put(\"other\", self.records.items.len); _ = entry.value_ptr.*; } };";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 2), findings.items.len);
    try std.testing.expectEqual(types.Rule.invalidated_element_pointer, findings.items[0].rule);
    try std.testing.expectEqual(types.Rule.stale_index_map, findings.items[1].rule);
}

test "stored sequence indices must remove references to an ordered-removed element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Node = struct { links: std.ArrayList(u32) }; " ++
        "const Graph = struct { nodes: std.ArrayList(Node), " ++
        "fn addEdge(self: *Graph, from: u32, to: u32) !void { " ++
        "if (to >= self.nodes.items.len) return error.UnknownNode; " ++
        "try self.nodes.items[from].links.append(a, to); } " ++
        "fn removeNode(self: *Graph, id: u32) void { _ = self.nodes.orderedRemove(id); " ++
        "for (self.nodes.items) |*node| for (node.links.items) |*link| { " ++
        "if (link.* > id) link.* -= 1; } } };";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(rule_types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = rule_types.Configuration.defaults(), .findings = &findings });

    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(rule_types.Rule.stale_index_map, findings.items[0].rule);
    try std.testing.expect(std.mem.indexOf(u8, findings.items[0].message, "links") != null);
}

test "removing equal references and shifting later indices repairs ordered removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Node = struct { links: std.ArrayList(u32) }; " ++
        "const Graph = struct { nodes: std.ArrayList(Node), " ++
        "fn addEdge(self: *Graph, from: u32, to: u32) !void { " ++
        "if (to >= self.nodes.items.len) return error.UnknownNode; " ++
        "try self.nodes.items[from].links.append(a, to); } " ++
        "fn removeNode(self: *Graph, id: u32) void { _ = self.nodes.orderedRemove(id); " ++
        "for (self.nodes.items) |*node| { var link_index: usize = 0; " ++
        "while (link_index < node.links.items.len) { " ++
        "if (node.links.items[link_index] == id) { _ = node.links.orderedRemove(link_index); continue; } " ++
        "if (node.links.items[link_index] > id) node.links.items[link_index] -= 1; link_index += 1; } } } };";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(rule_types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = rule_types.Configuration.defaults(), .findings = &findings });

    var stale_count: usize = 0;
    for (findings.items) |finding| {
        if (finding.rule == .stale_index_map) stale_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), stale_count);
}

test "an explicit self repair call keeps self-referential indices opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Node = struct { links: std.ArrayList(u32) }; " ++
        "const Graph = struct { nodes: std.ArrayList(Node), " ++
        "fn addEdge(self: *Graph, from: u32, to: u32) !void { " ++
        "if (to >= self.nodes.items.len) return error.UnknownNode; " ++
        "try self.nodes.items[from].links.append(a, to); } " ++
        "fn removeNode(self: *Graph, id: u32) void { _ = self.nodes.orderedRemove(id); self.repairLinks(id); } };";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(rule_types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = rule_types.Configuration.defaults(), .findings = &findings });

    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "removing from an unrelated list does not repair stored indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Node = struct { links: std.ArrayList(u32) }; " ++
        "const Graph = struct { nodes: std.ArrayList(Node), " ++
        "fn addEdge(self: *Graph, from: u32, to: u32) !void { " ++
        "if (to >= self.nodes.items.len) return error.UnknownNode; " ++
        "try self.nodes.items[from].links.append(a, to); } " ++
        "fn removeNode(self: *Graph, id: u32, scratch: *std.ArrayList(u32)) void { " ++
        "_ = self.nodes.orderedRemove(id); for (self.nodes.items) |*node| { " ++
        "if (node.links.items[0] == id) log(id); _ = scratch.orderedRemove(0); " ++
        "if (node.links.items[0] > id) node.links.items[0] -= 1; } } };";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(rule_types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = rule_types.Configuration.defaults(), .findings = &findings });

    var stale_count: usize = 0;
    for (findings.items) |finding| {
        if (finding.rule == .stale_index_map) stale_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), stale_count);
}

test "index map writes before removal do not repair changed indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Store = struct { rows: std.ArrayList(Row), by_key: std.AutoHashMap(Key, usize), " ++
        "fn replace(self: *Store, allocator: anytype, key: Key, index: usize) !void { " ++
        "try self.by_key.put(allocator, key, self.rows.items.len); _ = self.rows.swapRemove(index); } };";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(rule_types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = rule_types.Configuration.defaults(), .findings = &findings });

    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(rule_types.Rule.stale_index_map, findings.items[0].rule);
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
