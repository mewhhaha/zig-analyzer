const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.discarded_realloc_result);
    if (level == .off) return;

    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or
            context.tokens[equal_index - 1].tag != .identifier or !context.tokenIs(equal_index - 1, "_")) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        for (context.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or method_index == 0 or method_index + 1 >= statement_end or
                context.tokens[method_index - 1].tag != .period or context.tokens[method_index + 1].tag != .l_paren or
                (!context.tokenIs(method_index, "realloc") and !context.tokenIs(method_index, "reallocAdvanced"))) continue;
            try context.emit(.{
                .rule = .discarded_realloc_result,
                .level = level,
                .span = candidate.loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "discarding {s}'s returned slice keeps a potentially invalid pointer and the old length",
                    .{context.tokenText(method_index)},
                ),
            });
            break;
        }
    }
}

test "discarded realloc results report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn resize(allocator: anytype, bytes: []u8) !void {\n" ++
        "    _ = try allocator.realloc(bytes, 32);\n" ++
        "    _ = try allocator.reallocAdvanced(bytes, 64, 0);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "stored realloc results stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn resize(allocator: anytype, bytes: []u8) ![]u8 {\n" ++
        "    const resized = try allocator.realloc(bytes, 32);\n" ++
        "    return resized;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
