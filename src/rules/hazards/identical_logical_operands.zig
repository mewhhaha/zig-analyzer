const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;
const identicalPaths = @import("../../syntax/tokens.zig").identicalPaths;

pub const rules = [_]types.Rule{
    .identical_logical_operands,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.identical_logical_operands);
    if (level == .off) return;

    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const tag = tree.nodeTag(node);
        const op_text = switch (tag) {
            .bool_and => "and",
            .bool_or => "or",
            else => continue,
        };
        const left, const right = tree.nodeData(node).node_and_node;
        // In a chain `a and b and b` the left operand is `a and b`; the
        // operand next to this operator is its right-hand side.
        const adjacent = if (tree.nodeTag(left) == tag) tree.nodeData(left).node_and_node[1] else left;
        if (!identicalPaths(tree, adjacent, right)) continue;

        const span: std.zig.Token.Loc = .{
            .start = context.tokens[tree.firstToken(adjacent)].loc.start,
            .end = context.tokens[tree.lastToken(right)].loc.end,
        };
        if (containsComment(context.source[span.start..span.end])) continue;

        const operand_text = tree.getNodeSource(adjacent);
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = try context.allocator.print("Remove redundant '{s} {s}'", .{ op_text, operand_text }),
            .kind = .quickfix,
            .edits = try context.allocator.dupe(types.Edit, &.{.{
                .span = .{ .start = context.tokens[tree.lastToken(adjacent)].loc.end, .end = span.end },
                .replacement = "",
            }}),
            .preferred = true,
            .fix_all = true,
        };

        try context.emit(.{
            .rule = .identical_logical_operands,
            .level = level,
            .span = span,
            .message = try context.allocator.print(
                "logical '{s}' with identical operands '{s} {s} {s}' is redundant and likely a typo",
                .{ op_text, operand_text, op_text, operand_text },
            ),
            .fixes = fixes,
        });
    }
}

test "identical logical operands reports repeated conditions in and and or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(valid: bool, s: Struct) bool {\n" ++
        "    if (valid and valid) return true;\n" ++
        "    if (s.ready or s.ready) return true;\n" ++
        "    if (s.ptr.* and s.ptr.*) return true;\n" ++
        "    return false;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "valid and valid") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "s.ready or s.ready") != null);
    try std.testing.expect(std.mem.find(u8, findings[2].message, "s.ptr.* and s.ptr.*") != null);
    try std.testing.expectEqualStrings("", findings[0].fixes[0].edits[0].replacement);
}

test "distinct logical operands stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(a: bool, b: bool, s: Struct, other: Struct, start: usize, index: usize, end: usize) bool {\n" ++
        "    if (a and b) return true;\n" ++
        "    if (s.ready or other.ready) return true;\n" ++
        "    if (s.ptr.* and other.ptr.*) return true;\n" ++
        "    if (start < index and index < end) return true;\n" ++
        "    if (start == index or index + 1 == end) return true;\n" ++
        "    if (a and b or b) return true;\n" ++
        "    if (a or b and a) return true;\n" ++
        "    return false;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "operator precedence and chains decide the adjacent operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(a: bool, b: bool) bool {\n" ++
        "    if (a or b and b) return true;\n" ++
        "    if (a and b and b) return true;\n" ++
        "    return a or a or a;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try support.expectSpans(source, findings, &.{ "b and b", "b and b", "a or a", "a or a" });
    // The two fixes of `a or a or a` touch, without overlapping, and leave `a`.
    try std.testing.expect(findings[2].fixes[0].edits[0].span.end <= findings[3].fixes[0].edits[0].span.start);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.identical_logical_operands}, .warning));
}
