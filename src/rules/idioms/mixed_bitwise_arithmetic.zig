//! Bitwise and arithmetic operators mixed in one expression without parentheses.
const std = @import("std");

const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .mixed_bitwise_arithmetic,
};

pub fn run(context: RuleRun) !void {
    try findMixedBitwiseArithmetic(context);
}

fn findMixedBitwiseArithmetic(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.mixed_bitwise_arithmetic);
    if (level == .off) return;
    for (0..context.tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const parent_tag = context.tree.nodeTag(node);
        if (!isBitwiseOperator(parent_tag) and !isArithmeticOperator(parent_tag)) continue;
        const left, const right = context.tree.nodeData(node).node_and_node;
        const operator_index: usize = context.tree.nodeMainToken(node);
        if (operator_index >= tokens.len) continue;
        // Both operands of one operator can mix families; that is one finding
        // whose fix parenthesizes each of them.
        var edits: [2]types.Edit = undefined;
        var edit_count: usize = 0;
        var mixed_child: ?std.zig.Ast.Node.Index = null;
        for ([_]std.zig.Ast.Node.Index{ left, right }) |child| {
            const child_tag = context.tree.nodeTag(child);
            const mixes_families = isBitwiseOperator(parent_tag) and isArithmeticOperator(child_tag) or
                isArithmeticOperator(parent_tag) and isBitwiseOperator(child_tag);
            if (!mixes_families) continue;
            const first_token: usize = context.tree.firstToken(child);
            const last_token: usize = context.tree.lastToken(child);
            if (first_token >= tokens.len or last_token >= tokens.len) continue;
            const child_span = std.zig.Token.Loc{
                .start = tokens[first_token].loc.start,
                .end = tokens[last_token].loc.end,
            };
            edits[edit_count] = .{
                .span = child_span,
                .replacement = try context.allocator.print("({s})", .{source[child_span.start..child_span.end]}),
            };
            edit_count += 1;
            if (mixed_child == null) mixed_child = child;
        }
        const child = mixed_child orelse continue;
        const fixes = try context.allocator.alloc(Fix, 1);
        fixes[0] = .{
            .title = "Parenthesize mixed operator expression",
            .kind = .quickfix,
            .edits = try context.allocator.dupe(types.Edit, edits[0..edit_count]),
            .preferred = true,
        };
        try context.emit(.{
            .rule = .mixed_bitwise_arithmetic,
            .level = level,
            .span = tokens[operator_index].loc,
            .message = try context.allocator.print(
                "bitwise operator '{s}' and arithmetic operator '{s}' are mixed without parentheses",
                .{
                    if (isBitwiseOperator(parent_tag)) context.tree.tokenSlice(context.tree.nodeMainToken(node)) else context.tree.tokenSlice(context.tree.nodeMainToken(child)),
                    if (isArithmeticOperator(parent_tag)) context.tree.tokenSlice(context.tree.nodeMainToken(node)) else context.tree.tokenSlice(context.tree.nodeMainToken(child)),
                },
            ),
            .fixes = fixes,
        });
    }
}

fn isBitwiseOperator(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .shl, .shl_sat, .shr, .bit_xor, .bit_or, .bit_and => true,
        else => false,
    };
}

fn isArithmeticOperator(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .add,
        .add_sat,
        .add_wrap,
        .sub,
        .sub_sat,
        .sub_wrap,
        .mul,
        .mul_sat,
        .mul_wrap,
        .div,
        .mod,
        => true,
        else => false,
    };
}

test "mixed shift and addition offers parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn mix(value: u8) u8 { return 1 + value << 3; }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.mixed_bitwise_arithmetic}, .warning));
    try support.expectRules(found, &.{.mixed_bitwise_arithmetic});
    try std.testing.expectEqual(@as(usize, 1), found[0].fixes.len);
    try std.testing.expect(found[0].fixes[0].edits[0].replacement[0] == '(');
}

test "an operator with two mixed operands reports once and parenthesizes both" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn slot(root: u32, at: u32) u32 { return root *% 3 ^ at *% 5; }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.mixed_bitwise_arithmetic}, .warning));
    try support.expectSpans(source, found, &.{"^"});
    try std.testing.expectEqual(@as(usize, 2), found[0].fixes[0].edits.len);
    try std.testing.expectEqualStrings("(root *% 3)", found[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("(at *% 5)", found[0].fixes[0].edits[1].replacement);
}
