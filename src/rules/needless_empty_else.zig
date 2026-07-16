const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.needless_empty_else);
    if (level == .off) return;

    for (context.tokens, 0..) |token, else_index| {
        if (token.tag != .keyword_else or else_index == 0 or else_index + 2 >= context.tokens.len or
            context.tokens[else_index - 1].tag != .r_brace or context.tokens[else_index + 1].tag != .l_brace) continue;
        const closing_index = context.matchingToken(else_index + 1, .l_brace, .r_brace) orelse continue;
        if (closing_index != else_index + 2) continue;

        const removed_source = context.source[context.tokens[else_index - 1].loc.end..context.tokens[closing_index].loc.end];
        if (containsComment(removed_source)) continue;

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = context.tokens[else_index - 1].loc.end, .end = context.tokens[closing_index].loc.end },
            .replacement = "",
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Remove the empty else branch",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .needless_empty_else,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(u8, "empty else branch has no effect and obscures the conditional's active path"),
            .fixes = fixes,
        });
    }
}

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

test "empty else branches are removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "if (enabled) { run(); } else {}\n" ++
        "if (ready) { run(); }\nelse {\n}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqual(types.ActionKind.quickfix, findings[0].fixes[0].kind);
    try std.testing.expect(findings[0].fixes[0].fix_all);
}

test "nonempty commented and else-if branches stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "if (enabled) { run(); } else { fallback(); }\n" ++
        "if (enabled) { run(); } else { // intentional no-op\n}\n" ++
        "if (enabled) { run(); } else // intentional no-op\n{}\n" ++
        "if (enabled) { run(); } else if (fallback) { recover(); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "empty else respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line needless-empty-else\n" ++
        "if (enabled) { run(); } else {}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.needless_empty_else)] = .information;
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
