const std = @import("std");

const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .discarded_must_use,
};

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
            .message = try context.allocator.print(
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
    var configuration = types.Configuration.defaults();
    configuration.must_use_contracts = &.{"Builder.finish"};
    configuration.levels[@backingInt(types.Rule.discarded_must_use)] = .warning;
    const findings = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.discarded_must_use, findings[0].rule);
}
