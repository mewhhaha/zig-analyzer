const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;
const identicalPathOperands = @import("../../syntax/tokens.zig").identicalPathOperands;

pub const rules = [_]types.Rule{
    .identical_comparison_operands,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.identical_comparison_operands);
    if (level == .off) return;

    for (0..context.tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        switch (context.tree.nodeTag(node)) {
            .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal => {},
            else => continue,
        }
        const lhs, _ = identicalPathOperands(context.tree, node) orelse continue;

        const expr_source = context.tree.getNodeSource(node);
        if (containsComment(expr_source)) continue;

        const operand_text = context.tree.getNodeSource(lhs);
        const op_text = context.tree.tokenSlice(context.tree.nodeMainToken(node));

        const message = if (context.tree.nodeTag(node) == .equal_equal)
            try context.allocator.print("comparison '{s} == {s}' compares identical operands; floating-point NaN is not equal to itself", .{ operand_text, operand_text })
        else if (context.tree.nodeTag(node) == .bang_equal)
            try context.allocator.print("comparison '{s} != {s}' compares identical operands; if checking for NaN, use std.math.isNan", .{ operand_text, operand_text })
        else
            try context.allocator.print("comparison '{s} {s} {s}' compares identical operands; check whether a different value was intended", .{ operand_text, op_text, operand_text });

        try context.emit(.{
            .rule = .identical_comparison_operands,
            .level = level,
            .span = .{
                .start = context.tokens[context.tree.firstToken(node)].loc.start,
                .end = context.tokens[context.tree.lastToken(node)].loc.end,
            },
            .message = message,
        });
    }
}

test "identical comparison operands reports comparisons of identical paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(x: u32, s: Struct) bool {\n" ++
        "    if (x == x) return true;\n" ++
        "    if (s.len != s.len) return false;\n" ++
        "    if (x < x) return false;\n" ++
        "    if (s.ptr.* == s.ptr.*) return true;\n" ++
        "    return true;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 4), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "x == x") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "s.len != s.len") != null);
    try std.testing.expect(std.mem.find(u8, findings[2].message, "x < x") != null);
    try std.testing.expect(std.mem.find(u8, findings[3].message, "s.ptr.* == s.ptr.*") != null);
}

test "operator precedence decides the operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(chunk: u32, mask: u32) bool {\n" ++
        "    if (chunk & mask == mask) return true;\n" ++
        "    if (chunk + mask < mask) return true;\n" ++
        "    return chunk | mask != mask;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
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

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.identical_comparison_operands}, .warning));
}
