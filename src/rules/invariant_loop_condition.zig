const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.invariant_loop_condition);
    if (level == .off) return;

    for (context.tokens, 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 5 >= context.tokens.len or
            context.tokens[while_index + 1].tag != .l_paren or
            context.tokens[while_index + 2].tag != .identifier or
            context.tokens[while_index + 4].tag != .number_literal or
            context.tokens[while_index + 5].tag != .r_paren) continue;
        const operator = context.tokens[while_index + 3].tag;
        if (operator != .angle_bracket_left and operator != .angle_bracket_left_equal and
            operator != .angle_bracket_right and operator != .angle_bracket_right_equal and
            operator != .equal_equal and operator != .bang_equal) continue;
        const name = context.tokenText(while_index + 2);
        const left = uniqueLiteralConst(context, name) orelse continue;
        const right = std.fmt.parseInt(u128, context.tokenText(while_index + 4), 0) catch continue;
        const result = switch (operator) {
            .angle_bracket_left => left < right,
            .angle_bracket_left_equal => left <= right,
            .angle_bracket_right => left > right,
            .angle_bracket_right_equal => left >= right,
            .equal_equal => left == right,
            .bang_equal => left != right,
            else => unreachable,
        };
        try context.emit(.{
            .rule = .invariant_loop_condition,
            .level = level,
            .span = context.tokens[while_index + 2].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "while condition is invariant and always {s} because '{s}' is a constant; express the actual exit condition directly",
                .{ if (result) "true" else "false", name },
            ),
        });
    }
}

fn uniqueLiteralConst(context: RuleRun, name: []const u8) ?u128 {
    var value: ?u128 = null;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .keyword_const and token.tag != .keyword_var) continue;
        if (index + 3 >= context.tokens.len or !context.tokenIs(index + 1, name)) continue;
        if (token.tag == .keyword_var or value != null) return null;
        const statement_end = context.statementEnd(index) orelse return null;
        var equal_index = index + 2;
        while (equal_index < statement_end and context.tokens[equal_index].tag != .equal) : (equal_index += 1) {}
        if (equal_index + 2 != statement_end or context.tokens[equal_index + 1].tag != .number_literal) return null;
        value = std.fmt.parseInt(u128, context.tokenText(equal_index + 1), 0) catch return null;
    }
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        const is_const_name = index > 0 and context.tokens[index - 1].tag == .keyword_const;
        if (!is_const_name and index + 1 < context.tokens.len and context.tokens[index + 1].tag == .colon) return null;
        if ((index > 0 and context.tokens[index - 1].tag == .pipe) or
            (index + 1 < context.tokens.len and context.tokens[index + 1].tag == .pipe)) return null;
    }
    return value;
}

test "a loop condition over a literal constant reports its invariant result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const bytes_per_line = 16;\n" ++
        "fn dump() void { while (bytes_per_line > 0) { if (done()) break; } }\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "always true") != null);
}

test "variables and constants used in runtime conditions stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn consume(remaining: usize) void { while (remaining > 0) {} }\n" ++
        "fn count() void { var remaining: usize = 16; while (remaining > 0) : (remaining -= 1) {} }\n" ++
        "const limit = 16; fn shadowed(limit: usize) void { while (limit > 0) {} }\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.invariant_loop_condition)] = .information;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
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
