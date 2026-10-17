const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;
const syntax_scope = @import("../../syntax/scope.zig");

pub const rules = [_]types.Rule{
    .unsafe_orelse_unreachable,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.unsafe_orelse_unreachable);
    if (level == .off) return;
    const tree = context.tree;
    var test_only: ?syntax_scope.TestOnlyBodies = null;
    defer if (test_only) |*bodies| bodies.deinit(context.allocator);
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeTag(node) != .@"orelse") continue;
        const subject, const fallback = tree.nodeData(node).node_and_node;
        if (tree.nodeTag(fallback) != .unreachable_literal) continue;
        const index = tree.nodeMainToken(node);
        if (context.scopes.insideTestBlock(index) or invariantIsEstablished(context, subject, tree.lastToken(fallback))) continue;
        if (subjectSpan(context.tokens, index)) |span| {
            const subject_text = context.source[context.tokens[span.start].loc.start..context.tokens[span.end - 1].loc.end];
            if (isGuardedByNullAssertion(context, subject_text, span.start)) continue;
        }
        if (test_only == null) test_only = try syntax_scope.testOnlyBodies(context.allocator, context.source, context.tokens);
        if (test_only.?.contains(index)) continue;

        try context.emit(.{
            .rule = .unsafe_orelse_unreachable,
            .level = level,
            .span = context.tokens[index + 1].loc,
            .message = try context.allocator.dupe(
                u8,
                "orelse unreachable turns an absent optional into a panic; handle null or document the invariant with an assertion",
            ),
            .fixes = try unwrapFix(context, node, subject),
        });
    }
}

/// Whether the unwrap of `subject` states an established invariant: a
/// compile-time absence is a compile error, a call with compile-time-known
/// arguments gives the same optional on every run, and a comment can give the
/// reason.
fn invariantIsEstablished(context: RuleRun, subject: Ast.Node.Index, unreachable_index: usize) bool {
    const tree = context.tree;
    const start = tree.firstToken(subject);
    if (context.comptimeEvaluated(start) or
        context.explainedByComment(context.statementStart(start), unreachable_index)) return true;
    return switch (tree.nodeTag(subject)) {
        .call_one, .call_one_comma, .call, .call_comma => context.comptimeKnownCall(start, tree.nodeMainToken(subject)),
        else => false,
    };
}

/// `x orelse unreachable` spelled `x.?`, which is the same unwrap. The subject
/// is parenthesized unless it is already a suffix expression. Declined under
/// `&`, where `&x.?` points into `x` rather than at a copy of its payload.
fn unwrapFix(context: RuleRun, node: Ast.Node.Index, subject: Ast.Node.Index) ![]const types.Fix {
    const tree = context.tree;
    const first = tree.firstToken(node);
    if (first >= 2 and context.tokens[first - 1].tag == .l_paren and context.tokens[first - 2].tag == .ampersand) return &.{};
    const subject_end = context.tokens[tree.lastToken(subject)].loc.end;
    const end = context.tokens[tree.lastToken(node)].loc.end;
    if (containsComment(context.source[subject_end..end])) return &.{};
    const suffixable = switch (tree.nodeTag(subject)) {
        .identifier,
        .field_access,
        .call_one,
        .call_one_comma,
        .call,
        .call_comma,
        .array_access,
        .deref,
        .unwrap_optional,
        .grouped_expression,
        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => true,
        else => false,
    };
    const start = context.tokens[first].loc.start;
    return context.singleFix(.{
        .title = "Unwrap with '.?'",
        .span = if (suffixable) .{ .start = subject_end, .end = end } else .{ .start = start, .end = end },
        .replacement = if (suffixable)
            ".?"
        else
            try context.allocator.print("({s}).?", .{context.source[start..subject_end]}),
    });
}

fn subjectSpan(tokens: []const std.zig.Token, orelse_index: usize) ?struct { start: usize, end: usize } {
    if (orelse_index == 0) return null;
    var cursor = orelse_index;
    if (tokens[cursor - 1].tag != .identifier) return null;
    cursor -= 1;
    while (cursor >= 2 and tokens[cursor - 1].tag == .period and tokens[cursor - 2].tag == .identifier) {
        cursor -= 2;
    }
    return .{ .start = cursor, .end = orelse_index };
}

fn isGuardedByNullAssertion(context: RuleRun, subject_text: []const u8, start_index: usize) bool {
    var brace_depth: usize = 0;
    var cursor = start_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .r_brace => brace_depth += 1,
            .l_brace => {
                if (brace_depth == 0) return false;
                brace_depth -= 1;
            },
            .keyword_fn => return false,
            else => {},
        }
        if (brace_depth != 0) continue;

        if (context.tokens[cursor].tag == .identifier and
            cursor + 1 < start_index and
            isAssignmentOp(context.tokens[cursor + 1].tag))
        {
            if (std.mem.startsWith(u8, subject_text, context.tokenText(cursor))) {
                return false;
            }
        }

        if (isAssertCallee(context, cursor)) {
            if (cursor + 1 < context.tokens.len and context.tokens[cursor + 1].tag == .l_paren) {
                const close_paren = context.matchingToken(cursor + 1, .l_paren, .r_paren) orelse continue;
                if (assertionChecksNonNull(context, cursor + 2, close_paren, subject_text)) {
                    return true;
                }
            }
        }
    }
    return false;
}

fn isAssignmentOp(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal, .percent_equal => true,
        else => false,
    };
}

fn isAssertCallee(context: RuleRun, assert_index: usize) bool {
    if (!context.tokenIs(assert_index, "assert")) return false;
    if (assert_index >= 4 and
        context.tokenIs(assert_index - 4, "std") and
        context.tokens[assert_index - 3].tag == .period and
        context.tokenIs(assert_index - 2, "debug") and
        context.tokens[assert_index - 1].tag == .period and
        (assert_index == 4 or context.tokens[assert_index - 5].tag != .period))
    {
        return true;
    }
    if (assert_index >= 2 and
        context.tokenIs(assert_index - 2, "debug") and
        context.tokens[assert_index - 1].tag == .period and
        (assert_index == 2 or context.tokens[assert_index - 3].tag != .period))
    {
        return true;
    }
    if (assert_index == 0 or context.tokens[assert_index - 1].tag != .period) {
        return true;
    }
    return false;
}

fn assertionChecksNonNull(context: RuleRun, start: usize, end: usize, subject_text: []const u8) bool {
    var i = start;
    while (i < end) : (i += 1) {
        if (context.tokens[i].tag != .bang_equal) continue;
        if (i + 1 < end and context.tokenIs(i + 1, "null")) {
            const lhs_end = i;
            if (lhs_end > start and context.tokens[lhs_end - 1].tag == .identifier) {
                var lhs_start = lhs_end - 1;
                while (lhs_start >= start + 2 and context.tokens[lhs_start - 1].tag == .period and context.tokens[lhs_start - 2].tag == .identifier) {
                    lhs_start -= 2;
                }
                const lhs_text = context.source[context.tokens[lhs_start].loc.start..context.tokens[lhs_end - 1].loc.end];
                if (std.mem.eql(u8, lhs_text, subject_text)) return true;
            }
        }
        if (i > start and context.tokenIs(i - 1, "null")) {
            if (i + 1 < end and context.tokens[i + 1].tag == .identifier) {
                var rhs_end = i + 2;
                while (rhs_end + 1 < end and context.tokens[rhs_end].tag == .period and context.tokens[rhs_end + 1].tag == .identifier) {
                    rhs_end += 2;
                }
                const rhs_text = context.source[context.tokens[i + 1].loc.start..context.tokens[rhs_end - 1].loc.end];
                if (std.mem.eql(u8, rhs_text, subject_text)) return true;
            }
        }
    }
    return false;
}

test "orelse unreachable warns only when the idiomatic rule is enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn get(optional: ?u32) u32 { return optional orelse unreachable; }";
    const configuration = support.only(&.{.unsafe_orelse_unreachable}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "the unwrap fix respects precedence and declines under address-of" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn use(maybe: ?u32, s: S, a: ?u32, b: ?u32) void {\n" ++
        "    _ = maybe orelse unreachable;\n" ++
        "    _ = get() orelse unreachable;\n" ++
        "    _ = s.opt orelse unreachable;\n" ++
        "    _ = (maybe orelse unreachable) + 1;\n" ++
        "    _ = a orelse b orelse unreachable;\n" ++
        "    _ = try fetch() orelse unreachable;\n" ++
        "    _ = &(maybe orelse unreachable);\n" ++
        "    _ = maybe // why\n" ++
        "        orelse unreachable;\n" ++
        "}\n";
    const configuration = support.only(&.{.unsafe_orelse_unreachable}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 8), findings.len);
    const expected = [_]?[]const u8{
        "maybe.?",
        "get().?",
        "s.opt.?",
        "maybe.?",
        "(a orelse b).?",
        "(try fetch()).?",
        null,
        null,
    };
    for (findings, expected) |finding, fixed| {
        const want = fixed orelse {
            try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
            continue;
        };
        const edit = finding.fixes[0].edits[0];
        const statement_start = std.mem.findScalarLast(u8, source[0..edit.span.start], '=').? + 2;
        const result = try std.mem.concat(arena.allocator(), u8, &.{
            source[statement_start..edit.span.start],
            edit.replacement,
        });
        try std.testing.expect(std.mem.endsWith(u8, result, want));
        try std.testing.expect(!finding.fixes[0].fix_all);
    }
}

test "test fixtures may use orelse unreachable as an assertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "test \"fixture\" { _ = optional orelse unreachable; }";
    const configuration = support.only(&.{.unsafe_orelse_unreachable}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "orelse unreachable accepts compile-time evaluation, test-only helpers and stated invariants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const Kind = enum { a, b };\n" ++
        "const first = std.meta.stringToEnum(Kind, \"a\") orelse unreachable;\n" ++
        "fn run(items: []const u32) usize {\n" ++
        "    const second = comptime std.mem.findScalar(u8, \"ab\", 'b') orelse unreachable;\n" ++
        "    const third = std.meta.stringToEnum(Kind, \"b\") orelse unreachable;\n" ++
        "    // The caller appends the sentinel.\n" ++
        "    const fourth = std.mem.findScalar(u32, items, 0) orelse unreachable;\n" ++
        "    return second + @intFromEnum(third) + fourth + (std.mem.findScalar(u32, items, 1) orelse unreachable);\n" ++
        "}\n" ++
        "fn helper(items: []const u32) usize {\n" ++
        "    return std.mem.findScalar(u32, items, 2) orelse unreachable;\n" ++
        "}\n" ++
        "test \"helper\" {\n" ++
        "    _ = helper(&.{2});\n" ++
        "}\n";
    const configuration = support.only(&.{.unsafe_orelse_unreachable}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(std.mem.find(u8, source, "unreachable);").?, findings[0].span.start);
}

test "orelse unreachable does not warn when preceded by assert non-null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn foo(opt: ?u32) u32 {\n" ++
        "    assert(opt != null);\n" ++
        "    return opt orelse unreachable;\n" ++
        "}";
    const configuration = support.only(&.{.unsafe_orelse_unreachable}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "orelse unreachable does not warn when preceded by std.debug.assert non-null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn foo(self: Struct) u32 {\n" ++
        "    std.debug.assert(self.opt != null and self.valid);\n" ++
        "    return self.opt orelse unreachable;\n" ++
        "}";
    const configuration = support.only(&.{.unsafe_orelse_unreachable}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
