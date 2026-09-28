const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.identical_conditional_branches);
    if (level == .off) return;

    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 4 >= context.tokens.len or
            context.tokens[if_index + 1].tag != .l_paren) continue;

        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end == if_index + 2) continue;

        if (condition_end + 1 < context.tokens.len and context.tokens[condition_end + 1].tag == .pipe) continue;

        const then_start = condition_end + 1;
        if (then_start >= context.tokens.len) continue;

        // Case A: Braced branches: `if (cond) { ... } else { ... }`
        if (context.tokens[then_start].tag == .l_brace) {
            const then_close = context.matchingToken(then_start, .l_brace, .r_brace) orelse continue;
            const else_index = then_close + 1;
            if (else_index >= context.tokens.len or context.tokens[else_index].tag != .keyword_else) continue;
            const else_start = else_index + 1;
            if (else_start >= context.tokens.len or context.tokens[else_start].tag != .l_brace) continue;
            const else_close = context.matchingToken(else_start, .l_brace, .r_brace) orelse continue;

            const then_inner = TokenSpan{ .start = then_start + 1, .end = then_close };
            const else_inner = TokenSpan{ .start = else_start + 1, .end = else_close };

            if (!tokensMatch(context, then_inner, else_inner)) continue;

            const whole_source = context.source[token.loc.start..context.tokens[else_close].loc.end];
            if (containsComment(whole_source)) continue;

            const body_text = if (then_inner.start < then_inner.end)
                std.mem.trim(u8, context.source[context.tokens[then_inner.start].loc.start..context.tokens[then_inner.end - 1].loc.end], " \t\r\n")
            else
                "";

            const replacement = if (then_inner.start < then_inner.end)
                try std.fmt.allocPrint(context.allocator, "{s}\n", .{body_text})
            else
                "";

            const edits = try context.allocator.alloc(types.Edit, 1);
            edits[0] = .{
                .span = .{ .start = token.loc.start, .end = context.tokens[else_close].loc.end },
                .replacement = replacement,
            };
            const fixes = try context.allocator.alloc(types.Fix, 1);
            fixes[0] = .{
                .title = "Remove redundant 'if' check and use body directly",
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
                .fix_all = true,
            };

            try context.emit(.{
                .rule = .identical_conditional_branches,
                .level = level,
                .span = token.loc,
                .message = "'if' and 'else' branches have identical bodies; the condition has no effect",
                .fixes = fixes,
            });
            continue;
        }

        // Case B: Unbraced expression / statement: `if (cond) expr else expr`
        const branch_info = parseUnbracedBranches(context, then_start) orelse continue;

        if (!tokensMatch(context, branch_info.then_expr, branch_info.else_expr)) continue;

        const whole_source = context.source[token.loc.start..context.tokens[branch_info.else_expr.end - 1].loc.end];
        if (containsComment(whole_source)) continue;

        const expr_text = context.source[context.tokens[branch_info.then_expr.start].loc.start..context.tokens[branch_info.then_expr.end - 1].loc.end];

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = token.loc.start, .end = context.tokens[branch_info.else_expr.end - 1].loc.end },
            .replacement = try context.allocator.dupe(u8, expr_text),
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = try std.fmt.allocPrint(context.allocator, "Use '{s}' directly", .{expr_text}),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        try context.emit(.{
            .rule = .identical_conditional_branches,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "both branches of 'if' evaluate to the identical expression '{s}'; the condition has no effect",
                .{expr_text},
            ),
            .fixes = fixes,
        });
    }
}

const TokenSpan = struct {
    start: usize,
    end: usize,
};

const UnbracedBranches = struct {
    then_expr: TokenSpan,
    else_expr: TokenSpan,
};

fn parseUnbracedBranches(context: RuleRun, start: usize) ?UnbracedBranches {
    if (start >= context.tokens.len) return null;

    var else_index = start;
    var paren_depth: usize = 0;
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
    while (else_index < context.tokens.len) : (else_index += 1) {
        switch (context.tokens[else_index].tag) {
            .l_paren => paren_depth += 1,
            .r_paren => if (paren_depth > 0) {
                paren_depth -= 1;
            } else break,
            .l_brace => brace_depth += 1,
            .r_brace => if (brace_depth > 0) {
                brace_depth -= 1;
            } else break,
            .l_bracket => bracket_depth += 1,
            .r_bracket => if (bracket_depth > 0) {
                bracket_depth -= 1;
            } else break,
            .semicolon, .comma => if (paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) break,
            .keyword_else => if (paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) break,
            else => {},
        }
    }
    if (else_index >= context.tokens.len or context.tokens[else_index].tag != .keyword_else) return null;
    if (else_index + 1 >= context.tokens.len or context.tokens[else_index + 1].tag == .keyword_if) return null;
    if (context.tokens[else_index + 1].tag == .l_brace) return null;

    const then_expr = TokenSpan{ .start = start, .end = else_index };
    const else_start = else_index + 1;
    var else_end = else_start;
    while (else_end < context.tokens.len) : (else_end += 1) {
        switch (context.tokens[else_end].tag) {
            .semicolon, .comma, .r_paren, .r_bracket, .r_brace => break,
            else => {},
        }
    }
    if (else_end <= else_start) return null;

    return .{
        .then_expr = then_expr,
        .else_expr = .{ .start = else_start, .end = else_end },
    };
}

fn tokensMatch(context: RuleRun, a: TokenSpan, b: TokenSpan) bool {
    const a_len = a.end - a.start;
    const b_len = b.end - b.start;
    if (a_len != b_len) return false;
    for (0..a_len) |offset| {
        const a_tok = a.start + offset;
        const b_tok = b.start + offset;
        if (context.tokens[a_tok].tag != context.tokens[b_tok].tag or
            !context.tokenIs(a_tok, context.tokenText(b_tok)))
        {
            return false;
        }
    }
    return true;
}

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

test "identical conditional branches reports identical if and else bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(c: bool, flag: bool) u32 {\n" ++
        "    if (c) {\n" ++
        "        doWork();\n" ++
        "        return 1;\n" ++
        "    } else {\n" ++
        "        doWork();\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "    const x = if (flag) 42 else 42;\n" ++
        "    return x;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "identical bodies") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "identical expression '42'") != null);
    try std.testing.expectEqualStrings("42", findings[1].fixes[0].edits[0].replacement);
}

test "distinct conditional branches stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(c: bool, opt: ?u32) u32 {\n" ++
        "    if (c) {\n" ++
        "        return 1;\n" ++
        "    } else {\n" ++
        "        return 2;\n" ++
        "    }\n" ++
        "    const x = if (c) 1 else 2;\n" ++
        "    if (opt) |val| {\n" ++
        "        use(val);\n" ++
        "    } else {\n" ++
        "        use(val);\n" ++
        "    }\n" ++
        "    if (c) run() else if (x > 0) run() else finish();\n" ++
        "    return x;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "identical conditional branches honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(c: bool) u32 {\n" ++
        "    // zig-analyzer: disable-next-line identical-conditional-branches\n" ++
        "    return if (c) 10 else 10;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.identical_conditional_branches)] = .warning;
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
