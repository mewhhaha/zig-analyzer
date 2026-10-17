//! Test blocks with no expectation, propagated fallible call, catch, or debug assertion.
const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{.assertion_free_test};

pub fn run(context: RuleRun) !void {
    const level = context.level(.assertion_free_test);
    if (level == .off) return;
    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeTag(node) != .test_decl) continue;
        const body = tree.nodeData(node).opt_token_and_node[1];
        const opening = tree.firstToken(body);
        const closing = tree.lastToken(body);
        if (context.tokens[opening].tag != .l_brace or context.tokens[closing].tag != .r_brace) continue;
        // An empty test anchors a doctest, and a skipped one asserts nothing yet.
        if (closing == opening + 1 or startsWithSkip(context, opening + 1)) continue;
        if (testHasAssertion(context, opening + 1, closing) or referencesOnly(tree, body)) continue;
        try context.emit(.{
            .rule = .assertion_free_test,
            .level = level,
            .span = context.tokens[tree.nodeMainToken(node)].loc,
            .message = "test block contains no expectation, propagated fallible call, catch, or debug assertion",
        });
    }
}

fn testHasAssertion(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .keyword_try, .keyword_catch => return true,
        .identifier => if (index + 1 < end and context.tokens[index + 1].tag == .l_paren) {
            const name = context.tokenText(index);
            if (std.mem.eql(u8, name, "assert") or std.mem.startsWith(u8, name, "expect")) return true;
            // `refAllDecls` and `refAllDeclsRecursive` have the compiler check every declaration.
            if (std.mem.startsWith(u8, name, "refAllDecls")) return true;
        },
        else => {},
    };
    return false;
}

fn startsWithSkip(context: RuleRun, start: usize) bool {
    return start + 3 < context.tokens.len and context.tokens[start].tag == .keyword_return and
        context.tokens[start + 1].tag == .keyword_error and context.tokens[start + 2].tag == .period and
        context.tokenIs(start + 3, "SkipZigTest");
}

/// Whether the statement or block `node` only references declarations so the
/// compiler analyzes them (`_ = X;`, `_ = @import(...);`), possibly under an
/// `if` or `comptime`, or returns early.
fn referencesOnly(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node) orelse return false;
            if (statements.len == 0) return false;
            for (statements) |statement| if (!referencesOnly(tree, statement)) return false;
            return true;
        },
        .assign => {
            const target = tree.nodeData(node).node_and_node[0];
            return tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_");
        },
        .if_simple, .@"if" => {
            const statement = tree.fullIf(node) orelse return false;
            const otherwise = statement.ast.else_expr.unwrap() orelse return referencesOnly(tree, statement.ast.then_expr);
            return referencesOnly(tree, statement.ast.then_expr) and referencesOnly(tree, otherwise);
        },
        .@"comptime" => return referencesOnly(tree, tree.nodeData(node).node),
        .@"return" => return tree.nodeData(node).opt_node == .none,
        else => return false,
    }
}

test "ordinary calls do not turn smoke tests into assertions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "test \"setup only\" { setup(); }\n" ++
        "test \"fallible smoke\" { try setup(); }\n" ++
        "test \"expectation\" { try std.testing.expect(value); }\n";
    const configuration = support.only(&.{.assertion_free_test}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.assertion_free_test, found[0].rule);
}

test "tests without an expectation report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "test \"empty assertion\" { const value = 1; _ = value; }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.assertion_free_test}, .information));
    try support.expectRules(found, &.{.assertion_free_test});
}

test "reference lists, declaration checks, doctest anchors and skipped tests assert by construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const builtin = @import(\"builtin\");\n" ++
        "const Server = struct {};\n" ++
        "test {\n" ++
        "    std.testing.refAllDecls(@This());\n" ++
        "}\n" ++
        "test {\n" ++
        "    if (builtin.is_test) std.testing.refAllDeclsRecursive(@This());\n" ++
        "}\n" ++
        "test Server {}\n" ++
        "test {\n" ++
        "    _ = Server;\n" ++
        "    if (builtin.os.tag == .linux) _ = @import(\"std\");\n" ++
        "    if (builtin.os.tag == .wasi) {\n" ++
        "        _ = Server;\n" ++
        "    } else return;\n" ++
        "    comptime {\n" ++
        "        _ = Server;\n" ++
        "    }\n" ++
        "}\n" ++
        "test \"skipped\" {\n" ++
        "    return error.SkipZigTest;\n" ++
        "}\n" ++
        "test \"reported\" {\n" ++
        "    if (builtin.is_test) setup();\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.assertion_free_test}, .information));
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(std.mem.find(u8, source, "test \"reported\"").?, found[0].span.start);
}
