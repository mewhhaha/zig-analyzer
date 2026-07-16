const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.redundant_boolean_if);
    if (level == .off) return;

    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 5 >= context.tokens.len or
            context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end == if_index + 2 or condition_end + 4 >= context.tokens.len or
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
                break :blk try std.fmt.allocPrint(context.allocator, "!{s}", .{condition});
            }
            break :blk try std.fmt.allocPrint(context.allocator, "!({s})", .{condition});
        } else if (startsStandaloneExpression(context.tokens, if_index))
            try context.allocator.dupe(u8, condition)
        else
            try std.fmt.allocPrint(context.allocator, "({s})", .{condition});
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = token.loc.start, .end = context.tokens[condition_end + 3].loc.end },
            .replacement = replacement,
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = if (inverted) "Negate the boolean condition directly" else "Use the boolean condition directly",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
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

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
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

test "boolean if respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line redundant-boolean-if\n" ++
        "const direct = if (ready()) true else false;";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.redundant_boolean_if)] = .information;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
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
