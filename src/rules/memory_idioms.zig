const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findIndexOfPrefixTests(context);
    try findGuardedSuffixTests(context);
    try findScalarCounts(context);
    try findScalarReplacements(context);
    try findBooleanSearches(context);
}

fn findIndexOfPrefixTests(context: RuleRun) !void {
    const level = context.level(.prefer_starts_with);
    if (level == .off) return;
    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or !context.tokenIs(call_index, "indexOf") or call_index < 4 or
            call_index + 1 >= context.tokens.len or
            !context.tokenIs(call_index - 4, "std") or !context.tokenIs(call_index - 2, "mem") or
            context.tokens[call_index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end + 2 >= context.tokens.len or context.tokens[call_end + 1].tag != .equal_equal or
            !context.tokenIs(call_end + 2, "0")) continue;
        const arguments = threeArguments(context, call_index + 1, call_end) orelse continue;
        const haystack = argumentSource(context, arguments[1]);
        const needle = argumentSource(context, arguments[2]);
        try context.emit(.{
            .rule = .prefer_starts_with,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "indexOf checks whether '{s}' occurs at offset zero in '{s}'; use std.mem.startsWith",
                .{ needle, haystack },
            ),
        });
    }
}

fn findGuardedSuffixTests(context: RuleRun) !void {
    const level = context.level(.prefer_ends_with);
    if (level == .off) return;
    for (context.tokens, 0..) |token, eql_index| {
        if (token.tag != .identifier or !context.tokenIs(eql_index, "eql") or eql_index < 12 or
            eql_index + 1 >= context.tokens.len or
            !context.tokenIs(eql_index - 4, "std") or !context.tokenIs(eql_index - 2, "mem") or
            context.tokens[eql_index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(eql_index + 1, .l_paren, .r_paren) orelse continue;
        const arguments = threeArguments(context, eql_index + 1, call_end) orelse continue;
        const haystack = suffixSliceBase(context, arguments[1], arguments[2]) orelse continue;
        const needle = argumentSource(context, arguments[2]);
        if (!lengthGuard(context, eql_index - 5, haystack, needle)) continue;
        try context.emit(.{
            .rule = .prefer_ends_with,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "guarded tail comparison checks whether '{s}' ends with '{s}'; use std.mem.endsWith",
                .{ haystack, needle },
            ),
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

fn suffixSliceBase(context: RuleRun, slice: ArgumentRange, needle: ArgumentRange) ?[]const u8 {
    if (needle.start + 1 != needle.end or context.tokens[needle.start].tag != .identifier) return null;
    if (slice.end != slice.start + 11 or context.tokens[slice.start].tag != .identifier or
        context.tokens[slice.start + 1].tag != .l_bracket or
        !context.tokenIs(slice.start + 2, context.tokenText(slice.start)) or
        context.tokens[slice.start + 3].tag != .period or !context.tokenIs(slice.start + 4, "len") or
        context.tokens[slice.start + 5].tag != .minus or
        !context.tokenIs(slice.start + 6, context.tokenText(needle.start)) or
        context.tokens[slice.start + 7].tag != .period or !context.tokenIs(slice.start + 8, "len") or
        context.tokens[slice.start + 9].tag != .ellipsis2 or context.tokens[slice.start + 10].tag != .r_bracket) return null;
    return context.tokenText(slice.start);
}

fn lengthGuard(context: RuleRun, and_index: usize, haystack: []const u8, needle: []const u8) bool {
    if (and_index < 7 or context.tokens[and_index].tag != .keyword_and) return false;
    return context.tokenIs(and_index - 7, haystack) and context.tokens[and_index - 6].tag == .period and
        context.tokenIs(and_index - 5, "len") and context.tokens[and_index - 4].tag == .angle_bracket_right_equal and
        context.tokenIs(and_index - 3, needle) and context.tokens[and_index - 2].tag == .period and
        context.tokenIs(and_index - 1, "len");
}

fn findScalarCounts(context: RuleRun) !void {
    const level = context.level(.prefer_count_scalar);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end < declaration_index + 3 or !context.tokenIs(declaration_end - 1, "0") or
            context.tokens[declaration_end - 2].tag != .equal) continue;
        const count_name = context.tokenText(declaration_index + 1);
        const for_index = declaration_end + 1;
        const loop = singleCaptureLoop(context, for_index) orelse continue;
        if (!loopOnlyCountsMatch(context, loop, count_name)) continue;
        try context.emit(.{
            .rule = .prefer_count_scalar,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "'{s}' only counts matching elements in '{s}'; use std.mem.countScalar",
                .{ count_name, loop.iterable },
            ),
        });
    }
}

const SingleCaptureLoop = struct {
    iterable: []const u8,
    capture: []const u8,
    body_start: usize,
    body_end: usize,
};

fn singleCaptureLoop(context: RuleRun, for_index: usize) ?SingleCaptureLoop {
    if (for_index + 6 >= context.tokens.len or context.tokens[for_index].tag != .keyword_for or
        context.tokens[for_index + 1].tag != .l_paren) return null;
    const iterable_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse return null;
    if (iterable_end + 4 >= context.tokens.len) return null;
    if (iterable_end != for_index + 3 or context.tokens[for_index + 2].tag != .identifier or
        context.tokens[iterable_end + 1].tag != .pipe or context.tokens[iterable_end + 2].tag != .identifier or
        context.tokens[iterable_end + 3].tag != .pipe or context.tokens[iterable_end + 4].tag != .l_brace) return null;
    const body_end = context.matchingToken(iterable_end + 4, .l_brace, .r_brace) orelse return null;
    return .{
        .iterable = context.tokenText(for_index + 2),
        .capture = context.tokenText(iterable_end + 2),
        .body_start = iterable_end + 4,
        .body_end = body_end,
    };
}

fn loopOnlyCountsMatch(context: RuleRun, loop: SingleCaptureLoop, count_name: []const u8) bool {
    const if_index = loop.body_start + 1;
    if (if_index + 6 >= loop.body_end or context.tokens[if_index].tag != .keyword_if or
        context.tokens[if_index + 1].tag != .l_paren) return false;
    const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse return false;
    if (condition_end != if_index + 5 or context.tokens[if_index + 3].tag != .equal_equal or
        (!context.tokenIs(if_index + 2, loop.capture) and !context.tokenIs(if_index + 4, loop.capture))) return false;
    const left_is_capture = context.tokenIs(if_index + 2, loop.capture);
    const right_is_capture = context.tokenIs(if_index + 4, loop.capture);
    if (left_is_capture == right_is_capture) return false;
    const scalar_index = if (left_is_capture) if_index + 4 else if_index + 2;
    if (!simpleScalar(context.tokens[scalar_index].tag) or context.tokenIs(scalar_index, count_name)) return false;
    const body_start = condition_end + 1;
    if (body_start + 6 != loop.body_end or context.tokens[body_start].tag != .l_brace or
        !context.tokenIs(body_start + 1, count_name) or context.tokens[body_start + 2].tag != .plus_equal or
        !context.tokenIs(body_start + 3, "1") or context.tokens[body_start + 4].tag != .semicolon or
        context.tokens[body_start + 5].tag != .r_brace) return false;
    return true;
}

fn findScalarReplacements(context: RuleRun) !void {
    const level = context.level(.prefer_replace_scalar);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 8 >= context.tokens.len or
            context.tokens[for_index + 1].tag != .l_paren) continue;
        const iterable_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (iterable_end + 5 >= context.tokens.len) continue;
        if (iterable_end != for_index + 3 or context.tokens[for_index + 2].tag != .identifier or
            context.tokens[iterable_end + 1].tag != .pipe or context.tokens[iterable_end + 2].tag != .asterisk or
            context.tokens[iterable_end + 3].tag != .identifier or context.tokens[iterable_end + 4].tag != .pipe or
            context.tokens[iterable_end + 5].tag != .l_brace) continue;
        const body_end = context.matchingToken(iterable_end + 5, .l_brace, .r_brace) orelse continue;
        const element = context.tokenText(iterable_end + 3);
        if (!loopOnlyReplacesMatch(context, iterable_end + 5, body_end, element)) continue;
        try context.emit(.{
            .rule = .prefer_replace_scalar,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "loop only replaces matching elements in '{s}'; use std.mem.replaceScalar",
                .{context.tokenText(for_index + 2)},
            ),
        });
    }
}

fn loopOnlyReplacesMatch(context: RuleRun, opening: usize, closing: usize, element: []const u8) bool {
    const if_index = opening + 1;
    if (if_index + 7 >= closing or context.tokens[if_index].tag != .keyword_if or
        context.tokens[if_index + 1].tag != .l_paren) return false;
    const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse return false;
    if (condition_end != if_index + 6 or !context.tokenIs(if_index + 2, element) or
        context.tokens[if_index + 3].tag != .period_asterisk or context.tokens[if_index + 4].tag != .equal_equal) return false;
    const body_start = condition_end + 1;
    if (body_start + 7 != closing or context.tokens[body_start].tag != .l_brace or
        !context.tokenIs(body_start + 1, element) or context.tokens[body_start + 2].tag != .period_asterisk or
        context.tokens[body_start + 3].tag != .equal or context.tokens[body_start + 5].tag != .semicolon or
        context.tokens[body_start + 6].tag != .r_brace) return false;
    return simpleScalar(context.tokens[if_index + 5].tag) and simpleScalar(context.tokens[body_start + 4].tag);
}

fn simpleScalar(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .identifier, .number_literal, .char_literal => true,
        else => false,
    };
}

fn findBooleanSearches(context: RuleRun) !void {
    const level = context.level(.prefer_index_of);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for) continue;
        const loop = singleCaptureLoop(context, for_index) orelse continue;
        if (!loopOnlyReturnsTrueForMatch(context, loop)) continue;
        const fallback = loop.body_end + 1;
        if (fallback + 2 >= context.tokens.len or context.tokens[fallback].tag != .keyword_return or
            !context.tokenIs(fallback + 1, "false") or context.tokens[fallback + 2].tag != .semicolon) continue;
        try context.emit(.{
            .rule = .prefer_index_of,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "boolean linear search over '{s}' can use std.mem.indexOfScalar or std.mem.indexOf",
                .{loop.iterable},
            ),
        });
    }
}

fn loopOnlyReturnsTrueForMatch(context: RuleRun, loop: SingleCaptureLoop) bool {
    const if_index = loop.body_start + 1;
    if (if_index + 9 != loop.body_end or context.tokens[if_index].tag != .keyword_if or
        context.tokens[if_index + 1].tag != .l_paren or context.tokens[if_index + 3].tag != .equal_equal or
        (!context.tokenIs(if_index + 2, loop.capture) and !context.tokenIs(if_index + 4, loop.capture)) or
        context.tokens[if_index + 5].tag != .r_paren or context.tokens[if_index + 6].tag != .keyword_return or
        !context.tokenIs(if_index + 7, "true") or context.tokens[if_index + 8].tag != .semicolon) return false;
    const left_is_capture = context.tokenIs(if_index + 2, loop.capture);
    const right_is_capture = context.tokenIs(if_index + 4, loop.capture);
    if (left_is_capture == right_is_capture) return false;
    const scalar_index = if (left_is_capture) if_index + 4 else if_index + 2;
    if (!simpleScalar(context.tokens[scalar_index].tag)) return false;
    return true;
}

test "indexOf at zero prefers startsWith" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "const prefixed = std.mem.indexOf(u8, text, prefix) == 0;",
        .prefer_starts_with,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "guarded tail equality prefers endsWith" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "const suffixed = text.len >= suffix.len and std.mem.eql(u8, text[text.len - suffix.len..], suffix);",
        .prefer_ends_with,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "manual scalar counts prefer countScalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "var count: usize = 0; for (values) |value| { if (value == needle) { count += 1; } } use(count);",
        .prefer_count_scalar,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "manual scalar replacements prefer replaceScalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "for (values) |*value| { if (value.* == old) { value.* = replacement; } }",
        .prefer_replace_scalar,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "boolean scalar searches extend prefer indexOf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "for (values) |value| { if (value == needle) return true; } return false;",
        .prefer_index_of,
    );
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "nearby memory patterns without their proof stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const anywhere = std.mem.indexOf(u8, text, prefix) != null;\n" ++
        "const unsafe_tail = std.mem.eql(u8, text[text.len - suffix.len..], suffix);\n" ++
        "for (values) |*value| { if (value.* == old) inspect(value.*); }";
    for ([_]types.Rule{ .prefer_starts_with, .prefer_ends_with, .prefer_replace_scalar }) |rule| {
        const findings = try findingsFor(arena.allocator(), source, rule);
        try std.testing.expectEqual(@as(usize, 0), findings.len);
    }
}

test "memory idioms respect source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try findingsFor(
        arena.allocator(),
        "// zig-analyzer: disable-next-line prefer-starts-with\nconst prefixed = std.mem.indexOf(u8, text, prefix) == 0;",
        .prefer_starts_with,
    );
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8, rule: types.Rule) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(rule)] = .information;
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
