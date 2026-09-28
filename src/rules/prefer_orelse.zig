const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_orelse);
    if (level == .off) return;

    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 9 >= context.tokens.len or
            context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (!isSimplePath(context.tokens, if_index + 2, condition_end) or
            condition_end + 5 >= context.tokens.len or
            context.tokens[condition_end + 1].tag != .pipe or context.tokens[condition_end + 2].tag != .identifier or
            context.tokens[condition_end + 3].tag != .pipe or context.tokens[condition_end + 4].tag != .identifier or
            context.tokens[condition_end + 5].tag != .keyword_else) continue;
        if (condition_end + 6 < context.tokens.len and context.tokens[condition_end + 6].tag == .pipe) continue;
        const capture = context.tokenText(condition_end + 2);
        if (!context.tokenIs(condition_end + 4, capture)) continue;
        if (operandIsKnownErrorUnion(context, if_index + 2, condition_end)) continue;

        try context.emit(.{
            .rule = .prefer_orelse,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "optional capture '{s}' is returned unchanged; use orelse for the fallback value",
                .{capture},
            ),
        });
    }
}

fn isSimplePath(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    if (start >= end) return false;
    for (tokens[start..end], 0..) |token, offset| {
        if (offset % 2 == 0) {
            if (token.tag != .identifier) return false;
        } else {
            if (token.tag != .period) return false;
        }
    }
    return (end - start) % 2 == 1;
}

fn operandIsKnownErrorUnion(context: RuleRun, start: usize, end: usize) bool {
    const name = context.tokenText(end - 1);
    for (context.tokens[0..start], 0..) |tok, idx| {
        if (tok.tag != .identifier or !context.tokenIs(idx, name) or idx + 1 >= start or
            context.tokens[idx + 1].tag != .colon) continue;
        var cursor = idx + 2;
        while (cursor < start and context.tokens[cursor].tag != .semicolon and
            context.tokens[cursor].tag != .equal and context.tokens[cursor].tag != .comma and
            context.tokens[cursor].tag != .r_paren) : (cursor += 1)
        {
            if (context.tokens[cursor].tag == .bang) return true;
        }
    }
    return false;
}

test "unchanged optional captures prefer orelse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const value = if (optional) |payload| payload else fallback;";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(@as(usize, 0), findings[0].fixes.len);
}

test "transformed captures and error-union branches stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const transformed = if (optional) |payload| payload + 1 else fallback;\n" ++
        "const handled = if (fallible) |payload| payload else |err| recover(err);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer orelse respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line prefer-orelse\n" ++
        "const value = if (optional) |payload| payload else fallback;";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_orelse)] = .information;
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
