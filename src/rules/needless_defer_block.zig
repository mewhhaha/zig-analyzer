const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.needless_defer_block);
    if (level == .off) return;

    for (context.tokens, 0..) |token, defer_index| {
        if ((token.tag != .keyword_defer and token.tag != .keyword_errdefer) or
            defer_index + 3 >= context.tokens.len or context.tokens[defer_index + 1].tag != .l_brace or
            context.tokens[defer_index + 2].tag != .identifier) continue;
        const opening_index = defer_index + 1;
        const closing_index = context.matchingToken(opening_index, .l_brace, .r_brace) orelse continue;
        const statement_end = context.statementEnd(opening_index + 1) orelse continue;
        if (statement_end + 1 != closing_index) continue;

        const block_source = context.source[context.tokens[opening_index].loc.end..context.tokens[closing_index].loc.start];
        if (containsComment(block_source)) continue;
        const statement = std.mem.trim(u8, block_source, " \t\r\n");
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = context.tokens[opening_index].loc.start, .end = context.tokens[closing_index].loc.end },
            .replacement = try context.allocator.dupe(u8, statement),
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = if (token.tag == .keyword_defer) "Remove the single-statement defer block" else "Remove the single-statement errdefer block",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .needless_defer_block,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(
                u8,
                if (token.tag == .keyword_defer)
                    "defer block contains one expression statement and can use the direct form"
                else
                    "errdefer block contains one expression statement and can use the direct form",
            ),
            .fixes = fixes,
        });
    }
}

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

test "single-expression defer blocks use the direct form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "defer { file.close(); }\n" ++
        "errdefer { allocator.free(memory); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("file.close();", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("allocator.free(memory);", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqual(types.ActionKind.quickfix, findings[0].fixes[0].kind);
    try std.testing.expect(findings[0].fixes[0].fix_all);
}

test "multi-statement commented and declaration defer blocks stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "defer { file.close(); logClose(); }\n" ++
        "defer { file.close(); // explain ordering\n }\n" ++
        "defer { const value = current; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "defer block respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line needless-defer-block\n" ++
        "defer { file.close(); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.needless_defer_block)] = .information;
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
