const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_module = @import("../../syntax/tokens.zig");

pub const rules = [_]types.Rule{
    .prefer_multi_sequence_for,
};

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
        if (body_start >= context.tokens.len) continue;
        const is_braced = context.tokens[body_start].tag == .l_brace;
        const inner_start = if (is_braced) body_start + 1 else body_start;
        const inner_end = if (is_braced)
            context.matchingToken(body_start, .l_brace, .r_brace) orelse continue
        else
            findUnbracedStatementEnd(context.tokens, body_start) orelse continue;

        const second = indexedSequence(context, inner_start, inner_end, index_name) orelse continue;
        if (std.mem.eql(u8, first, second)) continue;
        const assertion = lengthAssertion(context, for_index, first, second) orelse continue;
        if (bindingUseCount(context, inner_start, inner_end, index_name) != 1) continue;

        try context.emit(.{
            .rule = .prefer_multi_sequence_for,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "'{s}' is indexed only to pair it with '{s}', whose equal length is asserted; iterate both sequences in the for loop",
                .{ second, first },
            ),
            .fixes = try pairedCaptureFix(context, for_index, inner_start, inner_end, second, assertion),
        });
    }
}

/// `for (a, b) |x, b_item|` reading `b_item` where the body read `b[i]`. The
/// capture is taken as the iteration starts, so the element must not change
/// before the read: `b` is a read-only parameter (`[]const T` or an array
/// value) or a const local array, and the body writes only `var` locals of
/// the function and calls nothing but pure builtins. The length assertion
/// must be `std.debug.assert`, which stops a mismatch before the loop's own
/// length check would. The new capture may not shadow or meet a name the
/// loop already sees.
fn pairedCaptureFix(context: RuleRun, for_index: usize, inner_start: usize, inner_end: usize, second: []const u8, assertion: usize) ![]const types.Fix {
    const tokens = context.tokens;
    const index_name = context.tokenText(for_index + 10);
    const access = indexedAccess(context, inner_start, inner_end, second, index_name) orelse return &.{};
    if (tokens[access - 1].tag == .period or tokens[access - 1].tag == .ampersand or
        (for_index > 0 and tokens[for_index - 1].tag == .keyword_inline) or
        !namesDebugAssert(context, assertion) or !readOnlySequence(context, access) or
        !bodyOnlyWritesLocals(context, inner_start, inner_end)) return &.{};
    const capture = try captureName(context, second, for_index, inner_end) orelse return &.{};
    const edits = try context.allocator.alloc(types.Edit, 3);
    errdefer context.allocator.free(edits);
    edits[0] = .{ .span = .{ .start = tokens[for_index + 4].loc.start, .end = tokens[for_index + 5].loc.end }, .replacement = second };
    edits[1] = .{ .span = tokens[for_index + 10].loc, .replacement = capture };
    edits[2] = .{ .span = .{ .start = tokens[access].loc.start, .end = tokens[access + 3].loc.end }, .replacement = capture };
    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{ .title = "Iterate both sequences", .kind = .quickfix, .edits = edits, .preferred = true };
    return fixes;
}

/// The identifier `sequence` of the `sequence[index_name]` read in `[start, end)`.
fn indexedAccess(context: RuleRun, start: usize, end: usize, sequence: []const u8, index_name: []const u8) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and index + 3 < end and context.tokenIs(index, sequence) and
            context.tokens[index + 1].tag == .l_bracket and context.tokenIs(index + 2, index_name) and
            context.tokens[index + 3].tag == .r_bracket) return index;
    }
    return null;
}

/// Whether the assertion callee at `assert_index` is `std.debug.assert`,
/// spelled out or through `const debug = std.debug;` or
/// `const assert = std.debug.assert;`.
fn namesDebugAssert(context: RuleRun, assert_index: usize) bool {
    const tokens = context.tokens;
    if (assert_index >= 4 and tokens[assert_index - 1].tag == .period and context.tokenIs(assert_index - 2, "debug") and
        tokens[assert_index - 3].tag == .period and context.tokenIs(assert_index - 4, "std")) return true;
    const alias = if (assert_index >= 2 and tokens[assert_index - 1].tag == .period) assert_index - 2 else assert_index;
    const binding = context.scopes.findBinding(alias) orelse return false;
    const value = binding.token_index + 2;
    if (tokens[binding.token_index + 1].tag != .equal or !context.tokenIs(value, "std") or
        tokens[value + 1].tag != .period or !context.tokenIs(value + 2, "debug")) return false;
    if (alias != assert_index) return tokens[value + 3].tag == .semicolon;
    return tokens[value + 3].tag == .period and context.tokenIs(value + 4, "assert") and tokens[value + 5].tag == .semicolon;
}

/// Whether the identifier at `index` names a sequence the loop cannot change:
/// a parameter of the enclosing function typed `[]const T` (with or without
/// a sentinel) or `[N]T`, or a const local array.
fn readOnlySequence(context: RuleRun, index: usize) bool {
    const tokens = context.tokens;
    const declaration = context.localDeclaration(index) orelse return false;
    const declared = context.annotatedType(declaration);
    switch (tokens[declaration - 1].tag) {
        // A local slice could view a local array that the body assigns.
        .keyword_const => {
            const start = if (declared) |range| range.start else if (tokens[declaration + 1].tag == .equal) declaration + 2 else return false;
            return arrayTypeAt(tokens, start);
        },
        .keyword_var => return false,
        else => {},
    }
    const range = declared orelse return false;
    if (arrayTypeAt(tokens, range.start)) return true;
    if (tokens[range.start].tag != .l_bracket) return false;
    var cursor = range.start + 1;
    if (tokens[cursor].tag == .colon) cursor = tokens_module.findTag(tokens, cursor, range.end, .r_bracket) orelse return false;
    return tokens[cursor].tag == .r_bracket and cursor + 1 < range.end and tokens[cursor + 1].tag == .keyword_const;
}

/// Whether an array type (`[N]T`, `[_]T`, `[N:s]T`) starts at `start`.
fn arrayTypeAt(tokens: []const std.zig.Token, start: usize) bool {
    return tokens[start].tag == .l_bracket and switch (tokens[start + 1].tag) {
        .r_bracket, .asterisk, .colon => false,
        else => true,
    };
}

/// Builtins that neither write memory nor call code.
const pure_builtins = std.StaticStringMap(void).initComptime(.{
    .{"@abs"},          .{"@as"},       .{"@bitCast"},  .{"@ceil"},        .{"@cos"},
    .{"@divExact"},     .{"@divFloor"}, .{"@divTrunc"}, .{"@exp"},         .{"@floatCast"},
    .{"@floatFromInt"}, .{"@floor"},    .{"@intCast"},  .{"@intFromBool"}, .{"@intFromEnum"},
    .{"@intFromFloat"}, .{"@log"},      .{"@max"},      .{"@min"},         .{"@mod"},
    .{"@mulAdd"},       .{"@rem"},      .{"@round"},    .{"@sin"},         .{"@sqrt"},
    .{"@trunc"},        .{"@truncate"},
});

/// Whether the loop body in `[start, end)` writes nothing but `var` locals of
/// the enclosing function and calls nothing but pure builtins, so no element
/// of a sequence changes while an iteration runs.
fn bodyOnlyWritesLocals(context: RuleRun, start: usize, end: usize) bool {
    const tokens = context.tokens;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren => switch (tokens[index - 1].tag) {
            .builtin => if (!pure_builtins.has(context.tokenText(index - 1))) return false,
            .identifier, .r_paren, .r_bracket, .r_brace, .period_asterisk, .question_mark => return false,
            else => {},
        },
        .keyword_asm => return false,
        else => if (tokens_module.isAssignment(token.tag) and !assignsLocal(context, index)) return false,
    };
    return true;
}

/// Whether the assignment operator at `operator` belongs to a declaration,
/// discards with `_ =`, or assigns a plain `var` local of the function.
fn assignsLocal(context: RuleRun, operator: usize) bool {
    const tokens = context.tokens;
    switch (tokens[tokens_module.statementStart(tokens, operator)].tag) {
        .keyword_const, .keyword_var => return true,
        else => {},
    }
    const target = operator - 1;
    if (tokens[target].tag != .identifier or tokens[target - 1].tag == .period) return false;
    if (context.tokenIs(target, "_")) return true;
    const declaration = context.localDeclaration(target) orelse return false;
    return tokens[declaration - 1].tag == .keyword_var;
}

/// A new capture name for the elements of `sequence` in the loop at
/// `for_index`: its singular (`values` gives `value`, `entries` `entry`),
/// else `sequence_item`, whichever is free.
fn captureName(context: RuleRun, sequence: []const u8, for_index: usize, end: usize) !?[]const u8 {
    const singular = if (std.mem.endsWith(u8, sequence, "ies") and sequence.len > 3)
        try context.allocator.print("{s}y", .{sequence[0 .. sequence.len - 3]})
    else if (sequence.len > 1 and sequence[sequence.len - 1] == 's' and sequence[sequence.len - 2] != 's')
        sequence[0 .. sequence.len - 1]
    else
        "";
    if (singular.len != 0 and captureNameFree(context, singular, for_index, end)) return singular;
    const item = try context.allocator.print("{s}_item", .{sequence});
    return if (captureNameFree(context, item, for_index, end)) item else null;
}

/// Whether `name` can be a new capture of the loop at `for_index`: a plain
/// name, no binding of it visible there, and unused by the loop through `end`.
fn captureNameFree(context: RuleRun, name: []const u8, for_index: usize, end: usize) bool {
    if (std.zig.Token.getKeyword(name) != null or std.zig.primitives.isPrimitive(name) or
        context.scopes.findBindingNamed(name, for_index) != null) return false;
    for (for_index..end + 1) |index| if (context.refersToBinding(index, name)) return false;
    return true;
}

fn findUnbracedStatementEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    var parentheses: usize = 0;
    var brackets: usize = 0;
    var braces: usize = 0;
    var index = start;
    while (index < tokens.len) : (index += 1) {
        switch (tokens[index].tag) {
            .l_paren => parentheses += 1,
            .r_paren => if (parentheses > 0) {
                parentheses -= 1;
            } else return null,
            .l_bracket => brackets += 1,
            .r_bracket => if (brackets > 0) {
                brackets -= 1;
            } else return null,
            .l_brace => braces += 1,
            .r_brace => if (braces > 0) {
                braces -= 1;
            } else return null,
            .semicolon => if (parentheses == 0 and brackets == 0 and braces == 0) return index,
            else => {},
        }
    }
    return null;
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

fn isAssertCallee(context: RuleRun, assert_index: usize) bool {
    if (!context.tokenIs(assert_index, "assert")) return false;
    // Check std.debug.assert
    if (assert_index >= 4 and
        context.tokenIs(assert_index - 4, "std") and
        context.tokens[assert_index - 3].tag == .period and
        context.tokenIs(assert_index - 2, "debug") and
        context.tokens[assert_index - 1].tag == .period and
        (assert_index == 4 or context.tokens[assert_index - 5].tag != .period))
    {
        return true;
    }
    // Check debug.assert
    if (assert_index >= 2 and
        context.tokenIs(assert_index - 2, "debug") and
        context.tokens[assert_index - 1].tag == .period and
        (assert_index == 2 or context.tokens[assert_index - 3].tag != .period))
    {
        return true;
    }
    // Check bare assert
    if (assert_index == 0 or context.tokens[assert_index - 1].tag != .period) {
        return true;
    }
    return false;
}

fn sameScopeBetween(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    var depth: usize = 0;
    for (tokens[start..end]) |tok| {
        switch (tok.tag) {
            .l_brace => depth += 1,
            .r_brace => if (depth > 0) {
                depth -= 1;
            } else return false,
            else => {},
        }
    }
    return depth == 0;
}

fn isAssignedBetween(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    var index = start;
    while (index < end) : (index += 1) {
        if (context.tokenIs(index, name) and index + 1 < end) {
            const next_tag = context.tokens[index + 1].tag;
            switch (next_tag) {
                .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal, .percent_equal => return true,
                else => {},
            }
        }
    }
    return false;
}

/// The callee of an `assert(first.len == second.len);` before `before` that
/// still holds there.
fn lengthAssertion(context: RuleRun, before: usize, first: []const u8, second: []const u8) ?usize {
    for (context.tokens[0..before], 0..) |_, assert_index| {
        if (!isAssertCallee(context, assert_index)) continue;
        if (assert_index + 10 >= before) continue;
        if (context.tokens[assert_index + 1].tag != .l_paren or
            context.tokens[assert_index + 2].tag != .identifier or
            context.tokens[assert_index + 3].tag != .period or
            !context.tokenIs(assert_index + 4, "len") or
            context.tokens[assert_index + 5].tag != .equal_equal or
            context.tokens[assert_index + 6].tag != .identifier or
            context.tokens[assert_index + 7].tag != .period or
            !context.tokenIs(assert_index + 8, "len") or
            context.tokens[assert_index + 9].tag != .r_paren or
            context.tokens[assert_index + 10].tag != .semicolon) continue;

        const left = context.tokenText(assert_index + 2);
        const right = context.tokenText(assert_index + 6);
        const matches = (std.mem.eql(u8, left, first) and std.mem.eql(u8, right, second)) or
            (std.mem.eql(u8, left, second) and std.mem.eql(u8, right, first));
        if (!matches) continue;

        const assert_end = assert_index + 11;
        if (assert_end == before) return assert_index;
        if (sameScopeBetween(context.tokens, assert_end, before) and
            !isAssignedBetween(context, assert_end, before, first) and
            !isAssignedBetween(context, assert_end, before, second))
        {
            return assert_index;
        }
    }
    return null;
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

test "multi-sequence for supports bare assert and unbraced body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "assert(names.len == values.len);\n" ++
        "for (names, 0..) |name, index| use(name, values[index]);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "multi-sequence for supports debug.assert with intervening assertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "debug.assert(names.len == values.len);\n" ++
        "debug.assert(names.len > 0);\n" ++
        "for (names, 0..) |name, index| {\n" ++
        "    use(name, values[index]);\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

/// The source after the fix of its one finding, or null when it offers none.
fn fixedFor(allocator: std.mem.Allocator, source: [:0]const u8) !?[]const u8 {
    const found = try findingsFor(allocator, source);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    if (found[0].fixes.len == 0) return null;
    return try support.applyFix(allocator, source, found[0].fixes[0]);
}

test "a read-only second sequence becomes a second loop input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\n" ++
            "fn dot(a: []const f32, weights: []const f32) f32 {\n" ++
            "    std.debug.assert(a.len == weights.len);\n" ++
            "    var sum: f32 = 0;\n" ++
            "    for (a, weights) |x, weight| {\n" ++
            "        sum += x * @abs(weight);\n" ++
            "    }\n" ++
            "    return sum;\n" ++
            "}",
        (try fixedFor(allocator, "const std = @import(\"std\");\n" ++
            "fn dot(a: []const f32, weights: []const f32) f32 {\n" ++
            "    std.debug.assert(a.len == weights.len);\n" ++
            "    var sum: f32 = 0;\n" ++
            "    for (a, 0..) |x, i| {\n" ++
            "        sum += x * @abs(weights[i]);\n" ++
            "    }\n" ++
            "    return sum;\n" ++
            "}")).?,
    );
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\nconst assert = std.debug.assert;\n" ++
            "fn f(a: []const u8, b: [4]u8) u8 {\n" ++
            "    assert(a.len == b.len);\n" ++
            "    var last: u8 = 0;\n" ++
            "    for (a, b) |x, b_item| last = x ^ b_item;\n" ++
            "    return last;\n" ++
            "}",
        (try fixedFor(allocator, "const std = @import(\"std\");\nconst assert = std.debug.assert;\n" ++
            "fn f(a: []const u8, b: [4]u8) u8 {\n" ++
            "    assert(a.len == b.len);\n" ++
            "    var last: u8 = 0;\n" ++
            "    for (a, 0..) |x, i| last = x ^ b[i];\n" ++
            "    return last;\n" ++
            "}")).?,
    );
}

test "a second sequence the body may change keeps its index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prefix = "const std = @import(\"std\");\nfn f(a: []const u8, b: []const u8, out: []u8) void {\n    std.debug.assert(a.len == b.len);\n";
    for ([_][:0]const u8{
        // A mutable slice, a write through another slice, or a call may change b[i].
        "const std = @import(\"std\");\nfn f(a: []const u8, b: []u8) void {\n    std.debug.assert(a.len == b.len);\n    for (a, 0..) |x, i| use(x, b[i]);\n}",
        prefix ++ "    for (a, 0..) |x, i| {\n        out[0] = x;\n        out[1] = b[i];\n    }\n}",
        prefix ++ "    for (a, 0..) |x, i| {\n        touch(out);\n        _ = x + b[i];\n    }\n}",
        // The assertion is not std.debug.assert.
        "fn f(a: []const u8, b: []const u8) u8 {\n    assert(a.len == b.len);\n    var s: u8 = 0;\n    for (a, 0..) |x, i| s +%= x ^ b[i];\n    return s;\n}",
        // The new capture would shadow a visible name.
        "const std = @import(\"std\");\nconst b_item = 0;\nfn f(a: []const u8, b: []const u8) u8 {\n    std.debug.assert(a.len == b.len);\n" ++
            "    var s: u8 = 0;\n    for (a, 0..) |x, i| s +%= x ^ b[i];\n    return s;\n}",
    }) |source| {
        errdefer std.debug.print("fixed: {s}\n", .{source});
        try std.testing.expectEqual(@as(?[]const u8, null), try fixedFor(allocator, source));
    }
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.prefer_multi_sequence_for}, .information));
}
