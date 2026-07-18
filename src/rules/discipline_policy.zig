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
}

fn findLongFunctions(context: RuleRun) !void {
    const level = context.level(.function_length);
    if (level == .off) return;
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or insideKeywordBlock(context, fn_index, .keyword_test) or
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
        if (token.tag != .keyword_fn) continue;
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
        if (std.mem.indexOfAny(u8, condition, "<>") != null or std.mem.indexOf(u8, condition, ".next(") != null) continue;
        const body_open = nextTagBefore(context.tokens, condition_end + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (conditionIsTrue(context, while_index + 2, condition_end) and eventLoopHasBlockingDispatch(context, body_open + 1, body_end)) continue;
        if (bodyHasCounterGuard(context, body_open + 1, body_end)) continue;
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
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or externallyConstrained(context, fn_index)) continue;
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
            context.tokens[while_index + 3].tag != .angle_bracket_left or
            condition_end < while_index + 7 or context.tokens[condition_end - 2].tag != .period or
            !context.tokenIs(condition_end - 1, "len")) continue;
        const guarded_sequence_start = while_index + 4;
        const guarded_sequence_end = condition_end - 2;
        if (!dottedPathsEqual(context, guarded_sequence_start, guarded_sequence_end, indexed_sequence_start, bracket)) continue;

        const loop_body = nextTagBefore(context.tokens, condition_end + 1, .l_brace, .semicolon) orelse continue;
        const loop_end = context.matchingToken(loop_body, .l_brace, .r_brace) orelse continue;
        if (bracket <= loop_body or bracket >= loop_end or mayMutateBeforeIndex(context, loop_body + 1, indexed_sequence_start)) continue;
        return true;
    }
    return false;
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
        if (token.tag != .keyword_if) continue;
        const limit = @min(end, index + 20);
        var comparison = false;
        var exits = false;
        for (context.tokens[index + 1 .. limit]) |candidate| switch (candidate.tag) {
            .angle_bracket_left, .angle_bracket_right, .equal_equal => comparison = true,
            .keyword_break, .keyword_return => exits = true,
            else => {},
        };
        if (comparison and exits) return true;
    }
    return false;
}

fn eventLoopHasBlockingDispatch(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        if (context.tokenIs(index, "wait") or context.tokenIs(index, "run") or context.tokenIs(index, "dispatch") or context.tokenIs(index, "accept")) return true;
    }
    return false;
}

fn conditionIsTrue(context: RuleRun, start: usize, end: usize) bool {
    return end == start + 1 and context.tokens[start].tag == .identifier and context.tokenIs(start, "true");
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
