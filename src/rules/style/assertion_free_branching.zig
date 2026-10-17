//! Computed indexing in a function with no visible bound: no assertion, dominating loop condition, unreachable arm, or early-exit validation.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const topLevelComma = @import("../../syntax/tokens.zig").topLevelComma;
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;
const lineSpan = @import("../../syntax/tokens.zig").lineSpan;
const syntax_scope = @import("../../syntax/scope.zig");

pub const rules = [_]types.Rule{.assertion_free_branching};

pub fn run(context: RuleRun) !void {
    const level = context.level(.assertion_free_branching);
    if (level == .off) return;
    var test_only: ?syntax_scope.TestOnlyBodies = null;
    defer if (test_only) |*bodies| bodies.deinit(context.allocator);
    for (context.tokens, 0..) |token, fn_index| {
        if (!context.isNamedFunction(fn_index) or context.scopes.insideTestBlock(fn_index)) continue;
        const body_open = nextTagBefore(context.tokens, fn_index + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (lineSpan(context.source, token.loc.start, context.tokens[body_end].loc.end) < 9) continue;
        if (hasInvariantCheck(context, body_open + 1, body_end)) continue;
        const bracket = computedBracket(context, body_open + 1, body_end) orelse continue;
        if (hasDominatingWhileBound(context, body_open, bracket) or hasCaptureBound(context, bracket) or
            hasLengthComparison(context, body_open, bracket)) continue;
        if (test_only == null) test_only = try syntax_scope.testOnlyBodies(context.allocator, context.source, context.tokens);
        if (test_only.?.contains(body_open)) continue;
        try context.emit(.{
            .rule = .assertion_free_branching,
            .level = level,
            .span = context.tokens[bracket].loc,
            .message = "computed indexing has no visible assertion, loop bound, unreachable arm, or early-exit validation stating its bounds",
        });
    }
}

/// The first `sequence[index]` or `sequence[index..]` whose bound the
/// compiler does not check itself: indexing in `comptime` code and by an
/// `inline for` capture is evaluated at compile time.
fn computedBracket(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .l_bracket or index == 0 or index + 2 >= end or
            !canEndIndexedExpression(context.tokens[index - 1].tag) or
            context.tokens[index + 1].tag != .identifier or
            (context.tokens[index + 2].tag != .r_bracket and context.tokens[index + 2].tag != .ellipsis2) or
            insideNestedFunction(context, start, index)) continue;
        if (insideComptime(context, start, index)) continue;
        if (forCapture(context, index + 1)) |capture| if (capture.inline_loop) continue;
        return index;
    }
    return null;
}

/// Whether a block between `start` and `index` is a `comptime` block.
fn insideComptime(context: RuleRun, start: usize, index: usize) bool {
    var brace = context.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening < start) return false;
        if (opening >= 1 and context.tokens[opening - 1].tag == .keyword_comptime) return true;
        if (opening >= 3 and context.tokens[opening - 1].tag == .colon and context.tokens[opening - 2].tag == .identifier and
            context.tokens[opening - 3].tag == .keyword_comptime) return true;
    }
    return false;
}

/// The `for` loop whose capture list declares the identifier `use` refers to.
const ForCapture = struct {
    /// The `(` and `)` around the loop's operands.
    operands_open: usize,
    operands_close: usize,
    /// The capture's position in the capture list, which is the position of
    /// the operand it iterates.
    position: usize,
    /// The first token after the capture list.
    body: usize,
    inline_loop: bool,
};

fn forCapture(context: RuleRun, use: usize) ?ForCapture {
    const binding = context.scopes.findBinding(use) orelse return null;
    const capture = binding.token_index;
    var position: usize = 0;
    var opening = capture;
    while (opening > 0) {
        opening -= 1;
        switch (context.tokens[opening].tag) {
            .pipe => break,
            .comma => position += 1,
            .identifier, .asterisk => {},
            else => return null,
        }
    } else return null;
    if (opening == 0 or context.tokens[opening - 1].tag != .r_paren) return null;
    const operands_close = opening - 1;
    const operands_open = context.scopes.matchingToken(operands_close) orelse return null;
    if (operands_open == 0 or context.tokens[operands_open - 1].tag != .keyword_for) return null;
    var closing = capture + 1;
    while (closing < context.tokens.len and context.tokens[closing].tag != .pipe) : (closing += 1) {}
    if (closing + 1 >= context.tokens.len) return null;
    return .{
        .operands_open = operands_open,
        .operands_close = operands_close,
        .position = position,
        .body = closing + 1,
        .inline_loop = operands_open >= 2 and context.tokens[operands_open - 2].tag == .keyword_inline,
    };
}

/// Whether the index is the capture of a `for` loop that ranges up to the
/// indexed sequence's length (`for (start..items.len) |index|`) or counts the
/// elements of that sequence or of an array its length sizes
/// (`for (items, 0..) |item, index|`).
fn hasCaptureBound(context: RuleRun, bracket: usize) bool {
    if (context.tokens[bracket + 2].tag != .r_bracket) return false;
    const indexed_sequence_start = context.pathStartBefore(bracket) orelse return false;
    const capture = forCapture(context, bracket + 1) orelse return false;
    const operand = operandAt(context, capture.operands_open, capture.operands_close, capture.position) orelse return false;
    const ellipsis = rangeEllipsis(context, operand) orelse return false;
    if (ellipsis + 1 < operand.end) {
        // 'start..sequence.len'
        if (operand.end < ellipsis + 4 or context.tokens[operand.end - 2].tag != .period or !context.tokenIs(operand.end - 1, "len") or
            !context.dottedPathsEqual(ellipsis + 1, operand.end - 2, indexed_sequence_start, bracket)) return false;
    } else {
        // A counter from zero beside the sequence it counts.
        if (ellipsis != operand.start + 1 or !context.tokenIs(operand.start, "0")) return false;
        var counted = false;
        var position: usize = 0;
        while (operandAt(context, capture.operands_open, capture.operands_close, position)) |other| : (position += 1) {
            if (position == capture.position or rangeEllipsis(context, other) != null) continue;
            if (context.dottedPathsEqual(other.start, other.end, indexed_sequence_start, bracket) or
                arrayLengthMatchesPath(context, indexed_sequence_start, bracket, other.start, other.end, capture.operands_open))
            {
                counted = true;
                break;
            }
        }
        if (!counted) return false;
    }
    return !mayMutateBeforeIndex(context, capture.body + @intFromBool(context.tokens[capture.body].tag == .l_brace), indexed_sequence_start);
}

const OperandRange = struct { start: usize, end: usize };

fn operandAt(context: RuleRun, opening: usize, closing: usize, wanted: usize) ?OperandRange {
    var start = opening + 1;
    var position: usize = 0;
    while (start < closing) : (position += 1) {
        const comma = topLevelComma(context.tokens, start, closing) orelse closing;
        if (position == wanted) return if (comma > start) .{ .start = start, .end = comma } else null;
        if (comma == closing) return null;
        start = comma + 1;
    }
    return null;
}

/// The `..` of a range operand, when the operand is one.
fn rangeEllipsis(context: RuleRun, operand: OperandRange) ?usize {
    var depth: usize = 0;
    for (context.tokens[operand.start..operand.end], operand.start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .ellipsis2 => if (depth == 0) return index,
        else => {},
    };
    return null;
}

/// Whether the function compares the index with the indexed sequence's
/// length before the access, as `if (index < items.len) items[index]` or
/// `while (index < items.len and items[index] != 0)` do, or counts the index
/// down from that length (`var index = items.len;`).
fn hasLengthComparison(context: RuleRun, body_open: usize, bracket: usize) bool {
    const indexed_sequence_start = context.pathStartBefore(bracket) orelse return false;
    const index_name = context.tokenText(bracket + 1);
    for (context.tokens[body_open + 1 .. bracket], body_open + 1..) |token, use| {
        if (token.tag != .identifier or !context.tokenIs(use, index_name) or
            context.tokens[use - 1].tag == .period) continue;
        var value = use + 1;
        if (context.tokens[value].tag == .colon and value + 2 < bracket and context.tokens[value + 1].tag == .identifier) value += 2;
        const assigned = context.tokens[value].tag == .equal;
        if (isComparison(context.tokens[use + 1].tag) or assigned) {
            // 'index < items.len' or 'var index = items.len;'
            const path_start = if (assigned) value + 1 else use + 2;
            var path_end = path_start;
            while (path_end + 1 < bracket and context.tokens[path_end].tag == .identifier and
                context.tokens[path_end + 1].tag == .period) : (path_end += 2)
            {}
            if (path_end > path_start + 1 and context.tokenIs(path_end, "len") and
                (!assigned or context.tokens[path_end + 1].tag == .semicolon) and
                context.dottedPathsEqual(path_start, path_end - 1, indexed_sequence_start, bracket)) return true;
        }
        if (use >= 4 and isComparison(context.tokens[use - 1].tag) and context.tokenIs(use - 2, "len") and
            context.tokens[use - 3].tag == .period)
        {
            // 'items.len > index'
            const path_start = context.pathStartBefore(use - 3) orelse continue;
            if (context.dottedPathsEqual(path_start, use - 3, indexed_sequence_start, bracket)) return true;
        }
    }
    return false;
}

fn isComparison(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .equal_equal,
        .bang_equal,
        => true,
        else => false,
    };
}

fn hasDominatingWhileBound(context: RuleRun, body_open: usize, bracket: usize) bool {
    if (bracket + 2 >= context.tokens.len or context.tokens[bracket + 1].tag != .identifier or
        context.tokens[bracket + 2].tag != .r_bracket) return false;

    const indexed_sequence_start = context.pathStartBefore(bracket) orelse return false;

    for (context.tokens[body_open..bracket], body_open..) |token, while_index| {
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

test "helpers inside test blocks are not held to the production bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "test \"inspect\" {\nconst Helper = struct {\nfn inspect(buffer: []u8, index: usize) u8 {\n" ++
        "const one = 1;\nconst two = 2;\nconst three = 3;\nconst four = 4;\n" ++
        "const five = 5;\nconst six = 6;\nconst seven = 7;\n_ = one + two + three + four + five + six + seven;\n" ++
        "return buffer[index];\n}\n};\n_ = Helper;\n}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.assertion_free_branching}, .information));
    try support.expectRules(found, &.{});
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

fn expectBranchingFindings(source: [:0]const u8, expected: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.assertion_free_branching}, .information));
    try std.testing.expectEqual(expected, found.len);
}

const filler = "_ = one;\n_ = two;\n_ = three;\n_ = four;\n_ = five;\n_ = six;\n";

test "loop ranges up to the length bound an index from any start and without braces" {
    try expectBranchingFindings("fn prefix(offsets: []u32) void {\n" ++ filler ++
        "for (1..offsets.len) |index| offsets[index] += offsets[index - 1];\n}\n", 0);
    try expectBranchingFindings("fn copy(values: []const u8, out: []u8) void {\n" ++ filler ++
        "for (values, 0..) |value, index| out[index] = value;\n}\n", 1);
    // A counter starting past zero overruns the sequence it counts.
    try expectBranchingFindings("fn shifted(values: []u8) void {\n" ++ filler ++
        "for (values, 1..) |_, index| values[index] = 0;\n}\n", 1);
}

test "comparisons with the length state the bound in the same condition" {
    try expectBranchingFindings("fn get(values: []const u8, index: usize) u8 {\n" ++ filler ++
        "return if (index < values.len) values[index] else 0;\n}\n", 0);
    try expectBranchingFindings("fn skip(list: *List, start: usize) usize {\n" ++ filler ++
        "var index = start;\nwhile (index < list.items.len and list.items[index] == 0) index += 1;\nreturn index;\n}\n", 0);
    try expectBranchingFindings("fn other(values: []const u8, others: []const u8, index: usize) u8 {\n" ++ filler ++
        "return if (index < others.len) values[index] else 0;\n}\n", 1);
    try expectBranchingFindings("fn last(list: *List) u8 {\n" ++ filler ++
        "var total: u8 = 0;\nvar index: usize = list.items.len;\nwhile (index != 0) {\nindex -= 1;\ntotal +%= list.items[index];\n}\nreturn total;\n}\n", 0);
}

test "compile-time indexing and helpers only tests call are not production bounds" {
    try expectBranchingFindings("fn words(value: anytype, out: *[2]u32) void {\n" ++ filler ++
        "inline for (.{ \"a\", \"b\" }, 0..) |name, index| out[index] = @field(value, name);\n}\n", 0);
    try expectBranchingFindings("fn table(comptime T: type) [T.len]u8 {\n" ++ filler ++
        "return comptime table: {\nvar result: [T.len]u8 = undefined;\nfor (T.names, 0..) |_, slot| result[slot] = 0;\nbreak :table result;\n};\n}\n", 0);
    try expectBranchingFindings("fn scenario(values: []u8, index: usize) u8 {\n" ++ filler ++
        "return values[index];\n}\ntest \"scenario\" {\n_ = scenario(&.{}, 0);\n}\n", 0);
}
