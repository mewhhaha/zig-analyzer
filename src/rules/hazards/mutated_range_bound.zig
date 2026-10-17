//! Assignments to a range bound inside the `for` loop over that range. The
//! range `0..count` is evaluated once, before the first iteration, so
//! changing `count` in the body does not change how often the loop runs; code
//! that shrinks the bound to skip removed elements still visits them.

const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");

pub const rules = [_]types.Rule{.mutated_range_bound};

pub fn run(context: RuleRun) !void {
    const level = context.level(.mutated_range_bound);
    if (level == .off) return;
    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const loop = tree.fullFor(node) orelse continue;
        if (loop.inline_token != null) continue;
        for (loop.ast.inputs) |input| {
            if (tree.nodeTag(input) != .for_range) continue;
            const start, const end = tree.nodeData(input).node_and_opt_node;
            for ([_]?Ast.Node.Index{ start, end.unwrap() }) |maybe_bound| {
                const bound = maybe_bound orelse continue;
                if (tree.nodeTag(bound) != .identifier) continue;
                const name = tree.nodeMainToken(bound);
                const assignment = boundAssignment(context, name, tree.firstToken(loop.ast.then_expr), tree.lastToken(loop.ast.then_expr)) orelse continue;
                const related = try context.allocator.alloc(types.RelatedSpan, 1);
                related[0] = .{ .span = context.tokens[name].loc, .message = "the range is evaluated once, here" };
                try context.emit(.{
                    .rule = .mutated_range_bound,
                    .level = level,
                    .span = context.tokens[assignment].loc,
                    .message = try context.allocator.print(
                        "assigning range bound '{s}' inside the loop does not change how many times it runs",
                        .{context.tokenText(name)},
                    ),
                    .related = related,
                });
            }
        }
    }
}

/// The first in-place update (`count -= 1`, `count += 1`) of the local `var`
/// named at `name` in `[first, last]` that the loop keeps running after: one
/// not followed by a `break` or `return` in its block. A plain assignment,
/// such as recording a position (`start = index`), is the variable's own use.
fn boundAssignment(context: RuleRun, name: usize, first: usize, last: usize) ?usize {
    const tokens = context.tokens;
    const binding = context.scopes.findBinding(name) orelse return null;
    if (binding.token_index == 0 or tokens[binding.token_index - 1].tag != .keyword_var) return null;
    const text = context.tokenText(name);
    for (first..last + 1) |index| {
        if (tokens[index].tag != .identifier or tokens[index - 1].tag == .period or !context.tokenIs(index, text) or
            tokens[index + 1].tag == .equal or !tokens_util.isAssignment(tokens[index + 1].tag)) continue;
        const resolved = context.scopes.findBinding(index) orelse continue;
        if (resolved.token_index != binding.token_index) continue;
        if (statementStartsAt(tokens, index) and !exitsAfter(context, index, last)) return index;
    }
    return null;
}

fn statementStartsAt(tokens: []const std.zig.Token, index: usize) bool {
    return switch (tokens[index - 1].tag) {
        .semicolon, .l_brace, .r_brace, .r_paren, .pipe, .keyword_else, .equal_angle_bracket_right => true,
        else => false,
    };
}

/// Whether the statement after the assignment at `index`, inside the loop
/// body ending at `last`, leaves the loop.
fn exitsAfter(context: RuleRun, index: usize, last: usize) bool {
    const end = context.statementEnd(index) orelse return false;
    if (end + 1 > last) return false;
    return switch (context.tokens[end + 1].tag) {
        .keyword_break, .keyword_return => true,
        else => false,
    };
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.mutated_range_bound}, .warning));
}

test "assigning a range bound inside its loop reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn compact(items: []u32) usize {
        \\    var count = items.len;
        \\    for (0..count) |index| {
        \\        if (items[index] == 0) {
        \\            items[index] = items[count - 1];
        \\            count -= 1;
        \\        }
        \\    }
        \\    var start: usize = 1;
        \\    for (items, start..) |_, _| start += 2;
        \\    return count;
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "count", "start" });
    try std.testing.expectEqualStrings("count", source[found[0].related[0].span.start..found[0].related[0].span.end]);
}

test "constants, other places and assignments before leaving stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn find(items: []u32, limit: usize) usize {
        \\    var count = items.len;
        \\    for (0..count) |index| {
        \\        if (items[index] == 0) {
        \\            count = index;
        \\            break;
        \\        }
        \\        items[count - 1] = 0;
        \\    }
        \\    var stats: struct { count: usize } = .{ .count = 0 };
        \\    for (0..limit) |_| stats.count += 1;
        \\    var total: usize = 0;
        \\    for (0..count) |_| total += 1;
        \\    var line_start: usize = 1;
        \\    for (line_start..items.len) |index| {
        \\        if (items[index] == 1) line_start = index;
        \\    }
        \\    return count + stats.count + total + line_start;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}
