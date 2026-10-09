const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;
const lineStart = @import("../../syntax/tokens.zig").lineStart;
const lineEnd = @import("../../syntax/tokens.zig").lineEnd;
const removedLinesSpan = @import("../../syntax/tokens.zig").removedLinesSpan;
const pathBefore = @import("../../syntax/tokens.zig").pathBefore;
const pathAfter = @import("../../syntax/tokens.zig").pathAfter;

pub const rules = [_]types.Rule{
    .self_assignment,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.self_assignment);
    if (level == .off) return;

    for (context.tokens, 0..) |token, eq_index| {
        if (token.tag != .equal or eq_index == 0 or eq_index + 2 >= context.tokens.len) continue;

        // Find LHS path
        const lhs_span = pathBefore(context.tokens, eq_index) orelse continue;

        // Ensure LHS is at statement start position (not preceded by var, const, etc.)
        if (!isStatementStart(context.tokens, lhs_span.start)) continue;

        // Find RHS path
        const rhs_span = pathAfter(context.tokens, eq_index + 1) orelse continue;

        // RHS must be immediately followed by semicolon
        if (rhs_span.end >= context.tokens.len or context.tokens[rhs_span.end].tag != .semicolon) continue;

        // Compare LHS and RHS tokens
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

        const statement_source = context.source[context.tokens[lhs_span.start].loc.start..context.tokens[rhs_span.end].loc.end];
        if (containsComment(statement_source)) continue;

        const path_text = context.source[context.tokens[lhs_span.start].loc.start..context.tokens[lhs_span.end - 1].loc.end];

        // The assignment does nothing, so the fix deletes it; a discard
        // `_ = x;` would be an error once `x` is used anywhere else.
        var fixes: []const types.Fix = &.{};
        const statement_start = context.tokens[lhs_span.start].loc.start;
        const statement_end = context.tokens[rhs_span.end].loc.end;
        if (std.mem.trim(u8, context.source[lineStart(context.source, statement_start)..statement_start], " \t").len == 0 and
            std.mem.trim(u8, context.source[statement_end..lineEnd(context.source, statement_end)], " \t\r\n").len == 0)
        {
            fixes = try context.singleFix(.{
                .title = try context.allocator.print("Remove the self-assignment of '{s}'", .{path_text}),
                .span = removedLinesSpan(context.source, statement_start, statement_end),
                .replacement = "",
                .preferred = true,
            });
        }

        try context.emit(.{
            .rule = .self_assignment,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "self-assignment of '{s}' has no effect and is likely a typo",
                .{path_text},
            ),
            .fixes = fixes,
        });
    }
}

fn isStatementStart(tokens: []const std.zig.Token, index: usize) bool {
    if (index == 0) return true;
    const prev = tokens[index - 1].tag;
    switch (prev) {
        .semicolon, .l_brace, .r_brace => return true,
        .colon => {
            if (index < 2 or tokens[index - 2].tag != .identifier) return false;
            return index == 2 or isStatementStart(tokens, index - 2);
        },
        else => return false,
    }
}

test "self-assignment reports simple and dotted paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(x: u32) void {\n" ++
        "    var a = x;\n" ++
        "    a = a;\n" ++
        "    self.field = self.field;\n" ++
        "    self.ptr.* = self.ptr.*;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "self-assignment of 'a'") != null);
    try std.testing.expectEqualStrings("", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "self-assignment of 'self.field'") != null);
    try std.testing.expect(std.mem.find(u8, findings[2].message, "self-assignment of 'self.ptr.*'") != null);
}

test "shadowing variable declarations and modifications stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(x: u32) void {\n" ++
        "    var x = x;\n" ++
        "    var y: u32 = y;\n" ++
        "    a = b;\n" ++
        "    self.a = a;\n" ++
        "    c = c + 1;\n" ++
        "    _ = x;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.self_assignment}, .warning));
}
