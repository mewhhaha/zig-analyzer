const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_min_max);
    if (level == .off) return;

    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 6 >= context.tokens.len or
            context.tokens[if_index + 1].tag != .l_paren) continue;

        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end == if_index + 2) continue;

        const op_info = findComparisonOp(context.tokens, if_index + 2, condition_end) orelse continue;

        const cond_lhs = TokenSpan{ .start = if_index + 2, .end = op_info.op_index };
        const cond_rhs = TokenSpan{ .start = op_info.op_index + 1, .end = condition_end };

        if (!isValidOperand(context.tokens, cond_lhs.start, cond_lhs.end) or
            !isValidOperand(context.tokens, cond_rhs.start, cond_rhs.end)) continue;

        const branch_info = parseBranches(context, condition_end + 1) orelse continue;

        const matches_forward = tokensMatch(context, cond_lhs, branch_info.then_expr) and
            tokensMatch(context, cond_rhs, branch_info.else_expr);
        const matches_reverse = tokensMatch(context, cond_rhs, branch_info.then_expr) and
            tokensMatch(context, cond_lhs, branch_info.else_expr);

        if (!matches_forward and !matches_reverse) continue;

        const is_less = (op_info.op == .angle_bracket_left or op_info.op == .angle_bracket_left_equal);
        const builtin_name = if (matches_forward)
            (if (is_less) "min" else "max")
        else
            (if (is_less) "max" else "min");

        const replace_end = if (branch_info.is_return_statement)
            context.tokens[branch_info.else_expr.end].loc.end
        else
            context.tokens[branch_info.else_expr.end - 1].loc.end;

        const entire_span = std.zig.Token.Loc{
            .start = token.loc.start,
            .end = replace_end,
        };
        const whole_source = context.source[entire_span.start..entire_span.end];
        if (containsComment(whole_source)) continue;

        const lhs_text = context.source[context.tokens[cond_lhs.start].loc.start..context.tokens[cond_lhs.end - 1].loc.end];
        const rhs_text = context.source[context.tokens[cond_rhs.start].loc.start..context.tokens[cond_rhs.end - 1].loc.end];

        const replacement = if (branch_info.is_return_statement)
            try std.fmt.allocPrint(context.allocator, "return @{s}({s}, {s});", .{ builtin_name, lhs_text, rhs_text })
        else
            try std.fmt.allocPrint(context.allocator, "@{s}({s}, {s})", .{ builtin_name, lhs_text, rhs_text });

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = entire_span,
            .replacement = replacement,
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = try std.fmt.allocPrint(context.allocator, "Use @{s}({s}, {s})", .{ builtin_name, lhs_text, rhs_text }),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        try context.emit(.{
            .rule = .prefer_min_max,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "conditional expression chooses between '{s}' and '{s}'; use '@{s}({s}, {s})' directly",
                .{ lhs_text, rhs_text, builtin_name, lhs_text, rhs_text },
            ),
            .fixes = fixes,
        });
    }
}

const TokenSpan = struct {
    start: usize,
    end: usize,
};

const ComparisonOp = struct {
    op: std.zig.Token.Tag,
    op_index: usize,
};

fn findComparisonOp(tokens: []const std.zig.Token, start: usize, end: usize) ?ComparisonOp {
    var op_info: ?ComparisonOp = null;
    for (tokens[start..end], start..) |tok, idx| {
        switch (tok.tag) {
            .angle_bracket_left,
            .angle_bracket_left_equal,
            .angle_bracket_right,
            .angle_bracket_right_equal,
            => {
                if (op_info != null) return null;
                op_info = .{ .op = tok.tag, .op_index = idx };
            },
            else => {},
        }
    }
    return op_info;
}

fn isValidOperand(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    if (start >= end) return false;
    var cursor = start;
    if (tokens[cursor].tag == .minus and cursor + 1 < end) {
        cursor += 1;
    }
    if (tokens[cursor].tag == .number_literal) {
        return cursor + 1 == end;
    }
    if (tokens[cursor].tag != .identifier) return false;
    cursor += 1;
    while (cursor < end) {
        if (cursor + 1 < end and tokens[cursor].tag == .period and tokens[cursor + 1].tag == .identifier) {
            cursor += 2;
        } else if (tokens[cursor].tag == .period_asterisk) {
            cursor += 1;
        } else return false;
    }
    return cursor == end;
}

const BranchInfo = struct {
    then_expr: TokenSpan,
    else_expr: TokenSpan,
    is_return_statement: bool,
};

fn parseBranches(context: RuleRun, start: usize) ?BranchInfo {
    if (start >= context.tokens.len) return null;

    if (context.tokens[start].tag == .keyword_return) {
        const then_start = start + 1;
        var then_end = then_start;
        while (then_end < context.tokens.len and context.tokens[then_end].tag != .semicolon) : (then_end += 1) {}
        if (then_end >= context.tokens.len) return null;
        const else_index = then_end + 1;
        if (else_index >= context.tokens.len or context.tokens[else_index].tag != .keyword_else) return null;
        if (else_index + 1 >= context.tokens.len or context.tokens[else_index + 1].tag != .keyword_return) return null;
        const else_start = else_index + 2;
        var else_end = else_start;
        while (else_end < context.tokens.len and context.tokens[else_end].tag != .semicolon) : (else_end += 1) {}
        if (else_end >= context.tokens.len) return null;

        return .{
            .then_expr = .{ .start = then_start, .end = then_end },
            .else_expr = .{ .start = else_start, .end = else_end },
            .is_return_statement = true,
        };
    }

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
        .is_return_statement = false,
    };
}

fn tokensMatch(context: RuleRun, a: TokenSpan, b: TokenSpan) bool {
    const a_len = a.end - a.start;
    const b_len = b.end - b.start;
    if (a_len != b_len or a_len == 0) return false;
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

test "prefer min max detects ternary-style min and max expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn clamp(a: u32, b: u32, x: u32) u32 {\n" ++
        "    const m1 = if (a < b) a else b;\n" ++
        "    const m2 = if (a > b) a else b;\n" ++
        "    const m3 = if (a <= b) b else a;\n" ++
        "    const m4 = if (x >= 10) 10 else x;\n" ++
        "    if (a < b) return a; else return b;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 5), findings.len);
    try std.testing.expectEqualStrings("@min(a, b)", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("@max(a, b)", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("@max(a, b)", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("@min(x, 10)", findings[3].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("return @min(a, b);", findings[4].fixes[0].edits[0].replacement);
}

test "distinct operands or non-comparison conditions stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(a: u32, b: u32, c: u32) u32 {\n" ++
        "    const x = if (a < b) a else c;\n" ++
        "    const y = if (a == b) a else b;\n" ++
        "    const z = if (a < b) 1 else 2;\n" ++
        "    return x + y + z;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer min max honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(a: u32, b: u32) u32 {\n" ++
        "    // zig-analyzer: disable-next-line prefer-min-max\n" ++
        "    return if (a < b) a else b;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.prefer_min_max)] = .warning;
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
