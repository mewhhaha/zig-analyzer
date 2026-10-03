const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_split_scalar);
    if (level == .off) return;

    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or call_index + 1 >= context.tokens.len or
            context.tokens[call_index + 1].tag != .l_paren) continue;

        const func_name = context.tokenText(call_index);
        const SplitFunc = enum {
            splitSequence,
            splitAny,
            split,
            splitBackwardsSequence,
            splitBackwardsAny,
            splitBackwards,
            tokenizeSequence,
            tokenizeAny,
            tokenize,
        };
        const func = std.meta.stringToEnum(SplitFunc, func_name) orelse continue;
        const replacement_func: []const u8 = switch (func) {
            .splitSequence, .splitAny, .split => "splitScalar",
            .splitBackwardsSequence, .splitBackwardsAny, .splitBackwards => "splitBackwardsScalar",
            .tokenizeSequence, .tokenizeAny, .tokenize => "tokenizeScalar",
        };

        const is_std_mem = (call_index >= 4 and context.tokenIs(call_index - 4, "std") and
            context.tokens[call_index - 3].tag == .period and context.tokenIs(call_index - 2, "mem") and
            context.tokens[call_index - 1].tag == .period);
        const is_mem = (call_index >= 2 and context.tokenIs(call_index - 2, "mem") and
            context.tokens[call_index - 1].tag == .period);
        if (!is_std_mem and !is_mem) continue;

        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;
        const arguments = threeArguments(context, call_index + 1, call_end) orelse continue;

        if (arguments[2].end != arguments[2].start + 1) continue;
        const delimiter_token = context.tokens[arguments[2].start];
        if (delimiter_token.tag != .string_literal) continue;

        const delimiter_text = context.tokenText(arguments[2].start);
        const char_lit = parseSingleByteLiteral(context.allocator, delimiter_text) orelse continue;

        const edits = try context.allocator.alloc(types.Edit, 2);
        edits[0] = .{
            .span = token.loc,
            .replacement = replacement_func,
        };
        edits[1] = .{
            .span = delimiter_token.loc,
            .replacement = char_lit,
        };

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = try context.allocator.print("Use '{s}' with {s}", .{ replacement_func, char_lit }),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        const prefix = if (is_std_mem) "std.mem." else "mem.";
        const message = try context.allocator.print(
            "splitting by single character '{s}' using {s}{s}; use {s}{s} with {s}",
            .{ delimiter_text, prefix, func_name, prefix, replacement_func, char_lit },
        );

        try context.emit(.{
            .rule = .prefer_split_scalar,
            .level = level,
            .span = token.loc,
            .message = message,
            .fixes = fixes,
        });
    }
}

const ArgumentRange = struct { start: usize, end: usize };

fn threeArguments(context: RuleRun, opening: usize, closing: usize) ?[3]ArgumentRange {
    var commas: [3]usize = undefined;
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
    if (comma_count == 2) {
        if (commas[0] == opening + 1 or commas[1] == commas[0] + 1 or commas[1] + 1 == closing) return null;
        return .{
            .{ .start = opening + 1, .end = commas[0] },
            .{ .start = commas[0] + 1, .end = commas[1] },
            .{ .start = commas[1] + 1, .end = closing },
        };
    } else if (comma_count == 3 and commas[2] + 1 == closing) {
        if (commas[0] == opening + 1 or commas[1] == commas[0] + 1 or commas[2] == commas[1] + 1) return null;
        return .{
            .{ .start = opening + 1, .end = commas[0] },
            .{ .start = commas[0] + 1, .end = commas[1] },
            .{ .start = commas[1] + 1, .end = commas[2] },
        };
    }
    return null;
}

fn parseSingleByteLiteral(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (text.len < 3 or text[0] != '"' or text[text.len - 1] != '"') return null;
    const inner = text[1 .. text.len - 1];
    if (inner.len == 1) {
        if (inner[0] == '\\') return null;
        if (inner[0] == '\'') return allocator.dupe(u8, "'\\''") catch null;
        return allocator.print("'{c}'", .{inner[0]}) catch null;
    }
    if (inner.len == 2 and inner[0] == '\\') {
        switch (inner[1]) {
            'n', 'r', 't', '\\', '0' => return allocator.print("'\\{c}'", .{inner[1]}) catch null,
            '\'' => return allocator.dupe(u8, "'\\''") catch null,
            '"' => return allocator.dupe(u8, "'\"'") catch null,
            else => return null,
        }
    }
    if (inner.len == 4 and inner[0] == '\\' and inner[1] == 'x') {
        return allocator.print("'{s}'", .{inner}) catch null;
    }
    return null;
}

test "prefer split scalar detects single-character splitting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(input: []const u8) void {\n" ++
        "    var it1 = std.mem.splitSequence(u8, input, \",\");\n" ++
        "    _ = it1;\n" ++
        "    var it2 = std.mem.tokenizeSequence(u8, input, \" \");\n" ++
        "    _ = it2;\n" ++
        "    var it3 = mem.splitBackwardsSequence(u8, input, \"\\n\");\n" ++
        "    _ = it3;\n" ++
        "    var it4 = std.mem.tokenizeAny(u8, input, \":\");\n" ++
        "    _ = it4;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 4), findings.len);
    try std.testing.expectEqualStrings("splitScalar", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("','", findings[0].fixes[0].edits[1].replacement);
    try std.testing.expectEqualStrings("tokenizeScalar", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("' '", findings[1].fixes[0].edits[1].replacement);
    try std.testing.expectEqualStrings("splitBackwardsScalar", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("'\\n'", findings[2].fixes[0].edits[1].replacement);
    try std.testing.expectEqualStrings("tokenizeScalar", findings[3].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("':'", findings[3].fixes[0].edits[1].replacement);
}

test "multi-character or scalar splitting stays unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(input: []const u8) void {\n" ++
        "    var it1 = std.mem.splitSequence(u8, input, \"::\");\n" ++
        "    _ = it1;\n" ++
        "    var it2 = std.mem.splitScalar(u8, input, ',');\n" ++
        "    _ = it2;\n" ++
        "    var it3 = std.mem.tokenizeAny(u8, input, \" \\t\\r\\n\");\n" ++
        "    _ = it3;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer split scalar honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(input: []const u8) void {\n" ++
        "    // zig-analyzer: disable-next-line prefer-split-scalar\n" ++
        "    var it = std.mem.splitSequence(u8, input, \",\");\n" ++
        "    _ = it;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.prefer_split_scalar)] = .warning;
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
