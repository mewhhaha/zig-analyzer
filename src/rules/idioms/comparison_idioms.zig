//! Comparisons that restate a value: booleans compared with literals and errors compared by value.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Configuration = types.Configuration;
const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .error_value_comparison,
    .redundant_bool_comparison,
};

pub fn run(context: RuleRun) !void {
    try findBooleanComparisons(context);
    try findErrorValueComparisons(context);
}

fn findBooleanComparisons(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.redundant_bool_comparison);
    if (level == .off) return;
    for (tokens, 0..) |operator, index| {
        if (index == 0 or index + 1 >= tokens.len) continue;
        if (operator.tag != .equal_equal and operator.tag != .bang_equal) continue;
        const left = tokens[index - 1];
        const right = tokens[index + 1];
        if (left.tag != .identifier or right.tag != .identifier) continue;
        const left_text = tokenText(source, left);
        const right_text = tokenText(source, right);
        const operand_index, const literal = if (isBooleanLiteral(right_text))
            .{ index - 1, right }
        else if (isBooleanLiteral(left_text))
            .{ index + 1, left }
        else
            continue;
        const operand = tokens[operand_index];
        const literal_text = tokenText(source, literal);
        const operand_name = tokenText(source, operand);
        if (!context.scopes.bindingHasType(source, tokens, operand_index, "bool")) continue;
        const equal_to_true = (operator.tag == .equal_equal) == std.mem.eql(u8, literal_text, "true");
        const replacement = if (equal_to_true)
            try context.allocator.dupe(u8, operand_name)
        else
            try context.allocator.print("!{s}", .{operand_name});
        const fixes = try Fix.single(context.allocator, .{
            .title = "Simplify boolean comparison",
            .span = .{ .start = left.loc.start, .end = right.loc.end },
            .replacement = replacement,
            .preferred = true,
            .fix_all = true,
        });
        try context.emit(.{
            .rule = .redundant_bool_comparison,
            .level = level,
            .span = operator.loc,
            .message = try context.allocator.print("comparison of bool '{s}' with '{s}' is redundant", .{ operand_name, literal_text }),
            .fixes = fixes,
        });
    }
}

fn isBooleanLiteral(name: []const u8) bool {
    return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false");
}

fn findErrorValueComparisons(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.error_value_comparison);
    if (level == .off) return;
    for (0..context.tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const tag = context.tree.nodeTag(node);
        if (tag != .equal_equal and tag != .bang_equal) continue;
        const left, const right = context.tree.nodeData(node).node_and_node;
        const error_value, const compared_value = if (context.tree.nodeTag(left) == .error_value)
            .{ left, right }
        else if (context.tree.nodeTag(right) == .error_value)
            .{ right, left }
        else
            continue;
        if (context.tree.nodeTag(compared_value) != .identifier) continue;
        const operator_index: usize = context.tree.nodeMainToken(node);
        if (operator_index >= tokens.len) continue;
        const binding_index: usize = context.tree.nodeMainToken(compared_value);
        if (binding_index >= tokens.len) continue;
        const binding_name = tokenText(source, tokens[binding_index]);
        const error_source = context.tree.getNodeSource(error_value);
        const error_name_start = std.mem.findScalarLast(u8, error_source, '.') orelse continue;
        const error_name = error_source[error_name_start + 1 ..];
        const error_is_declared: ?bool = declared: {
            var cursor = binding_index;
            while (cursor > 0) {
                cursor -= 1;
                if (tokens[cursor].tag != .identifier or !tokenIs(source, tokens[cursor], binding_name) or
                    cursor + 3 >= binding_index or tokens[cursor + 1].tag != .colon) continue;
                if (cursor == 0) continue;
                switch (tokens[cursor - 1].tag) {
                    .keyword_const, .keyword_var, .l_paren, .comma => {},
                    else => continue,
                }
                if (tokens[cursor + 2].tag != .keyword_error or tokens[cursor + 3].tag != .l_brace) break :declared null;
                const closing = matchingToken(tokens, cursor + 3, .l_brace, .r_brace) orelse break :declared null;
                if (closing >= binding_index or closing + 1 >= tokens.len) break :declared null;
                switch (tokens[closing + 1].tag) {
                    .equal, .comma, .r_paren => {},
                    else => break :declared null,
                }
                for (tokens[cursor + 4 .. closing]) |member| {
                    if (member.tag == .identifier and tokenIs(source, member, error_name)) break :declared true;
                }
                break :declared false;
            }
            break :declared null;
        };
        if (error_is_declared != false) continue;
        const impossible_result = if (tag == .equal_equal) "true" else "false";
        try context.emit(.{
            .rule = .error_value_comparison,
            .level = level,
            .span = tokens[operator_index].loc,
            .message = try context.allocator.print(
                "comparison with '{s}' can never be {s}; explicit error set of '{s}' does not contain it",
                .{ error_source, impossible_result, binding_name },
            ),
        });
    }
}

test "comparison with a member of an explicit error set is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn classify(err: error{Missing}) bool {\n" ++
        "    return err == error.Missing;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .error_value_comparison);
}

test "error values compared by equality report the comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn classify(err: error{Missing}) bool {\n" ++
        "    return err == error.Other;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.error_value_comparison}, .warning));
    try support.expectRules(found, &.{.error_value_comparison});
}
