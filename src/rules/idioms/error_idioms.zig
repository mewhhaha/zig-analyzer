const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .error_collapsed_to_absence,
    .redundant_error_capture,
};

pub fn run(context: RuleRun) !void {
    try findCollapsedErrors(context);
    try findRedundantCaptures(context);
}

fn findCollapsedErrors(context: RuleRun) !void {
    const level = context.level(.error_collapsed_to_absence);
    if (level == .off) return;
    for (context.tokens, 0..) |token, catch_index| {
        if (token.tag != .keyword_catch) continue;
        var fallback_index = catch_index + 1;
        if (fallback_index < context.tokens.len and context.tokens[fallback_index].tag == .pipe) {
            fallback_index += 1;
            while (fallback_index < context.tokens.len and context.tokens[fallback_index].tag != .pipe) : (fallback_index += 1) {}
            fallback_index += 1;
        }
        if (fallback_index >= context.tokens.len) continue;
        const fallback = context.tokenText(fallback_index);
        const collapses = context.tokens[fallback_index].tag == .identifier and
            (std.mem.eql(u8, fallback, "null") or std.mem.eql(u8, fallback, "false")) or
            context.tokens[fallback_index].tag == .number_literal and std.mem.eql(u8, fallback, "0");
        if (!collapses) continue;
        if (absenceImmediatelyTested(context, fallback_index)) continue;
        if (std.mem.eql(u8, fallback, "false") and conditionTestsFallback(context, fallback_index)) continue;
        try context.emit(.{
            .rule = .error_collapsed_to_absence,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "catch converts every error to '{s}', making failure indistinguishable from a valid empty result",
                .{fallback},
            ),
        });
    }
}

// 'x catch null == null' and 'if (x catch null) |value|' handle the absence on
// the spot, so the collapse is the point rather than a lost failure.
fn absenceImmediatelyTested(context: RuleRun, fallback_index: usize) bool {
    var after = fallback_index + 1;
    while (after < context.tokens.len and context.tokens[after].tag == .r_paren) : (after += 1) {}
    if (after >= context.tokens.len) return false;
    return switch (context.tokens[after].tag) {
        .equal_equal, .bang_equal => true,
        // Only a capture directly after a closed condition, to avoid reading a
        // bitwise-or fallback expression as a capture.
        .pipe => after > fallback_index + 1,
        else => false,
    };
}

/// Whether a `catch false` is an operand of `!`, `and` or `or` in the
/// condition of an `if` or `while`, which branches on the failure at once
/// the way `if (x catch null) |value|` does.
fn conditionTestsFallback(context: RuleRun, fallback_index: usize) bool {
    const tokens = context.tokens;
    var index = fallback_index + 1;
    while (index < tokens.len) {
        switch (tokens[index].tag) {
            .keyword_and, .keyword_or => index += 1,
            .l_paren, .l_bracket => index = (context.scopes.matchingToken(index) orelse return false) + 1,
            .r_paren => {
                const opening = context.scopes.matchingToken(index) orelse return false;
                if (opening == 0) return false;
                switch (tokens[opening - 1].tag) {
                    .keyword_if, .keyword_while => return true,
                    .bang, .keyword_and, .keyword_or, .l_paren => index += 1,
                    else => return false,
                }
            },
            // The rest of an operand that follows a boolean operator.
            .identifier, .period, .bang, .builtin, .number_literal, .equal_equal, .bang_equal => index += 1,
            .keyword_catch => {
                if (index + 1 >= tokens.len) return false;
                index += 2;
            },
            else => return false,
        }
    }
    return false;
}

fn findRedundantCaptures(context: RuleRun) !void {
    const level = context.level(.redundant_error_capture);
    if (level == .off) return;
    for (context.tokens, 0..) |token, catch_index| {
        if (token.tag != .keyword_catch or catch_index + 3 >= context.tokens.len or
            context.tokens[catch_index + 1].tag != .pipe or context.tokens[catch_index + 2].tag != .identifier or
            context.tokens[catch_index + 3].tag != .pipe or context.tokenIs(catch_index + 2, "_")) continue;
        const capture_name = context.tokenText(catch_index + 2);
        const body_start = catch_index + 4;
        if (body_start >= context.tokens.len) continue;
        const body_end = if (context.tokens[body_start].tag == .l_brace)
            context.matchingToken(body_start, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(body_start) orelse continue;
        var used = false;
        for (context.tokens[body_start..body_end], body_start..) |body_token, index| {
            if (body_token.tag == .identifier and context.tokenIs(index, capture_name)) {
                used = true;
                break;
            }
        }
        if (used) continue;
        const fixes = try context.singleFix(.{
            .title = "Remove the unused error capture",
            .span = .{
                .start = context.tokens[catch_index + 1].loc.start,
                .end = context.tokens[catch_index + 3].loc.end + @intFromBool(context.source[context.tokens[catch_index + 3].loc.end] == ' '),
            },
            .replacement = "",
            .preferred = true,
            .fix_all = true,
        });
        try context.emit(.{
            .rule = .redundant_error_capture,
            .level = level,
            .span = context.tokens[catch_index + 2].loc,
            .message = try context.allocator.print(
                "caught error '{s}' is never used; remove the capture",
                .{capture_name},
            ),
            .fixes = fixes,
        });
    }
}

test "immediately tested catch null is deliberate absence handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check() void {\n" ++
        "    if ((load() catch null) == null) mark();\n" ++
        "    if (parse() catch null) |value| use(value);\n" ++
        "    const leaked = load() catch null;\n" ++
        "    _ = leaked;\n" ++
        "}\n";
    const configuration = support.only(&.{.error_collapsed_to_absence}, .warning);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    var collapsed_count: usize = 0;
    for (findings) |finding| if (finding.rule == .error_collapsed_to_absence) {
        collapsed_count += 1;
        try std.testing.expect(finding.span.start > std.mem.find(u8, source, "leaked").?);
    };
    try std.testing.expectEqual(@as(usize, 1), collapsed_count);
}

test "catch false tested by an if or while condition handles the failure at once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(a: u32, b: u32) bool {\n" ++
        "    if (!(equal(a, b) catch false) or !(equal(b, a) catch false)) return false;\n" ++
        "    while (a > 0 and (equal(a, 1) catch false)) {}\n" ++
        "    try require(equal(a, b) catch false);\n" ++
        "    return a == 0 and (equal(a, b) catch false);\n" ++
        "}\n";
    const configuration = support.only(&.{.error_collapsed_to_absence}, .warning);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    for (findings) |finding| try std.testing.expect(finding.span.start > std.mem.find(u8, source, "try require").?);
}

test "collapsed errors and unused captures are distinguished" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const value = load() catch |err| null;";
    const configuration = support.with(support.only(&.{.error_collapsed_to_absence}, .warning), &.{.redundant_error_capture}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
}
