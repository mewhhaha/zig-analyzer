const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_module = @import("../../syntax/tokens.zig");

const ArgumentRange = tokens_module.Range;
const Tag = std.zig.Token.Tag;
const containsComment = tokens_module.containsComment;
const findTag = tokens_module.findTag;

pub const rules = [_]types.Rule{
    .prefer_index_of,
    .prefer_starts_with,
    .prefer_ends_with,
    .prefer_count_scalar,
    .prefer_replace_scalar,
};

pub fn run(context: RuleRun) !void {
    try findIndexOfPrefixTests(context);
    try findGuardedSuffixTests(context);
    try findScalarCounts(context);
    try findScalarReplacements(context);
    try findManualSearches(context);
    try findBooleanSearches(context);
}

fn findIndexOfPrefixTests(context: RuleRun) !void {
    const level = context.level(.prefer_starts_with);
    if (level == .off) return;
    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or (!context.tokenIs(call_index, "indexOf") and !context.tokenIs(call_index, "find")) or call_index < 4 or
            call_index + 1 >= context.tokens.len or
            !context.tokenIs(call_index - 4, "std") or !context.tokenIs(call_index - 2, "mem") or
            context.tokens[call_index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end + 2 >= context.tokens.len or context.tokens[call_end + 1].tag != .equal_equal or
            !context.tokenIs(call_end + 2, "0")) continue;
        const arguments = context.threeArguments(call_index + 1, call_end) orelse continue;
        const haystack = context.argumentSource(arguments[1]);
        const needle = context.argumentSource(arguments[2]);
        try context.emit(.{
            .rule = .prefer_starts_with,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "search checks whether '{s}' occurs at offset zero in '{s}'; use std.mem.startsWith",
                .{ needle, haystack },
            ),
            .fixes = try startsWithFix(context, call_index, call_end),
        });
    }
}

/// `std.mem.startsWith` over the same arguments: the callee is renamed and
/// `== 0` dropped, and both are true for an empty needle. Declined when an
/// operator on either side binds tighter than `==` (`== 0 + 1`,
/// `== 0 orelse x`, `!std.mem...`), which makes the call or the zero part of
/// a larger operand.
fn startsWithFix(context: RuleRun, call_index: usize, call_end: usize) ![]const types.Fix {
    const tokens = context.tokens;
    const namespace = call_index - 4;
    const zero = call_end + 2;
    if (tokens[namespace + 1].tag != .period or tokens[call_index - 1].tag != .period or namespace == 0 or
        !booleanOperandBefore(tokens[namespace - 1].tag) or !booleanOperandAfter(tokens[zero + 1].tag)) return &.{};
    const removed: std.zig.Token.Loc = .{ .start = tokens[call_end].loc.end, .end = tokens[zero].loc.end };
    if (containsComment(context.source[removed.start..removed.end])) return &.{};
    const edits = try context.allocator.alloc(types.Edit, 2);
    errdefer context.allocator.free(edits);
    edits[0] = .{ .span = tokens[call_index].loc, .replacement = "startsWith" };
    edits[1] = .{ .span = removed, .replacement = "" };
    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{ .title = "Use std.mem.startsWith", .kind = .quickfix, .edits = edits, .preferred = true, .fix_all = true };
    return fixes;
}

/// Tokens after which a comparison or an `and` chain is a whole operand:
/// openers, separators, `return`, `else` and the looser boolean operators.
fn booleanOperandBefore(tag: Tag) bool {
    return switch (tag) {
        .l_paren,
        .l_brace,
        .comma,
        .semicolon,
        .equal,
        .equal_angle_bracket_right,
        .keyword_return,
        .keyword_and,
        .keyword_or,
        .keyword_else,
        => true,
        else => false,
    };
}

/// Tokens before which a comparison or an `and` chain is a whole operand.
fn booleanOperandAfter(tag: Tag) bool {
    return switch (tag) {
        .r_paren, .r_brace, .r_bracket, .comma, .semicolon, .keyword_and, .keyword_or, .keyword_else => true,
        else => false,
    };
}

fn findGuardedSuffixTests(context: RuleRun) !void {
    const level = context.level(.prefer_ends_with);
    if (level == .off) return;
    for (context.tokens, 0..) |token, eql_index| {
        if (token.tag != .identifier or !context.tokenIs(eql_index, "eql") or eql_index < 12 or
            eql_index + 1 >= context.tokens.len or
            !context.tokenIs(eql_index - 4, "std") or !context.tokenIs(eql_index - 2, "mem") or
            context.tokens[eql_index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(eql_index + 1, .l_paren, .r_paren) orelse continue;
        const arguments = context.threeArguments(eql_index + 1, call_end) orelse continue;
        const haystack = suffixSliceBase(context, arguments[1], arguments[2]) orelse continue;
        const needle = context.argumentSource(arguments[2]);
        if (!lengthGuard(context, eql_index - 5, haystack, needle)) continue;
        try context.emit(.{
            .rule = .prefer_ends_with,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "guarded tail comparison checks whether '{s}' ends with '{s}'; use std.mem.endsWith",
                .{ haystack, needle },
            ),
            .fixes = try endsWithFix(context, eql_index, call_end, arguments),
        });
    }
}

/// `std.mem.endsWith(T, haystack, needle)`, which performs the same length
/// guard. The haystack is passed whole instead of sliced, so it must be a
/// slice or a pointer to an array: an array value would not coerce.
fn endsWithFix(context: RuleRun, eql_index: usize, call_end: usize, arguments: [3]ArgumentRange) ![]const types.Fix {
    const tokens = context.tokens;
    const haystack = eql_index - 12;
    if (tokens[eql_index - 3].tag != .period or tokens[eql_index - 1].tag != .period or haystack == 0 or
        !booleanOperandBefore(tokens[haystack - 1].tag) or !booleanOperandAfter(tokens[call_end + 1].tag) or
        !namesSliceable(context, haystack)) return &.{};
    const span = uncommentedSpan(context, haystack, call_end) orelse return &.{};
    const element = context.argumentSource(arguments[0]);
    if (std.mem.findScalar(u8, element, '\n') != null) return &.{};
    return context.singleFix(.{
        .title = "Use std.mem.endsWith",
        .span = span,
        .replacement = try context.allocator.print("std.mem.endsWith({s}, {s}, {s})", .{
            element, context.tokenText(haystack), context.argumentSource(arguments[2]),
        }),
        .preferred = true,
    });
}

fn suffixSliceBase(context: RuleRun, slice: ArgumentRange, needle: ArgumentRange) ?[]const u8 {
    if (needle.start + 1 != needle.end or context.tokens[needle.start].tag != .identifier) return null;
    if (slice.end != slice.start + 11 or context.tokens[slice.start].tag != .identifier or
        context.tokens[slice.start + 1].tag != .l_bracket or
        !context.tokenIs(slice.start + 2, context.tokenText(slice.start)) or
        context.tokens[slice.start + 3].tag != .period or !context.tokenIs(slice.start + 4, "len") or
        context.tokens[slice.start + 5].tag != .minus or
        !context.tokenIs(slice.start + 6, context.tokenText(needle.start)) or
        context.tokens[slice.start + 7].tag != .period or !context.tokenIs(slice.start + 8, "len") or
        context.tokens[slice.start + 9].tag != .ellipsis2 or context.tokens[slice.start + 10].tag != .r_bracket) return null;
    return context.tokenText(slice.start);
}

fn lengthGuard(context: RuleRun, and_index: usize, haystack: []const u8, needle: []const u8) bool {
    if (and_index < 7 or context.tokens[and_index].tag != .keyword_and) return false;
    return context.tokenIs(and_index - 7, haystack) and context.tokens[and_index - 6].tag == .period and
        context.tokenIs(and_index - 5, "len") and context.tokens[and_index - 4].tag == .angle_bracket_right_equal and
        context.tokenIs(and_index - 3, needle) and context.tokens[and_index - 2].tag == .period and
        context.tokenIs(and_index - 1, "len");
}

fn findScalarCounts(context: RuleRun) !void {
    const level = context.level(.prefer_count_scalar);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end < declaration_index + 3 or !context.tokenIs(declaration_end - 1, "0") or
            context.tokens[declaration_end - 2].tag != .equal) continue;
        const count_name = context.tokenText(declaration_index + 1);
        const for_index = declaration_end + 1;
        const loop = singleCaptureLoop(context, for_index) orelse continue;
        const scalar = loopOnlyCountsMatch(context, loop, count_name) orelse continue;
        try context.emit(.{
            .rule = .prefer_count_scalar,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "'{s}' only counts matching elements in '{s}'; use std.mem.countScalar",
                .{ count_name, loop.iterable },
            ),
            .fixes = try countFix(context, declaration_index, for_index, loop, scalar),
        });
    }
}

/// `const count: usize = std.mem.countScalar(T, values, needle);` in place of
/// the declaration and the loop, keeping `var` when the counter changes
/// later. A counter narrower than `usize` would not take the result.
fn countFix(context: RuleRun, declaration_index: usize, for_index: usize, loop: SingleCaptureLoop, scalar: usize) ![]const types.Fix {
    const tokens = context.tokens;
    if (tokens[declaration_index + 2].tag != .colon or !context.tokenIs(declaration_index + 3, "usize") or
        tokens[declaration_index + 4].tag != .equal) return &.{};
    const element = scalarCallElement(context, for_index + 2, &.{scalar}, .read) orelse return &.{};
    if (!plainLoopStatement(context, for_index, loop.body_end)) return &.{};
    const span = uncommentedSpan(context, declaration_index, loop.body_end) orelse return &.{};
    const name = context.tokenText(declaration_index + 1);
    const scope_end = context.enclosingScopeEnd(declaration_index) orelse tokens.len;
    return context.singleFix(.{
        .title = "Count with std.mem.countScalar",
        .span = span,
        .replacement = try context.allocator.print("{s} {s}: usize = std.mem.countScalar({s}, {s}, {s});", .{
            if (context.bindingMutatedAfter(loop.body_end + 1, scope_end, name)) "var" else "const",
            name,
            element,
            loop.iterable,
            context.tokenText(scalar),
        }),
        .preferred = true,
    });
}

const SingleCaptureLoop = struct {
    iterable: []const u8,
    capture: []const u8,
    body_start: usize,
    body_end: usize,
};

fn singleCaptureLoop(context: RuleRun, for_index: usize) ?SingleCaptureLoop {
    if (for_index + 6 >= context.tokens.len or context.tokens[for_index].tag != .keyword_for or
        context.tokens[for_index + 1].tag != .l_paren) return null;
    const iterable_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse return null;
    if (iterable_end + 4 >= context.tokens.len) return null;
    if (iterable_end != for_index + 3 or context.tokens[for_index + 2].tag != .identifier or
        context.tokens[iterable_end + 1].tag != .pipe or context.tokens[iterable_end + 2].tag != .identifier or
        context.tokens[iterable_end + 3].tag != .pipe or context.tokens[iterable_end + 4].tag != .l_brace) return null;
    const body_end = context.matchingToken(iterable_end + 4, .l_brace, .r_brace) orelse return null;
    return .{
        .iterable = context.tokenText(for_index + 2),
        .capture = context.tokenText(iterable_end + 2),
        .body_start = iterable_end + 4,
        .body_end = body_end,
    };
}

/// The compared scalar when the loop body is exactly
/// `if (element == scalar) { count += 1; }`.
fn loopOnlyCountsMatch(context: RuleRun, loop: SingleCaptureLoop, count_name: []const u8) ?usize {
    const if_index = loop.body_start + 1;
    if (if_index + 6 >= loop.body_end or context.tokens[if_index].tag != .keyword_if or
        context.tokens[if_index + 1].tag != .l_paren) return null;
    const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse return null;
    if (condition_end != if_index + 5 or context.tokens[if_index + 3].tag != .equal_equal or
        (!context.tokenIs(if_index + 2, loop.capture) and !context.tokenIs(if_index + 4, loop.capture))) return null;
    const left_is_capture = context.tokenIs(if_index + 2, loop.capture);
    const right_is_capture = context.tokenIs(if_index + 4, loop.capture);
    if (left_is_capture == right_is_capture) return null;
    const scalar_index = if (left_is_capture) if_index + 4 else if_index + 2;
    if (!simpleScalar(context.tokens[scalar_index].tag) or context.tokenIs(scalar_index, count_name)) return null;
    const body_start = condition_end + 1;
    if (body_start + 6 != loop.body_end or context.tokens[body_start].tag != .l_brace or
        !context.tokenIs(body_start + 1, count_name) or context.tokens[body_start + 2].tag != .plus_equal or
        !context.tokenIs(body_start + 3, "1") or context.tokens[body_start + 4].tag != .semicolon or
        context.tokens[body_start + 5].tag != .r_brace) return null;
    return scalar_index;
}

fn findScalarReplacements(context: RuleRun) !void {
    const level = context.level(.prefer_replace_scalar);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 8 >= context.tokens.len or
            context.tokens[for_index + 1].tag != .l_paren) continue;
        const iterable_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (iterable_end + 5 >= context.tokens.len) continue;
        if (iterable_end != for_index + 3 or context.tokens[for_index + 2].tag != .identifier or
            context.tokens[iterable_end + 1].tag != .pipe or context.tokens[iterable_end + 2].tag != .asterisk or
            context.tokens[iterable_end + 3].tag != .identifier or context.tokens[iterable_end + 4].tag != .pipe or
            context.tokens[iterable_end + 5].tag != .l_brace) continue;
        const body_end = context.matchingToken(iterable_end + 5, .l_brace, .r_brace) orelse continue;
        const element = context.tokenText(iterable_end + 3);
        if (!loopOnlyReplacesMatch(context, iterable_end + 5, body_end, element)) continue;
        try context.emit(.{
            .rule = .prefer_replace_scalar,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "loop only replaces matching elements in '{s}'; use std.mem.replaceScalar",
                .{context.tokenText(for_index + 2)},
            ),
            .fixes = try replaceFix(context, for_index, iterable_end + 5, body_end),
        });
    }
}

fn loopOnlyReplacesMatch(context: RuleRun, opening: usize, closing: usize, element: []const u8) bool {
    const if_index = opening + 1;
    if (if_index + 7 >= closing or context.tokens[if_index].tag != .keyword_if or
        context.tokens[if_index + 1].tag != .l_paren) return false;
    const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse return false;
    if (condition_end != if_index + 6 or !context.tokenIs(if_index + 2, element) or
        context.tokens[if_index + 3].tag != .period_asterisk or context.tokens[if_index + 4].tag != .equal_equal) return false;
    const body_start = condition_end + 1;
    if (body_start + 7 != closing or context.tokens[body_start].tag != .l_brace or
        !context.tokenIs(body_start + 1, element) or context.tokens[body_start + 2].tag != .period_asterisk or
        context.tokens[body_start + 3].tag != .equal or context.tokens[body_start + 5].tag != .semicolon or
        context.tokens[body_start + 6].tag != .r_brace) return false;
    return simpleScalar(context.tokens[if_index + 5].tag) and simpleScalar(context.tokens[body_start + 4].tag);
}

/// `std.mem.replaceScalar(T, values, old, replacement);`, which runs the same
/// loop; its slice parameter needs `values` to be a mutable slice.
fn replaceFix(context: RuleRun, for_index: usize, opening: usize, closing: usize) ![]const types.Fix {
    // `{ if (value.* == old) { value.* = replacement; } }`
    const old = opening + 6;
    const replacement = opening + 12;
    const element = scalarCallElement(context, for_index + 2, &.{ old, replacement }, .write) orelse return &.{};
    if (!plainLoopStatement(context, for_index, closing)) return &.{};
    const span = uncommentedSpan(context, for_index, closing) orelse return &.{};
    return context.singleFix(.{
        .title = "Replace with std.mem.replaceScalar",
        .span = span,
        .replacement = try context.allocator.print("std.mem.replaceScalar({s}, {s}, {s}, {s});", .{
            element, context.tokenText(for_index + 2), context.tokenText(old), context.tokenText(replacement),
        }),
        .preferred = true,
    });
}

fn simpleScalar(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .identifier, .number_literal, .char_literal => true,
        else => false,
    };
}

fn findManualSearches(context: RuleRun) !void {
    const level = context.level(.prefer_index_of);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 7 >= context.tokens.len or context.tokens[for_index + 1].tag != .l_paren) continue;
        const iter_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (iter_end + 6 >= context.tokens.len or context.tokens[iter_end + 1].tag != .pipe) continue;
        const capture_end = findTag(context.tokens, iter_end + 2, context.tokens.len, .pipe) orelse continue;
        if (capture_end != iter_end + 5 or context.tokens[iter_end + 2].tag != .identifier or
            context.tokens[iter_end + 3].tag != .comma or context.tokens[iter_end + 4].tag != .identifier) continue;
        if (capture_end + 1 >= context.tokens.len or context.tokens[capture_end + 1].tag != .l_brace) continue;
        const body_end = context.matchingToken(capture_end + 1, .l_brace, .r_brace) orelse continue;
        if (!isSimpleSearchBody(
            context,
            capture_end + 2,
            body_end,
            context.tokenText(iter_end + 2),
            context.tokenText(iter_end + 4),
        )) continue;
        const header_end = tokens_module.argumentsEnd(context.tokens, for_index + 1, iter_end) orelse continue;
        const iterable = std.mem.trim(u8, context.source[context.tokens[for_index + 2].loc.start..context.tokens[header_end - 1].loc.end], " \t\r\n");
        try context.emit(.{
            .rule = .prefer_index_of,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("manual linear search over '{s}' can state its intent with std.mem.findScalar or std.mem.find", .{iterable}),
            .fixes = try indexSearchFix(context, for_index, iter_end, body_end),
        });
    }
}

fn isSimpleSearchBody(context: RuleRun, start: usize, end: usize, element_name: []const u8, index_name: []const u8) bool {
    if (start + 5 >= end or context.tokens[start].tag != .keyword_if or context.tokens[start + 1].tag != .l_paren) return false;
    const condition_end = context.matchingToken(start + 1, .l_paren, .r_paren) orelse return false;
    if (condition_end + 1 >= end or condition_end != start + 5 or context.tokens[start + 3].tag != .equal_equal or
        (!context.tokenIs(start + 2, element_name) and !context.tokenIs(start + 4, element_name)) or
        context.tokens[condition_end + 1].tag == .keyword_else) return false;
    if (context.tokens[condition_end + 1].tag == .keyword_return) {
        return condition_end + 2 < end and context.tokenIs(condition_end + 2, index_name) and
            context.tokens[end - 1].tag == .semicolon and
            findTag(context.tokens, condition_end + 2, end - 1, .semicolon) == null;
    }
    if (context.tokens[condition_end + 1].tag != .l_brace) return false;
    const branch_end = context.matchingToken(condition_end + 1, .l_brace, .r_brace) orelse return false;
    return branch_end + 1 == end and condition_end + 2 < branch_end and
        context.tokens[condition_end + 2].tag == .keyword_return and condition_end + 3 < branch_end and
        context.tokenIs(condition_end + 3, index_name) and context.tokens[branch_end - 1].tag == .semicolon;
}

/// `if (std.mem.findScalar(T, items, needle)) |i| return i;`, reusing the
/// index capture, for a search over `(items, 0..)` whose body is exactly the
/// match test and `return i;`. A later start would shift the index.
fn indexSearchFix(context: RuleRun, for_index: usize, iter_end: usize, body_end: usize) ![]const types.Fix {
    if (iter_end != for_index + 6 or !context.tokenIs(for_index + 4, "0") or
        context.tokens[for_index + 5].tag != .ellipsis2) return &.{};
    // `) |item, i| { if (left == right)`, then `return i; }` or `{ return i; } }`.
    const condition_end = iter_end + 12;
    const braced = context.tokens[condition_end + 1].tag == .l_brace;
    if (body_end != condition_end + @as(usize, if (braced) 6 else 4)) return &.{};
    const needle = if (context.tokenIs(condition_end - 3, context.tokenText(iter_end + 2))) condition_end - 1 else condition_end - 3;
    const element = scalarCallElement(context, for_index + 2, &.{needle}, .read) orelse return &.{};
    if (!plainLoopStatement(context, for_index, body_end)) return &.{};
    const span = uncommentedSpan(context, for_index, body_end) orelse return &.{};
    const index_name = context.tokenText(iter_end + 4);
    return context.singleFix(.{
        .title = "Search with std.mem.findScalar",
        .span = span,
        .replacement = try context.allocator.print("if (std.mem.findScalar({s}, {s}, {s})) |{s}| return {s};", .{
            element, context.tokenText(for_index + 2), context.tokenText(needle), index_name, index_name,
        }),
        .preferred = true,
    });
}

fn findBooleanSearches(context: RuleRun) !void {
    const level = context.level(.prefer_index_of);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for) continue;
        const loop = singleCaptureLoop(context, for_index) orelse continue;
        const scalar = loopOnlyReturnsTrueForMatch(context, loop) orelse continue;
        const fallback = loop.body_end + 1;
        if (fallback + 2 >= context.tokens.len or context.tokens[fallback].tag != .keyword_return or
            !context.tokenIs(fallback + 1, "false") or context.tokens[fallback + 2].tag != .semicolon) continue;
        try context.emit(.{
            .rule = .prefer_index_of,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "boolean linear search over '{s}' can use std.mem.findScalar or std.mem.find",
                .{loop.iterable},
            ),
            .fixes = try presenceFix(context, for_index, loop.body_end, scalar, fallback + 2),
        });
    }
}

/// The compared scalar when the loop body is exactly
/// `if (element == scalar) return true;`.
fn loopOnlyReturnsTrueForMatch(context: RuleRun, loop: SingleCaptureLoop) ?usize {
    const if_index = loop.body_start + 1;
    if (if_index + 9 != loop.body_end or context.tokens[if_index].tag != .keyword_if or
        context.tokens[if_index + 1].tag != .l_paren or context.tokens[if_index + 3].tag != .equal_equal or
        (!context.tokenIs(if_index + 2, loop.capture) and !context.tokenIs(if_index + 4, loop.capture)) or
        context.tokens[if_index + 5].tag != .r_paren or context.tokens[if_index + 6].tag != .keyword_return or
        !context.tokenIs(if_index + 7, "true") or context.tokens[if_index + 8].tag != .semicolon) return null;
    const left_is_capture = context.tokenIs(if_index + 2, loop.capture);
    const right_is_capture = context.tokenIs(if_index + 4, loop.capture);
    if (left_is_capture == right_is_capture) return null;
    const scalar_index = if (left_is_capture) if_index + 4 else if_index + 2;
    if (!simpleScalar(context.tokens[scalar_index].tag)) return null;
    return scalar_index;
}

/// `return std.mem.findScalar(T, items, needle) != null;` in place of the
/// loop and the `return false;` after it, which ends at `last`.
fn presenceFix(context: RuleRun, for_index: usize, body_end: usize, scalar: usize, last: usize) ![]const types.Fix {
    const element = scalarCallElement(context, for_index + 2, &.{scalar}, .read) orelse return &.{};
    if (!plainLoopStatement(context, for_index, body_end)) return &.{};
    const span = uncommentedSpan(context, for_index, last) orelse return &.{};
    return context.singleFix(.{
        .title = "Search with std.mem.findScalar",
        .span = span,
        .replacement = try context.allocator.print("return std.mem.findScalar({s}, {s}, {s}) != null;", .{
            element, context.tokenText(for_index + 2), context.tokenText(scalar),
        }),
        .preferred = true,
    });
}

/// Whether the loop at `for_index` is a whole statement of a block: no label,
/// `inline`, unbraced `if` body or `defer` before it and no `else` after its
/// body, so replacing it with another statement keeps the control flow.
fn plainLoopStatement(context: RuleRun, for_index: usize, body_end: usize) bool {
    if (for_index == 0 or context.tokens[body_end + 1].tag == .keyword_else) return false;
    return switch (context.tokens[for_index - 1].tag) {
        .semicolon, .l_brace, .r_brace => true,
        else => false,
    };
}

/// Byte span of the tokens `[first, last]`, unless a comment inside would be
/// lost with them.
fn uncommentedSpan(context: RuleRun, first: usize, last: usize) ?std.zig.Token.Loc {
    const span: std.zig.Token.Loc = .{ .start = context.tokens[first].loc.start, .end = context.tokens[last].loc.end };
    return if (containsComment(context.source[span.start..span.end])) null else span;
}

/// How the `std.mem` function a fix calls takes its slice.
const SliceAccess = enum { read, write };

/// The element type `T` of `items` when a `std.mem` scalar function takes the
/// loop's operands unchanged: `items` is a slice of a named type declared in
/// the enclosing function (a mutable one for `.write`), every scalar has type
/// `T` exactly, and `std` names the standard library there.
fn scalarCallElement(context: RuleRun, items: usize, scalars: []const usize, access: SliceAccess) ?[]const u8 {
    const declaration = context.localDeclaration(items) orelse return null;
    const slice = sliceType(context, context.annotatedType(declaration) orelse return null) orelse return null;
    if (access == .write and !slice.mutable) return null;
    for (scalars) |scalar| if (!hasType(context, scalar, slice.element)) return null;
    return if (context.standardLibraryVisible(items)) slice.element else null;
}

/// Whether the scalar at `index` has type `element` exactly: an identifier
/// declared with that type, or an integer or character literal that
/// `element`, a primitive integer type, represents. `element == scalar` also
/// accepts a scalar that only peer-resolves with the element, which the
/// function's `T` parameter would reject.
fn hasType(context: RuleRun, index: usize, element: []const u8) bool {
    const token = context.tokens[index];
    if (token.tag == .identifier) {
        const binding = context.scopes.findBinding(index) orelse return false;
        const declared = context.annotatedType(binding.token_index) orelse return false;
        return std.mem.eql(u8, context.argumentSource(declared), element);
    }
    const value: u64 = switch (token.tag) {
        .char_literal => switch (std.zig.parseCharLiteral(context.tokenText(index))) {
            .success => |codepoint| codepoint,
            .failure => return false,
        },
        .number_literal => switch (std.zig.parseNumberLiteral(context.tokenText(index))) {
            .int => |int| int,
            else => return false,
        },
        else => return false,
    };
    const bits = magnitudeBits(element) orelse return false;
    return bits >= 64 or value >> @intCast(bits) == 0;
}

/// Bits a primitive integer type holds non-negative values in. `usize` and
/// `isize` count as 32-bit so that a literal fits on every target.
fn magnitudeBits(name: []const u8) ?u16 {
    if (std.mem.eql(u8, name, "usize")) return 32;
    if (std.mem.eql(u8, name, "isize")) return 31;
    if (name.len < 2 or (name[0] != 'u' and name[0] != 'i') or (name[1] == '0' and name.len > 2)) return null;
    for (name[1..]) |digit| if (!std.ascii.isDigit(digit)) return null;
    const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
    if (name[0] == 'u') return bits;
    return if (bits == 0) null else bits - 1;
}

/// Whether the identifier at `index` names a slice or a pointer to an array
/// declared in the enclosing function, or a local holding a string literal:
/// passed whole, it coerces to the slice type its tail would have had.
fn namesSliceable(context: RuleRun, index: usize) bool {
    const tokens = context.tokens;
    const declaration = context.localDeclaration(index) orelse return false;
    if (tokens[declaration + 1].tag == .equal)
        return tokens[declaration + 2].tag == .string_literal and tokens[declaration + 3].tag == .semicolon;
    const declared = context.annotatedType(declaration) orelse return false;
    if (sliceType(context, declared) != null) return true;
    var cursor = declared.start;
    if (tokens[cursor].tag != .asterisk) return false;
    cursor += 1;
    if (tokens[cursor].tag == .keyword_const) cursor += 1;
    return tokens[cursor].tag == .l_bracket and switch (tokens[cursor + 1].tag) {
        .r_bracket, .asterisk, .colon => false,
        else => true,
    };
}

const SliceType = struct { element: []const u8, mutable: bool };

/// `[]T`, `[]const T` or a sentinel-terminated slice of a dotted type path.
fn sliceType(context: RuleRun, declared: ArgumentRange) ?SliceType {
    const tokens = context.tokens;
    if (tokens[declared.start].tag != .l_bracket) return null;
    var cursor = declared.start + 1;
    if (tokens[cursor].tag == .colon) cursor = findTag(tokens, cursor, declared.end, .r_bracket) orelse return null;
    if (tokens[cursor].tag != .r_bracket or cursor + 1 >= declared.end) return null;
    cursor += 1;
    const mutable = tokens[cursor].tag != .keyword_const;
    if (!mutable) cursor += 1;
    if (!tokens_module.isDottedPath(tokens, cursor, declared.end)) return null;
    return .{ .element = context.source[tokens[cursor].loc.start..tokens[declared.end - 1].loc.end], .mutable = mutable };
}

test "indexOf at zero prefers startsWith" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "const prefixed = std.mem.indexOf(u8, text, prefix) == 0;",
        .prefer_starts_with,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "find at zero prefers startsWith" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try findingsFor(arena.allocator(), "const prefixed = std.mem.find(u8, text, prefix) == 0;", .prefer_starts_with);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "guarded tail equality prefers endsWith" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "const suffixed = text.len >= suffix.len and std.mem.eql(u8, text[text.len - suffix.len..], suffix);",
        .prefer_ends_with,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "manual scalar counts prefer countScalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "var count: usize = 0; for (values) |value| { if (value == needle) { count += 1; } } use(count);",
        .prefer_count_scalar,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "manual scalar replacements prefer replaceScalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "for (values) |*value| { if (value.* == old) { value.* = replacement; } }",
        .prefer_replace_scalar,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "boolean scalar searches extend prefer indexOf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "for (values) |value| { if (value == needle) return true; } return false;",
        .prefer_index_of,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "enumerated searches prefer indexOf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "for (values, 0..) |value, index| { if (value == needle) return index; }",
        .prefer_index_of,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "nearby memory patterns without their proof stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const anywhere = std.mem.indexOf(u8, text, prefix) != null;\n" ++
        "const unsafe_tail = std.mem.eql(u8, text[text.len - suffix.len..], suffix);\n" ++
        "for (values) |*value| { if (value.* == old) inspect(value.*); }";
    for ([_]types.Rule{ .prefer_starts_with, .prefer_ends_with, .prefer_replace_scalar }) |rule| {
        const findings = try findingsFor(arena.allocator(), source, rule);
        try std.testing.expectEqual(@as(usize, 0), findings.len);
    }
}

/// The source after the one fix of the one finding `rule` reports on it, or
/// null when the finding offers none.
fn fixedFor(allocator: std.mem.Allocator, source: [:0]const u8, rule: types.Rule) !?[]const u8 {
    const found = try findingsFor(allocator, source, rule);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    if (found[0].fixes.len == 0) return null;
    try std.testing.expectEqual(@as(usize, 1), found[0].fixes.len);
    return try support.applyFix(allocator, source, found[0].fixes[0]);
}

test "a prefix search at zero becomes startsWith for every fix-all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try findingsFor(arena.allocator(), "const ok = std.mem.indexOf(u8, text, prefix) == 0;", .prefer_starts_with);
    try std.testing.expect(found[0].fixes[0].fix_all);
    try std.testing.expectEqualStrings(
        "fn f(text: []const u8) bool { return x and std.mem.startsWith(u8, text, \"ab\") or y; }",
        (try fixedFor(arena.allocator(), "fn f(text: []const u8) bool { return x and std.mem.find(u8, text, \"ab\") == 0 or y; }", .prefer_starts_with)).?,
    );
}

test "a prefix search bound into a larger operand keeps its comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][:0]const u8{
        "const a = std.mem.indexOf(u8, text, prefix) == 0 + 1;",
        "const a = std.mem.indexOf(u8, text, prefix) == 0 orelse b;",
        "const a = std.mem.indexOf(u8, text, prefix) == 0 & mask;",
        "const a = !std.mem.indexOf(u8, text, prefix) == 0;",
        "const a = offset + std.mem.indexOf(u8, text, prefix) == 0;",
        "const a = other.std.mem.indexOf(u8, text, prefix) == 0;",
        "const a = std.mem.indexOf(u8, text, prefix) == // first\n    0;",
    }) |source| try std.testing.expectEqual(@as(?[]const u8, null), try fixedFor(arena.allocator(), source, .prefer_starts_with));
}

test "a guarded tail comparison of a slice becomes endsWith" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn f(text: []const u8, suffix: []const u8) bool {\n    return std.mem.endsWith(u8, text, suffix);\n}",
        (try fixedFor(
            arena.allocator(),
            "fn f(text: []const u8, suffix: []const u8) bool {\n    return text.len >= suffix.len and\n        std.mem.eql(u8, text[text.len - suffix.len ..], suffix);\n}",
            .prefer_ends_with,
        )).?,
    );
    try std.testing.expectEqualStrings(
        "fn f(suffix: []const u8) bool { const text = \"name.zig\"; return std.mem.endsWith(u8, text, suffix); }",
        (try fixedFor(
            arena.allocator(),
            "fn f(suffix: []const u8) bool { const text = \"name.zig\"; return text.len >= suffix.len and std.mem.eql(u8, text[text.len - suffix.len ..], suffix); }",
            .prefer_ends_with,
        )).?,
    );
    try std.testing.expectEqualStrings(
        "fn f(text: *const [4]u8, suffix: []const u8) bool { return std.mem.endsWith(u8, text, suffix); }",
        (try fixedFor(
            arena.allocator(),
            "fn f(text: *const [4]u8, suffix: []const u8) bool { return text.len >= suffix.len and std.mem.eql(u8, text[text.len - suffix.len ..], suffix); }",
            .prefer_ends_with,
        )).?,
    );
}

test "a guarded tail comparison keeps its slice when the haystack or operator is unproven" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tail = "text.len >= suffix.len and std.mem.eql(u8, text[text.len - suffix.len ..], suffix)";
    for ([_][:0]const u8{
        // An array value is sliceable but does not coerce to a slice.
        "fn f(text: [4]u8, suffix: []const u8) bool { return " ++ tail ++ "; }",
        "fn f(text: anytype, suffix: []const u8) bool { return " ++ tail ++ "; }",
        "const text: []const u8 = \"a\";\nfn f(suffix: []const u8) bool { return " ++ tail ++ "; }",
        "fn f(self: S, text: []const u8, suffix: []const u8) bool { return self." ++ tail ++ "; }",
        "fn f(text: []const u8, suffix: []const u8) bool { return " ++ tail ++ " == false; }",
        "fn f(text: []const u8, suffix: []const u8) bool { return !" ++ tail ++ "; }",
        "fn f(text: []const u8, suffix: []const u8) bool { return text.len >= suffix.len and // tail\n    std.mem.eql(u8, text[text.len - suffix.len ..], suffix); }",
    }) |source| try std.testing.expectEqual(@as(?[]const u8, null), try fixedFor(arena.allocator(), source, .prefer_ends_with));
}

test "an enumerated search becomes findScalar and reuses the index capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\n" ++
            "fn find(items: []const u32, needle: u32) ?usize {\n" ++
            "    if (std.mem.findScalar(u32, items, needle)) |i| return i;\n" ++
            "    return null;\n" ++
            "}",
        (try fixedFor(arena.allocator(), "const std = @import(\"std\");\n" ++
            "fn find(items: []const u32, needle: u32) ?usize {\n" ++
            "    for (items, 0..) |item, i| {\n" ++
            "        if (needle == item) {\n" ++
            "            return i;\n" ++
            "        }\n" ++
            "    }\n" ++
            "    return null;\n" ++
            "}", .prefer_index_of)).?,
    );
}

test "a boolean search becomes findScalar against null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\n" ++
            "fn has(bytes: []const u8) bool {\n" ++
            "    return std.mem.findScalar(u8, bytes, ' ') != null;\n" ++
            "}",
        (try fixedFor(arena.allocator(), "const std = @import(\"std\");\n" ++
            "fn has(bytes: []const u8) bool {\n" ++
            "    for (bytes) |byte| {\n" ++
            "        if (byte == ' ') return true;\n" ++
            "    }\n" ++
            "    return false;\n" ++
            "}", .prefer_index_of)).?,
    );
}

test "a search keeps its loop when the scalar call cannot take its operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const std_import = "const std = @import(\"std\");\n";
    for ([_][:0]const u8{
        // No `std` to name the function with.
        "fn has(items: []const u8, needle: u8) bool { for (items) |item| { if (item == needle) return true; } return false; }",
        // A wider needle peer-resolves in `==` but not as the `T` argument.
        std_import ++ "fn has(items: []const u8, needle: u16) bool { for (items) |item| { if (item == needle) return true; } return false; }",
        std_import ++ "fn has(items: []const u8) bool { for (items) |item| { if (item == 300) return true; } return false; }",
        std_import ++ "fn has(items: []const i8) bool { for (items) |item| { if (item == '\\xff') return true; } return false; }",
        std_import ++ "fn has(items: []const f32) bool { for (items) |item| { if (item == 1) return true; } return false; }",
        std_import ++ "fn has(items: []const u8, needle: anytype) bool { for (items) |item| { if (item == needle) return true; } return false; }",
        // An array value or an undeclared element type.
        std_import ++ "fn has(items: [4]u8, needle: u8) bool { for (items) |item| { if (item == needle) return true; } return false; }",
        std_import ++ "fn has(items: anytype, needle: u8) bool { for (items) |item| { if (item == needle) return true; } return false; }",
        // Statement shapes the replacement would change.
        std_import ++ "fn has(items: []const u8, needle: u8) bool { search: for (items) |item| { if (item == needle) return true; } return false; }",
        std_import ++ "fn has(items: []const u8, needle: u8, ready: bool) bool { if (ready) for (items) |item| { if (item == needle) return true; } return false; }",
        std_import ++ "fn has(items: []const u8, needle: u8) bool { for (items) |item| { if (item == needle) return true; } // none\n return false; }",
        std_import ++ "fn find(items: []const u8, needle: u8) ?usize { for (items, 1..) |item, i| { if (item == needle) return i; } return null; }",
        std_import ++ "fn find(items: []const u8, needle: u8) ?usize { for (items, 0..) |item, i| { if (item == needle) return i + 1; } return null; }",
        std_import ++ "fn find(items: []const u8, needle: u8) ?usize { for (items, 0..) |item, i| { if (item == needle) { return i + 1; } } return null; }",
    }) |source| try std.testing.expectEqual(@as(?[]const u8, null), try fixedFor(arena.allocator(), source, .prefer_index_of));
}

test "a counting loop becomes countScalar and keeps var only when the count changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = "    for (values) |value| {\n        if (value == needle) {\n            count += 1;\n        }\n    }\n";
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\nfn f(values: []const u8, needle: u8) usize {\n    const count: usize = std.mem.countScalar(u8, values, needle);\n    return count;\n}",
        (try fixedFor(
            arena.allocator(),
            "const std = @import(\"std\");\nfn f(values: []const u8, needle: u8) usize {\n    var count: usize = 0;\n" ++ loop ++ "    return count;\n}",
            .prefer_count_scalar,
        )).?,
    );
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\nfn f(values: []const u8, needle: u8) usize {\n    var count: usize = std.mem.countScalar(u8, values, needle);\n    count += 1;\n    return count;\n}",
        (try fixedFor(
            arena.allocator(),
            "const std = @import(\"std\");\nfn f(values: []const u8, needle: u8) usize {\n    var count: usize = 0;\n" ++ loop ++ "    count += 1;\n    return count;\n}",
            .prefer_count_scalar,
        )).?,
    );
    for ([_][:0]const u8{
        // countScalar returns usize, which a narrower counter cannot take.
        "const std = @import(\"std\");\nfn f(values: []const u8, needle: u8) u32 {\n    var count: u32 = 0;\n" ++ loop ++ "    return count;\n}",
        "const std = @import(\"std\");\nfn f(values: []const u8, needle: u8) usize {\n    var count: usize = 0;\n    // tally\n" ++ loop ++ "    return count;\n}",
        "const std = @import(\"std\");\nfn f(values: []const u8, needle: u32) usize {\n    var count: usize = 0;\n" ++ loop ++ "    return count;\n}",
    }) |source| try std.testing.expectEqual(@as(?[]const u8, null), try fixedFor(arena.allocator(), source, .prefer_count_scalar));
}

test "a replacing loop over a mutable slice becomes replaceScalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = "for (values) |*value| { if (value.* == old) { value.* = '_'; } }";
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\nfn f(values: []u8, old: u8) void { std.mem.replaceScalar(u8, values, old, '_'); }",
        (try fixedFor(arena.allocator(), "const std = @import(\"std\");\nfn f(values: []u8, old: u8) void { " ++ loop ++ " }", .prefer_replace_scalar)).?,
    );
    for ([_][:0]const u8{
        "const std = @import(\"std\");\nfn f(values: *[4]u8, old: u8) void { " ++ loop ++ " }",
        "const std = @import(\"std\");\nfn f(values: []const u8, old: u8) void { " ++ loop ++ " }",
        "const std = @import(\"std\");\nfn f(values: []u16, old: u8) void { " ++ loop ++ " }",
        "const std = @import(\"std\");\nfn f(values: []u8, old: u16) void { " ++ loop ++ " }",
        "fn f(values: []u8, old: u8) void { " ++ loop ++ " }",
    }) |source| try std.testing.expectEqual(@as(?[]const u8, null), try fixedFor(arena.allocator(), source, .prefer_replace_scalar));
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8, rule: types.Rule) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{rule}, .information));
}
