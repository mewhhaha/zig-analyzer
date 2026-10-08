//! Computed indexing in a function with no visible bound: no assertion, dominating loop condition, unreachable arm, or early-exit validation.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const topLevelComma = @import("../../syntax/tokens.zig").topLevelComma;
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;
const lineSpan = @import("../../syntax/tokens.zig").lineSpan;

pub const rules = [_]types.Rule{.assertion_free_branching};

pub fn run(context: RuleRun) !void {
    const level = context.level(.assertion_free_branching);
    if (level == .off) return;
    for (context.tokens, 0..) |token, fn_index| {
        if (!context.isNamedFunction(fn_index)) continue;
        const body_open = nextTagBefore(context.tokens, fn_index + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (lineSpan(context.source, token.loc.start, context.tokens[body_end].loc.end) < 9) continue;
        if (hasInvariantCheck(context, body_open + 1, body_end)) continue;
        const bracket = computedBracket(context, body_open + 1, body_end) orelse continue;
        if (hasDominatingWhileBound(context, bracket) or hasDominatingForBound(context, bracket)) continue;
        try context.emit(.{
            .rule = .assertion_free_branching,
            .level = level,
            .span = context.tokens[bracket].loc,
            .message = "computed indexing has no visible assertion, loop bound, unreachable arm, or early-exit validation stating its bounds",
        });
    }
}

fn computedBracket(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .l_bracket or index == 0 or index + 2 >= end or
            !canEndIndexedExpression(context.tokens[index - 1].tag) or
            insideNestedFunction(context, start, index)) continue;
        if (context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .r_bracket) return index;
        if (context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .ellipsis2) return index;
    }
    return null;
}

fn hasDominatingForBound(context: RuleRun, bracket: usize) bool {
    if (bracket + 2 >= context.tokens.len or context.tokens[bracket + 1].tag != .identifier or
        context.tokens[bracket + 2].tag != .r_bracket) return false;

    const indexed_sequence_start = context.pathStartBefore(bracket) orelse return false;
    for (context.tokens[0..bracket], 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 8 >= bracket or
            context.tokens[for_index + 1].tag != .l_paren) continue;
        const range_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (range_end + 4 < bracket and range_end >= for_index + 7 and
            context.tokenIs(for_index + 2, "0") and context.tokens[for_index + 3].tag == .ellipsis2 and
            context.tokens[range_end - 2].tag == .period and context.tokenIs(range_end - 1, "len") and
            context.tokens[range_end + 1].tag == .pipe and context.tokens[range_end + 2].tag == .identifier and
            context.tokenIs(range_end + 2, context.tokenText(bracket + 1)) and
            context.tokens[range_end + 3].tag == .pipe and context.tokens[range_end + 4].tag == .l_brace)
        {
            if (context.dottedPathsEqual(for_index + 4, range_end - 2, indexed_sequence_start, bracket)) {
                const loop_end = context.matchingToken(range_end + 4, .l_brace, .r_brace) orelse continue;
                if (bracket < loop_end and !mayMutateBeforeIndex(context, range_end + 5, indexed_sequence_start)) return true;
            }
        }

        if (range_end + 6 >= bracket or context.tokens[range_end + 1].tag != .pipe or
            context.tokens[range_end + 2].tag != .identifier or context.tokens[range_end + 3].tag != .comma or
            context.tokens[range_end + 4].tag != .identifier or
            !context.tokenIs(range_end + 4, context.tokenText(bracket + 1)) or
            context.tokens[range_end + 5].tag != .pipe or context.tokens[range_end + 6].tag != .l_brace) continue;
        const comma = topLevelComma(context.tokens, for_index + 2, range_end) orelse continue;
        if (comma + 3 != range_end or !context.tokenIs(comma + 1, "0") or context.tokens[comma + 2].tag != .ellipsis2) continue;
        const same_sequence = context.dottedPathsEqual(for_index + 2, comma, indexed_sequence_start, bracket);
        if (!same_sequence and !arrayLengthMatchesPath(context, indexed_sequence_start, bracket, for_index + 2, comma, for_index)) continue;

        const loop_end = context.matchingToken(range_end + 6, .l_brace, .r_brace) orelse continue;
        if (bracket < loop_end and !mayMutateBeforeIndex(context, range_end + 7, indexed_sequence_start)) return true;
    }
    return false;
}

fn hasDominatingWhileBound(context: RuleRun, bracket: usize) bool {
    if (bracket + 2 >= context.tokens.len or context.tokens[bracket + 1].tag != .identifier or
        context.tokens[bracket + 2].tag != .r_bracket) return false;

    const indexed_sequence_start = context.pathStartBefore(bracket) orelse return false;

    for (context.tokens[0..bracket], 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 4 >= bracket or
            context.tokens[while_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end + 1 >= bracket or context.tokens[while_index + 2].tag != .identifier or
            !context.tokenIs(while_index + 2, context.tokenText(bracket + 1)) or
            context.tokens[while_index + 3].tag != .angle_bracket_left) continue;
        const bound_matches = if (condition_end >= while_index + 7 and
            context.tokens[condition_end - 2].tag == .period and context.tokenIs(condition_end - 1, "len"))
            context.dottedPathsEqual(while_index + 4, condition_end - 2, indexed_sequence_start, bracket)
        else if (condition_end == while_index + 5 and context.tokens[condition_end - 1].tag == .number_literal)
            fixedArrayLengthMatches(context, indexed_sequence_start, bracket, condition_end - 1, while_index)
        else
            false;
        if (!bound_matches) continue;

        const loop_body = nextTagBefore(context.tokens, condition_end + 1, .l_brace, .semicolon) orelse continue;
        const loop_end = context.matchingToken(loop_body, .l_brace, .r_brace) orelse continue;
        if (bracket <= loop_body or bracket >= loop_end or mayMutateBeforeIndex(context, loop_body + 1, indexed_sequence_start)) continue;
        return true;
    }
    return false;
}

fn hasInvariantCheck(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_unreachable) return true;
        if (token.tag == .identifier and context.tokenIs(index, "assert") and index + 1 < end and context.tokens[index + 1].tag == .l_paren) return true;
        if (token.tag == .keyword_if and index + 1 < end) {
            const limited_end = @min(end, index + 20);
            for (context.tokens[index + 1 .. limited_end]) |guard_token| switch (guard_token.tag) {
                .keyword_return, .keyword_break, .keyword_continue => return true,
                else => {},
            };
        }
    }
    return false;
}

fn canEndIndexedExpression(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .identifier, .string_literal, .r_paren, .r_bracket, .r_brace => true,
        else => false,
    };
}

fn insideNestedFunction(context: RuleRun, start: usize, index: usize) bool {
    for (context.tokens[start..index], start..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const body_open = nextTagBefore(context.tokens, function_index + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (body_open < index and index < body_end) return true;
    }
    return false;
}

fn arrayLengthMatchesPath(
    context: RuleRun,
    array_start: usize,
    array_end: usize,
    path_start: usize,
    path_end: usize,
    before: usize,
) bool {
    if (array_end != array_start + 1) return false;
    const path_length = path_end - path_start;
    for (context.tokens[0..before], 0..) |token, declaration| {
        if ((token.tag != .keyword_var and token.tag != .keyword_const) or declaration + 3 >= before or
            !context.tokenIs(declaration + 1, context.tokenText(array_start))) continue;
        if (declaration + path_length + 7 < before and context.tokens[declaration + 2].tag == .colon and
            context.tokens[declaration + 3].tag == .l_bracket and
            context.dottedPathsEqual(declaration + 4, declaration + 4 + path_length, path_start, path_end))
        {
            const suffix = declaration + 4 + path_length;
            if (context.tokens[suffix].tag == .period and context.tokenIs(suffix + 1, "len") and
                context.tokens[suffix + 2].tag == .r_bracket) return true;
        }
        const declaration_end = context.statementEnd(declaration) orelse continue;
        if (declaration_end >= before) continue;
        for (context.tokens[declaration + 2 .. declaration_end], declaration + 2..) |candidate, method_index| {
            if (candidate.tag != .identifier or !context.tokenIs(method_index, "alloc") or
                method_index + 1 >= declaration_end or context.tokens[method_index + 1].tag != .l_paren) continue;
            const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
            if (call_end > declaration_end or call_end < method_index + 5 or
                context.tokens[call_end - 2].tag != .period or !context.tokenIs(call_end - 1, "len")) continue;
            const comma = topLevelComma(context.tokens, method_index + 2, call_end) orelse continue;
            if (context.dottedPathsEqual(comma + 1, call_end - 2, path_start, path_end)) return true;
        }
    }
    return false;
}

fn mayMutateBeforeIndex(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal, .percent_equal, .semicolon => return true,
            .identifier, .builtin => if (index + 1 < end and context.tokens[index + 1].tag == .l_paren) {
                const call_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse return true;
                if (call_end < end) return true;
            },
            else => {},
        }
    }
    return false;
}

fn fixedArrayLengthMatches(
    context: RuleRun,
    array_start: usize,
    array_end: usize,
    length_index: usize,
    before: usize,
) bool {
    if (array_end != array_start + 1) return false;
    var matching_length = false;
    for (context.tokens[0..before], 0..) |token, declaration| {
        if ((token.tag != .keyword_var and token.tag != .keyword_const) or declaration + 1 >= before or
            !context.tokenIs(declaration + 1, context.tokenText(array_start))) continue;
        matching_length = declaration + 5 < before and context.tokens[declaration + 2].tag == .colon and
            context.tokens[declaration + 3].tag == .l_bracket and context.tokens[declaration + 4].tag == .number_literal and
            context.tokens[declaration + 5].tag == .r_bracket and
            std.mem.eql(u8, context.tokenText(declaration + 4), context.tokenText(length_index));
    }
    return matching_length;
}

test "a matching while condition establishes the bound for its first indexed access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn removeValue(values: *Values, target: u8) void {\n" ++
        "var index: usize = 0;\n" ++
        "while (index < values.items.len) {\n" ++
        "if (values.items[index] == target) {\n" ++
        "_ = values.swapRemove(index);\n" ++
        "continue;\n" ++
        "}\n" ++
        "index += 1;\n" ++
        "}\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a matching while bound remains visible inside a borrowing call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn remove(catalog: *Catalog, path: []const u8) void {\n" ++
        "var index: usize = 0;\n" ++
        "while (index < catalog.items.len) : (index += 1) {\n" ++
        "if (std.mem.eql(u8, catalog.items[index].path, path)) return;\n" ++
        "}\n" ++
        "_ = one; _ = two; _ = three;\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a fixed array length establishes a literal while bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn printSelected(writer: *Writer) !void {\n" ++
        "const selected: [3]bool = .{ true, false, true };\n" ++
        "var index: usize = 0;\n" ++
        "while (index < 3) : (index += 1) {\n" ++
        "if (selected[index]) try writer.print(\"{d}\", .{index});\n" ++
        "}\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a shadowed slice does not inherit an outer fixed array bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn printSelected(writer: *Writer, dynamic: []const bool) !void {\n" ++
        "const selected: [3]bool = .{ true, false, true };\n" ++
        "{\n" ++
        "const selected = dynamic;\n" ++
        "var index: usize = 0;\n" ++
        "while (index < 3) : (index += 1) {\n" ++
        "if (selected[index]) try writer.print(\"{d}\", .{index});\n" ++
        "}\n" ++
        "}\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "a matching for range establishes the bound for its indexed access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn clear(values: []u8) void {\n" ++
        "for (0..values.len) |index| {\n" ++
        "if (values[index] != 0) {\n" ++
        "values[index] = 0;\n" ++
        "}\n" ++
        "}\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an index capture establishes the bound for an equally sized array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn names(comptime fields: []const Field) [fields.len][]const u8 {\n" ++
        "var result: [fields.len][]const u8 = undefined;\n" ++
        "for (fields, 0..) |field, index| {\n" ++
        "result[index] = field.name;\n" ++
        "}\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "return result;\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an allocation sized from the iterated slice establishes its index bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn clone(allocator: std.mem.Allocator, source: []const Note) ![]Note {\n" ++
        "const copy = try allocator.alloc(Note, source.len);\n" ++
        "for (source, 0..) |note, index| copy[index] = note;\n" ++
        "_ = one; _ = two; _ = three;\n" ++
        "return copy;\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an early loop exit establishes the bound for following indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn findStop(values: []const u8) ?u8 {\n" ++
        "for (values, 0..) |value, index| {\n" ++
        "_ = value;\n" ++
        "if (index + 1 >= values.len) break;\n" ++
        "if (values[index + 1] == 0) return value;\n" ++
        "}\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "return null;\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an unrelated or invalidated loop bound does not establish index safety" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn read(values: *Values, others: []u8, index: usize) u8 {\n" ++
        "while (index < others.len) {\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "_ = four;\n" ++
        "return values.items[index];\n" ++
        "}\n" ++
        "return 0;\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "array types are not computed indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn FixedBuffer(comptime capacity: usize) type {\n" ++
        "return struct {\n" ++
        "bytes: [capacity]u8,\n" ++
        "const Self = @This();\n" ++
        "fn clear(self: *Self) void {\n" ++
        "self.bytes = @splat(0);\n" ++
        "}\n" ++
        "};\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "nested function indexing is reported once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn Container() type {\n" ++
        "return struct {\n" ++
        "fn read(values: []u8, index: usize) u8 {\n" ++
        "_ = one;\n" ++
        "_ = two;\n" ++
        "_ = three;\n" ++
        "_ = four;\n" ++
        "_ = five;\n" ++
        "_ = six;\n" ++
        "_ = seven;\n" ++
        "return values[index];\n" ++
        "}\n" ++
        "};\n" ++
        "}\n";
    const configuration = support.only(&.{.assertion_free_branching}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "unchecked computed indexing reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn inspect(buffer: []u8, index: usize) u8 {\n" ++
        "const one = 1;\nconst two = 2;\nconst three = 3;\nconst four = 4;\n" ++
        "const five = 5;\nconst six = 6;\nconst seven = 7;\n_ = one + two + three + four + five + six + seven;\n" ++
        "return buffer[index];\n}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.assertion_free_branching}, .information));
    try support.expectRules(found, &.{.assertion_free_branching});
}
