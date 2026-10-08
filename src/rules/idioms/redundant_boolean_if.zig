const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;

pub const rules = [_]types.Rule{
    .redundant_boolean_if,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.redundant_boolean_if);
    if (level == .off) return;

    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 5 >= context.tokens.len or
            context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end == if_index + 2) continue;

        if (parseBooleanReturnBranch(context, condition_end + 1)) |then_branch| {
            const else_index = then_branch.end + 1;
            if (else_index < context.tokens.len and context.tokens[else_index].tag == .keyword_else) {
                if (parseBooleanReturnBranch(context, else_index + 1)) |else_branch| {
                    if (then_branch.value != else_branch.value) {
                        const inverted = !then_branch.value and else_branch.value;
                        const statement_source = context.source[token.loc.start..context.tokens[else_branch.end].loc.end];
                        if (!containsComment(statement_source)) {
                            const condition_source = context.source[context.tokens[if_index + 1].loc.end..context.tokens[condition_end].loc.start];
                            const condition = std.mem.trim(u8, condition_source, " \t\r\n");
                            const replacement = if (inverted) blk: {
                                if (isSimpleCondition(context, if_index + 2, condition_end)) {
                                    break :blk try context.allocator.print("return !{s};", .{condition});
                                }
                                break :blk try context.allocator.print("return !({s});", .{condition});
                            } else try context.allocator.print("return {s};", .{condition});

                            const fixes = try context.singleFix(.{
                                .title = if (inverted) "Negate the boolean condition directly" else "Return the boolean condition directly",
                                .span = .{ .start = token.loc.start, .end = context.tokens[else_branch.end].loc.end },
                                .replacement = replacement,
                                .preferred = true,
                                .fix_all = true,
                            });
                            try context.emit(.{
                                .rule = .redundant_boolean_if,
                                .level = level,
                                .span = token.loc,
                                .message = try context.allocator.dupe(
                                    u8,
                                    if (inverted)
                                        "if statement only negates its boolean condition"
                                    else
                                        "if statement returns the same boolean value as its condition",
                                ),
                                .fixes = fixes,
                            });
                            continue;
                        }
                    }
                }
            }
        }

        if (condition_end + 4 >= context.tokens.len or
            context.tokens[condition_end + 1].tag != .identifier or
            context.tokens[condition_end + 2].tag != .keyword_else or
            context.tokens[condition_end + 3].tag != .identifier or
            !endsExpression(context.tokens[condition_end + 4].tag)) continue;

        const when_true = context.tokenText(condition_end + 1);
        const when_false = context.tokenText(condition_end + 3);
        const inverted = std.mem.eql(u8, when_true, "false") and std.mem.eql(u8, when_false, "true");
        if (!inverted and !(std.mem.eql(u8, when_true, "true") and std.mem.eql(u8, when_false, "false"))) continue;

        const expression_source = context.source[token.loc.start..context.tokens[condition_end + 3].loc.end];
        if (containsComment(expression_source)) continue;
        const condition_source = context.source[context.tokens[if_index + 1].loc.end..context.tokens[condition_end].loc.start];
        const condition = std.mem.trim(u8, condition_source, " \t\r\n");
        const replacement = if (inverted) blk: {
            if (isSimpleCondition(context, if_index + 2, condition_end)) {
                break :blk try context.allocator.print("!{s}", .{condition});
            }
            break :blk try context.allocator.print("!({s})", .{condition});
        } else if (startsStandaloneExpression(context.tokens, if_index))
            try context.allocator.dupe(u8, condition)
        else
            try context.allocator.print("({s})", .{condition});
        const fixes = try context.singleFix(.{
            .title = if (inverted) "Negate the boolean condition directly" else "Use the boolean condition directly",
            .span = .{ .start = token.loc.start, .end = context.tokens[condition_end + 3].loc.end },
            .replacement = replacement,
            .preferred = true,
            .fix_all = true,
        });
        try context.emit(.{
            .rule = .redundant_boolean_if,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(
                u8,
                if (inverted)
                    "if expression only negates its boolean condition"
                else
                    "if expression returns the same boolean value as its condition",
            ),
            .fixes = fixes,
        });
    }
}

const BranchResult = struct {
    value: bool,
    end: usize,
};

fn parseBooleanReturnBranch(context: RuleRun, start: usize) ?BranchResult {
    if (start >= context.tokens.len) return null;
    if (context.tokens[start].tag == .l_brace) {
        if (start + 4 >= context.tokens.len) return null;
        if (context.tokens[start + 1].tag != .keyword_return) return null;
        if (context.tokens[start + 2].tag != .identifier) return null;
        if (context.tokens[start + 3].tag != .semicolon) return null;
        if (context.tokens[start + 4].tag != .r_brace) return null;
        const val_str = context.tokenText(start + 2);
        if (std.mem.eql(u8, val_str, "true")) return .{ .value = true, .end = start + 4 };
        if (std.mem.eql(u8, val_str, "false")) return .{ .value = false, .end = start + 4 };
        return null;
    } else if (context.tokens[start].tag == .keyword_return) {
        if (start + 2 >= context.tokens.len) return null;
        if (context.tokens[start + 1].tag != .identifier) return null;
        if (context.tokens[start + 2].tag != .semicolon) return null;
        const val_str = context.tokenText(start + 1);
        if (std.mem.eql(u8, val_str, "true")) return .{ .value = true, .end = start + 2 };
        if (std.mem.eql(u8, val_str, "false")) return .{ .value = false, .end = start + 2 };
        return null;
    }
    return null;
}

fn endsExpression(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .semicolon, .comma, .r_paren, .r_bracket, .r_brace => true,
        else => false,
    };
}

fn startsStandaloneExpression(tokens: []const std.zig.Token, if_index: usize) bool {
    if (if_index == 0) return true;
    return switch (tokens[if_index - 1].tag) {
        .equal,
        .comma,
        .l_paren,
        .l_bracket,
        .l_brace,
        .equal_angle_bracket_right,
        .keyword_return,
        => true,
        else => false,
    };
}

fn isSimpleCondition(context: RuleRun, start: usize, end: usize) bool {
    if (start + 1 == end and context.tokens[start].tag == .identifier) return true;
    if (start + 2 >= end or context.tokens[start].tag != .identifier or context.tokens[start + 1].tag != .l_paren) return false;
    return context.matchingToken(start + 1, .l_paren, .r_paren) == end - 1;
}

test "boolean-valued if expressions use their condition directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const direct = if (ready()) true else false;\n" ++
        "const inverse = if (ready()) false else true;";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("ready()", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("!ready()", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqual(types.ActionKind.quickfix, findings[0].fixes[0].kind);
    try std.testing.expect(findings[0].fixes[0].fix_all);
}

test "non-boolean branches and commented conditions stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const number = if (ready()) 1 else 0;\n" ++
        "const same = if (ready()) true else true;\n" ++
        "const compared = if (ready()) true else false == other;\n" ++
        "const explained = if (ready() // policy\n) true else false;\n" ++
        "const explained_branch = if (ready()) true // policy\nelse false;";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "boolean-valued if return statements suggest direct return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn testDirect(c: bool) bool {\n" ++
        "    if (c) return true; else return false;\n" ++
        "}\n" ++
        "fn testInverse(c: bool) bool {\n" ++
        "    if (c) { return false; } else { return true; }\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("return c;", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("return !c;", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqual(types.ActionKind.quickfix, findings[0].fixes[0].kind);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.redundant_boolean_if}, .information));
}
