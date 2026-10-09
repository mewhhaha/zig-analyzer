//! `std.mem` calls whose last argument is a one-byte string literal and that
//! have a scalar variant: `startsWith`, `endsWith`, the `indexOf` and `find`
//! family, and the `split` and `tokenize` family.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");

pub const rules = [_]types.Rule{
    .prefer_starts_with_scalar,
    .prefer_ends_with_scalar,
    .prefer_index_of_scalar,
    .prefer_split_scalar,
};

const Affix = enum { start, end };

/// A call that swaps its name and needle for a scalar variant.
const Rewrite = struct {
    name: []const u8,
    rule: types.Rule,
    replacement: []const u8,
};

const rewrites = [_]Rewrite{
    .{ .name = "indexOf", .rule = .prefer_index_of_scalar, .replacement = "findScalar" },
    .{ .name = "indexOfAny", .rule = .prefer_index_of_scalar, .replacement = "findScalar" },
    .{ .name = "find", .rule = .prefer_index_of_scalar, .replacement = "findScalar" },
    .{ .name = "findAny", .rule = .prefer_index_of_scalar, .replacement = "findScalar" },
    .{ .name = "lastIndexOf", .rule = .prefer_index_of_scalar, .replacement = "findScalarLast" },
    .{ .name = "lastIndexOfAny", .rule = .prefer_index_of_scalar, .replacement = "findScalarLast" },
    .{ .name = "findLast", .rule = .prefer_index_of_scalar, .replacement = "findScalarLast" },
    .{ .name = "findLastAny", .rule = .prefer_index_of_scalar, .replacement = "findScalarLast" },
    .{ .name = "count", .rule = .prefer_index_of_scalar, .replacement = "countScalar" },
    .{ .name = "splitSequence", .rule = .prefer_split_scalar, .replacement = "splitScalar" },
    .{ .name = "splitAny", .rule = .prefer_split_scalar, .replacement = "splitScalar" },
    .{ .name = "split", .rule = .prefer_split_scalar, .replacement = "splitScalar" },
    .{ .name = "splitBackwardsSequence", .rule = .prefer_split_scalar, .replacement = "splitBackwardsScalar" },
    .{ .name = "splitBackwardsAny", .rule = .prefer_split_scalar, .replacement = "splitBackwardsScalar" },
    .{ .name = "splitBackwards", .rule = .prefer_split_scalar, .replacement = "splitBackwardsScalar" },
    .{ .name = "tokenizeSequence", .rule = .prefer_split_scalar, .replacement = "tokenizeScalar" },
    .{ .name = "tokenizeAny", .rule = .prefer_split_scalar, .replacement = "tokenizeScalar" },
    .{ .name = "tokenize", .rule = .prefer_split_scalar, .replacement = "tokenizeScalar" },
};

/// A `mem.name(T, haystack, "x")` call whose last argument is one byte.
const ScalarNeedleCall = struct {
    /// First token of `mem.name` or `std.mem.name`.
    call_start: usize,
    call_end: usize,
    haystack: tokens_util.Range,
    needle_token: usize,
    needle_text: []const u8,
    /// The needle as a character literal.
    character: []const u8,
    qualifier: []const u8,
};

pub fn run(context: RuleRun) !void {
    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier) continue;
        const name = context.tokenText(call_index);
        if (std.mem.eql(u8, name, "startsWith")) {
            if (context.level(.prefer_starts_with_scalar) != .off) try reportAffix(context, .start, call_index);
        } else if (std.mem.eql(u8, name, "endsWith")) {
            if (context.level(.prefer_ends_with_scalar) != .off) try reportAffix(context, .end, call_index);
        } else for (rewrites) |rewrite| {
            if (!std.mem.eql(u8, name, rewrite.name)) continue;
            if (context.level(rewrite.rule) != .off) try reportRewrite(context, rewrite, call_index);
            break;
        }
    }
}

fn scalarNeedleCall(context: RuleRun, call_index: usize) !?ScalarNeedleCall {
    if (call_index + 1 >= context.tokens.len or context.tokens[call_index + 1].tag != .l_paren) return null;
    const is_std_mem = (call_index >= 4 and context.tokenIs(call_index - 4, "std") and
        context.tokens[call_index - 3].tag == .period and context.tokenIs(call_index - 2, "mem") and
        context.tokens[call_index - 1].tag == .period);
    const is_mem = (call_index >= 2 and context.tokenIs(call_index - 2, "mem") and
        context.tokens[call_index - 1].tag == .period);
    if (!is_std_mem and !is_mem) return null;
    const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse return null;
    const arguments = context.threeArguments(call_index + 1, call_end) orelse return null;
    if (arguments[2].end != arguments[2].start + 1) return null;
    if (context.tokens[arguments[2].start].tag != .string_literal) return null;
    const needle_text = context.tokenText(arguments[2].start);
    return .{
        .call_start = if (is_std_mem) call_index - 4 else call_index - 2,
        .call_end = call_end,
        .haystack = arguments[1],
        .needle_token = arguments[2].start,
        .needle_text = needle_text,
        .character = try tokens_util.parseSingleByteLiteral(context.allocator, needle_text) orelse return null,
        .qualifier = if (is_std_mem) "std.mem." else "mem.",
    };
}

fn reportAffix(context: RuleRun, affix: Affix, call_index: usize) !void {
    const call = try scalarNeedleCall(context, call_index) orelse return;
    const rule: types.Rule = switch (affix) {
        .start => .prefer_starts_with_scalar,
        .end => .prefer_ends_with_scalar,
    };
    const method = if (affix == .start) "startsWith" else "endsWith";
    const haystack_source = std.mem.trim(
        u8,
        context.source[context.tokens[call.haystack.start].loc.start..context.tokens[call.haystack.end - 1].loc.end],
        " \t\r\n",
    );
    const replacement = switch (affix) {
        .start => try context.allocator.print("{s}.len > 0 and {s}[0] == {s}", .{ haystack_source, haystack_source, call.character }),
        .end => try context.allocator.print(
            "{s}.len > 0 and {s}[{s}.len - 1] == {s}",
            .{ haystack_source, haystack_source, haystack_source, call.character },
        ),
    };
    var fixes: []const types.Fix = &.{};
    if (isSimpleExpression(context, call.haystack.start, call.haystack.end)) {
        fixes = try context.singleFix(.{
            .title = try context.allocator.print("Use byte indexing: {s}", .{replacement}),
            .span = .{
                .start = context.tokens[call.call_start].loc.start,
                .end = context.tokens[call.call_end].loc.end,
            },
            .replacement = replacement,
            .preferred = true,
            .fix_all = true,
        });
    }
    try context.emit(.{
        .rule = rule,
        .level = context.level(rule),
        .span = context.tokens[call_index].loc,
        .message = try context.allocator.print(
            "'{s}' with 1-byte needle {s} can be optimized to '{s}'",
            .{ method, call.needle_text, replacement },
        ),
        .fixes = fixes,
    });
}

fn namesIteratorType(context: RuleRun) bool {
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, "SplitIterator") or context.tokenIs(index, "SplitBackwardsIterator") or
            context.tokenIs(index, "TokenIterator")) return true;
    }
    return false;
}

fn reportRewrite(context: RuleRun, rewrite: Rewrite, call_index: usize) !void {
    const call = try scalarNeedleCall(context, call_index) orelse return;
    // The scalar variants return another iterator type, which a spelled-out
    // `SplitIterator(u8, .sequence)` would reject.
    if (rewrite.rule == .prefer_split_scalar and namesIteratorType(context)) return;
    const edits = try context.allocator.alloc(types.Edit, 2);
    edits[0] = .{ .span = context.tokens[call_index].loc, .replacement = rewrite.replacement };
    edits[1] = .{ .span = context.tokens[call.needle_token].loc, .replacement = call.character };
    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{
        .title = try context.allocator.print("Use '{s}' with {s}", .{ rewrite.replacement, call.character }),
        .kind = .quickfix,
        .edits = edits,
        .preferred = true,
        .fix_all = true,
    };
    const action = if (rewrite.rule == .prefer_split_scalar) "splitting by" else "searching for";
    try context.emit(.{
        .rule = rewrite.rule,
        .level = context.level(rewrite.rule),
        .span = context.tokens[call_index].loc,
        .message = try context.allocator.print(
            "{s} single character '{s}' using {s}{s}; use {s}{s} with {s}",
            .{ action, call.needle_text, call.qualifier, rewrite.name, call.qualifier, rewrite.replacement, call.character },
        ),
        .fixes = fixes,
    });
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

test "prefer starts with scalar detects 1-character needle and offers quickfix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn isFlag(arg: []const u8) bool {
        \\    return std.mem.startsWith(u8, arg, "-");
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_starts_with_scalar}, .warning));

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_starts_with_scalar, findings[0].rule);
    try std.testing.expectEqual(1, findings[0].fixes.len);
    try std.testing.expectEqualStrings("arg.len > 0 and arg[0] == '-'", findings[0].fixes[0].edits[0].replacement);
}

test "prefer starts with scalar detects escape character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn startsWithNewline(text: []const u8) bool {
        \\    return std.mem.startsWith(u8, text, "\n");
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_starts_with_scalar}, .warning));

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqualStrings("text.len > 0 and text[0] == '\\n'", findings[0].fixes[0].edits[0].replacement);
}

test "prefer starts with scalar ignores multi-character needle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn isZig(arg: []const u8) bool {
        \\    return std.mem.startsWith(u8, arg, "--");
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_starts_with_scalar}, .warning));

    try std.testing.expectEqual(0, findings.len);
}

test "prefer ends with scalar detects 1-character needle and offers quickfix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn isDirectory(path: []const u8) bool {
        \\    return std.mem.endsWith(u8, path, "/");
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_ends_with_scalar}, .warning));

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_ends_with_scalar, findings[0].rule);
    try std.testing.expectEqual(1, findings[0].fixes.len);
    try std.testing.expectEqualStrings("path.len > 0 and path[path.len - 1] == '/'", findings[0].fixes[0].edits[0].replacement);
}

test "prefer ends with scalar ignores multi-character suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn isZig(path: []const u8) bool {
        \\    return std.mem.endsWith(u8, path, ".zig");
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_ends_with_scalar}, .warning));

    try std.testing.expectEqual(0, findings.len);
}

test "prefer index of scalar detects single-character search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(path: []const u8) ?usize {\n" ++
        "    const a = std.mem.indexOf(u8, path, \"/\");\n" ++
        "    const b = std.mem.lastIndexOf(u8, path, \":\");\n" ++
        "    const c = mem.indexOf(u8, path, \"\\n\");\n" ++
        "    return a orelse b orelse c;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_index_of_scalar}, .warning));

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expectEqualStrings("findScalar", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("'/'", findings[0].fixes[0].edits[1].replacement);
    try std.testing.expectEqualStrings("findScalarLast", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("':'", findings[1].fixes[0].edits[1].replacement);
    try std.testing.expectEqualStrings("findScalar", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("'\\n'", findings[2].fixes[0].edits[1].replacement);
}

test "current find spellings use current scalar replacements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(path: []const u8) void {\n" ++
        "    _ = std.mem.find(u8, path, \"/\");\n" ++
        "    _ = std.mem.findLast(u8, path, \"/\");\n" ++
        "    _ = std.mem.findAny(u8, path, \"/\");\n" ++
        "    _ = std.mem.findLastAny(u8, path, \"/\");\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_index_of_scalar}, .warning));
    try std.testing.expectEqual(@as(usize, 4), findings.len);
    try std.testing.expectEqualStrings("findScalar", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("findScalarLast", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("findScalar", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("findScalarLast", findings[3].fixes[0].edits[0].replacement);
}

test "multi-character or scalar search stays unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(path: []const u8) ?usize {\n" ++
        "    const a = std.mem.indexOf(u8, path, \"//\");\n" ++
        "    const b = std.mem.indexOfScalar(u8, path, '/');\n" ++
        "    const c = std.mem.lastIndexOf(u8, path, \"\");\n" ++
        "    return a orelse b orelse c;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_index_of_scalar}, .warning));

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer index of scalar detects single-character count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn lineCount(buffer: []const u8) usize {\n" ++
        "    return std.mem.count(u8, buffer, \"\\n\");\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_index_of_scalar}, .warning));

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("countScalar", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("'\\n'", findings[0].fixes[0].edits[1].replacement);
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
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_split_scalar}, .warning));

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
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_split_scalar}, .warning));

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a spelled-out iterator type keeps the sequence variant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn fields(line: []const u8) std.mem.SplitIterator(u8, .sequence) {\n" ++
        "    return std.mem.splitSequence(u8, line, \",\");\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_split_scalar}, .information));
    try std.testing.expectEqual(@as(usize, 0), found.len);
}
