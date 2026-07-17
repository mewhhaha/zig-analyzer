const std = @import("std");

const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.discarded_must_use);
    if (level == .off or context.configuration.must_use_contracts.len == 0) return;

    for (context.tokens, 0..) |token, index| {
        if (token.tag != .equal or index == 0 or index + 2 >= context.tokens.len or
            context.tokens[index - 1].tag != .identifier or !context.tokenIs(index - 1, "_")) continue;
        const call_open = nextCallOpen(context.tokens, index + 1) orelse continue;
        const callable = callableBefore(context, call_open) orelse continue;
        const contract = matchingContract(callable, context.configuration.must_use_contracts) orelse continue;
        try context.emit(.{
            .rule = .discarded_must_use,
            .level = level,
            .span = context.tokens[call_open - 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "return value from '{s}' is discarded, but contract '{s}' requires callers to use it",
                .{ callable, contract },
            ),
        });
    }
}

fn nextCallOpen(tokens: []const std.zig.Token, start: usize) ?usize {
    var index = start;
    while (index < tokens.len and index - start < 4) : (index += 1) {
        if (tokens[index].tag == .l_paren and index > start) return index;
        if (tokens[index].tag == .semicolon) return null;
    }
    return null;
}

fn callableBefore(context: RuleRun, call_open: usize) ?[]const u8 {
    if (call_open == 0 or context.tokens[call_open - 1].tag != .identifier) return null;
    var start = call_open - 1;
    while (start >= 2 and context.tokens[start - 1].tag == .period and
        context.tokens[start - 2].tag == .identifier) start -= 2;
    return context.source[context.tokens[start].loc.start..context.tokens[call_open - 1].loc.end];
}

fn matchingContract(callable: []const u8, contracts: []const []const u8) ?[]const u8 {
    for (contracts) |contract| {
        if (std.mem.eql(u8, callable, contract)) return contract;
    }
    return null;
}

test "must-use contracts reject explicit result discards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void { _ = Builder.finish(); const result = Builder.finish(); _ = result; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.must_use_contracts = &.{"Builder.finish"};
    configuration.levels[@intFromEnum(types.Rule.discarded_must_use)] = .warning;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });

    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(types.Rule.discarded_must_use, findings.items[0].rule);
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
