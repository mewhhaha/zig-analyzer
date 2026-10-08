const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;
const pathBefore = @import("../../syntax/tokens.zig").pathBefore;
const pathAfter = @import("../../syntax/tokens.zig").pathAfter;

pub const rules = [_]types.Rule{
    .identical_bitwise_operands,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.identical_bitwise_operands);
    if (level == .off) return;

    for (context.tokens, 0..) |token, op_index| {
        if (!isBitwiseOp(token.tag) or op_index == 0 or op_index + 1 >= context.tokens.len) continue;

        const lhs_span = pathBefore(context.tokens, op_index) orelse continue;

        if (lhs_span.start > 0 and !isBitwiseBoundaryBefore(context.tokens[lhs_span.start - 1].tag)) continue;

        const rhs_span = pathAfter(context.tokens, op_index + 1) orelse continue;

        if (rhs_span.end < context.tokens.len and !isBitwiseBoundaryAfter(context.tokens[rhs_span.end].tag)) continue;

        if (token.tag == .pipe) {
            if (lhs_span.start > 0 and context.tokens[lhs_span.start - 1].tag == .pipe) continue;
            if (rhs_span.end < context.tokens.len and context.tokens[rhs_span.end].tag == .pipe) continue;
            if (identifierIsCaptureBinding(context.tokens, lhs_span.start) or
                identifierIsCaptureBinding(context.tokens, rhs_span.start)) continue;
        }

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
        const op_text = switch (token.tag) {
            .ampersand => "&",
            .pipe => "|",
            .caret => "^",
            else => unreachable,
        };

        const edits = try context.allocator.alloc(types.Edit, 1);
        const title: []const u8 = if (token.tag == .caret) blk: {
            edits[0] = .{
                .span = .{ .start = context.tokens[lhs_span.start].loc.start, .end = context.tokens[rhs_span.end - 1].loc.end },
                .replacement = "0",
            };
            break :blk "Replace with '0'";
        } else blk: {
            var fix_start = token.loc.start;
            if (lhs_span.end > 0 and context.tokens[lhs_span.end - 1].loc.end < token.loc.start) {
                fix_start = context.tokens[lhs_span.end - 1].loc.end;
            }
            edits[0] = .{
                .span = .{ .start = fix_start, .end = context.tokens[rhs_span.end - 1].loc.end },
                .replacement = "",
            };
            break :blk try context.allocator.print("Remove redundant '{s} {s}'", .{ op_text, operand_text });
        };

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = title,
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        const message = if (token.tag == .caret)
            try context.allocator.print(
                "bitwise '^' with identical operands '{s} ^ {s}' always evaluates to 0 and is likely a typo",
                .{ operand_text, operand_text },
            )
        else
            try context.allocator.print(
                "bitwise '{s}' with identical operands '{s} {s} {s}' is redundant and likely a typo",
                .{ op_text, operand_text, op_text, operand_text },
            );

        try context.emit(.{
            .rule = .identical_bitwise_operands,
            .level = level,
            .span = .{ .start = context.tokens[lhs_span.start].loc.start, .end = context.tokens[rhs_span.end - 1].loc.end },
            .message = message,
            .fixes = fixes,
        });
    }
}

fn isBitwiseOp(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .ampersand,
        .pipe,
        .caret,
        => true,
        else => false,
    };
}

fn isBitwiseBoundaryBefore(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .l_paren,
        .l_bracket,
        .keyword_if,
        .keyword_while,
        .keyword_return,
        .equal,
        .comma,
        .colon,
        .semicolon,
        .ampersand,
        .pipe,
        .caret,
        .plus,
        .minus,
        .asterisk,
        .slash,
        .percent,
        .equal_equal,
        .bang_equal,
        .angle_bracket_left,
        .angle_bracket_right,
        .angle_bracket_left_equal,
        .angle_bracket_right_equal,
        .angle_bracket_angle_bracket_left,
        .angle_bracket_angle_bracket_right,
        .keyword_and,
        .keyword_or,
        => true,
        else => false,
    };
}

fn isBitwiseBoundaryAfter(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .r_paren,
        .r_bracket,
        .semicolon,
        .comma,
        .colon,
        .keyword_else,
        .l_brace,
        .ampersand,
        .pipe,
        .caret,
        .plus,
        .minus,
        .asterisk,
        .slash,
        .percent,
        .equal_equal,
        .bang_equal,
        .angle_bracket_left,
        .angle_bracket_right,
        .angle_bracket_left_equal,
        .angle_bracket_right_equal,
        .angle_bracket_angle_bracket_left,
        .angle_bracket_angle_bracket_right,
        .keyword_and,
        .keyword_or,
        => true,
        else => false,
    };
}

fn identifierIsCaptureBinding(tokens: []const std.zig.Token, index: usize) bool {
    var opening = index;
    while (opening > 0 and index - opening < 16) {
        opening -= 1;
        switch (tokens[opening].tag) {
            .pipe => break,
            .identifier, .asterisk, .comma => {},
            else => return false,
        }
    } else return false;
    var closing = index + 1;
    while (closing < tokens.len and closing - index < 16) : (closing += 1) {
        switch (tokens[closing].tag) {
            .pipe => return true,
            .identifier, .asterisk, .comma => {},
            else => return false,
        }
    }
    return false;
}

test "identical bitwise operands reports repeated operands in &, |, ^" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(flags: u32, s: Struct) u32 {\n" ++
        "    const a = flags & flags;\n" ++
        "    const b = s.ready | s.ready;\n" ++
        "    const c = s.ptr.* ^ s.ptr.*;\n" ++
        "    return a + b + c;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "flags & flags") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "s.ready | s.ready") != null);
    try std.testing.expect(std.mem.find(u8, findings[2].message, "s.ptr.* ^ s.ptr.*") != null);
    try std.testing.expectEqualStrings("", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("0", findings[2].fixes[0].edits[0].replacement);
}

test "distinct bitwise operands stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(a: u32, b: u32, s: Struct, other: Struct) u32 {\n" ++
        "    const x = a & b;\n" ++
        "    const y = s.ready | other.ready;\n" ++
        "    const z = s.ptr.* ^ other.ptr.*;\n" ++
        "    return x + y + z;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "capture pipes and unary address-of do not trigger identical bitwise operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(opt: ?u32, items: []const u32) void {\n" ++
        "    if (opt) |val| val.call();\n" ++
        "    for (items) |item| item.process();\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.identical_bitwise_operands}, .warning));
}
