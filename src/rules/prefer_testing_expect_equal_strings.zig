const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_testing_expect_equal_strings);
    if (level == .off) return;

    for (context.tokens, 0..) |token, expect_index| {
        if (token.tag != .identifier or !context.tokenIs(expect_index, "expect") or
            expect_index + 8 >= context.tokens.len or context.tokens[expect_index + 1].tag != .l_paren or
            !calleeIsTestingQualified(context, expect_index)) continue;
        const expect_end = context.matchingToken(expect_index + 1, .l_paren, .r_paren) orelse continue;
        const eql_index = expect_index + 6;
        if (context.tokens[expect_index + 2].tag != .identifier or !context.tokenIs(expect_index + 2, "std") or
            context.tokens[expect_index + 3].tag != .period or !context.tokenIs(expect_index + 4, "mem") or
            context.tokens[expect_index + 5].tag != .period or !context.tokenIs(eql_index, "eql") or
            context.tokens[eql_index + 1].tag != .l_paren) continue;
        const eql_end = context.matchingToken(eql_index + 1, .l_paren, .r_paren) orelse continue;
        if (eql_end + 1 != expect_end or eql_index + 3 >= eql_end or !context.tokenIs(eql_index + 2, "u8") or
            context.tokens[eql_index + 3].tag != .comma) continue;
        const argument_comma = topLevelComma(context.tokens, eql_index + 4, eql_end) orelse continue;
        if (argument_comma == eql_index + 4 or argument_comma + 1 == eql_end) continue;

        const expression_start = callExpressionStart(context.tokens, expect_index + 1) orelse expect_index;
        const qualification = context.source[context.tokens[expression_start].loc.start..token.loc.start];
        const expected = std.mem.trim(
            u8,
            context.source[context.tokens[eql_index + 4].loc.start..context.tokens[argument_comma - 1].loc.end],
            " \t\r\n",
        );
        const actual = std.mem.trim(
            u8,
            context.source[context.tokens[argument_comma + 1].loc.start..context.tokens[eql_end - 1].loc.end],
            " \t\r\n",
        );
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = context.tokens[expression_start].loc.start, .end = context.tokens[expect_end].loc.end },
            .replacement = try std.fmt.allocPrint(
                context.allocator,
                "{s}expectEqualStrings({s}, {s})",
                .{ qualification, expected, actual },
            ),
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Use expectEqualStrings",
            .kind = .refactor_rewrite,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .prefer_testing_expect_equal_strings,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(
                u8,
                "byte-string comparison produces a less useful failure than expectEqualStrings",
            ),
            .fixes = fixes,
        });
    }
}

fn calleeIsTestingQualified(context: RuleRun, expect_index: usize) bool {
    if (expect_index == 0 or context.tokens[expect_index - 1].tag != .period) return true;
    return expect_index >= 2 and context.tokens[expect_index - 2].tag == .identifier and
        context.tokenIs(expect_index - 2, "testing");
}

fn topLevelComma(tokens: []const std.zig.Token, start: usize, end: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .comma => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index,
            else => {},
        }
    }
    return null;
}

fn callExpressionStart(tokens: []const std.zig.Token, opening: usize) ?usize {
    if (opening == 0 or tokens[opening - 1].tag != .identifier) return null;
    var start = opening - 1;
    while (start >= 2 and tokens[start - 1].tag == .period and tokens[start - 2].tag == .identifier) start -= 2;
    return start;
}

test "byte equality assertions use string-aware failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "try std.testing.expect(std.mem.eql(u8, expected(), actual));";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_testing_expect_equal_strings)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqualStrings(
        "std.testing.expectEqualStrings(expected(), actual)",
        findings.items[0].fixes[0].edits[0].replacement,
    );
}

test "a custom expect harness is not rewritten to expectEqualStrings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "try harness.expect(std.mem.eql(u8, expected, actual));";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_testing_expect_equal_strings)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "non-byte equality assertions do not use string expectations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "try std.testing.expect(std.mem.eql(u32, expected, actual));";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_testing_expect_equal_strings)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
