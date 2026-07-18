const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_optional_while_capture);
    if (level == .off) return;

    for (context.tokens, 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 8 >= context.tokens.len or
            context.tokens[while_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end != while_index + 3 or !context.tokenIs(while_index + 2, "true") or
            context.tokens[condition_end + 1].tag != .l_brace) continue;
        const body_end = context.matchingToken(condition_end + 1, .l_brace, .r_brace) orelse continue;
        const declaration_index = condition_end + 2;
        if (declaration_index + 5 >= body_end or context.tokens[declaration_index].tag != .keyword_const or
            context.tokens[declaration_index + 1].tag != .identifier or
            context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= body_end or declaration_end < declaration_index + 5 or
            context.tokens[declaration_end - 2].tag != .keyword_orelse or
            context.tokens[declaration_end - 1].tag != .keyword_break) continue;
        if (findTag(context.tokens, declaration_index + 3, declaration_end - 2, .keyword_orelse) != null) continue;

        const capture = context.tokenText(declaration_index + 1);
        const optional_source = std.mem.trim(
            u8,
            context.source[context.tokens[declaration_index + 3].loc.start..context.tokens[declaration_end - 3].loc.end],
            " \t\r\n",
        );
        try context.emit(.{
            .rule = .prefer_optional_while_capture,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "loop unwraps '{s}' into '{s}' and breaks on null; capture the optional in the while condition",
                .{ optional_source, capture },
            ),
        });
    }
}

fn findTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    for (tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

test "manual iterator unwrapping prefers a while capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "while (true) {\n" ++
        "    const entry = iterator.next() orelse break;\n" ++
        "    use(entry);\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "iterator.next()") != null);
}

test "labeled breaks and nonleading unwraps stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "outer: while (true) { const entry = iterator.next() orelse break :outer; use(entry); }\n" ++
        "while (true) { prepare(); const entry = iterator.next() orelse break; use(entry); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "optional while capture respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line prefer-optional-while-capture\n" ++
        "while (true) { const entry = iterator.next() orelse break; use(entry); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_optional_while_capture)] = .information;
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
