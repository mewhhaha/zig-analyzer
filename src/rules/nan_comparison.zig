const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.nan_comparison);
    if (level == .off) return;

    for (context.tokens, 0..) |token, op_index| {
        if (!isComparisonOp(token.tag) or op_index == 0 or op_index + 1 >= context.tokens.len) continue;

        // Check if RHS is a NaN call
        if (parseNanCall(context, op_index + 1)) |nan_call| {
            const lhs = findOperandBefore(context, op_index) orelse continue;
            try emitFinding(context, level, token, lhs, nan_call.span, nan_call.prefix, false);
            continue;
        }

        // Check if LHS is a NaN call
        if (parseNanCallEndingAt(context, op_index)) |nan_call| {
            const rhs = findOperandAfter(context, op_index + 1) orelse continue;
            try emitFinding(context, level, token, rhs, nan_call.span, nan_call.prefix, true);
            continue;
        }
    }
}

const TokenSpan = struct {
    start: usize,
    end: usize,
};

const NanCall = struct {
    span: TokenSpan,
    prefix: []const u8,
};

fn isComparisonOp(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal_equal,
        .bang_equal,
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        => true,
        else => false,
    };
}

fn parseNanCall(context: RuleRun, start: usize) ?NanCall {
    if (start >= context.tokens.len) return null;
    // Check std.math.nan(...) or std.math.snan(...)
    if (start + 5 < context.tokens.len and
        context.tokens[start].tag == .identifier and context.tokenIs(start, "std") and
        context.tokens[start + 1].tag == .period and
        context.tokens[start + 2].tag == .identifier and context.tokenIs(start + 2, "math") and
        context.tokens[start + 3].tag == .period and
        context.tokens[start + 4].tag == .identifier and
        (context.tokenIs(start + 4, "nan") or context.tokenIs(start + 4, "snan")) and
        context.tokens[start + 5].tag == .l_paren)
    {
        const close = context.matchingToken(start + 5, .l_paren, .r_paren) orelse return null;
        return .{
            .span = .{ .start = start, .end = close + 1 },
            .prefix = "std.math.isNan",
        };
    }
    // Check math.nan(...) or math.snan(...)
    if (start + 3 < context.tokens.len and
        context.tokens[start].tag == .identifier and context.tokenIs(start, "math") and
        context.tokens[start + 1].tag == .period and
        context.tokens[start + 2].tag == .identifier and
        (context.tokenIs(start + 2, "nan") or context.tokenIs(start + 2, "snan")) and
        context.tokens[start + 3].tag == .l_paren)
    {
        const close = context.matchingToken(start + 3, .l_paren, .r_paren) orelse return null;
        return .{
            .span = .{ .start = start, .end = close + 1 },
            .prefix = "math.isNan",
        };
    }
    return null;
}

fn parseNanCallEndingAt(context: RuleRun, end: usize) ?NanCall {
    if (end < 4 or context.tokens[end - 1].tag != .r_paren) return null;
    const open_paren = matchingOpeningToken(context.tokens, end - 1, .l_paren, .r_paren) orelse return null;
    if (open_paren < 2) return null;
    if (context.tokens[open_paren - 1].tag != .identifier) return null;
    if (!context.tokenIs(open_paren - 1, "nan") and !context.tokenIs(open_paren - 1, "snan")) return null;
    if (context.tokens[open_paren - 2].tag != .period) return null;

    if (open_paren >= 3 and context.tokens[open_paren - 3].tag == .identifier and context.tokenIs(open_paren - 3, "math")) {
        if (open_paren >= 5 and context.tokens[open_paren - 4].tag == .period and
            context.tokens[open_paren - 5].tag == .identifier and context.tokenIs(open_paren - 5, "std"))
        {
            return .{
                .span = .{ .start = open_paren - 5, .end = end },
                .prefix = "std.math.isNan",
            };
        }
        return .{
            .span = .{ .start = open_paren - 3, .end = end },
            .prefix = "math.isNan",
        };
    }
    return null;
}

fn matchingOpeningToken(
    tokens: []const std.zig.Token,
    closing_index: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    var cursor = closing_index;
    while (true) {
        const token = tokens[cursor];
        if (token.tag == closing_tag) depth += 1;
        if (token.tag == opening_tag) {
            depth -= 1;
            if (depth == 0) return cursor;
        }
        if (cursor == 0) break;
        cursor -= 1;
    }
    return null;
}

fn findOperandAfter(context: RuleRun, start: usize) ?TokenSpan {
    if (start >= context.tokens.len) return null;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var cursor = start;
    while (cursor < context.tokens.len) : (cursor += 1) {
        const tag = context.tokens[cursor].tag;
        switch (tag) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth == 0) break;
                paren_depth -= 1;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => {
                if (bracket_depth == 0) break;
                bracket_depth -= 1;
            },
            .l_brace => brace_depth += 1,
            .r_brace => {
                if (brace_depth == 0) break;
                brace_depth -= 1;
            },
            .semicolon, .comma => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) break;
            },
            .keyword_and, .keyword_or, .keyword_orelse, .keyword_catch, .keyword_else => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) break;
            },
            .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_left_equal, .angle_bracket_right, .angle_bracket_right_equal => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) break;
            },
            .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) break;
            },
            else => {},
        }
    }
    if (cursor == start) return null;
    return .{ .start = start, .end = cursor };
}

fn findOperandBefore(context: RuleRun, before: usize) ?TokenSpan {
    if (before == 0) return null;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var cursor = before;
    while (cursor > 0) {
        const tag = context.tokens[cursor - 1].tag;
        switch (tag) {
            .r_paren => paren_depth += 1,
            .l_paren => {
                if (paren_depth == 0) break;
                paren_depth -= 1;
            },
            .r_bracket => bracket_depth += 1,
            .l_bracket => {
                if (bracket_depth == 0) break;
                bracket_depth -= 1;
            },
            .r_brace => brace_depth += 1,
            .l_brace => {
                if (brace_depth == 0) break;
                brace_depth -= 1;
            },
            .semicolon, .comma => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) break;
            },
            .keyword_and, .keyword_or, .keyword_orelse, .keyword_catch, .keyword_return, .keyword_if, .keyword_while => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) break;
            },
            .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_left_equal, .angle_bracket_right, .angle_bracket_right_equal => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) break;
            },
            .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) break;
            },
            else => {},
        }
        cursor -= 1;
    }
    if (cursor == before) return null;
    return .{ .start = cursor, .end = before };
}

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

fn emitFinding(
    context: RuleRun,
    level: types.Level,
    op_token: std.zig.Token,
    operand_span: TokenSpan,
    nan_span: TokenSpan,
    prefix: []const u8,
    is_nan_lhs: bool,
) !void {
    const whole_span = if (is_nan_lhs)
        std.zig.Token.Loc{
            .start = context.tokens[nan_span.start].loc.start,
            .end = context.tokens[operand_span.end - 1].loc.end,
        }
    else
        std.zig.Token.Loc{
            .start = context.tokens[operand_span.start].loc.start,
            .end = context.tokens[nan_span.end - 1].loc.end,
        };

    const whole_source = context.source[whole_span.start..whole_span.end];
    if (containsComment(whole_source)) return;

    const operand_text = std.mem.trim(
        u8,
        context.source[context.tokens[operand_span.start].loc.start..context.tokens[operand_span.end - 1].loc.end],
        " \t\r\n",
    );

    const is_equality = op_token.tag == .equal_equal;
    const is_inequality = op_token.tag == .bang_equal;

    if (is_equality or is_inequality) {
        const replacement = if (is_equality)
            try std.fmt.allocPrint(context.allocator, "{s}({s})", .{ prefix, operand_text })
        else
            try std.fmt.allocPrint(context.allocator, "!{s}({s})", .{ prefix, operand_text });

        const fix_title = if (is_equality)
            try std.fmt.allocPrint(context.allocator, "Use '{s}({s})'", .{ prefix, operand_text })
        else
            try std.fmt.allocPrint(context.allocator, "Use '!{s}({s})'", .{ prefix, operand_text });

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = whole_span,
            .replacement = replacement,
        };

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = fix_title,
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        const message = if (is_equality)
            try std.fmt.allocPrint(
                context.allocator,
                "comparison '{s}' always evaluates to false; use '{s}({s})' to test for NaN",
                .{ whole_source, prefix, operand_text },
            )
        else
            try std.fmt.allocPrint(
                context.allocator,
                "comparison '{s}' always evaluates to true; use '!{s}({s})' to test for NaN",
                .{ whole_source, prefix, operand_text },
            );

        try context.emit(.{
            .rule = .nan_comparison,
            .level = level,
            .span = whole_span,
            .message = message,
            .fixes = fixes,
        });
    } else {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "comparison '{s}' always evaluates to false; NaN values are unordered",
            .{whole_source},
        );

        try context.emit(.{
            .rule = .nan_comparison,
            .level = level,
            .span = whole_span,
            .message = message,
        });
    }
}

test "nan comparison flags and fixes equality and inequality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        "fn check(x: f32) bool {\n" ++
        "    if (x == std.math.nan(f32)) return false;\n" ++
        "    if (std.math.nan(f32) == x) return false;\n" ++
        "    if (x != std.math.nan(f32)) return true;\n" ++
        "    if (x == math.nan(f32)) return false;\n" ++
        "    if (x != math.snan(f32)) return true;\n" ++
        "    if (x > std.math.nan(f32)) return false;\n" ++
        "    return x == 0.0;\n" ++
        "}\n";

    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 6), findings.len);

    try std.testing.expectEqualStrings("std.math.isNan(x)", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("std.math.isNan(x)", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("!std.math.isNan(x)", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("math.isNan(x)", findings[3].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("!math.isNan(x)", findings[4].fixes[0].edits[0].replacement);
    try std.testing.expectEqual(@as(usize, 0), findings[5].fixes.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]types.Finding {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    defer tokens.deinit(allocator);

    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }

    var list: std.ArrayList(types.Finding) = .empty;
    const run_context: RuleRun = .{
        .allocator = allocator,
        .source = source,
        .tokens = tokens.items,
        .configuration = Configuration.defaults(),
        .findings = &list,
    };
    try run(run_context);
    return list.toOwnedSlice(allocator);
}

const Configuration = struct {
    fn defaults() types.Configuration {
        var cfg = types.Configuration.defaults();
        cfg.levels[@backingInt(types.Rule.nan_comparison)] = .warning;
        return cfg;
    }
};
