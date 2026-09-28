const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.identical_logical_operands);
    if (level == .off) return;

    for (context.tokens, 0..) |token, op_index| {
        if ((token.tag != .keyword_and and token.tag != .keyword_or) or
            op_index == 0 or op_index + 1 >= context.tokens.len) continue;

        const lhs_span = pathBefore(context.tokens, op_index) orelse continue;

        if (lhs_span.start > 0 and !isLogicalBoundaryBefore(context.tokens[lhs_span.start - 1].tag)) continue;

        const rhs_span = pathAfter(context.tokens, op_index + 1) orelse continue;

        if (rhs_span.end < context.tokens.len and !isLogicalBoundaryAfter(context.tokens[rhs_span.end].tag)) continue;

        const lhs_len = lhs_span.end - lhs_span.start;
        const rhs_len = rhs_span.end - rhs_span.start;
        if (lhs_len != rhs_len) continue;

        var matches = true;
        for (0..lhs_len) |offset| {
            const lhs_tok = lhs_span.start + offset;
            const rhs_tok = rhs_span.start + offset;
            if (context.tokens[lhs_tok].tag != context.tokens[rhs_tok].tag or
                !context.tokenIs(lhs_tok, context.tokenText(rhs_tok)))
            {
                matches = false;
                break;
            }
        }
        if (!matches) continue;

        const expr_source = context.source[context.tokens[lhs_span.start].loc.start..context.tokens[rhs_span.end - 1].loc.end];
        if (containsComment(expr_source)) continue;

        const operand_text = context.source[context.tokens[lhs_span.start].loc.start..context.tokens[lhs_span.end - 1].loc.end];
        const op_text = if (token.tag == .keyword_and) "and" else "or";

        const edits = try context.allocator.alloc(types.Edit, 1);
        var fix_start = token.loc.start;
        if (lhs_span.end > 0 and context.tokens[lhs_span.end - 1].loc.end < token.loc.start) {
            fix_start = context.tokens[lhs_span.end - 1].loc.end;
        }
        edits[0] = .{
            .span = .{ .start = fix_start, .end = context.tokens[rhs_span.end - 1].loc.end },
            .replacement = "",
        };

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = try std.fmt.allocPrint(context.allocator, "Remove redundant '{s} {s}'", .{ op_text, operand_text }),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        const message = try std.fmt.allocPrint(
            context.allocator,
            "logical '{s}' with identical operands '{s} {s} {s}' is redundant and likely a typo",
            .{ op_text, operand_text, op_text, operand_text },
        );

        try context.emit(.{
            .rule = .identical_logical_operands,
            .level = level,
            .span = .{ .start = context.tokens[lhs_span.start].loc.start, .end = context.tokens[rhs_span.end - 1].loc.end },
            .message = message,
            .fixes = fixes,
        });
    }
}

const PathSpan = struct {
    start: usize,
    end: usize,
};

fn pathBefore(tokens: []const std.zig.Token, before: usize) ?PathSpan {
    if (before == 0) return null;
    var cursor = before;
    if (tokens[cursor - 1].tag == .period_asterisk) {
        cursor -= 1;
    }
    if (cursor == 0 or tokens[cursor - 1].tag != .identifier) return null;
    cursor -= 1;
    while (cursor >= 2 and tokens[cursor - 1].tag == .period and tokens[cursor - 2].tag == .identifier) {
        cursor -= 2;
    }
    return .{ .start = cursor, .end = before };
}

fn pathAfter(tokens: []const std.zig.Token, start: usize) ?PathSpan {
    if (start >= tokens.len or tokens[start].tag != .identifier) return null;
    var cursor = start + 1;
    while (cursor + 1 < tokens.len and tokens[cursor].tag == .period and tokens[cursor + 1].tag == .identifier) {
        cursor += 2;
    }
    if (cursor < tokens.len and tokens[cursor].tag == .period_asterisk) {
        cursor += 1;
    }
    return .{ .start = start, .end = cursor };
}

fn isLogicalBoundaryBefore(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .l_paren,
        .keyword_if,
        .keyword_while,
        .keyword_and,
        .keyword_or,
        .keyword_return,
        .equal,
        .comma,
        .colon,
        .semicolon,
        => true,
        else => false,
    };
}

fn isLogicalBoundaryAfter(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .r_paren,
        .keyword_and,
        .keyword_or,
        .semicolon,
        .comma,
        .l_brace,
        .keyword_else,
        => true,
        else => false,
    };
}

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

test "identical logical operands reports repeated conditions in and and or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(valid: bool, s: Struct) bool {\n" ++
        "    if (valid and valid) return true;\n" ++
        "    if (s.ready or s.ready) return true;\n" ++
        "    if (s.ptr.* and s.ptr.*) return true;\n" ++
        "    return false;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "valid and valid") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "s.ready or s.ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[2].message, "s.ptr.* and s.ptr.*") != null);
    try std.testing.expectEqualStrings("", findings[0].fixes[0].edits[0].replacement);
}

test "distinct logical operands stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(a: bool, b: bool, s: Struct, other: Struct, start: usize, index: usize, end: usize) bool {\n" ++
        "    if (a and b) return true;\n" ++
        "    if (s.ready or other.ready) return true;\n" ++
        "    if (s.ptr.* and other.ptr.*) return true;\n" ++
        "    if (start < index and index < end) return true;\n" ++
        "    if (start == index or index + 1 == end) return true;\n" ++
        "    return false;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "identical logical operands honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(x: bool) bool {\n" ++
        "    // zig-analyzer: disable-next-line identical-logical-operands\n" ++
        "    return x and x;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.identical_logical_operands)] = .warning;
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
