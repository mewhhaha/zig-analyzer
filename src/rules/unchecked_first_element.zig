const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.unchecked_first_element);
    if (level == .off) return;

    for (context.tokens, 0..) |token, use_index| {
        if (token.tag != .identifier or use_index + 3 >= context.tokens.len or
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
    for (context.tokens[0..use_index], 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or
            index + 3 >= use_index or context.tokens[index + 1].tag != .colon or
            context.tokens[index + 2].tag != .l_bracket) continue;
        if (context.tokens[index + 3].tag == .colon) continue;
        if (context.tokens[index + 3].tag != .r_bracket) continue;
        selected = index;
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

fn conditionBeforeUseProvesNonEmpty(context: RuleRun, name: []const u8, start: usize, use_index: usize) bool {
    var index = start;
    while (index + 6 < use_index) : (index += 1) {
        if (context.tokens[index].tag == .identifier and context.tokenIs(index, "assert") and
            index + 1 < use_index and context.tokens[index + 1].tag == .l_paren)
        {
            const condition_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
            if (condition_end < use_index and conditionProvesNonEmpty(context, name, index + 2, condition_end)) return true;
        }
        if (context.tokens[index].tag != .keyword_if or index + 8 >= use_index or
            context.tokens[index + 1].tag != .l_paren or !context.tokenIs(index + 2, name) or
            context.tokens[index + 3].tag != .period or !context.tokenIs(index + 4, "len") or
            context.tokens[index + 5].tag != .equal_equal or !context.tokenIs(index + 6, "0") or
            context.tokens[index + 7].tag != .r_paren) continue;
        const terminator = context.tokens[index + 8].tag;
        if (terminator == .keyword_return or terminator == .keyword_continue or terminator == .keyword_break) return true;
        if (terminator == .l_brace) {
            const closing = context.matchingToken(index + 8, .l_brace, .r_brace) orelse continue;
            if (closing < use_index and blockTerminates(context, index + 8, closing)) return true;
        }
    }
    return false;
}

fn blockTerminates(context: RuleRun, opening: usize, closing: usize) bool {
    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, index| {
        switch (token.tag) {
            .keyword_return, .keyword_continue, .keyword_break, .keyword_unreachable => {},
            else => continue,
        }
        if (context.enclosingOpeningBrace(index) != opening) continue;
        const statement_end = context.statementEnd(index) orelse continue;
        if (statement_end + 1 == closing) return true;
    }
    return false;
}

fn conditionProvesNonEmpty(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (!context.tokenIs(index, name) or context.tokens[index + 1].tag != .period or
            !context.tokenIs(index + 2, "len") or context.tokens[index + 4].tag != .number_literal or
            !context.tokenIs(index + 4, "0")) continue;
        if (context.tokens[index + 3].tag == .angle_bracket_right or context.tokens[index + 3].tag == .bang_equal) return true;
    }
    return false;
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
        "fn guarded(bytes: []const u8) ?u8 { if (bytes.len == 0) return null; return bytes[0]; }\n" ++
        "fn enclosed(bytes: []const u8) ?u8 { if (bytes.len > 0) { return bytes[0]; } return null; }\n" ++
        "fn sentinel(bytes: [:0]const u8) u8 { return bytes[0]; }\n" ++
        "fn fixed(bytes: [1]u8) u8 { return bytes[0]; }\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "non-dominating length checks do not prove a first element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn first(bytes: []const u8) u8 { if (bytes.len > 0) log(bytes.len); return bytes[0]; } " ++
        "pub fn asserted(bytes: []const u8) u8 { std.debug.assert(bytes.len > 0); return bytes[0]; }";
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
