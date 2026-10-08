//! Test blocks with no expectation, propagated fallible call, catch, or debug assertion.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;

pub const rules = [_]types.Rule{.assertion_free_test};

pub fn run(context: RuleRun) !void {
    const level = context.level(.assertion_free_test);
    if (level == .off) return;
    for (context.tokens, 0..) |token, test_index| {
        if (token.tag != .keyword_test) continue;
        const opening = nextTagBefore(context.tokens, test_index + 1, .l_brace, .semicolon) orelse continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        if (testHasAssertion(context, opening + 1, closing)) continue;
        try context.emit(.{
            .rule = .assertion_free_test,
            .level = level,
            .span = token.loc,
            .message = "test block contains no expectation, propagated fallible call, catch, or debug assertion",
        });
    }
}

fn testHasAssertion(context: RuleRun, start: usize, end: usize) bool {
    if (testIsCompileSmoke(context, start, end)) return true;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .keyword_try, .keyword_catch => return true,
        .identifier => if (index + 1 < end and context.tokens[index + 1].tag == .l_paren) {
            const name = context.tokenText(index);
            if (std.mem.eql(u8, name, "assert") or std.mem.startsWith(u8, name, "expect")) return true;
        },
        else => {},
    };
    return false;
}

fn testIsCompileSmoke(context: RuleRun, start: usize, end: usize) bool {
    var statement_start = start;
    var statements: usize = 0;
    while (statement_start < end) {
        if (statement_start + 2 >= end or context.tokens[statement_start].tag != .identifier or
            !context.tokenIs(statement_start, "_") or context.tokens[statement_start + 1].tag != .equal) return false;
        const statement_end = context.statementEnd(statement_start) orelse return false;
        if (statement_end >= end) return false;
        statements += 1;
        statement_start = statement_end + 1;
    }
    return statements != 0;
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
