//! `comptime` conditions that are constant and `comptime`/`inline` markers that change nothing.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .constant_comptime_condition,
    .redundant_comptime,
    .redundant_inline,
};

pub fn run(context: RuleRun) !void {
    try findConstantComptimeConditions(context);
    try findComptimeIdioms(context);
}

fn findConstantComptimeConditions(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.constant_comptime_condition);
    if (level == .off) return;
    for (tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 2 >= tokens.len or tokens[if_index + 1].tag != .l_paren) continue;
        const explicitly_comptime = if_index > 0 and tokens[if_index - 1].tag == .keyword_comptime;
        const condition_index = if (tokens[if_index + 2].tag == .keyword_comptime) if_index + 3 else if_index + 2;
        if (condition_index >= tokens.len or (!explicitly_comptime and tokens[if_index + 2].tag != .keyword_comptime)) continue;
        if (!tokenIs(source, tokens[condition_index], "true") and !tokenIs(source, tokens[condition_index], "false")) continue;
        try context.emit(.{
            .rule = .constant_comptime_condition,
            .level = level,
            .span = tokens[condition_index].loc,
            .message = try context.allocator.print(
                "comptime condition is always {s}; the other branch is inactive in this context.configuration",
                .{tokenText(source, tokens[condition_index])},
            ),
        });
    }
}

fn findComptimeIdioms(context: RuleRun) !void {
    const tokens = context.tokens;
    const comptime_level = context.level(.redundant_comptime);
    const inline_level = context.level(.redundant_inline);
    if (comptime_level == .off and inline_level == .off) return;
    for (tokens, 0..) |token, index| {
        const is_redundant_comptime = token.tag == .keyword_comptime and comptime_level != .off and
            index + 1 < tokens.len and tokens[index + 1].tag != .l_brace and insideComptimeScope(tokens, index);
        const is_redundant_inline = token.tag == .keyword_inline and inline_level != .off and
            index + 1 < tokens.len and
            (tokens[index + 1].tag == .keyword_for or tokens[index + 1].tag == .keyword_while) and
            insideComptimeScope(tokens, index);
        if (!is_redundant_comptime and !is_redundant_inline) continue;
        const fixes = try Fix.single(context.allocator, .{
            .title = if (is_redundant_comptime) "Remove redundant comptime" else "Remove redundant inline",
            .kind = .refactor_rewrite,
            .span = .{ .start = token.loc.start, .end = tokens[index + 1].loc.start },
            .replacement = "",
            .preferred = true,
            .fix_all = true,
        });
        try context.emit(.{
            .rule = if (is_redundant_comptime) .redundant_comptime else .redundant_inline,
            .level = if (is_redundant_comptime) comptime_level else inline_level,
            .span = token.loc,
            .message = try context.allocator.dupe(
                u8,
                if (is_redundant_comptime)
                    "expression is already evaluated inside a comptime block"
                else
                    "loop is already evaluated inside a comptime block; inline is redundant",
            ),
            .fixes = fixes,
        });
    }
}

fn insideComptimeScope(tokens: []const std.zig.Token, index: usize) bool {
    var cursor = index;
    var nested_closings: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == .r_brace) {
            nested_closings += 1;
            continue;
        }
        if (tokens[cursor].tag != .l_brace) continue;
        if (nested_closings != 0) {
            nested_closings -= 1;
            continue;
        }
        if (cursor > 0 and tokens[cursor - 1].tag == .keyword_comptime) return true;
    }
    return false;
}

test "an explicit constant comptime condition is reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run() void { if (comptime true) {} }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.constant_comptime_condition}, .hint));
    try support.expectRules(found, &.{.constant_comptime_condition});
}
