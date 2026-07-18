const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_multi_sequence_for);
    if (level == .off) return;

    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 11 >= context.tokens.len or
            context.tokens[for_index + 1].tag != .l_paren or context.tokens[for_index + 2].tag != .identifier or
            context.tokens[for_index + 3].tag != .comma or !context.tokenIs(for_index + 4, "0") or
            context.tokens[for_index + 5].tag != .ellipsis2 or context.tokens[for_index + 6].tag != .r_paren or
            context.tokens[for_index + 7].tag != .pipe or context.tokens[for_index + 8].tag != .identifier or
            context.tokens[for_index + 9].tag != .comma or context.tokens[for_index + 10].tag != .identifier or
            context.tokens[for_index + 11].tag != .pipe) continue;
        const first = context.tokenText(for_index + 2);
        const index_name = context.tokenText(for_index + 10);
        const body_start = for_index + 12;
        if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        const second = indexedSequence(context, body_start + 1, body_end, index_name) orelse continue;
        if (std.mem.eql(u8, first, second)) continue;
        if (!hasLengthAssertion(context, for_index, first, second)) continue;
        if (bindingUseCount(context, body_start + 1, body_end, index_name) != 1) continue;

        try context.emit(.{
            .rule = .prefer_multi_sequence_for,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "'{s}' is indexed only to pair it with '{s}', whose equal length is asserted; iterate both sequences in the for loop",
                .{ second, first },
            ),
        });
    }
}

fn indexedSequence(context: RuleRun, start: usize, end: usize, index_name: []const u8) ?[]const u8 {
    var sequence: ?[]const u8 = null;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 3 >= end or context.tokens[index + 1].tag != .l_bracket or
            !context.tokenIs(index + 2, index_name) or context.tokens[index + 3].tag != .r_bracket) continue;
        if (sequence != null and !std.mem.eql(u8, sequence.?, context.tokenText(index))) return null;
        sequence = context.tokenText(index);
    }
    return sequence;
}

fn bindingUseCount(context: RuleRun, start: usize, end: usize, name: []const u8) usize {
    var count: usize = 0;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.refersToBinding(index, name)) count += 1;
    }
    return count;
}

fn hasLengthAssertion(context: RuleRun, before: usize, first: []const u8, second: []const u8) bool {
    for (context.tokens[0..before], 0..) |token, assert_index| {
        if (token.tag != .identifier or !context.tokenIs(assert_index, "assert") or assert_index < 4 or
            assert_index + 10 >= before or !context.tokenIs(assert_index - 4, "std") or
            context.tokens[assert_index - 3].tag != .period or !context.tokenIs(assert_index - 2, "debug") or
            context.tokens[assert_index - 1].tag != .period or context.tokens[assert_index + 1].tag != .l_paren or
            context.tokens[assert_index + 3].tag != .period or !context.tokenIs(assert_index + 4, "len") or
            context.tokens[assert_index + 5].tag != .equal_equal or context.tokens[assert_index + 7].tag != .period or
            !context.tokenIs(assert_index + 8, "len") or context.tokens[assert_index + 9].tag != .r_paren or
            context.tokens[assert_index + 10].tag != .semicolon or assert_index + 11 != before) continue;
        const left = context.tokenText(assert_index + 2);
        const right = context.tokenText(assert_index + 6);
        if (std.mem.eql(u8, left, first) and std.mem.eql(u8, right, second) or
            std.mem.eql(u8, left, second) and std.mem.eql(u8, right, first)) return true;
    }
    return false;
}

test "an index used only for an equal-length sequence prefers a multi-sequence for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "std.debug.assert(names.len == values.len);\n" ++
        "for (names, 0..) |name, index| { use(name, values[index]); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "unproven lengths and meaningful indices stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "for (names, 0..) |name, index| { use(name, values[index]); }\n" ++
        "std.debug.assert(left.len == right.len); for (left, 0..) |value, index| { use(value, right[index], index); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "multi-sequence for preference respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "std.debug.assert(names.len == values.len);\n" ++
        "// zig-analyzer: disable-next-line prefer-multi-sequence-for\n" ++
        "for (names, 0..) |name, index| { use(name, values[index]); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_multi_sequence_for)] = .information;
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
