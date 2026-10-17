const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;
const lineIndentation = @import("../../syntax/tokens.zig").lineIndentation;

pub const rules = [_]types.Rule{
    .unbraced_multiline_if,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.unbraced_multiline_if);
    if (level == .off) return;

    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 3 >= context.tokens.len) continue;
        if (if_index > 0) switch (context.tokens[if_index - 1].tag) {
            // 'else' admits the trailing if of an else-if chain; expression-position
            // chains are excluded below because their body contains 'else' or ends
            // without a top-level semicolon.
            .semicolon, .l_brace, .r_brace, .keyword_else => {},
            else => continue,
        };
        if (context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_close = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        var guard_end = condition_close;
        var body_start = condition_close + 1;
        if (body_start < context.tokens.len and context.tokens[body_start].tag == .pipe) {
            var capture_close = body_start + 1;
            while (capture_close < context.tokens.len and context.tokens[capture_close].tag != .pipe) capture_close += 1;
            if (capture_close >= context.tokens.len) continue;
            guard_end = capture_close;
            body_start = capture_close + 1;
        }
        if (body_start + 1 >= context.tokens.len) continue;
        switch (context.tokens[body_start].tag) {
            .l_brace, .keyword_if, .keyword_for, .keyword_while, .keyword_inline, .keyword_switch, .keyword_defer, .keyword_errdefer => continue,
            // A labeled block or loop brings its own braces.
            .identifier => if (context.tokens[body_start + 1].tag == .colon) continue,
            else => {},
        }
        const guard_end_offset = context.tokens[guard_end].loc.end;
        const body_start_offset = context.tokens[body_start].loc.start;
        if (std.mem.findScalar(u8, context.source[guard_end_offset..body_start_offset], '\n') == null) continue;
        // A guard clause cannot be misread: nothing after it is guarded,
        // because the guarded statement never completes.
        if (context.statementDiverges(body_start)) continue;
        const statement_end = context.statementEnd(body_start) orelse continue;
        if (containsElse(context, body_start, statement_end)) continue;

        const semicolon_end = context.tokens[statement_end].loc.end;
        const statement_line_end = std.mem.findScalarPos(u8, context.source, semicolon_end, '\n') orelse context.source.len;
        const fixes: []const types.Fix = if (containsComment(context.source[guard_end_offset..statement_line_end])) &.{} else blk: {
            const indent = lineIndentation(context.source, token.loc.start);
            // zig fmt opens the block on a line of its own when the condition
            // continues onto an indented line.
            const continued = lineIndentation(context.source, guard_end_offset).len > indent.len;
            const edits = try context.allocator.alloc(types.Edit, 2);
            edits[0] = .{
                .span = .{ .start = guard_end_offset, .end = guard_end_offset },
                .replacement = if (continued) try context.allocator.print("\n{s}{{", .{indent}) else " {",
            };
            edits[1] = .{
                .span = .{ .start = semicolon_end, .end = semicolon_end },
                .replacement = try context.allocator.print("\n{s}}}", .{indent}),
            };
            const fixes = try context.allocator.alloc(types.Fix, 1);
            fixes[0] = .{
                .title = "Wrap the if body in braces",
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
                .fix_all = true,
            };
            break :blk fixes;
        };
        try context.emit(.{
            .rule = .unbraced_multiline_if,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "unbraced 'if' body starting with '{s}' begins on a different line than the condition; only that single statement is guarded",
                .{context.tokenText(body_start)},
            ),
            .fixes = fixes,
        });
    }
}

fn containsElse(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| if (token.tag == .keyword_else) return true;
    return false;
}

test "if body on its own unbraced line warns and offers a brace fix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn guard(flag: bool) void {\n" ++
        "    if (flag)\n" ++
        "        fail();\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "'fail'") != null);
    try std.testing.expectEqual(@as(usize, 2), findings[0].fixes[0].edits.len);
    try std.testing.expectEqualStrings(" {", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("\n    }", findings[0].fixes[0].edits[1].replacement);
    try std.testing.expect(findings[0].fixes[0].fix_all);
}

test "a condition continued onto an indented line opens the block on its own line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn guard(flag: bool, other: bool) void {\n" ++
        "    if (flag and\n" ++
        "        other)\n" ++
        "        fail();\n" ++
        "    if (check(\n" ++
        "        flag,\n" ++
        "    ))\n" ++
        "        fail();\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("\n    {", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings(" {", findings[1].fixes[0].edits[0].replacement);
}

test "a comment inside the guarded statement keeps the diagnostic but declines the fix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn note(flag: bool) void {\n" ++
        "    if (flag) // reason\n" ++
        "        fail();\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(@as(usize, 0), findings[0].fixes.len);
}

test "the trailing if of an else-if chain warns when its body drops to another line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn pick(flag: bool, other: bool) void {\n" ++
        "    if (flag) {\n" ++
        "        one();\n" ++
        "    } else if (other)\n" ++
        "        two();\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "'two'") != null);
    try std.testing.expectEqualStrings(" {", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("\n    }", findings[0].fixes[0].edits[1].replacement);
}

test "braced same-line expression and else-chained ifs stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn braced(flag: bool) void {\n    if (flag) {\n        fail();\n    }\n}\n" ++
        "fn inline_body(flag: bool) void { if (flag) fail(); }\n" ++
        "fn choose(flag: bool) u8 {\n    const value = if (flag)\n        1\n    else\n        2;\n    return value;\n}\n" ++
        "fn chain(flag: bool) void {\n    if (flag)\n        one()\n    else\n        two();\n}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "labeled blocks and guard clauses stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn fatal() noreturn {\n    @panic(\"fatal\");\n}\n" ++
        "fn guards(flag: bool, items: []const u8) !u8 {\n" ++
        "    if (flag and\n        items.len > 1)\n    prune: {\n        if (flag) break :prune;\n        one();\n    }\n" ++
        "    for (items) |item| {\n        if (item == 0)\n            continue;\n        if (item == 1)\n            break;\n    }\n" ++
        "    if (flag)\n        return error.Bad;\n" ++
        "    if (!flag)\n        unreachable;\n" ++
        "    if (items.len == 0)\n        @panic(\"empty\");\n" ++
        "    if (items.len == 2)\n        std.process.exit(1);\n" ++
        "    if (items.len == 3)\n        fatal();\n" ++
        "    if (items.len == 4)\n        return items[0] +\n            items[1];\n" ++
        "    return 0;\n}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.unbraced_multiline_if}, .information));
}
