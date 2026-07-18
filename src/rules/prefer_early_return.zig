const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_early_return);
    if (level == .off) return;

    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 7 >= context.tokens.len or
            context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        const body_start = condition_end + 1;
        if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (body_end + 2 >= context.tokens.len or context.tokens[body_end + 1].tag != .keyword_else or
            context.tokens[body_end + 2].tag != .l_brace) continue;
        const else_end = context.matchingToken(body_end + 2, .l_brace, .r_brace) orelse continue;
        if (!singleReturn(context.tokens, body_end + 3, else_end)) continue;

        try context.emit(.{
            .rule = .prefer_early_return,
            .level = level,
            .span = token.loc,
            .message = "the else branch only returns; invert the condition and return early to keep the main path unindented",
        });
    }
}

fn singleReturn(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    if (start >= end or tokens[start].tag != .keyword_return or tokens[end - 1].tag != .semicolon) return false;
    for (tokens[start + 1 .. end - 1]) |token| switch (token.tag) {
        .semicolon, .l_brace, .r_brace => return false,
        else => {},
    };
    return true;
}

test "a returning else branch prefers an early return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(ready: bool) void {\n" ++
        "    if (ready) {\n" ++
        "        work();\n" ++
        "    } else {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(@as(usize, 0), findings[0].fixes.len);
}

test "else branches with cleanup before returning stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (ready) { work(); } else { cleanup(); return; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "early return preference respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line prefer-early-return\n" ++
        "if (ready) { work(); } else { return; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_early_return)] = .information;
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
