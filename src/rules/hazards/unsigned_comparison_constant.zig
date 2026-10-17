//! Comparisons of an unsigned value against zero that cannot fail or cannot
//! succeed: `count >= 0` always holds and `items.len < 0` never does. The
//! check that was meant usually needed a signed value, a `> 0`, or a
//! different bound. Descending `while (index >= 0) : (index -= 1)` loops are
//! `unsigned-reverse-loop`'s to report.

const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");

pub const rules = [_]types.Rule{.unsigned_comparison_constant};

pub fn run(context: RuleRun) !void {
    const level = context.level(.unsigned_comparison_constant);
    if (level == .off) return;
    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const tag = tree.nodeTag(node);
        switch (tag) {
            .greater_or_equal, .less_than, .less_or_equal, .greater_than => {},
            else => continue,
        }
        const left, const right = tree.nodeData(node).node_and_node;
        // `x >= 0` and `x < 0`, or the mirrored `0 <= x` and `0 > x`.
        const subject, const always: bool = if (isZero(tree, right) and (tag == .greater_or_equal or tag == .less_than))
            .{ left, tag == .greater_or_equal }
        else if (isZero(tree, left) and (tag == .less_or_equal or tag == .greater_than))
            .{ right, tag == .less_or_equal }
        else
            continue;
        if (context.numberKind(subject) != .unsigned) continue;
        if (reverseLoopCondition(context, node) or assertedAlone(context, node)) continue;
        const first = tree.firstToken(node);
        if (first > 0 and context.tokens[first - 1].tag == .keyword_comptime) continue;
        const text = tree.getNodeSource(node);
        if (tokens_util.containsComment(text)) continue;
        try context.emit(.{
            .rule = .unsigned_comparison_constant,
            .level = level,
            .span = .{ .start = context.tokens[first].loc.start, .end = context.tokens[tree.lastToken(node)].loc.end },
            .message = try context.allocator.print(
                "'{s}' is always {s} because '{s}' is unsigned",
                .{ text, if (always) "true" else "false", tree.getNodeSource(subject) },
            ),
        });
    }
}

fn isZero(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .number_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "0");
}

/// Whether the comparison at `node` is the whole condition of a `while` loop
/// with a continue expression, the shape `unsigned-reverse-loop` reports.
fn reverseLoopCondition(context: RuleRun, node: Ast.Node.Index) bool {
    const tokens = context.tokens;
    const first = context.tree.firstToken(node);
    const last = context.tree.lastToken(node);
    if (first < 2 or tokens[first - 1].tag != .l_paren or tokens[first - 2].tag != .keyword_while) return false;
    return tokens[last + 1].tag == .r_paren and tokens[last + 2].tag == .colon;
}

/// Whether the comparison is the whole argument of an `assert` call, where a
/// lower bound written beside the upper one documents the range on purpose.
fn assertedAlone(context: RuleRun, node: Ast.Node.Index) bool {
    const tokens = context.tokens;
    const first = context.tree.firstToken(node);
    const last = context.tree.lastToken(node);
    return first >= 2 and tokens[first - 1].tag == .l_paren and context.tokenIs(first - 2, "assert") and
        tokens[last + 1].tag == .r_paren;
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.unsigned_comparison_constant}, .warning));
}

test "unsigned values compared against zero report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn check(count: u32, items: []const u8, offset: usize) bool {
        \\    if (count >= 0) return true;
        \\    if (items.len < 0) return false;
        \\    for (items, 0..) |_, index| {
        \\        if (0 > index) return false;
        \\    }
        \\    const width: u16 = 4;
        \\    return 0 <= width and offset >= 0;
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "count >= 0", "items.len < 0", "0 > index", "0 <= width", "offset >= 0" });
    try std.testing.expectEqualStrings("'count >= 0' is always true because 'count' is unsigned", found[0].message);
    try std.testing.expectEqualStrings("'items.len < 0' is always false because 'items.len' is unsigned", found[1].message);
}

test "signed, unproven, nonzero and reverse-loop comparisons stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn check(delta: i32, value: anytype, count: u32, ratio: f32, generic: T) bool {
        \\    var index: usize = 4;
        \\    while (index >= 0) : (index -= 1) {}
        \\    if (delta >= 0 or value >= 0 or ratio < 0 or generic >= 0) return true;
        \\    if (count > 0 or count <= 0 or 0 < count) return true;
        \\    std.debug.assert(count >= 0);
        \\    return comptime count >= 0;
        \\}
        \\const T = u8;
        \\const std = @import("std");
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}
