const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .negated_comptime_expression,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.negated_comptime_expression);
    if (level == .off) return;

    for (context.tokens, 0..) |token, bang_index| {
        if (token.tag != .bang or bang_index + 1 >= context.tokens.len or
            context.tokens[bang_index + 1].tag != .keyword_comptime) continue;
        const comptime_index = bang_index + 1;
        const span: std.zig.Token.Loc = .{ .start = token.loc.start, .end = context.tokens[comptime_index].loc.end };

        if (boundedExpressionEnd(context, comptime_index)) |expression_end| {
            const expression = context.source[context.tokens[comptime_index + 1].loc.start..context.tokens[expression_end].loc.end];
            const fixes = try context.singleFix(.{
                .title = "Move the negation inside the comptime expression",
                .span = .{ .start = token.loc.start, .end = context.tokens[expression_end].loc.end },
                .replacement = try context.allocator.print("comptime !({s})", .{expression}),
                .preferred = true,
            });
            try context.emit(.{
                .rule = .negated_comptime_expression,
                .level = level,
                .span = span,
                .message = try context.allocator.print(
                    "'!comptime {s}' applies the negation with surprising precedence; write 'comptime !({s})'",
                    .{ expression, expression },
                ),
                .fixes = fixes,
            });
        } else {
            try context.emit(.{
                .rule = .negated_comptime_expression,
                .level = level,
                .span = span,
                .message = try context.allocator.dupe(
                    u8,
                    "'!' directly before 'comptime' applies the negation with surprising precedence; hoist it inside the comptime expression",
                ),
            });
        }
    }
}

fn boundedExpressionEnd(context: RuleRun, comptime_index: usize) ?usize {
    var index = comptime_index + 1;
    if (index >= context.tokens.len or context.tokens[index].tag != .identifier) return null;
    while (index + 2 < context.tokens.len and context.tokens[index + 1].tag == .period and
        context.tokens[index + 2].tag == .identifier) index += 2;
    var end = index;
    if (end + 1 < context.tokens.len and context.tokens[end + 1].tag == .l_paren) {
        end = context.matchingToken(end + 1, .l_paren, .r_paren) orelse return null;
    }
    if (end + 1 >= context.tokens.len) return null;
    return switch (context.tokens[end + 1].tag) {
        .semicolon, .r_paren, .r_bracket, .comma => end,
        else => null,
    };
}

test "negated comptime call warns and rewrites into the comptime expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn skip() void { if (!comptime builtin.isDebug()) return; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "builtin.isDebug()") != null);
    try std.testing.expectEqualStrings("comptime !(builtin.isDebug())", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expect(!findings[0].fixes[0].fix_all);
}

test "negated comptime compound expression warns without a fix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const wide = !comptime bits + extra;";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(@as(usize, 0), findings[0].fixes.len);
}

test "inequality error unions and plain negation stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn compare(a: u8, b: u8) bool { return a != comptime maximum(); }\n" ++
        "fn fallible() !u8 { return 1; }\n" ++
        "const off = !enabled;";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.negated_comptime_expression}, .information));
}
