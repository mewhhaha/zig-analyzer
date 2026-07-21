const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

const proof_window_tokens = 256;

pub fn run(context: RuleRun) !void {
    const level = context.level(.unchecked_first_element);
    if (level == .off) return;

    for (context.tokens, 0..) |token, use_index| {
        if (token.tag != .identifier or use_index + 3 >= context.tokens.len or
            (use_index > 0 and context.tokens[use_index - 1].tag == .period) or
            context.tokens[use_index + 1].tag != .l_bracket or
            context.tokens[use_index + 2].tag != .number_literal or !context.tokenIs(use_index + 2, "0") or
            context.tokens[use_index + 3].tag != .r_bracket) continue;
        const declaration_index = plainSliceDeclaration(context, context.tokenText(use_index), use_index) orelse continue;
        if (!isPublicFunctionParameter(context, declaration_index)) continue;
        if (bindingShadowed(context, context.tokenText(use_index), declaration_index + 1, use_index)) continue;
        if (hasNonEmptyProof(context, context.tokenText(use_index), declaration_index, use_index)) continue;
        try context.emit(.{
            .rule = .unchecked_first_element,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "slice '{s}' is indexed at zero without a visible proof that it is non-empty",
                .{context.tokenText(use_index)},
            ),
        });
    }
}

fn isPublicFunctionParameter(context: RuleRun, declaration_index: usize) bool {
    var opening = declaration_index;
    while (opening > 0) {
        opening -= 1;
        switch (context.tokens[opening].tag) {
            .l_paren => break,
            .l_brace, .semicolon => return false,
            else => {},
        }
    }
    if (context.tokens[opening].tag != .l_paren) return false;
    var function_index = opening;
    while (function_index > 0 and opening - function_index < 4) {
        function_index -= 1;
        if (context.tokens[function_index].tag != .keyword_fn) continue;
        return function_index > 0 and context.tokens[function_index - 1].tag == .keyword_pub;
    }
    return false;
}

fn plainSliceDeclaration(context: RuleRun, name: []const u8, use_index: usize) ?usize {
    var selected: ?usize = null;
    var selected_body_start: usize = 0;
    for (context.tokens[0..use_index], 0..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index + 2 >= use_index or
            context.tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = context.matchingToken(function_index + 2, .l_paren, .r_paren) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < use_index and context.tokens[body_start].tag != .l_brace and
            context.tokens[body_start].tag != .semicolon) : (body_start += 1)
        {}
        if (body_start >= use_index or context.tokens[body_start].tag != .l_brace or body_start < selected_body_start) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (body_end < use_index) continue;
        for (context.tokens[function_index + 3 .. parameters_end], function_index + 3..) |parameter, index| {
            if (parameter.tag != .identifier or !context.tokenIs(index, name) or
                index + 3 >= parameters_end or context.tokens[index + 1].tag != .colon or
                context.tokens[index + 2].tag != .l_bracket) continue;
            if (context.tokens[index + 3].tag != .r_bracket) continue;
            selected = index;
            selected_body_start = body_start;
        }
    }
    return selected;
}

fn bindingShadowed(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if ((token.tag == .keyword_const or token.tag == .keyword_var) and
            index + 1 < end and context.tokenIs(index + 1, name)) return true;
    }
    return false;
}

fn hasNonEmptyProof(context: RuleRun, name: []const u8, declaration_index: usize, use_index: usize) bool {
    if (conditionBeforeUseProvesNonEmpty(context, name, declaration_index, use_index)) return true;
    if (functionEntryProvesNonEmpty(context, name, declaration_index, use_index)) return true;
    if (shortCircuitProvesNonEmpty(context, name, declaration_index, use_index)) return true;
    if (guardHelperShortCircuitProvesNonEmpty(context, name, declaration_index, use_index)) return true;
    if (inlineConditionalProvesNonEmpty(context, name, declaration_index, use_index)) return true;
    if (switchProvesNonEmpty(context, name, declaration_index, use_index)) return true;
    var opening = context.enclosingOpeningBrace(use_index);
    while (opening) |brace| {
        if (brace >= 6 and context.tokens[brace - 1].tag == .r_paren) {
            const condition_open = matchingOpeningParenthesis(context, brace - 1);
            if (condition_open) |start| if (conditionProvesNonEmpty(context, name, start + 1, brace - 1)) return true;
        }
        opening = context.enclosingOpeningBrace(brace);
    }
    return false;
}

fn functionEntryProvesNonEmpty(context: RuleRun, name: []const u8, declaration_index: usize, use_index: usize) bool {
    var parameters_start = declaration_index;
    while (parameters_start > 0 and context.tokens[parameters_start].tag != .l_paren) : (parameters_start -= 1) {}
    if (context.tokens[parameters_start].tag != .l_paren) return false;
    const parameters_end = context.matchingToken(parameters_start, .l_paren, .r_paren) orelse return false;
    var body_start = parameters_end + 1;
    while (body_start < use_index and context.tokens[body_start].tag != .l_brace and
        context.tokens[body_start].tag != .semicolon) : (body_start += 1)
    {}
    if (body_start == use_index or context.tokens[body_start].tag != .l_brace) return false;
    const entry_end = @min(use_index, body_start + 1 + proof_window_tokens);
    return conditionBeforeUseProvesNonEmpty(context, name, body_start + 1, entry_end);
}

fn guardHelperShortCircuitProvesNonEmpty(context: RuleRun, name: []const u8, start: usize, use_index: usize) bool {
    const search_start = @max(start, use_index -| proof_window_tokens);
    for (context.tokens[search_start..use_index], search_start..) |token, call_index| {
        if (token.tag != .identifier or call_index + 3 >= use_index or
            context.tokens[call_index + 1].tag != .l_paren or !context.tokenIs(call_index + 2, name) or
            context.tokens[call_index + 3].tag != .r_paren) continue;
        const boolean_index = call_index + 4;
        if (boolean_index >= use_index or context.tokens[boolean_index].tag != .keyword_or) continue;
        var same_expression = true;
        for (context.tokens[boolean_index + 1 .. use_index]) |candidate| switch (candidate.tag) {
            .semicolon, .l_brace, .r_brace => {
                same_expression = false;
                break;
            },
            else => {},
        };
        if (same_expression and functionReturnsTrueForEmptySlice(context, context.tokenText(call_index))) return true;
    }
    return false;
}

fn functionReturnsTrueForEmptySlice(context: RuleRun, function_name: []const u8) bool {
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index + 3 >= context.tokens.len or
            !context.tokenIs(function_index + 1, function_name) or context.tokens[function_index + 2].tag != .l_paren or
            context.tokens[function_index + 3].tag != .identifier) continue;
        const parameter = context.tokenText(function_index + 3);
        const parameters_end = context.matchingToken(function_index + 2, .l_paren, .r_paren) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace and
            context.tokens[body_start].tag != .semicolon) : (body_start += 1)
        {}
        if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        for (context.tokens[body_start + 1 .. body_end], body_start + 1..) |_, index| {
            if (!context.tokenIs(index, parameter) or index + 4 >= body_end or context.tokens[index + 1].tag != .period or
                !context.tokenIs(index + 2, "len") or context.tokens[index + 3].tag != .equal_equal or
                !context.tokenIs(index + 4, "0")) continue;
            var statement_start = index;
            while (statement_start > body_start + 1 and context.tokens[statement_start - 1].tag != .semicolon and
                context.tokens[statement_start - 1].tag != .l_brace) : (statement_start -= 1)
            {}
            if (context.tokens[statement_start].tag != .keyword_return) continue;
            const statement_end = context.statementEnd(statement_start) orelse continue;
            for (context.tokens[index + 5 .. @min(statement_end, body_end)]) |following| {
                if (following.tag == .keyword_or) return true;
            }
        }
    }
    return false;
}

fn shortCircuitProvesNonEmpty(context: RuleRun, name: []const u8, start: usize, use_index: usize) bool {
    var index = @max(start, use_index -| proof_window_tokens);
    while (index + 4 < use_index) : (index += 1) {
        if (!context.tokenIs(index, name) or context.tokens[index + 1].tag != .period or
            !context.tokenIs(index + 2, "len")) continue;
        const bound = positiveIntegerBound(context, index + 4) orelse continue;
        const true_proof = switch (context.tokens[index + 3].tag) {
            .angle_bracket_right, .bang_equal => bound == 0,
            .angle_bracket_right_equal, .equal_equal => bound > 0,
            else => false,
        };
        const false_proof = switch (context.tokens[index + 3].tag) {
            .equal_equal => bound == 0,
            .angle_bracket_left => bound > 0,
            .bang_equal => bound > 0,
            else => false,
        };
        var saw_boolean = false;
        var only_and = true;
        var only_or = true;
        var cursor = index + 5;
        while (cursor < use_index) : (cursor += 1) switch (context.tokens[cursor].tag) {
            .keyword_and => {
                saw_boolean = true;
                only_or = false;
            },
            .keyword_or => {
                saw_boolean = true;
                only_and = false;
            },
            .semicolon, .l_brace, .r_brace => {
                saw_boolean = false;
                break;
            },
            else => {},
        };
        if (saw_boolean and ((true_proof and only_and) or (false_proof and only_or))) return true;
    }
    return false;
}

fn inlineConditionalProvesNonEmpty(context: RuleRun, name: []const u8, start: usize, use_index: usize) bool {
    const search_start = @max(start, use_index -| proof_window_tokens);
    for (context.tokens[search_start..use_index], search_start..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 1 >= use_index or context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end >= use_index or !falseConditionProvesNonEmpty(context, name, if_index + 2, condition_end)) continue;
        const statement_end = context.statementEnd(if_index) orelse continue;
        if (statement_end < use_index) continue;
        for (context.tokens[condition_end + 1 .. use_index]) |branch_token| {
            if (branch_token.tag == .keyword_else) return true;
        }
    }
    return false;
}

fn switchProvesNonEmpty(context: RuleRun, name: []const u8, start: usize, use_index: usize) bool {
    var opening = context.enclosingOpeningBrace(use_index);
    while (opening) |body_start| {
        if (switchConditionNamesLength(context, name, body_start)) {
            var index = use_index;
            while (index > body_start + 1) {
                index -= 1;
                if (context.tokens[index].tag == .equal_angle_bracket_right and index > body_start + 1 and
                    context.tokens[index - 1].tag == .number_literal)
                {
                    const value = std.fmt.parseInt(usize, context.tokenText(index - 1), 0) catch 0;
                    if (value > 0) return true;
                    break;
                }
            }
        }
        opening = context.enclosingOpeningBrace(body_start);
    }

    const search_start = @max(start, use_index -| proof_window_tokens);
    for (context.tokens[search_start..use_index], search_start..) |token, switch_index| {
        if (token.tag != .keyword_switch or switch_index + 1 >= use_index or
            context.tokens[switch_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(switch_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end + 1 >= use_index or context.tokens[condition_end + 1].tag != .l_brace or
            !conditionRangeNamesLength(context, name, switch_index + 2, condition_end)) continue;
        const body_end = context.matchingToken(condition_end + 1, .l_brace, .r_brace) orelse continue;
        if (body_end >= use_index) continue;
        var index = condition_end + 2;
        while (index + 2 < body_end) : (index += 1) {
            if (context.tokens[index].tag == .number_literal and context.tokenIs(index, "0") and
                context.tokens[index + 1].tag == .equal_angle_bracket_right and
                context.tokens[index + 2].tag == .keyword_return) return true;
        }
    }
    return false;
}

fn switchConditionNamesLength(context: RuleRun, name: []const u8, body_start: usize) bool {
    if (body_start == 0 or context.tokens[body_start - 1].tag != .r_paren) return false;
    const condition_start = matchingOpeningParenthesis(context, body_start - 1) orelse return false;
    if (condition_start == 0 or context.tokens[condition_start - 1].tag != .keyword_switch) return false;
    return conditionRangeNamesLength(context, name, condition_start + 1, body_start - 1);
}

fn conditionRangeNamesLength(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    return start + 3 == end and context.tokenIs(start, name) and context.tokens[start + 1].tag == .period and
        context.tokenIs(start + 2, "len");
}

fn conditionBeforeUseProvesNonEmpty(context: RuleRun, name: []const u8, start: usize, use_index: usize) bool {
    var index = @max(start, use_index -| proof_window_tokens);
    while (index + 2 < use_index) : (index += 1) {
        if (context.tokens[index].tag == .identifier and context.tokenIs(index, "assert") and
            index + 1 < use_index and context.tokens[index + 1].tag == .l_paren)
        {
            const condition_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
            if (condition_end < use_index and proofScopeContainsUse(context, index, use_index) and
                conditionProvesNonEmpty(context, name, index + 2, condition_end)) return true;
        }
        if (context.tokens[index].tag != .keyword_if or context.tokens[index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end + 1 >= use_index or !proofScopeContainsUse(context, index, use_index) or
            !falseConditionProvesNonEmpty(context, name, index + 2, condition_end)) continue;
        const terminator = context.tokens[condition_end + 1].tag;
        if (terminator == .keyword_return or terminator == .keyword_continue or terminator == .keyword_break) return true;
        if (terminator == .l_brace) {
            const closing = context.matchingToken(condition_end + 1, .l_brace, .r_brace) orelse continue;
            if (closing < use_index and blockTerminates(context, condition_end + 1, closing)) return true;
        }
        if (terminator == .builtin and terminatingBuiltin(context, condition_end + 1)) return true;
    }
    return false;
}

fn proofScopeContainsUse(context: RuleRun, proof_index: usize, use_index: usize) bool {
    const opening = context.enclosingOpeningBrace(proof_index) orelse return false;
    const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse return false;
    return use_index < closing;
}

fn falseConditionProvesNonEmpty(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    var depth: usize = 0;
    var has_top_level_and = false;
    for (context.tokens[start..end]) |token| switch (token.tag) {
        .l_paren => depth += 1,
        .r_paren => depth -|= 1,
        .keyword_and => if (depth == 0) {
            has_top_level_and = true;
        },
        else => {},
    };
    if (has_top_level_and) return false;

    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (!context.tokenIs(index, name) or context.tokens[index + 1].tag != .period or
            !context.tokenIs(index + 2, "len")) continue;
        const bound = positiveIntegerBound(context, index + 4) orelse continue;
        return switch (context.tokens[index + 3].tag) {
            .equal_equal => bound == 0,
            .bang_equal => bound > 0,
            .angle_bracket_left => bound > 0,
            .angle_bracket_left_equal => true,
            else => false,
        };
    }
    index = start;
    while (index + 4 < end) : (index += 1) {
        if (context.tokens[index + 1].tag != .angle_bracket_right or
            !context.tokenIs(index + 2, name) or context.tokens[index + 3].tag != .period or
            !context.tokenIs(index + 4, "len")) continue;
        const bound = positiveIntegerBound(context, index) orelse continue;
        if (bound > 0) return true;
    }
    return false;
}

fn blockTerminates(context: RuleRun, opening: usize, closing: usize) bool {
    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, index| {
        switch (token.tag) {
            .keyword_return, .keyword_continue, .keyword_break, .keyword_unreachable => {},
            .builtin => if (terminatingBuiltin(context, index)) {} else continue,
            else => continue,
        }
        if (context.enclosingOpeningBrace(index) != opening) continue;
        const statement_end = context.statementEnd(index) orelse continue;
        if (statement_end + 1 == closing) return true;
    }
    return false;
}

fn terminatingBuiltin(context: RuleRun, index: usize) bool {
    return context.tokenIs(index, "@compileError") or context.tokenIs(index, "@panic");
}

fn conditionProvesNonEmpty(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (!context.tokenIs(index, name) or context.tokens[index + 1].tag != .period or
            !context.tokenIs(index + 2, "len")) continue;
        const bound = positiveIntegerBound(context, index + 4) orelse continue;
        switch (context.tokens[index + 3].tag) {
            .angle_bracket_right, .bang_equal => if (bound == 0) return true,
            .angle_bracket_right_equal, .equal_equal => if (bound > 0) return true,
            else => {},
        }
    }
    return false;
}

fn positiveIntegerBound(context: RuleRun, bound_index: usize) ?usize {
    if (context.tokens[bound_index].tag == .number_literal) {
        return std.fmt.parseInt(usize, context.tokenText(bound_index), 0) catch null;
    }
    if (context.tokens[bound_index].tag != .identifier) return null;

    const name = context.tokenText(bound_index);
    for (context.tokens[0..bound_index], 0..) |token, declaration_index| {
        if (token.tag != .keyword_const or context.enclosingOpeningBrace(declaration_index) != null or
            declaration_index + 3 >= bound_index or !context.tokenIs(declaration_index + 1, name)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        for (context.tokens[declaration_index + 2 .. declaration_end], declaration_index + 2..) |candidate, value_index| {
            if (candidate.tag != .equal or value_index + 1 >= declaration_end or
                context.tokens[value_index + 1].tag != .number_literal) continue;
            return std.fmt.parseInt(usize, context.tokenText(value_index + 1), 0) catch null;
        }
    }
    return null;
}

fn matchingOpeningParenthesis(context: RuleRun, closing: usize) ?usize {
    var depth: usize = 0;
    var index = closing + 1;
    while (index > 0) {
        index -= 1;
        if (context.tokens[index].tag == .r_paren) depth += 1;
        if (context.tokens[index].tag != .l_paren) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

test "plain slices require a non-empty proof before indexing zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "pub fn first(bytes: []const u8) u8 { return bytes[0]; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "guards fixed arrays and sentinel slices stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn guarded(bytes: []const u8) ?u8 { if (bytes.len == 0) return null; return bytes[0]; }\n" ++
        "pub fn enclosed(bytes: []const u8) ?u8 { if (bytes.len > 0) { return bytes[0]; } return null; }\n" ++
        "pub fn sentinel(bytes: [:0]const u8) u8 { return bytes[0]; }\n" ++
        "pub fn fixed(bytes: [1]u8) u8 { return bytes[0]; }\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "slice parameters do not affect same-named fixed arrays in later functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn guarded(bytes: []const u8) ?u8 { if (bytes.len == 0) return null; return bytes[0]; }\n" ++
        "pub fn fixed(bytes: [1]u8) u8 { return bytes[0]; }\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "non-dominating length checks do not prove a first element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn first(bytes: []const u8) u8 { if (bytes.len > 0) log(bytes.len); return bytes[0]; } " ++
        "pub fn asserted(bytes: []const u8) u8 { std.debug.assert(bytes.len > 0); return bytes[0]; }" ++
        "pub fn separated(bytes: []const u8) u8 { _ = bytes.len > 0 and ready(); return bytes[0]; }" ++
        "pub fn afterConditional(bytes: []const u8) u8 { _ = if (bytes.len == 0) 0 else 1; return bytes[0]; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
}

test "guards in closed nested scopes do not prove a later first element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn first(bytes: []const u8, ready: bool) u8 { " ++
        "if (ready) { if (bytes.len == 0) return 0; std.debug.assert(bytes.len > 0); } return bytes[0]; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "braced empty guards prove a first element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn first(bytes: []const u8) ?u8 { if (bytes.len == 0) { return null; } return bytes[0]; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "compound and minimum-length guards prove a first element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn first(bytes: []const u8) ?u8 { if (bytes.len == 0 or invalid(bytes)) return null; return bytes[0]; }\n" ++
        "pub fn pair(bytes: []const u8) u8 { if (bytes.len < 2) return 0; return bytes[0]; }\n" ++
        "pub fn exact(bytes: []const u8) u8 { if (bytes.len != 7) return 0; return bytes[0]; }\n" ++
        "pub fn compileTime(bytes: []const u8) u8 { if (bytes.len == 0) @compileError(\"empty\"); return bytes[0]; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "named positive length guards prove a first element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const header_length: usize = 8;\n" ++
        "const empty_length = 0;\n" ++
        "pub fn decode(bytes: []const u8) ?u8 { if (bytes.len < header_length) return null; return bytes[0]; }\n" ++
        "pub fn unguarded(bytes: []const u8) ?u8 { if (bytes.len < empty_length) return null; return bytes[0]; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "short circuit inline conditionals and switch guards prove a first element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn left(bytes: []const u8) bool { return bytes.len > 0 and bytes[0] == 1; }\n" ++
        "pub fn right(bytes: []const u8) bool { return bytes.len == 0 or bytes[0] == 1; }\n" ++
        "pub fn fallback(bytes: []const u8) u8 { return if (bytes.len == 0) 0 else bytes[0]; }\n" ++
        "pub fn switched(bytes: []const u8) u8 { switch (bytes.len) { 0 => return 0, 1 => return bytes[0], else => {} } return bytes[0]; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "entry guards remain valid in long functions and fields do not alias parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const padding = "use();" ** 80;
    const source = try std.fmt.allocPrintSentinel(
        arena.allocator(),
        "pub fn first(values: []const u8, result: Result) ?u8 {{ if (values.len == 0) return null; {s} return values[0] + result.values[0]; }}",
        .{padding},
        0,
    );
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
