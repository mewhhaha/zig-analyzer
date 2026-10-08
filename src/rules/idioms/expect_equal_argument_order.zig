const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;
const ArgumentRange = @import("../../syntax/tokens.zig").Range;

pub const rules = [_]types.Rule{
    .expect_equal_argument_order,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.expect_equal_argument_order);
    if (level == .off) return;

    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or !context.tokenIs(call_index, "expectEqual") or
            call_index + 1 >= context.tokens.len or
            context.tokens[call_index + 1].tag != .l_paren) continue;

        const is_std_testing = (call_index >= 4 and context.tokenIs(call_index - 4, "std") and
            context.tokens[call_index - 3].tag == .period and context.tokenIs(call_index - 2, "testing") and
            context.tokens[call_index - 1].tag == .period);
        const is_testing = (call_index >= 2 and context.tokenIs(call_index - 2, "testing") and
            context.tokens[call_index - 1].tag == .period);
        if (!is_std_testing and !is_testing) continue;

        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;
        const arguments = twoArguments(context, call_index + 1, call_end) orelse continue;

        if (!isLiteralArgument(context, arguments[1]) or isLiteralArgument(context, arguments[0])) continue;

        const expr_source = context.source[context.tokens[arguments[0].start].loc.start..context.tokens[arguments[1].end - 1].loc.end];
        if (containsComment(expr_source)) continue;

        const actual_text = context.argumentSource(arguments[0]);
        const expected_text = context.argumentSource(arguments[1]);
        if (actual_text.len == 0 or expected_text.len == 0) continue;

        const replacement = try context.allocator.print("{s}, {s}", .{ expected_text, actual_text });

        const fixes = try context.singleFix(.{
            .title = try context.allocator.dupe(u8, "Swap 'expected' and 'actual' arguments"),
            .span = .{
                .start = context.tokens[arguments[0].start].loc.start,
                .end = context.tokens[arguments[1].end - 1].loc.end,
            },
            .replacement = replacement,
            .preferred = true,
            .fix_all = true,
        });

        const message = try context.allocator.print(
            "std.testing.expectEqual expects '(expected, actual)', but literal '{s}' is passed as the second argument",
            .{expected_text},
        );

        try context.emit(.{
            .rule = .expect_equal_argument_order,
            .level = level,
            .span = token.loc,
            .message = message,
            .fixes = fixes,
        });
    }
}

fn twoArguments(context: RuleRun, opening: usize, closing: usize) ?[2]ArgumentRange {
    var commas: [2]usize = undefined;
    var comma_count: usize = 0;
    var depth: usize = 0;
    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            if (comma_count == commas.len) return null;
            commas[comma_count] = index;
            comma_count += 1;
        },
        else => {},
    };
    if (comma_count == 1) {
        if (commas[0] == opening + 1 or commas[0] + 1 == closing) return null;
        return .{
            .{ .start = opening + 1, .end = commas[0] },
            .{ .start = commas[0] + 1, .end = closing },
        };
    } else if (comma_count == 2 and commas[1] + 1 == closing) {
        if (commas[0] == opening + 1 or commas[1] == commas[0] + 1) return null;
        return .{
            .{ .start = opening + 1, .end = commas[0] },
            .{ .start = commas[0] + 1, .end = commas[1] },
        };
    }
    return null;
}

fn isLiteralArgument(context: RuleRun, range: ArgumentRange) bool {
    const len = range.end - range.start;
    if (len == 0) return false;

    if (len == 1) {
        return switch (context.tokens[range.start].tag) {
            .number_literal,
            .char_literal,
            .string_literal,
            => true,
            .identifier => context.tokenIs(range.start, "true") or
                context.tokenIs(range.start, "false") or
                context.tokenIs(range.start, "null") or
                context.tokenIs(range.start, "undefined"),
            else => false,
        };
    }

    if (len == 2 and context.tokens[range.start].tag == .period and
        context.tokens[range.start + 1].tag == .identifier)
    {
        return true;
    }

    if (len == 3 and context.tokens[range.start].tag == .period and
        context.tokens[range.start + 1].tag == .l_brace and
        context.tokens[range.start + 2].tag == .r_brace)
    {
        return true;
    }

    if (len == 4 and context.tokens[range.start].tag == .ampersand and
        context.tokens[range.start + 1].tag == .period and
        context.tokens[range.start + 2].tag == .l_brace and
        context.tokens[range.start + 3].tag == .r_brace)
    {
        return true;
    }

    if (len >= 6 and context.tokens[range.start].tag == .builtin and
        context.tokenIs(range.start, "@as") and
        context.tokens[range.start + 1].tag == .l_paren and
        context.tokens[range.end - 1].tag == .r_paren)
    {
        const inner_closing = range.end - 1;
        var comma_idx: ?usize = null;
        var depth: usize = 0;
        for (context.tokens[range.start + 2 .. inner_closing], range.start + 2..) |tok, idx| switch (tok.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                comma_idx = idx;
                break;
            },
            else => {},
        };
        if (comma_idx) |ci| {
            return isLiteralArgument(context, .{ .start = ci + 1, .end = inner_closing });
        }
    }

    return false;
}

test "expect equal argument order detects swapped literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(val: u32, opt: ?u32, flag: bool, mode: Mode) !void {\n" ++
        "    try std.testing.expectEqual(val, 42);\n" ++
        "    try std.testing.expectEqual(opt, null);\n" ++
        "    try std.testing.expectEqual(flag, true);\n" ++
        "    try std.testing.expectEqual(mode, .ready);\n" ++
        "    try std.testing.expectEqual(val, @as(u32, 10));\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 5), findings.len);
    try std.testing.expectEqualStrings("42, val", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("null, opt", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("true, flag", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings(".ready, mode", findings[3].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("@as(u32, 10), val", findings[4].fixes[0].edits[0].replacement);
}

test "correct expectEqual argument order stays unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(val: u32, expected: u32) !void {\n" ++
        "    try std.testing.expectEqual(42, val);\n" ++
        "    try std.testing.expectEqual(@as(u32, 10), val);\n" ++
        "    try std.testing.expectEqual(expected, val);\n" ++
        "    try std.testing.expectEqual(1, 2);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.expect_equal_argument_order}, .warning));
}
