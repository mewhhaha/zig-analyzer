const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

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
        if (body_start >= context.tokens.len) continue;
        switch (context.tokens[body_start].tag) {
            .l_brace, .keyword_if, .keyword_for, .keyword_while, .keyword_switch, .keyword_defer, .keyword_errdefer => continue,
            else => {},
        }
        const guard_end_offset = context.tokens[guard_end].loc.end;
        const body_start_offset = context.tokens[body_start].loc.start;
        if (std.mem.indexOfScalar(u8, context.source[guard_end_offset..body_start_offset], '\n') == null) continue;
        const statement_end = context.statementEnd(body_start) orelse continue;
        if (containsElse(context, body_start, statement_end)) continue;

        const semicolon_end = context.tokens[statement_end].loc.end;
        const statement_line_end = std.mem.indexOfScalarPos(u8, context.source, semicolon_end, '\n') orelse context.source.len;
        const fixes: []const types.Fix = if (containsComment(context.source[guard_end_offset..statement_line_end])) &.{} else blk: {
            const indent = lineIndent(context.source, token.loc.start);
            const edits = try context.allocator.alloc(types.Edit, 2);
            edits[0] = .{ .span = .{ .start = guard_end_offset, .end = guard_end_offset }, .replacement = " {" };
            edits[1] = .{
                .span = .{ .start = semicolon_end, .end = semicolon_end },
                .replacement = try std.fmt.allocPrint(context.allocator, "\n{s}}}", .{indent}),
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
            .message = try std.fmt.allocPrint(
                context.allocator,
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

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

fn lineIndent(source: []const u8, offset: usize) []const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |newline| newline + 1 else 0;
    var end = line_start;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    return source[line_start..end];
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
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'fail'") != null);
    try std.testing.expectEqual(@as(usize, 2), findings[0].fixes[0].edits.len);
    try std.testing.expectEqualStrings(" {", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("\n    }", findings[0].fixes[0].edits[1].replacement);
    try std.testing.expect(findings[0].fixes[0].fix_all);
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
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'two'") != null);
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

test "unbraced multiline if diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn guard(flag: bool) void {\n" ++
        "    // zig-analyzer: disable-next-line unbraced-multiline-if\n" ++
        "    if (flag)\n" ++
        "        fail();\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unbraced_multiline_if)] = .information;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
