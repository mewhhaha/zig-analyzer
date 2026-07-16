const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findSliceExpectations(context);
    try findManualErrorExpectations(context);
    try findApproximateExpectations(context);
}

fn findSliceExpectations(context: RuleRun) !void {
    const level = context.level(.prefer_testing_expect_equal_slices);
    if (level == .off) return;
    for (context.tokens, 0..) |token, expect_index| {
        if (!context.tokenIs(expect_index, "expect") or token.tag != .identifier or expect_index + 10 >= context.tokens.len or
            context.tokens[expect_index + 1].tag != .l_paren or !calleeIsTestingQualified(context, expect_index)) continue;
        const expect_end = context.matchingToken(expect_index + 1, .l_paren, .r_paren) orelse continue;
        const eql_index = expect_index + 6;
        if (!qualifiedMemEql(context, expect_index, eql_index)) continue;
        const eql_end = context.matchingToken(eql_index + 1, .l_paren, .r_paren) orelse continue;
        if (eql_end + 1 != expect_end) continue;
        const type_comma = topLevelComma(context.tokens, eql_index + 2, eql_end) orelse continue;
        const argument_comma = topLevelComma(context.tokens, type_comma + 1, eql_end) orelse continue;
        if (type_comma == eql_index + 2 or argument_comma == type_comma + 1 or argument_comma + 1 == eql_end) continue;
        const element_type = sourceBetween(context, eql_index + 2, type_comma);
        if (std.mem.eql(u8, element_type, "u8")) continue;
        const expected = sourceBetween(context, type_comma + 1, argument_comma);
        const actual = sourceBetween(context, argument_comma + 1, eql_end);
        const call_start = callExpressionStart(context.tokens, expect_index + 1) orelse expect_index;
        const qualification = context.source[context.tokens[call_start].loc.start..token.loc.start];
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = context.tokens[call_start].loc.start, .end = context.tokens[expect_end].loc.end },
            .replacement = try std.fmt.allocPrint(
                context.allocator,
                "{s}expectEqualSlices({s}, {s}, {s})",
                .{ qualification, element_type, expected, actual },
            ),
        };
        const fixes = try oneFix(context, "Use expectEqualSlices", edits);
        try context.emit(.{
            .rule = .prefer_testing_expect_equal_slices,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "slice comparison for element type '{s}' produces a less useful failure than expectEqualSlices",
                .{element_type},
            ),
            .fixes = fixes,
        });
    }
}

fn findManualErrorExpectations(context: RuleRun) !void {
    const level = context.level(.prefer_testing_expect_error);
    if (level == .off) return;
    for (context.tokens, 0..) |token, catch_index| {
        if (token.tag != .keyword_catch or catch_index + 4 >= context.tokens.len or
            context.tokens[catch_index + 1].tag != .pipe or context.tokens[catch_index + 2].tag != .identifier or
            context.tokens[catch_index + 3].tag != .pipe or context.tokens[catch_index + 4].tag != .l_brace) continue;
        const capture_name = context.tokenText(catch_index + 2);
        const body_end = context.matchingToken(catch_index + 4, .l_brace, .r_brace) orelse continue;
        const expected_error = expectedErrorInBody(context, capture_name, catch_index + 5, body_end) orelse continue;
        if (!containsTag(context.tokens, catch_index + 5, body_end, .keyword_return) or body_end + 6 >= context.tokens.len or
            context.tokens[body_end + 1].tag != .semicolon or context.tokens[body_end + 2].tag != .keyword_return or
            !context.tokenIs(body_end + 3, "error") or context.tokens[body_end + 4].tag != .period or
            !context.tokenIs(body_end + 5, "TestExpectedError") or context.tokens[body_end + 6].tag != .semicolon) continue;
        const expression_start = statementStart(context.tokens, catch_index);
        var operation_start = expression_start;
        if (context.tokenIs(operation_start, "_") and operation_start + 1 < catch_index and
            context.tokens[operation_start + 1].tag == .equal) operation_start += 2;
        if (operation_start >= catch_index or
            operationHasAssignment(context.tokens, operation_start, catch_index)) continue;
        const operation = std.mem.trim(
            u8,
            context.source[context.tokens[operation_start].loc.start..token.loc.start],
            " \t\r\n",
        );
        if (operation.len == 0) continue;
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = context.tokens[expression_start].loc.start, .end = context.tokens[body_end + 6].loc.end },
            .replacement = try std.fmt.allocPrint(
                context.allocator,
                "try std.testing.expectError({s}, {s});",
                .{ expected_error, operation },
            ),
        };
        const fixes = try oneFix(context, "Use expectError", edits);
        try context.emit(.{
            .rule = .prefer_testing_expect_error,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(u8, "manual catch assertion is equivalent to std.testing.expectError"),
            .fixes = fixes,
        });
    }
}

fn findApproximateExpectations(context: RuleRun) !void {
    const level = context.level(.prefer_testing_expect_approx);
    if (level == .off) return;
    for (context.tokens, 0..) |token, expect_index| {
        if (!context.tokenIs(expect_index, "expect") or token.tag != .identifier or expect_index + 10 >= context.tokens.len or
            context.tokens[expect_index + 1].tag != .l_paren or context.tokens[expect_index + 2].tag != .builtin or
            !context.tokenIs(expect_index + 2, "@abs") or context.tokens[expect_index + 3].tag != .l_paren or
            context.tokens[expect_index + 4].tag != .identifier or context.tokens[expect_index + 5].tag != .minus or
            context.tokens[expect_index + 6].tag != .identifier or context.tokens[expect_index + 7].tag != .r_paren or
            (context.tokens[expect_index + 8].tag != .angle_bracket_left and
                context.tokens[expect_index + 8].tag != .angle_bracket_left_equal) or
            (context.tokens[expect_index + 9].tag != .identifier and context.tokens[expect_index + 9].tag != .number_literal) or
            context.tokens[expect_index + 10].tag != .r_paren) continue;
        try context.emit(.{
            .rule = .prefer_testing_expect_approx,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(u8, "manual absolute-difference assertion produces a less useful failure than expectApproxEqAbs"),
        });
    }
}

fn calleeIsTestingQualified(context: RuleRun, expect_index: usize) bool {
    if (expect_index == 0 or context.tokens[expect_index - 1].tag != .period) return true;
    return expect_index >= 2 and context.tokens[expect_index - 2].tag == .identifier and
        context.tokenIs(expect_index - 2, "testing");
}

fn operationHasAssignment(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    var depth: usize = 0;
    for (tokens[start..end]) |token| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .equal => if (depth == 0) return true,
        .keyword_const, .keyword_var => return true,
        else => {},
    };
    return false;
}

fn qualifiedMemEql(context: RuleRun, expect_index: usize, eql_index: usize) bool {
    return context.tokens[expect_index + 2].tag == .identifier and context.tokenIs(expect_index + 2, "std") and
        context.tokens[expect_index + 3].tag == .period and context.tokenIs(expect_index + 4, "mem") and
        context.tokens[expect_index + 5].tag == .period and context.tokenIs(eql_index, "eql") and
        context.tokens[eql_index + 1].tag == .l_paren;
}

fn expectedErrorInBody(context: RuleRun, capture: []const u8, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, index| {
        if (!context.tokenIs(index, "expectEqual") or token.tag != .identifier or index + 7 >= end or
            context.tokens[index + 1].tag != .l_paren or !context.tokenIs(index + 2, "error") or
            context.tokens[index + 3].tag != .period or context.tokens[index + 4].tag != .identifier or
            context.tokens[index + 5].tag != .comma or !context.tokenIs(index + 6, capture) or
            context.tokens[index + 7].tag != .r_paren) continue;
        return context.source[context.tokens[index + 2].loc.start..context.tokens[index + 4].loc.end];
    }
    return null;
}

fn oneFix(context: RuleRun, title: []const u8, edits: []const types.Edit) ![]const types.Fix {
    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{ .title = title, .kind = .refactor_rewrite, .edits = edits, .preferred = true, .fix_all = true };
    return fixes;
}

fn sourceBetween(context: RuleRun, start: usize, end: usize) []const u8 {
    return std.mem.trim(u8, context.source[context.tokens[start].loc.start..context.tokens[end - 1].loc.end], " \t\r\n");
}

fn topLevelComma(tokens: []const std.zig.Token, start: usize, end: usize) ?usize {
    var depth: usize = 0;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) return index,
        else => {},
    };
    return null;
}

fn callExpressionStart(tokens: []const std.zig.Token, opening: usize) ?usize {
    if (opening == 0 or tokens[opening - 1].tag != .identifier) return null;
    var start = opening - 1;
    while (start >= 2 and tokens[start - 1].tag == .period and tokens[start - 2].tag == .identifier) start -= 2;
    return start;
}

fn statementStart(tokens: []const std.zig.Token, index: usize) usize {
    var start = index;
    while (start > 0) {
        switch (tokens[start - 1].tag) {
            .semicolon, .l_brace, .r_brace => return start,
            else => start -= 1,
        }
    }
    return start;
}

fn containsTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) bool {
    for (tokens[start..end]) |token| if (token.tag == tag) return true;
    return false;
}

test "testing idioms produce framework-specific fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "try std.testing.expect(std.mem.eql(u32, expected, actual));\n" ++
        "try std.testing.expect(@abs(actual_float - expected_float) <= tolerance);";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_testing_expect_equal_slices)] = .information;
    configuration.levels[@intFromEnum(types.Rule.prefer_testing_expect_approx)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 2), findings.items.len);
}

test "manual catch assertion becomes expectError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "operation() catch |err| {\n" ++
        "    try std.testing.expectEqual(error.NotFound, err);\n" ++
        "    return;\n" ++
        "};\n" ++
        "return error.TestExpectedError;";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_testing_expect_error)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqualStrings(
        "try std.testing.expectError(error.NotFound, operation());",
        findings.items[0].fixes[0].edits[0].replacement,
    );
}

test "a discarded operation loses its discard in the expectError rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "_ = operation() catch |err| {\n" ++
        "    try std.testing.expectEqual(error.NotFound, err);\n" ++
        "    return;\n" ++
        "};\n" ++
        "return error.TestExpectedError;";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_testing_expect_error)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    const edit = findings.items[0].fixes[0].edits[0];
    try std.testing.expectEqualStrings(
        "try std.testing.expectError(error.NotFound, operation());",
        edit.replacement,
    );
    try std.testing.expectEqual(@as(usize, 0), edit.span.start);
}

test "an operation bound to a name is not rewritten to expectError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const outcome = operation() catch |err| {\n" ++
        "    try std.testing.expectEqual(error.NotFound, err);\n" ++
        "    return;\n" ++
        "};\n" ++
        "return error.TestExpectedError;";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_testing_expect_error)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a custom expect harness is not rewritten to expectEqualSlices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "try harness.expect(std.mem.eql(u32, expected, actual));";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_testing_expect_equal_slices)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
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
