//! `catch |e| return e` rewritten as `try`.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const matchingOpeningToken = @import("../../syntax/tokens.zig").matchingOpeningToken;
const callExpressionStart = @import("../../syntax/tokens.zig").callExpressionStart;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .prefer_try,
};

pub fn run(context: RuleRun) !void {
    try findTryIdioms(context);
}

fn findTryIdioms(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.prefer_try);
    if (level == .off) return;
    for (tokens, 0..) |token, catch_index| {
        if (token.tag != .keyword_catch or catch_index < 2 or catch_index + 5 >= tokens.len or
            tokens[catch_index - 1].tag != .r_paren or tokens[catch_index + 1].tag != .pipe or
            tokens[catch_index + 2].tag != .identifier or tokens[catch_index + 3].tag != .pipe or
            tokens[catch_index + 4].tag != .keyword_return or tokens[catch_index + 5].tag != .identifier) continue;
        const error_name = tokenText(source, tokens[catch_index + 2]);
        if (!tokenIs(source, tokens[catch_index + 5], error_name)) continue;
        const call_open = matchingOpeningToken(tokens, catch_index - 1, .l_paren, .r_paren) orelse continue;
        const expression_start = callExpressionStart(tokens, call_open) orelse continue;
        const expression = std.mem.trim(u8, source[tokens[expression_start].loc.start..token.loc.start], " \t\r\n");
        const fixes = try Fix.single(context.allocator, .{
            .title = "Propagate the error with try",
            .kind = .refactor_rewrite,
            .span = .{ .start = tokens[expression_start].loc.start, .end = tokens[catch_index + 5].loc.end },
            .replacement = try context.allocator.print("try {s}", .{expression}),
            .preferred = true,
            .fix_all = true,
        });
        try context.emit(.{
            .rule = .prefer_try,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("caught error '{s}' is returned unchanged; use try to propagate it", .{error_name}),
            .fixes = fixes,
        });
    }
}

test "prefer try rewrites chained calls from the expression start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(stream: anytype, data: []const u8) !void {\n" ++
        "    const written = stream.getWriter().write(data) catch |err| return err;\n" ++
        "    _ = written;\n" ++
        "}\n" ++
        "fn opaque_receiver(data: []const u8) !void {\n" ++
        "    const written = (makeWriter()).write(data) catch |err| return err;\n" ++
        "    _ = written;\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_try}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var try_count: usize = 0;
    for (found) |finding| if (finding.rule == .prefer_try) {
        try_count += 1;
        try std.testing.expectEqualStrings("try stream.getWriter().write(data)", finding.fixes[0].edits[0].replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), try_count);
}
