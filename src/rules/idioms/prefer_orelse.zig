const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_module = @import("../../syntax/tokens.zig");

pub const rules = [_]types.Rule{
    .prefer_orelse,
};

/// An `if (optional) |payload| payload else fallback` the rule reports.
const Candidate = struct { if_index: usize, condition_end: usize };

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_orelse);
    if (level == .off) return;

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(context.allocator);
    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 9 >= context.tokens.len or
            context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (!tokens_module.isDottedPath(context.tokens, if_index + 2, condition_end) or
            condition_end + 5 >= context.tokens.len or
            context.tokens[condition_end + 1].tag != .pipe or context.tokens[condition_end + 2].tag != .identifier or
            context.tokens[condition_end + 3].tag != .pipe or context.tokens[condition_end + 4].tag != .identifier or
            context.tokens[condition_end + 5].tag != .keyword_else) continue;
        if (condition_end + 6 < context.tokens.len and context.tokens[condition_end + 6].tag == .pipe) continue;
        const capture = context.tokenText(condition_end + 2);
        if (!context.tokenIs(condition_end + 4, capture)) continue;
        if (operandIsKnownErrorUnion(context, if_index + 2, condition_end)) continue;
        try candidates.append(context.allocator, .{ .if_index = if_index, .condition_end = condition_end });
    }
    if (candidates.items.len == 0) return;

    // One pass over the tree finds each fallback expression, whose extent and
    // precedence the fix depends on.
    const fallbacks = try context.allocator.alloc(?Ast.Node.Index, candidates.items.len);
    defer context.allocator.free(fallbacks);
    @memset(fallbacks, null);
    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeTag(node) != .@"if") continue;
        const position = candidateAt(candidates.items, tree.nodeMainToken(node)) orelse continue;
        fallbacks[position] = tree.ifFull(node).ast.else_expr.unwrap();
    }

    for (candidates.items, fallbacks) |candidate, fallback| {
        try context.emit(.{
            .rule = .prefer_orelse,
            .level = level,
            .span = context.tokens[candidate.if_index].loc,
            .message = try context.allocator.print(
                "optional capture '{s}' is returned unchanged; use orelse for the fallback value",
                .{context.tokenText(candidate.condition_end + 2)},
            ),
            .fixes = if (fallback) |node| try orelseFix(context, candidates.items, candidate, node) else &.{},
        });
    }
}

fn candidateAt(candidates: []const Candidate, if_index: usize) ?usize {
    return std.sort.binarySearch(Candidate, candidates, if_index, struct {
        fn order(target: usize, candidate: Candidate) std.math.Order {
            return std.math.order(target, candidate.if_index);
        }
    }.order);
}

/// `optional orelse fallback` in place of `if (optional) |payload| payload
/// else fallback`. Both unwrap the same way, and an `if` with a payload but
/// no error capture only compiles on an optional. The `if` takes everything
/// after `else` as its fallback while `orelse` binds tighter than comparisons
/// and boolean operators, so such a fallback, or one this rule also turns
/// into an `orelse`, is parenthesized. Declined after an operator binding
/// tighter than `orelse` (`1 + if ...`, `try if ...`), which would take the
/// optional alone as its operand.
fn orelseFix(context: RuleRun, candidates: []const Candidate, candidate: Candidate, fallback: Ast.Node.Index) ![]const types.Fix {
    const tree = context.tree;
    const tokens = context.tokens;
    const if_index = candidate.if_index;
    if (if_index == 0 or !orelseOperandBefore(tokens[if_index - 1].tag)) return &.{};
    const first = tree.firstToken(fallback);
    const last = tree.lastToken(fallback);
    const head = context.source[tokens[if_index].loc.start..tokens[first].loc.start];
    if (tokens_module.containsComment(head) or std.mem.findScalar(u8, head, '\n') != null) return &.{};
    const optional = context.source[tokens[if_index + 2].loc.start..tokens[candidate.condition_end - 1].loc.end];
    const parenthesized = switch (tree.nodeTag(fallback)) {
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .bool_and,
        .bool_or,
        .bit_and,
        .bit_or,
        .bit_xor,
        .@"orelse",
        .@"catch",
        => true,
        .@"if" => candidateAt(candidates, tree.nodeMainToken(fallback)) != null,
        else => false,
    };
    if (!parenthesized) return context.singleFix(.{
        .title = "Use orelse",
        .span = .{ .start = tokens[if_index].loc.start, .end = tokens[first - 1].loc.end },
        .replacement = try context.allocator.print("{s} orelse", .{optional}),
        .preferred = true,
        .fix_all = true,
    });
    if (std.mem.findScalar(u8, context.source[tokens[first].loc.start..tokens[last].loc.end], '\n') != null) return &.{};
    const edits = try context.allocator.alloc(types.Edit, 2);
    errdefer context.allocator.free(edits);
    edits[0] = .{
        .span = .{ .start = tokens[if_index].loc.start, .end = tokens[first].loc.start },
        .replacement = try context.allocator.print("{s} orelse (", .{optional}),
    };
    edits[1] = .{ .span = .{ .start = tokens[last].loc.end, .end = tokens[last].loc.end }, .replacement = ")" };
    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{ .title = "Use orelse", .kind = .quickfix, .edits = edits, .preferred = true, .fix_all = true };
    return fixes;
}

/// Tokens after which `optional orelse fallback` is still a whole operand:
/// openers, separators, `return`, `else`, assignments and the operators
/// binding looser than `orelse`.
fn orelseOperandBefore(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .l_paren,
        .l_bracket,
        .l_brace,
        .comma,
        .semicolon,
        .equal_angle_bracket_right,
        .keyword_return,
        .keyword_else,
        .keyword_and,
        .keyword_or,
        .equal_equal,
        .bang_equal,
        .angle_bracket_left,
        .angle_bracket_right,
        .angle_bracket_left_equal,
        .angle_bracket_right_equal,
        => true,
        else => tokens_module.isAssignment(tag),
    };
}

fn operandIsKnownErrorUnion(context: RuleRun, start: usize, end: usize) bool {
    const name = context.tokenText(end - 1);
    for (context.tokens[0..start], 0..) |tok, idx| {
        if (tok.tag != .identifier or !context.tokenIs(idx, name) or idx + 1 >= start or
            context.tokens[idx + 1].tag != .colon) continue;
        var cursor = idx + 2;
        while (cursor < start and context.tokens[cursor].tag != .semicolon and
            context.tokens[cursor].tag != .equal and context.tokens[cursor].tag != .comma and
            context.tokens[cursor].tag != .r_paren) : (cursor += 1)
        {
            if (context.tokens[cursor].tag == .bang) return true;
        }
    }
    return false;
}

test "unchanged optional captures prefer orelse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const value = if (optional) |payload| payload else fallback;";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(findings[0].fixes[0].fix_all);
    try std.testing.expectEqualStrings("const value = optional orelse fallback;", try support.applyFix(arena.allocator(), source, findings[0].fixes[0]));
}

test "transformed captures and error-union branches stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const transformed = if (optional) |payload| payload + 1 else fallback;\n" ++
        "const handled = if (fallible) |payload| payload else |err| recover(err);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "orelse parenthesizes a fallback that binds looser than it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][2][:0]const u8{
        .{ "const ok = if (self.cache) |hit| hit else a == b;", "const ok = self.cache orelse (a == b);" },
        .{ "const ok = if (cache) |hit| hit else a or b;", "const ok = cache orelse (a or b);" },
        .{ "const n = if (cache) |hit| hit else other orelse 0;", "const n = cache orelse (other orelse 0);" },
        .{ "const n = if (cache) |hit| hit else a + b;", "const n = cache orelse a + b;" },
        .{ "const n = f(if (cache) |hit| hit else return error.Missing);", "const n = f(cache orelse return error.Missing);" },
        .{ "const n = if (cache) |hit| hit else if (ready) 1 else 2;", "const n = cache orelse if (ready) 1 else 2;" },
    }) |case| {
        const findings = try findingsFor(arena.allocator(), case[0]);
        try std.testing.expectEqual(@as(usize, 1), findings.len);
        try std.testing.expectEqualStrings(case[1], try support.applyFix(arena.allocator(), case[0], findings[0].fixes[0]));
    }
}

test "orelse chains from nested optional ifs keep their grouping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const v = if (first) |a| a else if (second) |b| b else 0;";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("const v = first orelse (if (second) |b| b else 0);", try support.applyFix(arena.allocator(), source, findings[0].fixes[0]));
    try std.testing.expectEqualStrings("const v = if (first) |a| a else second orelse 0;", try support.applyFix(arena.allocator(), source, findings[1].fixes[0]));
    const both: types.Fix = .{
        .title = "both",
        .kind = .quickfix,
        .edits = try std.mem.concat(arena.allocator(), types.Edit, &.{ findings[0].fixes[0].edits, findings[1].fixes[0].edits }),
    };
    try std.testing.expectEqualStrings("const v = first orelse (second orelse 0);", try support.applyFix(arena.allocator(), source, both));
}

test "orelse is not offered where its operands would regroup or text would be lost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][:0]const u8{
        "const n = 1 + if (cache) |hit| hit else 0;",
        "const n = try if (cache) |hit| hit else fallback;",
        "const n = other orelse if (cache) |hit| hit else 0;",
        "const n = if (cache) |hit| hit // cached\n    else 0;",
        "const n = if (cache) |hit| hit else\n    0;",
        "const ok = if (cache) |hit| hit else a ==\n    b;",
    }) |source| {
        const findings = try findingsFor(arena.allocator(), source);
        try std.testing.expectEqual(@as(usize, 1), findings.len);
        try std.testing.expectEqual(@as(usize, 0), findings[0].fixes.len);
    }
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.prefer_orelse}, .information));
}
