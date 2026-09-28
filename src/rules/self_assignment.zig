const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

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

        var fixes: []const types.Fix = &.{};
        if (lhs_len == 1) {
            const edits = try context.allocator.alloc(types.Edit, 1);
            edits[0] = .{
                .span = .{ .start = context.tokens[lhs_span.start].loc.start, .end = context.tokens[lhs_span.end - 1].loc.end },
                .replacement = "_",
            };
            const f = try context.allocator.alloc(types.Fix, 1);
            f[0] = .{
                .title = try std.fmt.allocPrint(context.allocator, "Discard '{s}' with '_ = {s};'", .{ path_text, path_text }),
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
            };
            fixes = f;
        }

        try context.emit(.{
            .rule = .self_assignment,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "self-assignment of '{s}' has no effect and is likely a typo",
                .{path_text},
            ),
            .fixes = fixes,
        });
    }
}

const PathSpan = struct {
    start: usize,
    end: usize,
};

fn pathBefore(tokens: []const std.zig.Token, before: usize) ?PathSpan {
    if (before == 0 or tokens[before - 1].tag != .identifier) return null;
    var cursor = before - 1;
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
    return .{ .start = start, .end = cursor };
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

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

test "self-assignment reports simple and dotted paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(x: u32) void {\n" ++
        "    var a = x;\n" ++
        "    a = a;\n" ++
        "    self.field = self.field;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "self-assignment of 'a'") != null);
    try std.testing.expectEqualStrings("_", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "self-assignment of 'self.field'") != null);
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

test "self-assignment honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void {\n" ++
        "    // zig-analyzer: disable-next-line self-assignment\n" ++
        "    a = a;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.self_assignment)] = .warning;
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
