//! `expect(a == b)` rewritten as `expectEqual`.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const callExpressionStart = @import("../../syntax/tokens.zig").callExpressionStart;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .prefer_testing_expect_equal,
};

pub fn run(context: RuleRun) !void {
    try findTestingIdioms(context);
}

fn findTestingIdioms(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.prefer_testing_expect_equal);
    if (level == .off) return;
    for (tokens, 0..) |token, expect_index| {
        if (token.tag != .identifier or !tokenIs(source, token, "expect") or expect_index + 5 >= tokens.len or
            tokens[expect_index + 1].tag != .l_paren) continue;
        const closing = context.scopes.matchingToken(expect_index + 1) orelse continue;
        const comparison = literalComparison(context, expect_index + 2, closing) orelse continue;
        // Beyond a plain name, `== null` tests absence (`std.mem.find(...) == null`)
        // and `== false` is better stated as `!f()`.
        if (tokens[comparison.expected].tag == .identifier and comparison.actual_end != comparison.actual_start + 1) continue;
        const expected = tokens[comparison.expected];
        const actual = source[tokens[comparison.actual_start].loc.start..tokens[comparison.actual_end - 1].loc.end];
        if (std.mem.findScalar(u8, actual, '\n') != null) continue;
        const expression_start = callExpressionStart(tokens, expect_index + 1) orelse expect_index;
        const qualification = source[tokens[expression_start].loc.start..token.loc.start];
        const fixes = try Fix.single(context.allocator, .{
            .title = "Use expectEqual",
            .kind = .refactor_rewrite,
            .span = .{ .start = tokens[expression_start].loc.start, .end = tokens[closing].loc.end },
            .replacement = try context.allocator.print(
                "{s}expectEqual({s}, {s})",
                .{ qualification, tokenText(source, expected), actual },
            ),
        });
        try context.emit(.{
            .rule = .prefer_testing_expect_equal,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "comparison of '{s}' with a literal produces a less useful test failure than expectEqual",
                .{actual},
            ),
            .fixes = fixes,
        });
    }
}

const Comparison = struct { expected: usize, actual_start: usize, actual_end: usize };

/// `actual == literal` or `literal == actual` filling `[start, end)`, where
/// the actual side is one postfix expression: a name, field, call, index,
/// dereference or unwrap chain.
fn literalComparison(context: RuleRun, start: usize, end: usize) ?Comparison {
    const tokens = context.tokens;
    if (end < start + 3) return null;
    if (isSimpleLiteral(context.source, tokens[start]) and tokens[start + 1].tag == .equal_equal) {
        if (postfixExpressionEnd(context, start + 2) != end) return null;
        return .{ .expected = start, .actual_start = start + 2, .actual_end = end };
    }
    if (isSimpleLiteral(context.source, tokens[end - 1]) and tokens[end - 2].tag == .equal_equal) {
        if (postfixExpressionEnd(context, start) != end - 2) return null;
        return .{ .expected = end - 1, .actual_start = start, .actual_end = end - 2 };
    }
    return null;
}

fn postfixExpressionEnd(context: RuleRun, start: usize) ?usize {
    const tokens = context.tokens;
    var cursor = start;
    switch (tokens[cursor].tag) {
        .identifier => {
            if (isSimpleLiteral(context.source, tokens[cursor])) return null;
            cursor += 1;
        },
        .builtin => {
            if (tokens[cursor + 1].tag != .l_paren) return null;
            cursor = (context.scopes.matchingToken(cursor + 1) orelse return null) + 1;
        },
        else => return null,
    }
    while (cursor + 1 < tokens.len) switch (tokens[cursor].tag) {
        .period => switch (tokens[cursor + 1].tag) {
            .identifier, .question_mark => cursor += 2,
            else => return null,
        },
        .period_asterisk => cursor += 1,
        .l_paren, .l_bracket => cursor = (context.scopes.matchingToken(cursor) orelse return null) + 1,
        else => return cursor,
    };
    return null;
}

fn isSimpleLiteral(source: []const u8, token: std.zig.Token) bool {
    return switch (token.tag) {
        .number_literal, .string_literal, .char_literal => true,
        .identifier => tokenIs(source, token, "true") or tokenIs(source, token, "false") or tokenIs(source, token, "null"),
        else => false,
    };
}

test "an expected equality comparison rewrites to expectEqual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "test \"value\" { const actual: u32 = 1; try std.testing.expect(actual == 42); }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_testing_expect_equal}, .information));
    try support.expectRules(found, &.{.prefer_testing_expect_equal});
}

test "field, length, call and dereference comparisons rewrite to expectEqual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "test \"shapes\" {\n" ++
        "    try std.testing.expect(list.items.len == 0);\n" ++
        "    try std.testing.expect(record.value == null);\n" ++
        "    try std.testing.expect(3 == count());\n" ++
        "    try std.testing.expect(rows[1].* == 'a');\n" ++
        "    try std.testing.expect(@intFromEnum(tag) == 2);\n" ++
        "    try std.testing.expect(record.value.? + 1 == 2);\n" ++
        "    try std.testing.expect(record.kind == .ready);\n" ++
        "    try std.testing.expect(ready() == false);\n" ++
        "    try std.testing.expect(ready and record.len == 1);\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_testing_expect_equal}, .information));
    var replacements: std.ArrayList([]const u8) = .empty;
    for (found) |finding| try replacements.append(arena.allocator(), finding.fixes[0].edits[0].replacement);
    try std.testing.expectEqual(@as(usize, 4), replacements.items.len);
    const expected = [_][]const u8{
        "std.testing.expectEqual(0, list.items.len)",
        "std.testing.expectEqual(3, count())",
        "std.testing.expectEqual('a', rows[1].*)",
        "std.testing.expectEqual(2, @intFromEnum(tag))",
    };
    for (expected, replacements.items) |want, got| try std.testing.expectEqualStrings(want, got);
}
