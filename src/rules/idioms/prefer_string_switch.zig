//! `std.mem.eql` ladders over one string that a string switch expresses directly.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const topLevelComma = @import("../../syntax/tokens.zig").topLevelComma;

pub const rules = [_]types.Rule{.prefer_string_switch};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_string_switch);
    if (level == .off) return;
    var first: ?usize = null;
    var subject: ?[]const u8 = null;
    var first_literal: ?[]const u8 = null;
    var second_literal: ?[]const u8 = null;
    var arms: usize = 0;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "eql") or index < 4 or index + 6 >= context.tokens.len) continue;
        if (!context.tokenIs(index - 4, "std") or !context.tokenIs(index - 2, "mem") or context.tokens[index + 1].tag != .l_paren or
            !context.tokenIs(index + 2, "u8") or context.tokens[index + 3].tag != .comma) continue;
        const end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        const comma = topLevelComma(context.tokens, index + 4, end) orelse continue;
        if (comma + 1 >= end or context.tokens[comma + 1].tag != .string_literal) continue;
        const if_index = precedingIf(context.tokens, index) orelse continue;
        const current_subject = std.mem.trim(u8, context.source[context.tokens[index + 4].loc.start..context.tokens[comma - 1].loc.end], " \t\r\n");
        const literal = context.tokenText(comma + 1);
        const continues_chain = if_index > 0 and context.tokens[if_index - 1].tag == .keyword_else;
        const maps_to_value = maps: {
            if (if_index + 1 >= context.tokens.len or context.tokens[if_index + 1].tag != .l_paren) break :maps false;
            const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse break :maps false;
            const value_start = condition_end + 1;
            if (value_start >= context.tokens.len) break :maps false;
            if (context.tokens[value_start].tag == .period) {
                break :maps value_start + 2 < context.tokens.len and context.tokens[value_start + 1].tag == .identifier and
                    context.tokens[value_start + 2].tag == .keyword_else;
            }
            break :maps value_start + 1 < context.tokens.len and switch (context.tokens[value_start].tag) {
                .identifier, .number_literal, .string_literal, .char_literal => context.tokens[value_start + 1].tag == .keyword_else,
                else => false,
            };
        };
        if (!maps_to_value) {
            subject = null;
            first = null;
            arms = 0;
            first_literal = null;
            second_literal = null;
            continue;
        }
        if (subject == null or !continues_chain) {
            subject = current_subject;
            first = index;
            arms = 1;
            first_literal = literal;
            second_literal = null;
        } else if (std.mem.eql(u8, subject.?, current_subject)) {
            arms += 1;
            if (arms == 2) second_literal = literal;
        } else {
            subject = current_subject;
            first = index;
            arms = 1;
            first_literal = literal;
            second_literal = null;
        }
        if (arms != 3) continue;
        if (std.mem.eql(u8, literal, first_literal.?) or std.mem.eql(u8, literal, second_literal.?)) continue;
        try context.emit(.{
            .rule = .prefer_string_switch,
            .level = level,
            .span = context.tokens[first.?].loc,
            .message = try context.allocator.print("three or more string comparisons dispatch on '{s}'; use std.meta.stringToEnum or std.StaticStringMap", .{subject.?}),
        });
    }
}

fn precedingIf(tokens: []const std.zig.Token, index: usize) ?usize {
    var cursor = index;
    while (cursor > 0 and index - cursor < 24) {
        cursor -= 1;
        if (tokens[cursor].tag == .keyword_if) return cursor;
        if (tokens[cursor].tag == .semicolon or tokens[cursor].tag == .l_brace or tokens[cursor].tag == .r_brace) return null;
    }
    return null;
}

test "string dispatch with branch bodies stays explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(name: []const u8) !void {\n" ++
        "    if (std.mem.eql(u8, name, \"first\")) { try expectFirst();\n" ++
        "    } else if (std.mem.eql(u8, name, \"second\")) { try expectSecond();\n" ++
        "    } else if (std.mem.eql(u8, name, \"third\")) { try expectThird(); }\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_string_switch}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "string comparison ladders report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f(cmd: []const u8) void { const action = if (std.mem.eql(u8, cmd, \"start\")) .start else if (std.mem.eql(u8, cmd, \"stop\")) .stop else if (std.mem.eql(u8, cmd, \"status\")) .status else .unknown; _ = action; }";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_string_switch}, .information));
    try support.expectRules(found, &.{.prefer_string_switch});
}
