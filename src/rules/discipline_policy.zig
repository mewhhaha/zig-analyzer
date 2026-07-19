const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findLongFunctions(context);
    try findUncheckedIndexing(context);
    try findUnboundedLoops(context);
    try findLongLines(context);
    try findParameterOrder(context);
    try findTaskMarkers(context);
    try findAssertionFreeTests(context);
    try findQuadraticFrontRemoval(context);
}

fn findQuadraticFrontRemoval(context: RuleRun) !void {
    const level = context.level(.quadratic_front_removal);
    if (level == .off) return;

    for (context.tokens, 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 1 >= context.tokens.len or
            context.tokens[while_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        const drained = drainedArrayListPath(context, while_index + 2, condition_end, while_index) orelse continue;
        const body_open = whileBodyOpening(context, condition_end) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        const removal = frontOrderedRemoval(context, drained.start, drained.end, body_open + 1, body_end) orelse continue;
        const path = context.source[context.tokens[drained.start].loc.start..context.tokens[drained.end - 1].loc.end];
        try context.emit(.{
            .rule = .quadratic_front_removal,
            .level = level,
            .span = context.tokens[removal].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "draining ArrayList '{s}' with orderedRemove(0) shifts every remaining element and takes quadratic time",
                .{path},
            ),
        });
    }
}

const PathRange = struct { start: usize, end: usize };

fn drainedArrayListPath(context: RuleRun, start: usize, end: usize, before: usize) ?PathRange {
    for (context.tokens[start..end], start..) |token, items_index| {
        if (token.tag != .identifier or !context.tokenIs(items_index, "items") or items_index < start + 2 or
            items_index + 3 >= end or context.tokens[items_index - 1].tag != .period or
            context.tokens[items_index + 1].tag != .period or !context.tokenIs(items_index + 2, "len") or
            !lengthComparedWithZero(context, items_index + 2, start, end)) continue;
        const path_end = items_index - 1;
        const path_start = pathStartBefore(context, path_end) orelse continue;
        if (!arrayListPathVisible(context, path_start, path_end, before)) continue;
        return .{ .start = path_start, .end = path_end };
    }
    return null;
}

fn lengthComparedWithZero(context: RuleRun, length_index: usize, start: usize, end: usize) bool {
    if (length_index + 2 < end and comparisonOperator(context.tokens[length_index + 1].tag) and
        context.tokens[length_index + 2].tag == .number_literal and context.tokenIs(length_index + 2, "0")) return true;
    return length_index >= start + 2 and context.tokens[length_index - 2].tag == .number_literal and
        context.tokenIs(length_index - 2, "0") and comparisonOperator(context.tokens[length_index - 1].tag);
}

fn comparisonOperator(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .bang_equal,
        => true,
        else => false,
    };
}

fn arrayListPathVisible(context: RuleRun, path_start: usize, path_end: usize, before: usize) bool {
    if (path_end == path_start + 1) {
        return localBindingIsArrayList(context, context.tokenText(path_start), before);
    }
    if (path_end == path_start + 3 and context.tokenIs(path_start, "self")) {
        return selfFieldIsArrayList(context, context.tokenText(path_start + 2), before);
    }
    return false;
}

fn localBindingIsArrayList(context: RuleRun, name: []const u8, before: usize) bool {
    var name_index = before;
    while (name_index > 0) {
        name_index -= 1;
        if (!context.tokenIs(name_index, name) or name_index + 1 >= before) continue;
        if (context.tokens[name_index + 1].tag == .colon) {
            return rangeNamesArrayList(context, name_index + 2, before);
        }
        if (name_index > 0 and
            (context.tokens[name_index - 1].tag == .keyword_const or context.tokens[name_index - 1].tag == .keyword_var) and
            context.tokens[name_index + 1].tag == .equal)
        {
            const declaration_end = @min(context.statementEnd(name_index - 1) orelse before, before);
            return rangeNamesArrayList(context, name_index + 2, declaration_end);
        }
    }
    return false;
}

fn selfFieldIsArrayList(context: RuleRun, field_name: []const u8, before: usize) bool {
    const function_body = functionBodyContaining(context, before) orelse return false;
    const type_body = context.enclosingOpeningBrace(function_body) orelse return false;
    for (context.tokens[type_body + 1 .. function_body], type_body + 1..) |token, field_index| {
        if (token.tag != .identifier or !context.tokenIs(field_index, field_name) or
            field_index + 2 >= function_body or context.tokens[field_index + 1].tag != .colon or
            context.enclosingOpeningBrace(field_index) != type_body) continue;
        return rangeNamesArrayList(context, field_index + 2, function_body);
    }
    return false;
}

fn rangeNamesArrayList(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "ArrayList")) return true;
        if (token.tag == .comma or token.tag == .equal or token.tag == .r_paren or token.tag == .semicolon) return false;
    }
    return false;
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

fn frontOrderedRemoval(
    context: RuleRun,
    expected_start: usize,
    expected_end: usize,
    start: usize,
    end: usize,
) ?usize {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, "orderedRemove") or
            method_index < start + 2 or context.tokens[method_index - 1].tag != .period or
            method_index + 3 >= end or context.tokens[method_index + 1].tag != .l_paren or
            context.tokens[method_index + 2].tag != .number_literal or !context.tokenIs(method_index + 2, "0") or
            context.tokens[method_index + 3].tag != .r_paren) continue;
        const candidate_end = method_index - 1;
        const candidate_start = pathStartBefore(context, candidate_end) orelse continue;
        if (dottedPathsEqual(context, expected_start, expected_end, candidate_start, candidate_end)) return method_index;
    }
    return null;
}

fn findLongFunctions(context: RuleRun) !void {
    const level = context.level(.function_length);
    if (level == .off) return;
    for (context.tokens, 0..) |token, fn_index| {
        if (!isNamedFunction(context, fn_index) or insideKeywordBlock(context, fn_index, .keyword_test) or
            insideKeywordBlock(context, fn_index, .keyword_comptime)) continue;
        const body_open = nextTagBefore(context.tokens, fn_index + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        const lines = lineNumber(context.source, context.tokens[body_end].loc.end) - lineNumber(context.source, token.loc.start) + 1;
        if (lines <= context.configuration.function_length_limit) continue;
        const name = if (fn_index + 1 < context.tokens.len and context.tokens[fn_index + 1].tag == .identifier) context.tokenText(fn_index + 1) else "function";
        try context.emit(.{
            .rule = .function_length,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(context.allocator, "function '{s}' spans {d} lines, exceeding the configured limit of {d}", .{ name, lines, context.configuration.function_length_limit }),
        });
    }
}

fn findUncheckedIndexing(context: RuleRun) !void {
    const level = context.level(.assertion_free_branching);
    if (level == .off) return;
    for (context.tokens, 0..) |token, fn_index| {
        if (!isNamedFunction(context, fn_index)) continue;
        const body_open = nextTagBefore(context.tokens, fn_index + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (lineNumber(context.source, context.tokens[body_end].loc.end) - lineNumber(context.source, token.loc.start) < 8) continue;
        if (hasInvariantCheck(context, body_open + 1, body_end)) continue;
        const bracket = computedBracket(context, body_open + 1, body_end) orelse continue;
        if (hasDominatingWhileBound(context, bracket) or hasDominatingForBound(context, bracket)) continue;
        try context.emit(.{
            .rule = .assertion_free_branching,
            .level = level,
            .span = context.tokens[bracket].loc,
            .message = "computed indexing has no visible assertion, loop bound, unreachable arm, or early-exit validation stating its bounds",
        });
    }
}

fn findUnboundedLoops(context: RuleRun) !void {
    const level = context.level(.unbounded_loop);
    if (level == .off) return;
    for (context.tokens, 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 2 >= context.tokens.len or context.tokens[while_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        const condition = context.source[context.tokens[while_index + 2].loc.start..context.tokens[condition_end - 1].loc.end];
        const body_open = whileBodyOpening(context, condition_end) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (std.mem.indexOfAny(u8, condition, "<>") != null or
            conditionStatesExhaustion(context, while_index + 2, condition_end, body_open, body_end) or
            optionalCaptureStatesExhaustion(context, while_index + 2, condition_end, body_open, body_end) or
            equalityConditionHasUpdate(context, while_index + 2, condition_end, body_open, body_end) or
            callConditionHasUpdate(context, while_index + 2, condition_end, body_open, body_end) or
            bodyHasExhaustionExit(context, body_open + 1, body_end) or
            bodyHasBoundAssertion(context, while_index + 2, condition_end, body_open + 1, body_end) or
            bodyHasExhaustionPredicate(context, body_open + 1, body_end) or
            bodyDrainsCollection(context, body_open + 1, body_end) or
            bodyRetriesInterruptedCall(context, body_open + 1, body_end)) continue;
        if (eventLoopHasBlockingDispatch(context, body_open + 1, body_end)) continue;
        if (bodyHasCounterGuard(context, body_open + 1, body_end) or
            bodyHasDerivedCounterGuard(context, body_open + 1, body_end)) continue;
        try context.emit(.{
            .rule = .unbounded_loop,
            .level = level,
            .span = token.loc,
            .message = "loop has no statically visible iteration bound; state a maximum and handle exhaustion explicitly",
        });
    }
}

fn findLongLines(context: RuleRun) !void {
    const level = context.level(.line_length);
    if (level == .off) return;
    var start: usize = 0;
    while (start < context.source.len) {
        const relative_end = std.mem.indexOfScalar(u8, context.source[start..], '\n') orelse context.source.len - start;
        const end = start + relative_end;
        const line = context.source[start..end];
        const columns = displayColumns(line);
        if (columns > context.configuration.line_length_limit and
            (!context.configuration.line_length_allow_unsplittable or !singleUnsplittableToken(line)))
        {
            try context.emit(.{
                .rule = .line_length,
                .level = level,
                .span = .{ .start = start, .end = end },
                .message = try std.fmt.allocPrint(context.allocator, "line is {d} display columns, exceeding the configured limit of {d}", .{ columns, context.configuration.line_length_limit }),
            });
        }
        if (end == context.source.len) break;
        start = end + 1;
    }
}

fn findParameterOrder(context: RuleRun) !void {
    const allocator_level = context.level(.allocator_first_parameter);
    const comptime_level = context.level(.comptime_parameter_order);
    if (allocator_level == .off and comptime_level == .off) return;
    for (context.tokens, 0..) |_, fn_index| {
        if (!isNamedFunction(context, fn_index) or externallyConstrained(context, fn_index)) continue;
        const opening = nextTagBefore(context.tokens, fn_index + 1, .l_paren, .semicolon) orelse continue;
        const closing = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        if (nextTagBefore(context.tokens, closing + 1, .l_brace, .semicolon) == null) continue;
        var parameter_start = opening + 1;
        var position: usize = 0;
        var saw_runtime = false;
        while (parameter_start < closing) {
            const comma = topLevelComma(context.tokens, parameter_start, closing) orelse closing;
            if (parameter_start < comma) {
                const is_self = position == 0 and context.tokens[parameter_start].tag == .identifier and context.tokenIs(parameter_start, "self");
                const is_comptime = context.tokens[parameter_start].tag == .keyword_comptime;
                if (is_comptime and saw_runtime and comptime_level != .off) try context.emit(.{
                    .rule = .comptime_parameter_order,
                    .level = comptime_level,
                    .span = context.tokens[parameter_start].loc,
                    .message = "comptime parameters configure the function and should precede runtime parameters",
                });
                if (!is_comptime and !is_self) saw_runtime = true;
                const allocator_type = findAllocatorType(context, parameter_start, comma);
                const expected_position: usize = if (firstParameterIsSelf(context, opening + 1, closing)) 1 else 0;
                if (allocator_type != null and position != expected_position and allocator_level != .off) try context.emit(.{
                    .rule = .allocator_first_parameter,
                    .level = allocator_level,
                    .span = context.tokens[allocator_type.?].loc,
                    .message = "std.mem.Allocator should be the first parameter after an optional self parameter",
                });
                position += 1;
            }
            if (comma == closing) break;
            parameter_start = comma + 1;
        }
    }
}

fn isNamedFunction(context: RuleRun, fn_index: usize) bool {
    return context.tokens[fn_index].tag == .keyword_fn and fn_index + 2 < context.tokens.len and
        context.tokens[fn_index + 1].tag == .identifier and context.tokens[fn_index + 2].tag == .l_paren;
}

fn findTaskMarkers(context: RuleRun) !void {
    const level = context.level(.todo_comment);
    if (level == .off) return;
    var line_start: usize = 0;
    while (line_start < context.source.len) {
        const relative_end = std.mem.indexOfScalar(u8, context.source[line_start..], '\n') orelse context.source.len - line_start;
        const line_end = line_start + relative_end;
        const line = context.source[line_start..line_end];
        if (commentStart(line)) |comment_start| {
            const comment = line[comment_start + 2 ..];
            for (context.configuration.todo_markers) |marker| {
                const marker_offset = std.mem.indexOf(u8, comment, marker) orelse continue;
                const absolute = line_start + comment_start + 2 + marker_offset;
                try context.emit(.{
                    .rule = .todo_comment,
                    .level = level,
                    .span = .{ .start = absolute, .end = absolute + marker.len },
                    .message = try std.fmt.allocPrint(context.allocator, "comment contains task marker '{s}'; track or resolve the promise before it becomes invisible debt", .{marker}),
                });
                break;
            }
        }
        if (line_end == context.source.len) break;
        line_start = line_end + 1;
    }
}

fn findAssertionFreeTests(context: RuleRun) !void {
    const level = context.level(.assertion_free_test);
    if (level == .off) return;
    for (context.tokens, 0..) |token, test_index| {
        if (token.tag != .keyword_test) continue;
        const opening = nextTagBefore(context.tokens, test_index + 1, .l_brace, .semicolon) orelse continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        if (testHasAssertion(context, opening + 1, closing)) continue;
        try context.emit(.{
            .rule = .assertion_free_test,
            .level = level,
            .span = token.loc,
            .message = "test block contains no expectation, propagated fallible call, catch, or debug assertion",
        });
    }
}

fn testHasAssertion(context: RuleRun, start: usize, end: usize) bool {
    if (testIsCompileSmoke(context, start, end)) return true;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .keyword_try, .keyword_catch => return true,
        .identifier, .builtin => if (index + 1 < end and context.tokens[index + 1].tag == .l_paren) return true,
        else => {},
    };
    return false;
}

fn testIsCompileSmoke(context: RuleRun, start: usize, end: usize) bool {
    var statement_start = start;
    var statements: usize = 0;
    while (statement_start < end) {
        if (statement_start + 2 >= end or context.tokens[statement_start].tag != .identifier or
            !context.tokenIs(statement_start, "_") or context.tokens[statement_start + 1].tag != .equal) return false;
        const statement_end = context.statementEnd(statement_start) orelse return false;
        if (statement_end >= end) return false;
        statements += 1;
        statement_start = statement_end + 1;
    }
    return statements != 0;
}

fn hasInvariantCheck(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_unreachable) return true;
        if (token.tag == .identifier and context.tokenIs(index, "assert") and index + 1 < end and context.tokens[index + 1].tag == .l_paren) return true;
        if (token.tag == .keyword_if and index + 1 < end) {
            const limited_end = @min(end, index + 20);
            for (context.tokens[index + 1 .. limited_end]) |guard_token| switch (guard_token.tag) {
                .keyword_return, .keyword_break, .keyword_continue => return true,
                else => {},
            };
        }
    }
    return false;
}

fn computedBracket(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .l_bracket or index == 0 or index + 2 >= end or
            !canEndIndexedExpression(context.tokens[index - 1].tag) or
            insideNestedFunction(context, start, index)) continue;
        if (context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .r_bracket) return index;
        if (context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .ellipsis2) return index;
    }
    return null;
}

fn canEndIndexedExpression(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .identifier, .string_literal, .r_paren, .r_bracket, .r_brace => true,
        else => false,
    };
}

fn insideNestedFunction(context: RuleRun, start: usize, index: usize) bool {
    for (context.tokens[start..index], start..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const body_open = nextTagBefore(context.tokens, function_index + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (body_open < index and index < body_end) return true;
    }
    return false;
}

fn hasDominatingWhileBound(context: RuleRun, bracket: usize) bool {
    if (bracket + 2 >= context.tokens.len or context.tokens[bracket + 1].tag != .identifier or
        context.tokens[bracket + 2].tag != .r_bracket) return false;

    const indexed_sequence_start = pathStartBefore(context, bracket) orelse return false;

    for (context.tokens[0..bracket], 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 4 >= bracket or
            context.tokens[while_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end + 1 >= bracket or context.tokens[while_index + 2].tag != .identifier or
            !context.tokenIs(while_index + 2, context.tokenText(bracket + 1)) or
            context.tokens[while_index + 3].tag != .angle_bracket_left) continue;
        const bound_matches = if (condition_end >= while_index + 7 and
            context.tokens[condition_end - 2].tag == .period and context.tokenIs(condition_end - 1, "len"))
            dottedPathsEqual(context, while_index + 4, condition_end - 2, indexed_sequence_start, bracket)
        else if (condition_end == while_index + 5 and context.tokens[condition_end - 1].tag == .number_literal)
            fixedArrayLengthMatches(context, indexed_sequence_start, bracket, condition_end - 1, while_index)
        else
            false;
        if (!bound_matches) continue;

        const loop_body = nextTagBefore(context.tokens, condition_end + 1, .l_brace, .semicolon) orelse continue;
        const loop_end = context.matchingToken(loop_body, .l_brace, .r_brace) orelse continue;
        if (bracket <= loop_body or bracket >= loop_end or mayMutateBeforeIndex(context, loop_body + 1, indexed_sequence_start)) continue;
        return true;
    }
    return false;
}

fn fixedArrayLengthMatches(
    context: RuleRun,
    array_start: usize,
    array_end: usize,
    length_index: usize,
    before: usize,
) bool {
    if (array_end != array_start + 1) return false;
    var matching_length = false;
    for (context.tokens[0..before], 0..) |token, declaration| {
        if ((token.tag != .keyword_var and token.tag != .keyword_const) or declaration + 1 >= before or
            !context.tokenIs(declaration + 1, context.tokenText(array_start))) continue;
        matching_length = declaration + 5 < before and context.tokens[declaration + 2].tag == .colon and
            context.tokens[declaration + 3].tag == .l_bracket and context.tokens[declaration + 4].tag == .number_literal and
            context.tokens[declaration + 5].tag == .r_bracket and
            std.mem.eql(u8, context.tokenText(declaration + 4), context.tokenText(length_index));
    }
    return matching_length;
}

fn hasDominatingForBound(context: RuleRun, bracket: usize) bool {
    if (bracket + 2 >= context.tokens.len or context.tokens[bracket + 1].tag != .identifier or
        context.tokens[bracket + 2].tag != .r_bracket) return false;

    const indexed_sequence_start = pathStartBefore(context, bracket) orelse return false;
    for (context.tokens[0..bracket], 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 8 >= bracket or
            context.tokens[for_index + 1].tag != .l_paren) continue;
        const range_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (range_end + 4 < bracket and range_end >= for_index + 7 and
            context.tokenIs(for_index + 2, "0") and context.tokens[for_index + 3].tag == .ellipsis2 and
            context.tokens[range_end - 2].tag == .period and context.tokenIs(range_end - 1, "len") and
            context.tokens[range_end + 1].tag == .pipe and context.tokens[range_end + 2].tag == .identifier and
            context.tokenIs(range_end + 2, context.tokenText(bracket + 1)) and
            context.tokens[range_end + 3].tag == .pipe and context.tokens[range_end + 4].tag == .l_brace)
        {
            if (dottedPathsEqual(context, for_index + 4, range_end - 2, indexed_sequence_start, bracket)) {
                const loop_end = context.matchingToken(range_end + 4, .l_brace, .r_brace) orelse continue;
                if (bracket < loop_end and !mayMutateBeforeIndex(context, range_end + 5, indexed_sequence_start)) return true;
            }
        }

        if (range_end + 6 >= bracket or context.tokens[range_end + 1].tag != .pipe or
            context.tokens[range_end + 2].tag != .identifier or context.tokens[range_end + 3].tag != .comma or
            context.tokens[range_end + 4].tag != .identifier or
            !context.tokenIs(range_end + 4, context.tokenText(bracket + 1)) or
            context.tokens[range_end + 5].tag != .pipe or context.tokens[range_end + 6].tag != .l_brace) continue;
        const comma = topLevelComma(context.tokens, for_index + 2, range_end) orelse continue;
        if (comma + 3 != range_end or !context.tokenIs(comma + 1, "0") or context.tokens[comma + 2].tag != .ellipsis2) continue;
        const same_sequence = dottedPathsEqual(context, for_index + 2, comma, indexed_sequence_start, bracket);
        if (!same_sequence and !arrayLengthMatchesPath(context, indexed_sequence_start, bracket, for_index + 2, comma, for_index)) continue;

        const loop_end = context.matchingToken(range_end + 6, .l_brace, .r_brace) orelse continue;
        if (bracket < loop_end and !mayMutateBeforeIndex(context, range_end + 7, indexed_sequence_start)) return true;
    }
    return false;
}

fn arrayLengthMatchesPath(
    context: RuleRun,
    array_start: usize,
    array_end: usize,
    path_start: usize,
    path_end: usize,
    before: usize,
) bool {
    if (array_end != array_start + 1) return false;
    const path_length = path_end - path_start;
    for (context.tokens[0..before], 0..) |token, declaration| {
        if ((token.tag != .keyword_var and token.tag != .keyword_const) or declaration + path_length + 7 >= before or
            !context.tokenIs(declaration + 1, context.tokenText(array_start)) or
            context.tokens[declaration + 2].tag != .colon or context.tokens[declaration + 3].tag != .l_bracket or
            !dottedPathsEqual(context, declaration + 4, declaration + 4 + path_length, path_start, path_end)) continue;
        const suffix = declaration + 4 + path_length;
        if (context.tokens[suffix].tag == .period and context.tokenIs(suffix + 1, "len") and
            context.tokens[suffix + 2].tag == .r_bracket) return true;
    }
    return false;
}

fn pathStartBefore(context: RuleRun, end: usize) ?usize {
    var start = end;
    var expect_identifier = true;
    while (start > 0) {
        const previous = context.tokens[start - 1];
        if (expect_identifier and previous.tag == .identifier) {
            start -= 1;
            expect_identifier = false;
        } else if (!expect_identifier and previous.tag == .period) {
            start -= 1;
            expect_identifier = true;
        } else break;
    }
    return if (expect_identifier) null else start;
}

fn dottedPathsEqual(context: RuleRun, left_start: usize, left_end: usize, right_start: usize, right_end: usize) bool {
    if (left_end - left_start != right_end - right_start or left_start >= left_end) return false;
    for (context.tokens[left_start..left_end], context.tokens[right_start..right_end], 0..) |left, right, offset| {
        const expected: std.zig.Token.Tag = if (offset % 2 == 0) .identifier else .period;
        if (left.tag != expected or right.tag != expected or
            !std.mem.eql(u8, context.source[left.loc.start..left.loc.end], context.source[right.loc.start..right.loc.end])) return false;
    }
    return (left_end - left_start) % 2 == 1;
}

fn mayMutateBeforeIndex(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal, .percent_equal, .semicolon => return true,
            .identifier, .builtin => if (index + 1 < end and context.tokens[index + 1].tag == .l_paren) return true,
            else => {},
        }
    }
    return false;
}

fn bodyHasCounterGuard(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_if or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end >= end or !hasBoundComparison(context.tokens[index + 2 .. condition_end])) continue;
        var branch_start = condition_end + 1;
        if (context.tokens[branch_start].tag == .pipe) {
            branch_start = nextTagBefore(context.tokens, branch_start + 1, .pipe, .semicolon) orelse continue;
            branch_start += 1;
        }
        const branch_end = if (context.tokens[branch_start].tag == .l_brace)
            context.matchingToken(branch_start, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(branch_start) orelse continue;
        if (rangeCanExitLoop(context.tokens, branch_start, branch_end)) return true;
    }
    return false;
}

fn bodyHasDerivedCounterGuard(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, declaration| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration + 3 >= end or
            context.tokens[declaration + 1].tag != .identifier or context.tokens[declaration + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration) orelse continue;
        if (declaration_end >= end or !hasBoundComparison(context.tokens[declaration + 3 .. declaration_end])) continue;
        const name = context.tokenText(declaration + 1);
        for (context.tokens[declaration_end + 1 .. end], declaration_end + 1..) |candidate, if_index| {
            if (candidate.tag != .keyword_if or if_index + 3 >= end or context.tokens[if_index + 1].tag != .l_paren or
                !context.tokenIs(if_index + 2, name) or context.tokens[if_index + 3].tag != .r_paren) continue;
            const branch_start = if_index + 4;
            if (branch_start >= end) continue;
            const branch_end = if (context.tokens[branch_start].tag == .l_brace)
                context.matchingToken(branch_start, .l_brace, .r_brace) orelse continue
            else
                context.statementEnd(branch_start) orelse continue;
            if (branch_end <= end and rangeCanExitLoop(context.tokens, branch_start, branch_end)) return true;
        }
    }
    return false;
}

fn hasBoundComparison(tokens: []const std.zig.Token) bool {
    for (tokens) |token| switch (token.tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .equal_equal,
        => return true,
        else => {},
    };
    return false;
}

fn rangeCanExitLoop(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| if (token.tag == .keyword_break or token.tag == .keyword_return) return true;
    return false;
}

fn whileBodyOpening(context: RuleRun, condition_end: usize) ?usize {
    var cursor = condition_end + 1;
    if (cursor >= context.tokens.len) return null;
    if (context.tokens[cursor].tag == .pipe) {
        cursor = nextTagBefore(context.tokens, cursor + 1, .pipe, .semicolon) orelse return null;
        cursor += 1;
    }
    if (cursor < context.tokens.len and context.tokens[cursor].tag == .colon) {
        cursor += 1;
        if (cursor >= context.tokens.len or context.tokens[cursor].tag != .l_paren) return null;
        cursor = (context.matchingToken(cursor, .l_paren, .r_paren) orelse return null) + 1;
    }
    return if (cursor < context.tokens.len and context.tokens[cursor].tag == .l_brace) cursor else null;
}

fn conditionStatesExhaustion(context: RuleRun, start: usize, end: usize, body_open: usize, body_end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const name = context.tokenText(index);
        if (std.mem.eql(u8, name, "next") or std.mem.endsWith(u8, name, "_next") or
            std.mem.eql(u8, name, "iteration")) return true;
        if (std.mem.eql(u8, name, "isClosed") or std.mem.eql(u8, name, "isRunning") or
            std.mem.eql(u8, name, "shouldStop") or std.mem.eql(u8, name, "isShutdown")) return true;
        if (std.mem.eql(u8, name, "eof") and bodyCalls(context, body_open + 1, body_end, "advance")) return true;
    }
    return false;
}

fn bodyCalls(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index + 1 < end and
            context.tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

fn bodyHasExhaustionExit(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_orelse) continue;
        var branch_start = index + 1;
        if (branch_start >= end) continue;
        if (context.tokens[branch_start].tag == .pipe) {
            branch_start = nextTagBefore(context.tokens, branch_start + 1, .pipe, .semicolon) orelse continue;
            branch_start += 1;
        }
        if (branch_start >= end) continue;
        if (context.tokens[branch_start].tag == .keyword_break or context.tokens[branch_start].tag == .keyword_return) return true;
        const branch_end = if (context.tokens[branch_start].tag == .l_brace)
            context.matchingToken(branch_start, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(branch_start) orelse continue;
        if (branch_end <= end and rangeCanExitLoop(context.tokens, branch_start + 1, branch_end)) return true;
    }
    return false;
}

fn bodyHasBoundAssertion(context: RuleRun, condition_start: usize, condition_end: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren or
            (!context.tokenIs(index, "assert") and !context.tokenIs(index, "expect"))) continue;
        const call_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end > end) continue;
        if (hasOrderingComparison(context.tokens[index + 2 .. call_end])) return true;
        if (hasEqualityComparison(context.tokens[index + 2 .. call_end]) and
            rangesShareConditionVariable(context, condition_start, condition_end, index + 2, call_end)) return true;
    }
    return false;
}

fn hasOrderingComparison(tokens: []const std.zig.Token) bool {
    for (tokens) |token| switch (token.tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        => return true,
        else => {},
    };
    return false;
}

fn hasEqualityComparison(tokens: []const std.zig.Token) bool {
    for (tokens) |token| if (token.tag == .equal_equal or token.tag == .bang_equal) return true;
    return false;
}

fn rangesShareConditionVariable(context: RuleRun, left_start: usize, left_end: usize, right_start: usize, right_end: usize) bool {
    for (context.tokens[left_start..left_end], left_start..) |left, left_index| {
        if (left.tag != .identifier or context.tokenIs(left_index, "true") or context.tokenIs(left_index, "false")) continue;
        for (context.tokens[right_start..right_end], right_start..) |right, right_index| {
            if (right.tag == .identifier and context.tokenIs(right_index, context.tokenText(left_index))) return true;
        }
    }
    return false;
}

fn bodyHasExhaustionPredicate(context: RuleRun, start: usize, end: usize) bool {
    if (!rangeCanExitLoop(context.tokens, start, end)) return false;
    return bodyCalls(context, start, end, "eof") or
        bodyCalls(context, start, end, "takeDelimiterExclusive") or
        bodyCalls(context, start, end, "streamDelimiterEnding");
}

fn bodyDrainsCollection(context: RuleRun, start: usize, end: usize) bool {
    if (!rangeCanExitLoop(context.tokens, start, end)) return false;
    var continues = false;
    for (context.tokens[start..end]) |token| if (token.tag == .keyword_continue) {
        continues = true;
        break;
    };
    if (!continues) return false;
    return bodyCalls(context, start, end, "swapRemove") or bodyCalls(context, start, end, "orderedRemove");
}

fn bodyRetriesInterruptedCall(context: RuleRun, start: usize, end: usize) bool {
    if (!bodyCalls(context, start, end, "errno")) return false;
    var saw_interrupted = false;
    var saw_retry = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "INTR")) saw_interrupted = true;
        if (token.tag == .keyword_continue) saw_retry = true;
    }
    return saw_interrupted and saw_retry;
}

fn optionalCaptureStatesExhaustion(
    context: RuleRun,
    condition_start: usize,
    condition_end: usize,
    body_open: usize,
    body_end: usize,
) bool {
    if (condition_end + 2 >= body_open or context.tokens[condition_end + 1].tag != .pipe) return false;
    const capture_end = nextTagBefore(context.tokens, condition_end + 2, .pipe, .semicolon) orelse return false;
    if (capture_end >= body_open) return false;

    for (context.tokens[condition_start..condition_end], condition_start..) |token, index| {
        if ((token.tag == .identifier or token.tag == .builtin) and index + 1 < condition_end and
            context.tokens[index + 1].tag == .l_paren) return true;
    }

    return conditionVariableUpdated(context, condition_start, condition_end, capture_end + 1, body_open) or
        conditionVariableUpdated(context, condition_start, condition_end, body_open + 1, body_end);
}

fn equalityConditionHasUpdate(
    context: RuleRun,
    condition_start: usize,
    condition_end: usize,
    body_open: usize,
    body_end: usize,
) bool {
    var has_equality = false;
    for (context.tokens[condition_start..condition_end]) |token| {
        if (token.tag == .equal_equal or token.tag == .bang_equal) {
            has_equality = true;
            break;
        }
    }
    if (!has_equality) return false;
    if (condition_end + 2 < body_open and context.tokens[condition_end + 1].tag == .colon and
        conditionVariableUpdated(context, condition_start, condition_end, condition_end + 2, body_open)) return true;
    return conditionVariableUpdated(context, condition_start, condition_end, body_open + 1, body_end);
}

fn callConditionHasUpdate(
    context: RuleRun,
    condition_start: usize,
    condition_end: usize,
    body_open: usize,
    body_end: usize,
) bool {
    var has_call = false;
    for (context.tokens[condition_start..condition_end], condition_start..) |token, index| {
        if ((token.tag == .identifier or token.tag == .builtin) and index + 1 < condition_end and
            context.tokens[index + 1].tag == .l_paren)
        {
            has_call = true;
            break;
        }
    }
    return has_call and conditionVariableUpdated(context, condition_start, condition_end, body_open + 1, body_end);
}

fn conditionVariableUpdated(context: RuleRun, condition_start: usize, condition_end: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, operator_index| {
        if (!isAssignmentOperator(token.tag) or operator_index == start or context.tokens[operator_index - 1].tag != .identifier) continue;
        const assigned_path_start = pathStartBefore(context, operator_index) orelse continue;
        if (dottedPathOccurs(context, assigned_path_start, operator_index, condition_start, condition_end)) return true;
        if (assigned_path_start != operator_index - 1) continue;
        for (context.tokens[condition_start..condition_end], condition_start..) |condition_token, condition_index| {
            if (condition_token.tag == .identifier and
                (condition_index == condition_start or context.tokens[condition_index - 1].tag != .period) and
                context.tokenIs(condition_index, context.tokenText(operator_index - 1))) return true;
        }
    }
    return false;
}

fn dottedPathOccurs(context: RuleRun, path_start: usize, path_end: usize, start: usize, end: usize) bool {
    const path_length = path_end - path_start;
    if (path_length == 0 or path_length > end - start) return false;
    var candidate = start;
    while (candidate + path_length <= end) : (candidate += 1) {
        if (dottedPathsEqual(context, path_start, path_end, candidate, candidate + path_length)) return true;
    }
    return false;
}

fn isAssignmentOperator(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal,
        .plus_equal,
        .minus_equal,
        .asterisk_equal,
        .slash_equal,
        .percent_equal,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_right_equal,
        .ampersand_equal,
        .caret_equal,
        .pipe_equal,
        => true,
        else => false,
    };
}

fn eventLoopHasBlockingDispatch(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        if (context.tokenIs(index, "wait") or context.tokenIs(index, "run") or context.tokenIs(index, "dispatch") or
            context.tokenIs(index, "accept") or context.tokenIs(index, "pollEvent")) return true;
    }
    return false;
}

fn firstParameterIsSelf(context: RuleRun, start: usize, end: usize) bool {
    const comma = topLevelComma(context.tokens, start, end) orelse end;
    return start < comma and context.tokens[start].tag == .identifier and context.tokenIs(start, "self");
}

fn findAllocatorType(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "Allocator") and index >= start + 4 and
            context.tokenIs(index - 4, "std") and context.tokenIs(index - 2, "mem")) return index;
    }
    return null;
}

fn externallyConstrained(context: RuleRun, fn_index: usize) bool {
    var cursor = fn_index;
    while (cursor > 0 and fn_index - cursor < 5) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .keyword_extern or context.tokens[cursor].tag == .keyword_export) return true;
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) break;
    }
    return false;
}

fn insideKeywordBlock(context: RuleRun, index: usize, keyword: std.zig.Token.Tag) bool {
    var keyword_scopes: [256]bool = @splat(false);
    var depth: usize = 0;
    for (context.tokens[0..index], 0..) |token, token_index| switch (token.tag) {
        .l_brace => {
            if (depth == keyword_scopes.len) return false;
            const inherited = depth != 0 and keyword_scopes[depth - 1];
            var belongs = false;
            var cursor = token_index;
            while (cursor > 0 and token_index - cursor < 16) {
                cursor -= 1;
                if (context.tokens[cursor].tag == keyword) {
                    belongs = true;
                    break;
                }
                if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .r_brace) break;
            }
            keyword_scopes[depth] = inherited or belongs;
            depth += 1;
        },
        .r_brace => depth -|= 1,
        else => {},
    };
    return depth != 0 and keyword_scopes[depth - 1];
}

fn displayColumns(line: []const u8) usize {
    var columns: usize = 0;
    var view = std.unicode.Utf8View.init(line) catch return line.len;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == '\t') {
            columns += 8 - (columns % 8);
        } else {
            columns += 1;
        }
    }
    return columns;
}

fn singleUnsplittableToken(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.indexOf(u8, trimmed, "http://") != null or std.mem.indexOf(u8, trimmed, "https://") != null) return true;
    return std.mem.indexOfAny(u8, trimmed, " \t") == null;
}

fn commentStart(line: []const u8) ?usize {
    var quote: ?u8 = null;
    var escaped = false;
    var index: usize = 0;
    while (index + 1 < line.len) : (index += 1) {
        const byte = line[index];
        if (quote) |delimiter| {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == delimiter) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '/' and line[index + 1] == '/') return index;
    }
    return null;
}

fn lineNumber(source: []const u8, offset: usize) usize {
    return std.mem.count(u8, source[0..@min(offset, source.len)], "\n") + 1;
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

test "disciplined and policy rules report their bounded local shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_writer: std.Io.Writer.Allocating = .init(arena.allocator());
    try source_writer.writer.writeAll(
        "fn inspect(buffer: []u8, index: usize) u8 {\n" ++
            "const one = 1;\nconst two = 2;\nconst three = 3;\nconst four = 4;\n" ++
            "const five = 5;\nconst six = 6;\nconst seven = 7;\n_ = one + two + three + four + five + six + seven;\n" ++
            "return buffer[index];\n}\n" ++
            "fn spin(flag: bool) void { while (flag) {} }\n" ++
            "fn configure(value: u8, comptime T: type, other: u8, allocator: std.mem.Allocator) void { _ = T; _ = value; _ = other; _ = allocator; }\n" ++
            "// TODO replace this marker\n" ++
            "test \"empty assertion\" { const value = 1; _ = value; }\n" ++
            "const long = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\";\n" ++
            "fn longFunction() void {\n",
    );
    for (0..70) |_| try source_writer.writer.writeAll("_ = 1;\n");
    try source_writer.writer.writeAll("}\n");
    const bytes = try source_writer.toOwnedSlice();
    const source = try arena.allocator().dupeZ(u8, bytes);
    var configuration = types.Configuration.defaults();
    const expected_rules = [_]types.Rule{
        .function_length,
        .assertion_free_branching,
        .unbounded_loop,
        .line_length,
        .allocator_first_parameter,
        .comptime_parameter_order,
        .todo_comment,
        .assertion_free_test,
    };
    for (expected_rules) |rule| configuration.levels[@intFromEnum(rule)] = .information;
    const found = try findingsFor(arena.allocator(), source, configuration);
    for (expected_rules) |rule| {
        var seen = false;
        for (found) |finding| if (finding.rule == rule) {
            seen = true;
            break;
        };
        if (!seen) std.debug.print("missing discipline test finding {s}\n", .{rule.code()});
        try std.testing.expect(seen);
    }
}

test "a queue pop loop states exhaustion through its optional capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn drain(mailbox: *Mailbox) void {\n" ++
        "while (mailbox.pop()) |message| {\n" ++
        "consume(message);\n" ++
        "}\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbounded_loop)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "optional-producing calls state exhaustion through their captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn decode(iterator: *Iterator) !void {\n" ++
        "while (iterator.nextCodepoint()) |codepoint| consume(codepoint);\n" ++
        "while (try parseOneItem(iterator)) |value| consume(value);\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbounded_loop)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "boolean next calls and orelse exits state iterator exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn visit(iterator: *Iterator) !void {\n" ++
        "while (iterator.next()) { consume(iterator.value()); }\n" ++
        "while (placement_iterator_next(iterator)) { consume(iterator.value()); }\n" ++
        "while (true) { const value = (try iterator.nextValue()) orelse break; consume(value); }\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbounded_loop)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "optional traversal must visibly advance its condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn visit(first: ?*Node, state: *State) void {\n" ++
        "var node = first;\n" ++
        "while (node) |value| : (node = value.next) { consume(value); }\n" ++
        "while (state.row) |row| { state.row = row.next; }\n" ++
        "while (first) |value| { consume(value); }\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbounded_loop)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "equality loop updates state used by its condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn scan(bytes: []const u8, end: usize) void {\n" ++
        "var offset: usize = 0;\n" ++
        "while (offset != end) : (offset += 1) { consume(bytes[offset]); }\n" ++
        "while (bytes.len == end) { consume(bytes); }\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbounded_loop)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "body guards and blocking waits state loop termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn consumeAll(input: []const u8, pipeline: *Pipeline) void {\n" ++
        "var index: usize = 0;\n" ++
        "while (true) { if (index >= input.len) break; consume(input[index]); index += 1; }\n" ++
        "while (pipeline.count == 0) { pipeline.ready.wait(&pipeline.mutex); }\n" ++
        "while (glib.MainContext.iteration(null, 0) != 0) {}\n" ++
        "while (!pipeline.done) { pipeline.loop.pollEvent(); }\n" ++
        "while (!pipeline.isClosed()) { pipeline.handleOne(); }\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbounded_loop)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "input exhaustion and compound sentinel updates state loop termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(parser: *Parser, state: *State, input: []const u8) !void {\n" ++
        "while (!parser.eof()) { parser.advance(); }\n" ++
        "while (state.current != state.active and state.current != state.last) { state.current = state.current.next.?; }\n" ++
        "while (state.current.isUsed()) { state.current = state.current.next.?; }\n" ++
        "var index: usize = 0;\n" ++
        "while (true) { try testing.expect(index < input.len); index += 1; if (input[index] == 0) return; }\n" ++
        "while (true) { parser.advance(); if (parser.eof()) break; }\n" ++
        "drain: while (true) { if (state.expired()) { _ = state.entries.swapRemove(0); continue :drain; } break :drain; }\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbounded_loop)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "unbraced while expressions do not borrow nested braces as their body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(reader: *Reader) void {\n" ++
        "while (true) switch (reader.readByte() catch ',') { ',' => break, else => {}, };\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbounded_loop)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an unrelated equality assertion does not bound a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn generate(value: usize) void {\n" ++
        "while (true) { assert(value == value); consume(value); }\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbounded_loop)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "derived bounds readers and interrupted calls state loop termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(reader: *Reader, duration: usize) !void {\n" ++
        "while (true) { const finished = elapsed() >= duration; if (finished) return; step(); }\n" ++
        "while (reader.seek != reader.end) { _ = reader.streamDelimiterEnding('\\n') catch return; if (reader.empty()) break; }\n" ++
        "while (true) { switch (posix.errno(retry())) { .SUCCESS => break, .INTR => continue, else => return error.Failed, } }\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbounded_loop)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a matching while condition establishes the bound for its first indexed access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn removeValue(values: *Values, target: u8) void {\n" ++
        "var index: usize = 0;\n" ++
        "while (index < values.items.len) {\n" ++
        "if (values.items[index] == target) {\n" ++
        "_ = values.swapRemove(index);\n" ++
        "continue;\n" ++
        "}\n" ++
        "index += 1;\n" ++
        "}\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.assertion_free_branching)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a fixed array length establishes a literal while bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn printSelected(writer: *Writer) !void {\n" ++
        "const selected: [3]bool = .{ true, false, true };\n" ++
        "var index: usize = 0;\n" ++
        "while (index < 3) : (index += 1) {\n" ++
        "if (selected[index]) try writer.print(\"{d}\", .{index});\n" ++
        "}\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.assertion_free_branching)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a shadowed slice does not inherit an outer fixed array bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn printSelected(writer: *Writer, dynamic: []const bool) !void {\n" ++
        "const selected: [3]bool = .{ true, false, true };\n" ++
        "{\n" ++
        "const selected = dynamic;\n" ++
        "var index: usize = 0;\n" ++
        "while (index < 3) : (index += 1) {\n" ++
        "if (selected[index]) try writer.print(\"{d}\", .{index});\n" ++
        "}\n" ++
        "}\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.assertion_free_branching)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "a matching for range establishes the bound for its indexed access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn clear(values: []u8) void {\n" ++
        "for (0..values.len) |index| {\n" ++
        "if (values[index] != 0) {\n" ++
        "values[index] = 0;\n" ++
        "}\n" ++
        "}\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.assertion_free_branching)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an index capture establishes the bound for an equally sized array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn names(comptime fields: []const Field) [fields.len][]const u8 {\n" ++
        "var result: [fields.len][]const u8 = undefined;\n" ++
        "for (fields, 0..) |field, index| {\n" ++
        "result[index] = field.name;\n" ++
        "}\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "return result;\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.assertion_free_branching)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an early loop exit establishes the bound for following indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn findStop(values: []const u8) ?u8 {\n" ++
        "for (values, 0..) |value, index| {\n" ++
        "_ = value;\n" ++
        "if (index + 1 >= values.len) break;\n" ++
        "if (values[index + 1] == 0) return value;\n" ++
        "}\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "return null;\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.assertion_free_branching)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an unrelated or invalidated loop bound does not establish index safety" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn read(values: *Values, others: []u8, index: usize) u8 {\n" ++
        "while (index < others.len) {\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "_ = four;\n" ++
        "return values.items[index];\n" ++
        "}\n" ++
        "return 0;\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.assertion_free_branching)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "array types are not computed indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn FixedBuffer(comptime capacity: usize) type {\n" ++
        "return struct {\n" ++
        "bytes: [capacity]u8,\n" ++
        "const Self = @This();\n" ++
        "fn clear(self: *Self) void {\n" ++
        "self.bytes = @splat(0);\n" ++
        "}\n" ++
        "};\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.assertion_free_branching)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "nested function indexing is reported once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn Container() type {\n" ++
        "return struct {\n" ++
        "fn read(values: []u8, index: usize) u8 {\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "_ = four;\n" ++
        "_ = five;\n" ++
        "_ = six;\n" ++
        "_ = seven;\n" ++
        "return values[index];\n" ++
        "}\n" ++
        "};\n" ++
        "}\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.assertion_free_branching)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "draining an array list with ordered front removal reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn drain(allocator: std.mem.Allocator) void { " ++
        "var queue: std.ArrayList(u32) = .empty; defer queue.deinit(allocator); " ++
        "while (queue.items.len > 0) { consume(queue.orderedRemove(0)); } }";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.quadratic_front_removal)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.quadratic_front_removal, found[0].rule);
}

test "one-off and non-front array list removals remain clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Unrelated = struct { queue: std.ArrayList(u32) }; " ++
        "fn removeOne(queue: *std.ArrayList(u32)) void { _ = queue.orderedRemove(0); } " ++
        "fn drainBack(allocator: std.mem.Allocator) void { " ++
        "var queue = std.ArrayList(u32).empty; defer queue.deinit(allocator); " ++
        "while (queue.items.len != 0) { _ = queue.orderedRemove(queue.items.len - 1); } } " ++
        "fn custom(queue: *CustomQueue) void { " ++
        "while (queue.items.len != 0) { _ = queue.orderedRemove(0); } }";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.quadratic_front_removal)] = .information;

    const found = try findingsFor(arena.allocator(), source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8, configuration: types.Configuration) ![]const types.Finding {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    var found: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = allocator, .source = source, .tokens = tokens.items, .configuration = configuration, .findings = &found });
    return try found.toOwnedSlice(allocator);
}
