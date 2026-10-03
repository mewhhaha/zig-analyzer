const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_empty_slice_len);
    if (level == .off) return;

    for (context.tokens, 0..) |token, eql_index| {
        if (token.tag != .identifier or !context.tokenIs(eql_index, "eql") or
            eql_index + 1 >= context.tokens.len or
            context.tokens[eql_index + 1].tag != .l_paren) continue;

        const call_start: usize = blk: {
            if (eql_index >= 4 and context.tokenIs(eql_index - 4, "std") and
                context.tokens[eql_index - 3].tag == .period and
                context.tokenIs(eql_index - 2, "mem") and
                context.tokens[eql_index - 1].tag == .period)
            {
                break :blk eql_index - 4;
            }
            if (eql_index >= 2 and context.tokenIs(eql_index - 2, "mem") and
                context.tokens[eql_index - 1].tag == .period)
            {
                break :blk eql_index - 2;
            }
            continue;
        };

        const call_end = context.matchingToken(eql_index + 1, .l_paren, .r_paren) orelse continue;
        const arguments = threeArguments(context, eql_index + 1, call_end) orelse continue;

        const empty_first = isEmptySlice(context, arguments[1]);
        const empty_second = isEmptySlice(context, arguments[2]);
        if (empty_first == empty_second) continue;

        const slice_arg = if (empty_first) arguments[2] else arguments[1];
        const slice_text = argumentSource(context, slice_arg);
        if (slice_text.len == 0) continue;

        var start_token = call_start;
        var end_token = call_end;
        var negated = false;

        if (call_start > 0 and context.tokens[call_start - 1].tag == .bang) {
            start_token = call_start - 1;
            negated = true;
        } else if (call_end + 2 < context.tokens.len) {
            const next_tok = context.tokens[call_end + 1];
            if (next_tok.tag == .equal_equal) {
                if (context.tokenIs(call_end + 2, "false")) {
                    end_token = call_end + 2;
                    negated = true;
                } else if (context.tokenIs(call_end + 2, "true")) {
                    end_token = call_end + 2;
                }
            } else if (next_tok.tag == .bang_equal) {
                if (context.tokenIs(call_end + 2, "true")) {
                    end_token = call_end + 2;
                    negated = true;
                } else if (context.tokenIs(call_end + 2, "false")) {
                    end_token = call_end + 2;
                }
            }
        }

        const parens = needsParens(context.tokens, slice_arg);
        const op = if (negated) "!=" else "==";
        const replacement = if (parens)
            try std.fmt.allocPrint(context.allocator, "({s}).len {s} 0", .{ slice_text, op })
        else
            try std.fmt.allocPrint(context.allocator, "{s}.len {s} 0", .{ slice_text, op });

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{
                .start = context.tokens[start_token].loc.start,
                .end = context.tokens[end_token].loc.end,
            },
            .replacement = replacement,
        };

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = try std.fmt.allocPrint(context.allocator, "Use '{s}'", .{replacement}),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        const message = try std.fmt.allocPrint(
            context.allocator,
            "comparing slice '{s}' to an empty slice with std.mem.eql; use '{s}'",
            .{ slice_text, replacement },
        );

        try context.emit(.{
            .rule = .prefer_empty_slice_len,
            .level = level,
            .span = .{
                .start = context.tokens[start_token].loc.start,
                .end = context.tokens[end_token].loc.end,
            },
            .message = message,
            .fixes = fixes,
        });
    }
}

const ArgumentRange = struct { start: usize, end: usize };

fn threeArguments(context: RuleRun, opening: usize, closing: usize) ?[3]ArgumentRange {
    var commas: [2]usize = undefined;
    var comma_count: usize = 0;
    var depth: usize = 0;
    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            if (comma_count == commas.len) return null;
            commas[comma_count] = index;
            comma_count += 1;
        },
        else => {},
    };
    if (comma_count != 2 or commas[0] == opening + 1 or commas[1] == commas[0] + 1 or commas[1] + 1 == closing) return null;
    return .{
        .{ .start = opening + 1, .end = commas[0] },
        .{ .start = commas[0] + 1, .end = commas[1] },
        .{ .start = commas[1] + 1, .end = closing },
    };
}

fn argumentSource(context: RuleRun, range: ArgumentRange) []const u8 {
    return std.mem.trim(
        u8,
        context.source[context.tokens[range.start].loc.start..context.tokens[range.end - 1].loc.end],
        " \t\r\n",
    );
}

fn isEmptySlice(context: RuleRun, range: ArgumentRange) bool {
    const src = argumentSource(context, range);
    return std.mem.eql(u8, src, "\"\"") or
        std.mem.eql(u8, src, ".{}") or
        std.mem.eql(u8, src, "&.{}") or
        std.mem.eql(u8, src, "&[_]u8{}");
}

fn needsParens(tokens: []const std.zig.Token, range: ArgumentRange) bool {
    for (tokens[range.start..range.end]) |tok| {
        switch (tok.tag) {
            .identifier, .period, .period_asterisk, .l_bracket, .r_bracket, .l_paren, .r_paren, .number_literal, .string_literal => {},
            else => return true,
        }
    }
    return false;
}

test "prefer empty slice len detects std.mem.eql with empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(name: []const u8, other: []const u8) bool {\n" ++
        "    if (std.mem.eql(u8, name, \"\")) return true;\n" ++
        "    if (!std.mem.eql(u8, name, \"\")) return false;\n" ++
        "    if (mem.eql(u8, \"\", other)) return true;\n" ++
        "    if (std.mem.eql(u8, other, &.{})) return true;\n" ++
        "    if (std.mem.eql(u8, name, \"\") == false) return false;\n" ++
        "    return false;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 5), findings.len);
    try std.testing.expectEqualStrings("name.len == 0", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("name.len != 0", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("other.len == 0", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("other.len == 0", findings[3].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("name.len != 0", findings[4].fixes[0].edits[0].replacement);
}

test "non-empty slice comparisons stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(name: []const u8, expected: []const u8) bool {\n" ++
        "    if (std.mem.eql(u8, name, expected)) return true;\n" ++
        "    if (std.mem.eql(u8, name, \"hello\")) return true;\n" ++
        "    return false;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer empty slice len honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(name: []const u8) bool {\n" ++
        "    // zig-analyzer: disable-next-line prefer-empty-slice-len\n" ++
        "    return std.mem.eql(u8, name, \"\");\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.prefer_empty_slice_len)] = .warning;
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
