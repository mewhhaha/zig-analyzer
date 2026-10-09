//! Counted `while` loops over `usize` that a `for` range expresses directly.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const findTag = @import("../../syntax/tokens.zig").findTag;

pub const rules = [_]types.Rule{.prefer_range_for};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_range_for);
    if (level == .off) return;
    for (context.tokens, 0..) |token, var_index| {
        if (token.tag != .keyword_var or var_index + 5 >= context.tokens.len or context.tokens[var_index + 1].tag != .identifier) continue;
        if (context.tokens[var_index + 2].tag != .colon or !context.tokenIs(var_index + 3, "usize")) continue;
        const declaration_end = context.statementEnd(var_index) orelse continue;
        const equal = findTag(context.tokens, var_index + 2, declaration_end, .equal) orelse continue;
        if (equal + 1 >= declaration_end or !context.tokenIs(equal + 1, "0")) continue;
        const while_index = declaration_end + 1;
        if (while_index + 11 >= context.tokens.len or context.tokens[while_index].tag != .keyword_while or
            context.tokens[while_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end <= while_index + 4 or !context.tokenIs(while_index + 2, context.tokenText(var_index + 1)) or
            context.tokens[while_index + 3].tag != .angle_bracket_left) continue;
        const continue_open = condition_end + 2;
        if (context.tokens[condition_end + 1].tag != .colon or context.tokens[continue_open].tag != .l_paren) continue;
        const continue_end = context.matchingToken(continue_open, .l_paren, .r_paren) orelse continue;
        if (continue_end != continue_open + 4 or !context.tokenIs(continue_open + 1, context.tokenText(var_index + 1)) or
            context.tokens[continue_open + 2].tag != .plus_equal or !context.tokenIs(continue_open + 3, "1")) continue;
        if (continue_end + 1 >= context.tokens.len or context.tokens[continue_end + 1].tag != .l_brace) continue;
        const body_end = context.matchingToken(continue_end + 1, .l_brace, .r_brace) orelse continue;
        const name = context.tokenText(var_index + 1);
        if (bindingAssigned(context, continue_end + 2, body_end, name)) continue;
        if (condition_end != while_index + 5 or
            (context.tokens[while_index + 4].tag != .identifier and context.tokens[while_index + 4].tag != .number_literal)) continue;
        if (context.tokens[while_index + 4].tag == .identifier and
            bindingAssigned(context, continue_end + 2, body_end, context.tokenText(while_index + 4))) continue;
        const scope_end = context.enclosingScopeEnd(var_index) orelse context.tokens.len;
        if (context.findIdentifier(body_end + 1, scope_end, name) != null) continue;
        const bound = context.source[context.tokens[while_index + 4].loc.start..context.tokens[condition_end - 1].loc.end];
        const capture = if (context.rangeContainsName(name, continue_end + 2, body_end)) name else "_";
        const replacement = try context.allocator.print("for (0..{s}) |{s}| {{", .{ bound, capture });
        errdefer context.allocator.free(replacement);
        const fixes = try context.singleFix(.{
            .title = "Use a range for loop",
            .kind = .refactor_rewrite,
            .span = .{ .start = token.loc.start, .end = context.tokens[continue_end + 1].loc.end },
            .replacement = replacement,
            .preferred = true,
            .fix_all = true,
        });
        try context.emit(.{
            .rule = .prefer_range_for,
            .level = level,
            .span = context.tokens[while_index].loc,
            .message = try context.allocator.print("counter '{s}' only describes the range 0..{s}; use a range for loop", .{ name, bound }),
            .fixes = fixes,
        });
    }
}

fn bindingAssigned(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index + 1 >= end) continue;
        switch (context.tokens[index + 1].tag) {
            .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal => return true,
            else => {},
        }
    }
    return false;
}

test "range loops preserve non-usize counter types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run() void { var seed: u64 = 0; while (seed < 16) : (seed += 1) use(seed); }";
    const configuration = support.only(&.{.prefer_range_for}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "counted while loops over usize report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f() void { var i: usize = 0; while (i < count) : (i += 1) { use(names[i]); } }";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_range_for}, .information));
    try support.expectRules(found, &.{.prefer_range_for});
}

test "an unused counter becomes a discarded capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f() void { var i: usize = 0; while (i < count) : (i += 1) { total += 1; } }";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_range_for}, .information));
    try support.expectRules(found, &.{.prefer_range_for});
    try std.testing.expectEqualStrings("for (0..count) |_| {", found[0].fixes[0].edits[0].replacement);
}
