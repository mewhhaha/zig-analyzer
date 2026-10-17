const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const topLevelComma = @import("../../syntax/tokens.zig").topLevelComma;
const dottedCalleeStart = @import("../../syntax/tokens.zig").dottedCalleeStart;

pub const rules = [_]types.Rule{
    .prefer_testing_expect_equal_slices,
    .prefer_testing_expect_error,
    .prefer_testing_expect_approx,
    .prefer_doctest,
};

pub fn run(context: RuleRun) !void {
    try findSliceExpectations(context);
    try findManualErrorExpectations(context);
    try findApproximateExpectations(context);
    try findDoctestCandidates(context);
}

/// `test "parse"` beside a root `fn parse`: `test parse` makes it the
/// declaration's doctest. The rename is declined when it would collide with
/// another test of that name.
fn findDoctestCandidates(context: RuleRun) !void {
    const level = context.level(.prefer_doctest);
    if (level == .off) return;
    const tree = context.tree;
    const root = tree.rootDecls();
    var declared: std.StringHashMapUnmanaged(void) = .empty;
    defer declared.deinit(context.allocator);
    // Test names, string and identifier alike, with how often each occurs.
    var test_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer test_names.deinit(context.allocator);
    for (root) |declaration| switch (tree.nodeTag(declaration)) {
        .fn_decl, .simple_var_decl, .local_var_decl, .aligned_var_decl, .global_var_decl => {
            const name_token = tree.nodeMainToken(declaration) + 1;
            if (tree.tokenTag(name_token) == .identifier) try declared.put(context.allocator, tree.tokenSlice(name_token), {});
        },
        .test_decl => {
            const name_token = tree.nodeData(declaration).opt_token_and_node[0].unwrap() orelse continue;
            const entry = try test_names.getOrPut(context.allocator, testName(tree, name_token) orelse continue);
            entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
        },
        else => {},
    };
    if (declared.count() == 0) return;
    for (root) |declaration| {
        if (tree.nodeTag(declaration) != .test_decl) continue;
        const name_token = tree.nodeData(declaration).opt_token_and_node[0].unwrap() orelse continue;
        if (tree.tokenTag(name_token) != .string_literal) continue;
        const name = testName(tree, name_token) orelse continue;
        if (!declared.contains(name) or test_names.get(name).? != 1) continue;
        try context.emit(.{
            .rule = .prefer_doctest,
            .level = level,
            .span = context.tokens[name_token].loc,
            .message = try context.allocator.print(
                "test \"{s}\" names the declaration '{s}'; `test {s}` makes it that declaration's doctest",
                .{ name, name, name },
            ),
            .fixes = try context.singleFix(.{
                .title = try context.allocator.print("Rename to the doctest 'test {s}'", .{name}),
                .span = context.tokens[name_token].loc,
                .replacement = name,
                .preferred = true,
            }),
        });
    }
}

/// The name a test declares: an identifier's text, or a string literal's
/// contents when they need no escape.
fn testName(tree: *const std.zig.Ast, name_token: std.zig.Ast.TokenIndex) ?[]const u8 {
    const text = tree.tokenSlice(name_token);
    return switch (tree.tokenTag(name_token)) {
        .identifier => text,
        .string_literal => if (text.len >= 2 and std.mem.findScalar(u8, text, '\\') == null) text[1 .. text.len - 1] else null,
        else => null,
    };
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
        const call_start = dottedCalleeStart(context.tokens, expect_index + 1) orelse expect_index;
        const qualification = context.source[context.tokens[call_start].loc.start..token.loc.start];
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = context.tokens[call_start].loc.start, .end = context.tokens[expect_end].loc.end },
            .replacement = try context.allocator.print(
                "{s}expectEqualSlices({s}, {s}, {s})",
                .{ qualification, element_type, expected, actual },
            ),
        };
        const fixes = try oneFix(context, "Use expectEqualSlices", edits);
        try context.emit(.{
            .rule = .prefer_testing_expect_equal_slices,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "slice comparison for element type '{s}' produces a less useful failure than expectEqualSlices",
                .{element_type},
            ),
            .fixes = fixes,
        });
    }
}

/// `operation() catch |err| { try std.testing.expectEqual(error.E, err); return; };`
/// followed by `return error.TestExpectedError;` at the end of a function or
/// test body. Only that shape is `expectError`: another handler statement (an
/// `error.OutOfMemory` pass-through for an allocation-failure sweep, a further
/// assertion), a labeled `break`, or a nested block, where the handler's
/// `return` skips the statements after the block, behaves differently.
fn findManualErrorExpectations(context: RuleRun) !void {
    const level = context.level(.prefer_testing_expect_error);
    if (level == .off) return;
    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const body = switch (tree.nodeTag(node)) {
            .fn_decl => tree.nodeData(node).node_and_node[1],
            .test_decl => tree.nodeData(node).opt_token_and_node[1],
            else => continue,
        };
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, body) orelse continue;
        if (statements.len < 2 or !returnsTestExpectedError(tree, statements[statements.len - 1])) continue;
        const statement = statements[statements.len - 2];
        const handled = switch (tree.nodeTag(statement)) {
            .@"catch" => statement,
            .assign => discarded: {
                const target, const value = tree.nodeData(statement).node_and_node;
                if (tree.nodeTag(target) != .identifier or !context.tokenIs(tree.nodeMainToken(target), "_") or
                    tree.nodeTag(value) != .@"catch") continue;
                break :discarded value;
            },
            else => continue,
        };
        const catch_token = tree.nodeMainToken(handled);
        if (tree.tokenTag(catch_token + 1) != .pipe or tree.tokenTag(catch_token + 2) != .identifier) continue;
        const operation, const handler = tree.nodeData(handled).node_and_node;
        const expectation = expectedErrorHandler(context, handler, context.tokenText(catch_token + 2)) orelse continue;
        const fixes: []const types.Fix = if (expectation.qualifier) |qualifier| fixes: {
            const edits = try context.allocator.alloc(types.Edit, 1);
            edits[0] = .{
                .span = .{
                    .start = context.tokens[tree.firstToken(statement)].loc.start,
                    .end = context.tokens[tree.lastToken(statements[statements.len - 1]) + 1].loc.end,
                },
                .replacement = try context.allocator.print(
                    "try {s}expectError({s}, {s});",
                    .{ qualifier, expectation.expected_error, nodeSource(context, operation) },
                ),
            };
            break :fixes try oneFix(context, "Use expectError", edits);
        } else &.{};
        try context.emit(.{
            .rule = .prefer_testing_expect_error,
            .level = level,
            .span = context.tokens[catch_token].loc,
            .message = try context.allocator.dupe(u8, "manual catch assertion is equivalent to std.testing.expectError"),
            .fixes = fixes,
        });
    }
}

fn returnsTestExpectedError(tree: *const Ast, statement: Ast.Node.Index) bool {
    if (tree.nodeTag(statement) != .@"return") return false;
    const value = tree.nodeData(statement).opt_node.unwrap() orelse return false;
    return tree.nodeTag(value) == .error_value and
        std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value) + 2), "TestExpectedError");
}

const ErrorExpectation = struct {
    expected_error: []const u8,
    /// What precedes `expectEqual`, such as `std.testing.`; null for a bare
    /// alias, whose `expectError` counterpart may not be in scope.
    qualifier: ?[]const u8,
};

/// A handler block that is exactly `try <testing>.expectEqual(error.E, capture); return;`.
fn expectedErrorHandler(context: RuleRun, handler: Ast.Node.Index, capture: []const u8) ?ErrorExpectation {
    const tree = context.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, handler) orelse return null;
    if (statements.len != 2 or tree.nodeTag(statements[0]) != .@"try" or
        tree.nodeTag(statements[1]) != .@"return" or tree.nodeData(statements[1]).opt_node != .none) return null;
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, tree.nodeData(statements[0]).node) orelse return null;
    if (call.ast.params.len != 2 or tree.nodeTag(call.ast.params[0]) != .error_value or
        tree.nodeTag(call.ast.params[1]) != .identifier or
        !context.tokenIs(tree.nodeMainToken(call.ast.params[1]), capture)) return null;
    const callee_name = tree.lastToken(call.ast.fn_expr);
    if (!context.tokenIs(callee_name, "expectEqual")) return null;
    return .{
        .expected_error = nodeSource(context, call.ast.params[0]),
        .qualifier = if (tree.nodeTag(call.ast.fn_expr) == .field_access)
            context.source[context.tokens[tree.firstToken(call.ast.fn_expr)].loc.start..context.tokens[callee_name].loc.start]
        else
            null,
    };
}

fn nodeSource(context: RuleRun, node: Ast.Node.Index) []const u8 {
    return context.source[context.tokens[context.tree.firstToken(node)].loc.start..context.tokens[context.tree.lastToken(node)].loc.end];
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

fn qualifiedMemEql(context: RuleRun, expect_index: usize, eql_index: usize) bool {
    return context.tokens[expect_index + 2].tag == .identifier and context.tokenIs(expect_index + 2, "std") and
        context.tokens[expect_index + 3].tag == .period and context.tokenIs(expect_index + 4, "mem") and
        context.tokens[expect_index + 5].tag == .period and context.tokenIs(eql_index, "eql") and
        context.tokens[eql_index + 1].tag == .l_paren;
}

fn oneFix(context: RuleRun, title: []const u8, edits: []const types.Edit) ![]const types.Fix {
    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{ .title = title, .kind = .refactor_rewrite, .edits = edits, .preferred = true, .fix_all = true };
    return fixes;
}

fn sourceBetween(context: RuleRun, start: usize, end: usize) []const u8 {
    return std.mem.trim(u8, context.source[context.tokens[start].loc.start..context.tokens[end - 1].loc.end], " \t\r\n");
}

test "testing idioms produce framework-specific fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "try std.testing.expect(std.mem.eql(u32, expected, actual));\n" ++
        "try std.testing.expect(@abs(actual_float - expected_float) <= tolerance);";
    const configuration = support.only(&.{ .prefer_testing_expect_equal_slices, .prefer_testing_expect_approx }, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "manual catch assertion becomes expectError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "test {\n" ++
        "    operation(&.{}, .{ .depth = 1 }) catch |err| {\n" ++
        "        try std.testing.expectEqual(error.NotFound, err);\n" ++
        "        return;\n" ++
        "    };\n" ++
        "    return error.TestExpectedError;\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_testing_expect_error}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    const edit = findings[0].fixes[0].edits[0];
    try std.testing.expectEqualStrings(
        "try std.testing.expectError(error.NotFound, operation(&.{}, .{ .depth = 1 }));",
        edit.replacement,
    );
    try std.testing.expectEqualStrings(source[std.mem.find(u8, source, "operation").? .. std.mem.findScalarLast(u8, source, ';').? + 1], source[edit.span.start..edit.span.end]);
}

test "a discarded operation loses its discard in the expectError rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check() !void {\n" ++
        "    _ = operation() catch |err| {\n" ++
        "        try testing.expectEqual(error.NotFound, err);\n" ++
        "        return;\n" ++
        "    };\n" ++
        "    return error.TestExpectedError;\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_testing_expect_error}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    const edit = findings[0].fixes[0].edits[0];
    try std.testing.expectEqualStrings("try testing.expectError(error.NotFound, operation());", edit.replacement);
    try std.testing.expectEqual(std.mem.find(u8, source, "_ =").?, edit.span.start);
}

test "an operation bound to a name is not rewritten to expectError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "test {\n" ++
        "    const outcome = operation() catch |err| {\n" ++
        "        try std.testing.expectEqual(error.NotFound, err);\n" ++
        "        return;\n" ++
        "    };\n" ++
        "    return error.TestExpectedError;\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_testing_expect_error}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "catch handlers that do more than expectError, or return past later code, are kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        // An allocation-failure sweep needs OutOfMemory to propagate.
        "fn passthrough(a: Allocator) !void {\n" ++
        "    operation(a) catch |err| {\n" ++
        "        if (err == error.OutOfMemory) return err;\n" ++
        "        try std.testing.expectEqual(error.NotFound, err);\n" ++
        "        return;\n" ++
        "    };\n" ++
        "    return error.TestExpectedError;\n" ++
        "}\n" ++
        "fn assertions() !void {\n" ++
        "    operation() catch |err| {\n" ++
        "        try std.testing.expectEqual(error.NotFound, err);\n" ++
        "        try std.testing.expect(state.clean());\n" ++
        "        return;\n" ++
        "    };\n" ++
        "    return error.TestExpectedError;\n" ++
        "}\n" ++
        // Removing the only break would leave an unused block label.
        "fn labeled() !void {\n" ++
        "    rejection: {\n" ++
        "        operation() catch |err| {\n" ++
        "            try std.testing.expectEqual(error.NotFound, err);\n" ++
        "            break :rejection;\n" ++
        "        };\n" ++
        "        return error.TestExpectedError;\n" ++
        "    }\n" ++
        "    try later();\n" ++
        "}\n" ++
        // The handler's return skips `later`; expectError would not.
        "fn nested(flag: bool) !void {\n" ++
        "    if (flag) {\n" ++
        "        operation() catch |err| {\n" ++
        "            try std.testing.expectEqual(error.NotFound, err);\n" ++
        "            return;\n" ++
        "        };\n" ++
        "        return error.TestExpectedError;\n" ++
        "    }\n" ++
        "    try later();\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_testing_expect_error}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a test named after a root declaration can be its doctest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn parse() void {}\n" ++
        "const Header = struct {};\n" ++
        "test \"parse\" {}\n" ++
        "test \"Header\" {}\n" ++
        "test \"parse works\" {}\n";
    const configuration = support.only(&.{.prefer_doctest}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try support.expectSpans(source, findings, &.{ "\"parse\"", "\"Header\"" });
    try std.testing.expectEqualStrings("parse", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expect(!findings[0].fixes[0].fix_all);
}

test "doctest renames that would collide or name no root declaration are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse() void {}\n" ++
        "fn render() void {}\n" ++
        "const Inner = struct { fn local() void {} test \"local\" {} };\n" ++
        "test parse {}\n" ++
        "test \"parse\" {}\n" ++
        "test \"missing\" {}\n" ++
        "test \"render\\x00\" {}\n";
    const configuration = support.only(&.{.prefer_doctest}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a custom expect harness is not rewritten to expectEqualSlices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "try harness.expect(std.mem.eql(u32, expected, actual));";
    const configuration = support.only(&.{.prefer_testing_expect_equal_slices}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
