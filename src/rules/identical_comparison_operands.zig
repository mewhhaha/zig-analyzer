const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.identical_comparison_operands);
    if (level == .off) return;

    for (context.tokens, 0..) |token, op_index| {
        if (!isComparisonOp(token.tag) or op_index == 0 or op_index + 1 >= context.tokens.len) continue;

        // Find LHS path ending at op_index
        const lhs_span = pathBefore(context.tokens, op_index) orelse continue;

        // Ensure LHS is not part of a larger dot, call, or index expression
        if (lhs_span.start > 0) {
            const prev = context.tokens[lhs_span.start - 1].tag;
            if (prev == .period or prev == .r_paren or prev == .r_bracket) continue;
        }

        // Find RHS path starting at op_index + 1
        const rhs_span = pathAfter(context.tokens, op_index + 1) orelse continue;

        // Ensure RHS is not part of a larger dot, call, or index expression
        if (rhs_span.end < context.tokens.len) {
            const next = context.tokens[rhs_span.end].tag;
            if (next == .period or next == .l_paren or next == .l_bracket) continue;
        }

        // Compare LHS and RHS paths
        const lhs_len = lhs_span.end - lhs_span.start;
        const rhs_len = rhs_span.end - rhs_span.start;
        if (lhs_len != rhs_len) continue;

        var matches = true;
        for (0..lhs_len) |offset| {
            const lhs_tok = lhs_span.start + offset;
            const rhs_tok = rhs_span.start + offset;
            if (context.tokens[lhs_tok].tag != context.tokens[rhs_tok].tag or
                !context.tokenIs(lhs_tok, context.tokenText(rhs_tok)))
            {
                matches = false;
                break;
            }
        }
        if (!matches) continue;

        const expr_source = context.source[context.tokens[lhs_span.start].loc.start..context.tokens[rhs_span.end - 1].loc.end];
        if (containsComment(expr_source)) continue;

        const operand_text = context.source[context.tokens[lhs_span.start].loc.start..context.tokens[lhs_span.end - 1].loc.end];
        const op_text = context.tokenText(op_index);

        const message = if (token.tag == .equal_equal)
            try std.fmt.allocPrint(context.allocator, "comparison '{s} == {s}' always evaluates to true; operands are identical", .{ operand_text, operand_text })
        else if (token.tag == .bang_equal)
            try std.fmt.allocPrint(context.allocator, "comparison '{s} != {s}' always evaluates to false; if checking for NaN, use std.math.isNan or @isnan", .{ operand_text, operand_text })
        else
            try std.fmt.allocPrint(context.allocator, "comparison '{s} {s} {s}' compares identical operands and always evaluates to a constant", .{ operand_text, op_text, operand_text });

        try context.emit(.{
            .rule = .identical_comparison_operands,
            .level = level,
            .span = .{ .start = context.tokens[lhs_span.start].loc.start, .end = context.tokens[rhs_span.end - 1].loc.end },
            .message = message,
        });
    }
}

fn isComparisonOp(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal_equal,
        .bang_equal,
        .angle_bracket_left,
        .angle_bracket_right,
        .angle_bracket_left_equal,
        .angle_bracket_right_equal,
        => true,
        else => false,
    };
}

const PathSpan = struct {
    start: usize,
    end: usize,
};

fn pathBefore(tokens: []const std.zig.Token, before: usize) ?PathSpan {
    if (before == 0 or tokens[before - 1].tag != .identifier) return null;
    var cursor = before - 1;
    while (cursor >= 2 and tokens[cursor - 1].tag == .period and tokens[cursor - 2].tag == .identifier) {
        cursor -= 2;
    }
    return .{ .start = cursor, .end = before };
}

fn pathAfter(tokens: []const std.zig.Token, start: usize) ?PathSpan {
    if (start >= tokens.len or tokens[start].tag != .identifier) return null;
    var cursor = start + 1;
    while (cursor + 1 < tokens.len and tokens[cursor].tag == .period and tokens[cursor + 1].tag == .identifier) {
        cursor += 2;
    }
    return .{ .start = start, .end = cursor };
}

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

test "identical comparison operands reports comparisons of identical paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(x: u32, s: Struct) bool {\n" ++
        "    if (x == x) return true;\n" ++
        "    if (s.len != s.len) return false;\n" ++
        "    if (x < x) return false;\n" ++
        "    return true;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "x == x") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "s.len != s.len") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[2].message, "x < x") != null);
}

test "comparisons of distinct operands stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(x: u32, y: u32, s: Struct, other: Struct) bool {\n" ++
        "    if (x == y) return true;\n" ++
        "    if (s.len == other.len) return true;\n" ++
        "    if (s.len < 10) return true;\n" ++
        "    if (get().x == get().x) return true;\n" ++
        "    return false;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "identical comparison operands honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(x: u32) bool {\n" ++
        "    // zig-analyzer: disable-next-line identical-comparison-operands\n" ++
        "    return x == x;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.identical_comparison_operands)] = .warning;
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
