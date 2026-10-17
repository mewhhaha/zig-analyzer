//! Arithmetic whose literal operand decides the result on its own. `x * 0`,
//! `x & 0` and an integer `x % 1` are always zero whatever `x` holds, and an
//! assignment such as `x += 0` or `x *= 1` changes nothing; either way the
//! other operand was meant to matter, which usually points at a typo or a
//! stale constant. A binary `x + 0` or `x << 0` is left alone: written out
//! beside `x + 1` and `x << 8`, it keeps a table or an unrolled sequence
//! regular.

const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");

pub const rules = [_]types.Rule{.identity_operation};

pub fn run(context: RuleRun) !void {
    const level = context.level(.identity_operation);
    if (level == .off) return;
    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const shape = operation(context, node) orelse continue;
        const operator = tree.nodeMainToken(node);
        if (tokens_util.containsComment(tree.getNodeSource(node))) continue;
        if (partOfSequence(context, operator, shape.literal)) continue;
        const subject = tree.getNodeSource(shape.subject);
        const text = tree.getNodeSource(node);
        try context.emit(.{
            .rule = .identity_operation,
            .level = level,
            .span = .{ .start = context.tokens[tree.firstToken(node)].loc.start, .end = context.tokens[tree.lastToken(node)].loc.end },
            .message = switch (shape.effect) {
                .constant => try context.allocator.print("'{s}' is always {s} whatever '{s}' holds", .{ text, shape.result, subject }),
                .none => try context.allocator.print("'{s}' leaves '{s}' unchanged", .{ text, subject }),
            },
        });
    }
}

const Shape = struct {
    /// The operand the literal makes irrelevant or leaves unchanged.
    subject: Ast.Node.Index,
    /// The literal operand.
    literal: Ast.Node.Index,
    effect: enum { constant, none },
    /// The constant result for `.constant`.
    result: []const u8 = "0",
};

/// The shape of `node` when it is an operation one literal operand decides.
fn operation(context: RuleRun, node: Ast.Node.Index) ?Shape {
    const tree = context.tree;
    const tag = tree.nodeTag(node);
    switch (tag) {
        .mul, .mul_wrap, .mul_sat, .bit_and => {
            const left, const right = tree.nodeData(node).node_and_node;
            const subject, const literal = if (isLiteral(tree, right, "0"))
                .{ left, right }
            else if (isLiteral(tree, left, "0"))
                .{ right, left }
            else
                return null;
            // `0 * 16` in a table of literals is a constant on purpose.
            if (tree.nodeTag(subject) == .number_literal) return null;
            if (tag != .bit_and and context.numberKind(subject) == .float) return null;
            return .{ .subject = subject, .literal = literal, .effect = .constant };
        },
        .mod => {
            const left, const right = tree.nodeData(node).node_and_node;
            if (!isLiteral(tree, right, "1") or !isInteger(context, left)) return null;
            return .{ .subject = left, .literal = right, .effect = .constant };
        },
        .assign_mul, .assign_mul_wrap, .assign_mul_sat, .assign_bit_and, .assign_mod => {
            const target, const value = tree.nodeData(node).node_and_node;
            if (tag == .assign_mod) {
                if (!isLiteral(tree, value, "1") or !isInteger(context, target)) return null;
                return .{ .subject = target, .literal = value, .effect = .constant };
            }
            if (isLiteral(tree, value, "1") and tag != .assign_bit_and) return .{ .subject = target, .literal = value, .effect = .none };
            if (!isLiteral(tree, value, "0")) return null;
            if (tag != .assign_bit_and and context.numberKind(target) == .float) return null;
            return .{ .subject = target, .literal = value, .effect = .constant };
        },
        .assign_add,
        .assign_add_wrap,
        .assign_add_sat,
        .assign_sub,
        .assign_sub_wrap,
        .assign_sub_sat,
        .assign_bit_or,
        .assign_bit_xor,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        => {
            const target, const value = tree.nodeData(node).node_and_node;
            if (!isLiteral(tree, value, "0")) return null;
            return .{ .subject = target, .literal = value, .effect = .none };
        },
        .assign_div => {
            const target, const value = tree.nodeData(node).node_and_node;
            if (!isLiteral(tree, value, "1")) return null;
            return .{ .subject = target, .literal = value, .effect = .none };
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            if (!std.mem.eql(u8, name, "@mod") and !std.mem.eql(u8, name, "@rem")) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const parameters = tree.builtinCallParams(&buffer, node) orelse return null;
            if (parameters.len != 2 or !isLiteral(tree, parameters[1], "1") or !isInteger(context, parameters[0])) return null;
            return .{ .subject = parameters[0], .literal = parameters[1], .effect = .constant };
        },
        else => return null,
    }
}

fn isLiteral(tree: *const Ast, node: Ast.Node.Index, text: []const u8) bool {
    return tree.nodeTag(node) == .number_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), text);
}

/// Whether `node` is proven an integer; `x % 1` keeps the fraction of a float.
fn isInteger(context: RuleRun, node: Ast.Node.Index) bool {
    const kind = context.numberKind(node) orelse return false;
    return kind != .float;
}

/// Whether the same operator with another literal operand sits on a nearby
/// line, as in rows of a table or unrolled steps (`x * 0`, `x * 1`, ...).
fn partOfSequence(context: RuleRun, operator: usize, literal: Ast.Node.Index) bool {
    const tokens = context.tokens;
    const own = context.tree.tokenSlice(context.tree.nodeMainToken(literal));
    const line_window = 2;
    var start = operator;
    var lines: usize = 0;
    while (start > 0 and lines <= line_window) : (start -= 1) {
        if (std.mem.findScalar(u8, context.source[tokens[start - 1].loc.end..tokens[start].loc.start], '\n') != null) lines += 1;
    }
    var end = operator;
    lines = 0;
    while (tokens[end].tag != .eof and lines <= line_window) : (end += 1) {
        if (std.mem.findScalar(u8, context.source[tokens[end].loc.end..tokens[end + 1].loc.start], '\n') != null) lines += 1;
    }
    const operator_tag = tokens[operator].tag;
    for (start..end) |index| {
        if (index == operator or tokens[index].tag != operator_tag) continue;
        for ([_]usize{ index -| 1, index + 1 }) |neighbour| {
            if (tokens[neighbour].tag == .number_literal and !context.tokenIs(neighbour, own)) return true;
        }
    }
    return false;
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.identity_operation}, .warning));
}

test "operations a literal operand decides report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn scale(count: u32, flags: u8, items: []const u8, ratio: f32) u32 {
        \\    var total = count * 0;
        \\    total += flags & 0;
        \\    total += items.len % 1;
        \\    total += @rem(count, 1);
        \\    total += 0;
        \\    total *= 1;
        \\    var mask = flags;
        \\    mask |= 0;
        \\    mask &= 0;
        \\    _ = ratio;
        \\    return total + mask;
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{
        "count * 0",  "flags & 0",  "items.len % 1", "@rem(count, 1)",
        "total += 0", "total *= 1", "mask |= 0",     "mask &= 0",
    });
    try std.testing.expectEqualStrings("'count * 0' is always 0 whatever 'count' holds", found[0].message);
    try std.testing.expectEqualStrings("'total += 0' leaves 'total' unchanged", found[4].message);
}

test "tables, floats, binary identities and unproven integers stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn table(base: u32, ratio: f32, value: anytype) [4]u32 {
        \\    const offsets = [_]u32{ base * 0, base * 1, base * 2, 0 * 16 };
        \\    _ = ratio * 0;
        \\    _ = value % 1;
        \\    _ = @mod(ratio, 1);
        \\    _ = base + 0;
        \\    _ = base << 0;
        \\    _ = @as(u32, 0) * 4;
        \\    return offsets;
        \\}
        \\fn rows(out: []u32, base: u32) void {
        \\    out[0] = base & 0;
        \\    out[1] = base & 1;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}
