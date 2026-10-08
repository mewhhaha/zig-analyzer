//! Element-by-element fills that `@memset` expresses directly.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_module = @import("../../syntax/tokens.zig");

const findTag = tokens_module.findTag;

pub const rules = [_]types.Rule{.prefer_memset};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_memset);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 7 >= context.tokens.len or context.tokens[for_index + 1].tag != .l_paren) continue;
        const iter_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (iter_end + 3 >= context.tokens.len or context.tokens[iter_end + 1].tag != .pipe) continue;
        const capture_end = findTag(context.tokens, iter_end + 2, context.tokens.len, .pipe) orelse continue;

        // Determine target slice from loop header
        const header_end = tokens_module.argumentsEnd(context.tokens, for_index + 1, iter_end) orelse continue;
        const comma_in_header = tokens_module.topLevelComma(context.tokens, for_index + 2, header_end);

        const target_end_token = if (comma_in_header) |c| c - 1 else header_end - 1;
        if (target_end_token < for_index + 2) continue;

        // If secondary iterable exists, it must be 0..
        if (comma_in_header) |c| {
            if (c + 1 >= header_end) continue;
            const second_header = std.mem.trim(u8, context.source[context.tokens[c + 1].loc.start..context.tokens[header_end - 1].loc.end], " \t\r\n");
            if (!std.mem.startsWith(u8, second_header, "0..")) continue;
        }

        // Check captures: |*element| or |*element, _|
        const capture_tokens = context.tokens[iter_end + 2 .. capture_end];
        if (capture_tokens.len < 2 or capture_tokens[0].tag != .asterisk or capture_tokens[1].tag != .identifier) continue;
        const name = context.tokenText(iter_end + 3);
        var second_capture_name: ?[]const u8 = null;
        if (capture_tokens.len > 2) {
            if (capture_tokens.len < 4 or capture_tokens[2].tag != .comma or capture_tokens[3].tag != .identifier) continue;
            second_capture_name = context.tokenText(iter_end + 5);
        }

        // Check loop body: braced or unbraced
        if (capture_end + 1 >= context.tokens.len) continue;
        const is_braced = context.tokens[capture_end + 1].tag == .l_brace;
        const body_end = if (is_braced)
            context.matchingToken(capture_end + 1, .l_brace, .r_brace) orelse continue
        else blk: {
            var s = capture_end + 1;
            while (s < context.tokens.len and context.tokens[s].tag != .semicolon) : (s += 1) {}
            if (s >= context.tokens.len) continue;
            break :blk s;
        };

        const stmt_start = if (is_braced) capture_end + 2 else capture_end + 1;
        const semi_index = if (is_braced) body_end - 1 else body_end;
        if (stmt_start + 3 >= semi_index) continue;
        if (!context.tokenIs(stmt_start, name) or
            context.tokens[stmt_start + 1].tag != .period_asterisk or
            context.tokens[stmt_start + 2].tag != .equal or
            context.tokens[semi_index].tag != .semicolon) continue;

        const val_start = stmt_start + 3;
        const val_end = semi_index;
        if (context.findIdentifier(val_start, val_end, name) != null) continue;
        if (second_capture_name) |sec| {
            if (!std.mem.eql(u8, sec, "_") and context.findIdentifier(val_start, val_end, sec) != null) continue;
        }
        if (!stableFillValue(context.tokens, val_start, val_end)) continue;

        const target = std.mem.trim(u8, context.source[context.tokens[for_index + 2].loc.start..context.tokens[target_end_token].loc.end], " \t\r\n");
        const value = std.mem.trim(u8, context.source[context.tokens[val_start].loc.start..context.tokens[val_end - 1].loc.end], " \t\r\n");

        const fixes = try context.singleFix(.{
            .title = "Replace the element loop with @memset",
            .kind = .refactor_rewrite,
            .span = .{ .start = token.loc.start, .end = context.tokens[body_end].loc.end },
            .replacement = try context.allocator.print("@memset({s}, {s});", .{ target, value }),
            .preferred = true,
            .fix_all = true,
        });
        try context.emit(.{ .rule = .prefer_memset, .level = level, .span = token.loc, .message = "this loop only fills every element with one invariant value; use @memset", .fixes = fixes });
    }
}

fn stableFillValue(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    if (start >= end) return false;
    for (tokens[start..end]) |token| switch (token.tag) {
        .identifier, .number_literal, .string_literal, .char_literal, .period, .minus, .plus => {},
        else => return false,
    };
    return true;
}

test "memset rewrites do not collapse repeated side effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn fill(buffer: []u8) void { for (buffer) |*element| { element.* = nextValue(); } }";
    const configuration = support.only(&.{.prefer_memset}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "prefer_memset handles unbraced and discarded index loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn fill(buffer: []u8) void {\n" ++
        "    for (buffer) |*b| b.* = 0;\n" ++
        "    for (buffer, 0..) |*b, _| { b.* = 42; }\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_memset}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("@memset(buffer, 0);", found[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("@memset(buffer, 42);", found[1].fixes[0].edits[0].replacement);
}

test "element fill loops report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f(buffer: anytype) void { for (buffer) |*element| { element.* = 0; } }";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_memset}, .information));
    try support.expectRules(found, &.{.prefer_memset});
}
