const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;
const identicalPathOperands = @import("../../syntax/tokens.zig").identicalPathOperands;

pub const rules = [_]types.Rule{
    .identical_bitwise_operands,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.identical_bitwise_operands);
    if (level == .off) return;

    for (0..context.tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const op_text = switch (context.tree.nodeTag(node)) {
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            else => continue,
        };
        const lhs, const rhs = identicalPathOperands(context.tree, node) orelse continue;

        const expr_source = context.tree.getNodeSource(node);
        if (containsComment(expr_source)) continue;

        const first_token = context.tree.firstToken(node);
        const last_token = context.tree.lastToken(node);
        const span: std.zig.Token.Loc = .{ .start = context.tokens[first_token].loc.start, .end = context.tokens[last_token].loc.end };
        const operand_text = context.tree.getNodeSource(lhs);
        const is_xor = context.tree.nodeTag(node) == .bit_xor;

        // `x ^ x` is `0`, which `0` only matches when the type does not matter.
        const edits = try context.allocator.alloc(types.Edit, 1);
        const title: []const u8 = if (is_xor) blk: {
            edits[0] = .{ .span = span, .replacement = "0" };
            break :blk "Replace with '0'";
        } else blk: {
            edits[0] = .{
                .span = .{ .start = context.tokens[context.tree.lastToken(lhs)].loc.end, .end = span.end },
                .replacement = "",
            };
            break :blk try context.allocator.print("Remove redundant '{s} {s}'", .{ op_text, operand_text });
        };
        _ = rhs;

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = title,
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        const message = if (is_xor)
            try context.allocator.print(
                "bitwise '^' with identical operands '{s} ^ {s}' always evaluates to 0 and is likely a typo",
                .{ operand_text, operand_text },
            )
        else
            try context.allocator.print(
                "bitwise '{s}' with identical operands '{s} {s} {s}' is redundant and likely a typo",
                .{ op_text, operand_text, op_text, operand_text },
            );

        try context.emit(.{
            .rule = .identical_bitwise_operands,
            .level = level,
            .span = span,
            .message = message,
            .fixes = fixes,
        });
    }
}

test "identical bitwise operands reports repeated operands in &, |, ^" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(flags: u32, s: Struct) u32 {\n" ++
        "    const a = flags & flags;\n" ++
        "    const b = s.ready | s.ready;\n" ++
        "    const c = s.ptr.* ^ s.ptr.*;\n" ++
        "    return a + b + c;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "flags & flags") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "s.ready | s.ready") != null);
    try std.testing.expect(std.mem.find(u8, findings[2].message, "s.ptr.* ^ s.ptr.*") != null);
    try std.testing.expectEqualStrings("", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("0", findings[2].fixes[0].edits[0].replacement);
}

test "distinct bitwise operands stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(a: u32, b: u32, s: Struct, other: Struct) u32 {\n" ++
        "    const x = a & b;\n" ++
        "    const y = s.ready | other.ready;\n" ++
        "    const z = s.ptr.* ^ other.ptr.*;\n" ++
        "    return x + y + z;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "operator precedence decides the operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(value: u32, mask: u32) u32 {\n" ++
        "    const a = value ^ value >> 15;\n" ++
        "    const b = value & value + 1;\n" ++
        "    const c = mask | mask << 2;\n" ++
        "    return a + b + c;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "capture pipes and unary address-of do not trigger identical bitwise operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(opt: ?u32, items: []const u32) void {\n" ++
        "    if (opt) |val| val.call();\n" ++
        "    for (items) |item| item.process();\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.identical_bitwise_operands}, .warning));
}
