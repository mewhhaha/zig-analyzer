const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;

pub const rules = [_]types.Rule{
    .redundant_boolean_negation,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.redundant_boolean_negation);
    if (level == .off) return;

    var index: usize = 0;
    while (index < context.tokens.len) : (index += 1) {
        const token = context.tokens[index];
        if (token.tag != .bang) continue;

        // Case 1: `!!expr`
        if (index + 2 < context.tokens.len and context.tokens[index + 1].tag == .bang) {
            const operand_start = index + 2;
            const operand_end = findOperandEnd(context, operand_start) orelse continue;
            const operand_source = context.source[context.tokens[operand_start].loc.start..context.tokens[operand_end - 1].loc.end];
            if (containsComment(context.source[token.loc.start..context.tokens[operand_end - 1].loc.end])) continue;

            const fixes = try context.singleFix(.{
                .title = "Remove redundant double negation",
                .span = .{ .start = token.loc.start, .end = context.tokens[index + 1].loc.end },
                .replacement = "",
                .preferred = true,
                .fix_all = true,
            });

            try context.emit(.{
                .rule = .redundant_boolean_negation,
                .level = level,
                .span = .{ .start = token.loc.start, .end = context.tokens[index + 1].loc.end },
                .message = try context.allocator.print(
                    "double boolean negation '!!{s}' is redundant; use '{s}' directly",
                    .{ operand_source, operand_source },
                ),
                .fixes = fixes,
            });
            index = operand_end - 1;
            continue;
        }

        // Case 2: `!(!expr)`
        if (index + 3 < context.tokens.len and
            context.tokens[index + 1].tag == .l_paren and
            context.tokens[index + 2].tag == .bang)
        {
            const close_paren = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
            if (close_paren <= index + 3) continue;

            const inner_source = std.mem.trim(
                u8,
                context.source[context.tokens[index + 3].loc.start..context.tokens[close_paren].loc.start],
                " \t\r\n",
            );
            if (containsComment(context.source[token.loc.start..context.tokens[close_paren].loc.end])) continue;

            const fixes = try context.singleFix(.{
                .title = "Remove redundant double negation",
                .span = .{ .start = token.loc.start, .end = context.tokens[close_paren].loc.end },
                .replacement = try context.allocator.dupe(u8, inner_source),
                .preferred = true,
                .fix_all = true,
            });

            try context.emit(.{
                .rule = .redundant_boolean_negation,
                .level = level,
                .span = .{ .start = token.loc.start, .end = context.tokens[close_paren].loc.end },
                .message = try context.allocator.print(
                    "double boolean negation '!(!{s})' is redundant; use '{s}' directly",
                    .{ inner_source, inner_source },
                ),
                .fixes = fixes,
            });
            index = close_paren;
            continue;
        }

        // Case 3: `!true` or `!false`
        if (index + 1 < context.tokens.len and context.tokens[index + 1].tag == .identifier) {
            const next_text = context.tokenText(index + 1);
            const is_true = std.mem.eql(u8, next_text, "true");
            const is_false = std.mem.eql(u8, next_text, "false");
            if (is_true or is_false) {
                const constant_source = if (is_true) "true" else "false";
                const simplified = if (is_true) "false" else "true";
                const whole_span = std.zig.Token.Loc{
                    .start = token.loc.start,
                    .end = context.tokens[index + 1].loc.end,
                };
                if (!containsComment(context.source[whole_span.start..whole_span.end])) {
                    const fixes = try context.singleFix(.{
                        .title = try context.allocator.print("Simplify '!{s}' to '{s}'", .{ constant_source, simplified }),
                        .span = whole_span,
                        .replacement = try context.allocator.dupe(u8, simplified),
                        .preferred = true,
                        .fix_all = true,
                    });

                    try context.emit(.{
                        .rule = .redundant_boolean_negation,
                        .level = level,
                        .span = whole_span,
                        .message = try context.allocator.print(
                            "negation of boolean constant '!{s}' is redundant; use '{s}' directly",
                            .{ constant_source, simplified },
                        ),
                        .fixes = fixes,
                    });
                    index += 1;
                    continue;
                }
            }
        }
    }
}

fn findOperandEnd(context: RuleRun, start: usize) ?usize {
    if (start >= context.tokens.len) return null;
    if (context.tokens[start].tag == .l_paren) {
        const close = context.matchingToken(start, .l_paren, .r_paren) orelse return null;
        return close + 1;
    }
    if (context.tokens[start].tag != .identifier) return null;
    var cursor = start + 1;
    while (cursor < context.tokens.len) {
        if (cursor + 1 < context.tokens.len and context.tokens[cursor].tag == .period and context.tokens[cursor + 1].tag == .identifier) {
            cursor += 2;
        } else if (context.tokens[cursor].tag == .l_paren) {
            const close = context.matchingToken(cursor, .l_paren, .r_paren) orelse return null;
            cursor = close + 1;
        } else break;
    }
    return cursor;
}

test "redundant boolean negation reports !! and !(!...)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(flag: bool) bool {\n" ++
        "    if (!!flag) return true;\n" ++
        "    if (!(!flag)) return true;\n" ++
        "    if (!true) return false;\n" ++
        "    if (!false) return true;\n" ++
        "    return false;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 4), findings.len);
    try std.testing.expectEqualStrings("", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("flag", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("false", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("true", findings[3].fixes[0].edits[0].replacement);
}

test "single negation stays unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(flag: bool) bool {\n" ++
        "    if (!flag) return true;\n" ++
        "    return !(flag and other);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.redundant_boolean_negation}, .information));
}
