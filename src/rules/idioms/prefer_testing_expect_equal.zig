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
            tokens[expect_index + 1].tag != .l_paren or tokens[expect_index + 3].tag != .equal_equal or
            tokens[expect_index + 5].tag != .r_paren) continue;
        const left = tokens[expect_index + 2];
        const right = tokens[expect_index + 4];
        const left_literal = isSimpleLiteral(source, left);
        const right_literal = isSimpleLiteral(source, right);
        if (left_literal == right_literal) continue;
        const expected = if (left_literal) left else right;
        const actual = if (left_literal) right else left;
        if (actual.tag != .identifier) continue;
        const expression_start = callExpressionStart(tokens, expect_index + 1) orelse expect_index;
        const qualification = source[tokens[expression_start].loc.start..token.loc.start];
        const fixes = try Fix.single(context.allocator, .{
            .title = "Use expectEqual",
            .kind = .refactor_rewrite,
            .span = .{ .start = tokens[expression_start].loc.start, .end = tokens[expect_index + 5].loc.end },
            .replacement = try context.allocator.print(
                "{s}expectEqual({s}, {s})",
                .{ qualification, tokenText(source, expected), tokenText(source, actual) },
            ),
        });
        try context.emit(.{
            .rule = .prefer_testing_expect_equal,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "comparison of '{s}' with a literal produces a less useful test failure than expectEqual",
                .{tokenText(source, actual)},
            ),
            .fixes = fixes,
        });
    }
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
