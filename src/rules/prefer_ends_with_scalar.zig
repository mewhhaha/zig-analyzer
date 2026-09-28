const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_ends_with_scalar);
    if (level == .off) return;

    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or !context.tokenIs(call_index, "endsWith") or
            call_index + 1 >= context.tokens.len or context.tokens[call_index + 1].tag != .l_paren) continue;

        const is_std_mem = (call_index >= 4 and context.tokenIs(call_index - 4, "std") and
            context.tokens[call_index - 3].tag == .period and context.tokenIs(call_index - 2, "mem") and
            context.tokens[call_index - 1].tag == .period);
        const is_mem = (call_index >= 2 and context.tokenIs(call_index - 2, "mem") and
            context.tokens[call_index - 1].tag == .period);
        if (!is_std_mem and !is_mem) continue;

        const call_start = if (is_std_mem) call_index - 4 else call_index - 2;
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;

        const arguments = threeArguments(context, call_index + 1, call_end) orelse continue;

        // Check argument 3: needle must be a 1-character string literal
        if (arguments[2].end != arguments[2].start + 1) continue;
        const needle_token = context.tokens[arguments[2].start];
        if (needle_token.tag != .string_literal) continue;

        const needle_text = context.tokenText(arguments[2].start);
        const char_lit = parseSingleByteLiteral(context.allocator, needle_text) orelse continue;

        const haystack_source = std.mem.trim(
            u8,
            context.source[context.tokens[arguments[1].start].loc.start..context.tokens[arguments[1].end - 1].loc.end],
            " \t\r\n",
        );

        var fixes: []const types.Fix = &.{};
        if (isSimpleExpression(context, arguments[1].start, arguments[1].end)) {
            const replacement = try std.fmt.allocPrint(
                context.allocator,
                "{s}.len > 0 and {s}[{s}.len - 1] == {s}",
                .{ haystack_source, haystack_source, haystack_source, char_lit },
            );
            const edits = try context.allocator.alloc(types.Edit, 1);
            edits[0] = .{
                .span = .{
                    .start = context.tokens[call_start].loc.start,
                    .end = context.tokens[call_end].loc.end,
                },
                .replacement = replacement,
            };
            const fix_list = try context.allocator.alloc(types.Fix, 1);
            fix_list[0] = .{
                .title = try std.fmt.allocPrint(context.allocator, "Use byte indexing: {s}", .{replacement}),
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
                .fix_all = true,
            };
            fixes = fix_list;
        }

        try context.emit(.{
            .rule = .prefer_ends_with_scalar,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "'endsWith' with 1-byte needle {s} can be optimized to '{s}.len > 0 and {s}[{s}.len - 1] == {s}'",
                .{ needle_text, haystack_source, haystack_source, haystack_source, char_lit },
            ),
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

    if (comma_count != 2) return null;
    if (commas[0] == opening + 1 or commas[1] == commas[0] + 1 or commas[1] + 1 == closing) return null;

    return .{
        .{ .start = opening + 1, .end = commas[0] },
        .{ .start = commas[0] + 1, .end = commas[1] },
        .{ .start = commas[1] + 1, .end = closing },
    };
}

fn isSimpleExpression(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| {
        switch (token.tag) {
            .identifier, .period => {},
            else => return false,
        }
    }
    return true;
}

fn parseSingleByteLiteral(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (text.len < 3 or text[0] != '"' or text[text.len - 1] != '"') return null;
    const inner = text[1 .. text.len - 1];
    if (inner.len == 1) {
        if (inner[0] == '\\') return null;
        if (inner[0] == '\'') return allocator.dupe(u8, "'\\''") catch null;
        return std.fmt.allocPrint(allocator, "'{c}'", .{inner[0]}) catch null;
    }
    if (inner.len == 2 and inner[0] == '\\') {
        switch (inner[1]) {
            'n', 'r', 't', '\\', '0' => return std.fmt.allocPrint(allocator, "'\\{c}'", .{inner[1]}) catch null,
            '\'' => return allocator.dupe(u8, "'\\''") catch null,
            '"' => return allocator.dupe(u8, "'\"'") catch null,
            else => return null,
        }
    }
    if (inner.len == 4 and inner[0] == '\\' and inner[1] == 'x') {
        return std.fmt.allocPrint(allocator, "'{s}'", .{inner}) catch null;
    }
    return null;
}

test "prefer ends with scalar detects 1-character needle and offers quickfix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn isDirectory(path: []const u8) bool {
        \\    return std.mem.endsWith(u8, path, "/");
        \\}
    ;

    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = testConfiguration(),
        .findings = &findings,
    });

    try std.testing.expectEqual(1, findings.items.len);
    try std.testing.expectEqual(types.Rule.prefer_ends_with_scalar, findings.items[0].rule);
    try std.testing.expectEqual(1, findings.items[0].fixes.len);
    try std.testing.expectEqualStrings("path.len > 0 and path[path.len - 1] == '/'", findings.items[0].fixes[0].edits[0].replacement);
}

test "prefer ends with scalar ignores multi-character suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn isZig(path: []const u8) bool {
        \\    return std.mem.endsWith(u8, path, ".zig");
        \\}
    ;

    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = testConfiguration(),
        .findings = &findings,
    });

    try std.testing.expectEqual(0, findings.items.len);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokenizer = std.zig.Tokenizer.init(source);
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }
    return try tokens.toOwnedSlice(allocator);
}

fn testConfiguration() types.Configuration {
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_ends_with_scalar)] = .warning;
    return configuration;
}
