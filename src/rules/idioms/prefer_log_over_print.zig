//! `std.debug.print` in library code that `std.log` should carry.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const findTag = @import("../../syntax/tokens.zig").findTag;

pub const rules = [_]types.Rule{.prefer_log_over_print};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_log_over_print);
    if (level == .off) return;
    if (std.mem.find(u8, context.source, "pub fn build(") != null or
        std.mem.find(u8, context.source, "pub fn main(") != null) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "print") or index < 4 or
            !context.tokenIs(index - 4, "std") or !context.tokenIs(index - 2, "debug")) continue;
        if (insideTestBlock(context, index) or insideTestOnlyFunction(context, index)) continue;
        const fixes = try context.singleFix(.{
            .title = "Use std.log.debug",
            .span = .{ .start = context.tokens[index - 4].loc.start, .end = token.loc.end },
            .replacement = "std.log.debug",
        });
        try context.emit(.{ .rule = .prefer_log_over_print, .level = level, .span = token.loc, .message = "std.debug.print is unconditional diagnostic output; use std.log so callers control level and scope", .fixes = fixes });
    }
}

fn insideTestBlock(context: RuleRun, index: usize) bool {
    var test_scopes: [256]bool = @splat(false);
    var depth: usize = 0;
    for (context.tokens[0..index], 0..) |token, token_index| switch (token.tag) {
        .l_brace => {
            if (depth == test_scopes.len) return false;
            const inherited = depth != 0 and test_scopes[depth - 1];
            test_scopes[depth] = inherited or braceBelongsToTest(context.tokens, token_index);
            depth += 1;
        },
        .r_brace => depth -|= 1,
        else => {},
    };
    return depth != 0 and test_scopes[depth - 1];
}

fn insideTestOnlyFunction(context: RuleRun, index: usize) bool {
    const function = functionContaining(context, index) orelse return false;
    var visited: [16]usize = @splat(std.math.maxInt(usize));
    return functionIsTestOnly(context, function, &visited, 0);
}

fn braceBelongsToTest(tokens: []const std.zig.Token, opening: usize) bool {
    var cursor = opening;
    while (cursor > 0 and opening - cursor < 16) {
        cursor -= 1;
        if (tokens[cursor].tag == .keyword_test) return true;
        if (tokens[cursor].tag == .r_brace or tokens[cursor].tag == .semicolon or tokens[cursor].tag == .keyword_fn) return false;
    }
    return false;
}

fn functionContaining(context: RuleRun, index: usize) ?FunctionIdentity {
    var function: ?FunctionIdentity = null;
    for (context.tokens[0..index], 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 1 >= context.tokens.len or context.tokens[fn_index + 1].tag != .identifier) continue;
        const opening = findTag(context.tokens, fn_index + 2, index + 1, .l_brace) orelse continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        if (index >= closing) continue;
        function = .{ .name = context.tokenText(fn_index + 1), .declaration_index = fn_index + 1 };
    }
    return function;
}

fn functionIsTestOnly(
    context: RuleRun,
    function: FunctionIdentity,
    visited: *[16]usize,
    depth: usize,
) bool {
    if (depth == visited.len) return false;
    for (visited[0..depth]) |declaration_index| if (declaration_index == function.declaration_index) return true;
    visited[depth] = function.declaration_index;
    var saw_caller = false;
    for (context.tokens, 0..) |token, reference| {
        if (reference == function.declaration_index or token.tag != .identifier or !context.tokenIs(reference, function.name) or
            reference + 1 >= context.tokens.len or context.tokens[reference + 1].tag != .l_paren) continue;
        saw_caller = true;
        if (insideTestBlock(context, reference)) continue;
        const caller = functionContaining(context, reference) orelse return false;
        if (!functionIsTestOnly(context, caller, visited, depth + 1)) return false;
    }
    return saw_caller;
}

const FunctionIdentity = struct { name: []const u8, declaration_index: usize };

test "command output from main is not replaced with logging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "pub fn main() void { std.debug.print(\"usage: tool\\n\", .{}); }\n";
    const configuration = support.only(&.{.prefer_log_over_print}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "debug output reachable only from tests remains test output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn printCase() void { std.debug.print(\"case\", .{}); }\n" ++
        "fn verifyCase() void { printCase(); }\n" ++
        "test \"case\" { verifyCase(); }\n";
    const configuration = support.only(&.{.prefer_log_over_print}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "debug prints in library code report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f() void { std.debug.print(\"hello\", .{}); }";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_log_over_print}, .information));
    try support.expectRules(found, &.{.prefer_log_over_print});
}
