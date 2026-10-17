//! `std.mem.eql` ladders over one string that a string switch expresses directly.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_module = @import("../../syntax/tokens.zig");
const topLevelComma = tokens_module.topLevelComma;

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
            .fixes = try stringMapFix(context, first.?),
        });
    }
}

/// `std.StaticStringMap(V).initComptime(.{ .{ "a", x }, ... }).get(s) orelse y`
/// for a whole chain `if (std.mem.eql(u8, s, "a")) x else ... else y` that
/// starts a `return` or a `const name: V =` initializer. Every arm compares
/// the same path with a distinct literal and yields one token value (or an
/// enum literal), so the map finds what the first matching arm returned and
/// `orelse` evaluates the fallback only when no arm matched. `V` is the
/// spelled result type the values already coerce to.
fn stringMapFix(context: RuleRun, first_eql: usize) ![]const types.Fix {
    const tokens = context.tokens;
    const head = precedingIf(tokens, first_eql) orelse return &.{};
    const value_type = chainResultType(context, head) orelse return &.{};
    if (!context.standardLibraryVisible(first_eql - 4)) return &.{};
    var entries: std.Io.Writer.Allocating = .init(context.allocator);
    defer entries.deinit();
    var literals: std.ArrayList([]const u8) = .empty;
    defer literals.deinit(context.allocator);
    var subject: ?[]const u8 = null;
    var cursor = head;
    const fallback = while (true) {
        // `if (std.mem.eql(u8, subject, "literal")) value else`
        if (cursor + 10 >= tokens.len or tokens[cursor].tag != .keyword_if or tokens[cursor + 1].tag != .l_paren or
            !context.tokenIs(cursor + 2, "std") or tokens[cursor + 3].tag != .period or !context.tokenIs(cursor + 4, "mem") or
            tokens[cursor + 5].tag != .period or !context.tokenIs(cursor + 6, "eql") or tokens[cursor + 7].tag != .l_paren or
            !context.tokenIs(cursor + 8, "u8") or tokens[cursor + 9].tag != .comma) return &.{};
        const condition_end = context.matchingToken(cursor + 1, .l_paren, .r_paren) orelse return &.{};
        const call_end = context.matchingToken(cursor + 7, .l_paren, .r_paren) orelse return &.{};
        const comma = topLevelComma(tokens, cursor + 10, call_end) orelse return &.{};
        if (call_end + 1 != condition_end or comma + 2 != call_end or tokens[comma + 1].tag != .string_literal or
            !tokens_module.isDottedPath(tokens, cursor + 10, comma)) return &.{};
        const arm_subject = context.source[tokens[cursor + 10].loc.start..tokens[comma - 1].loc.end];
        if (subject) |known| {
            if (!std.mem.eql(u8, known, arm_subject)) return &.{};
        } else subject = arm_subject;
        const literal = context.tokenText(comma + 1);
        for (literals.items) |seen| if (std.mem.eql(u8, seen, literal)) return &.{};
        try literals.append(context.allocator, literal);
        const value_end = simpleValueEnd(tokens, condition_end + 1) orelse return &.{};
        if (tokens[value_end].tag != .keyword_else) return &.{};
        try entries.writer.print("{s}.{{ {s}, {s} }}", .{
            if (literals.items.len == 1) "" else ", ",
            literal,
            context.source[tokens[condition_end + 1].loc.start..tokens[value_end - 1].loc.end],
        });
        cursor = value_end + 1;
        if (tokens[cursor].tag == .keyword_if) continue;
        const fallback_end = simpleValueEnd(tokens, cursor) orelse return &.{};
        if (tokens[fallback_end].tag != .semicolon) return &.{};
        break fallback_end;
    };
    const span: std.zig.Token.Loc = .{ .start = tokens[head].loc.start, .end = tokens[fallback - 1].loc.end };
    if (tokens_module.containsComment(context.source[span.start..span.end])) return &.{};
    return context.singleFix(.{
        .title = "Look the string up in a std.StaticStringMap",
        .span = span,
        .replacement = try context.allocator.print("std.StaticStringMap({s}).initComptime(.{{ {s} }}).get({s}) orelse {s}", .{
            value_type,
            entries.written(),
            subject.?,
            context.source[tokens[cursor].loc.start..tokens[fallback - 1].loc.end],
        }),
        .preferred = true,
    });
}

/// The token after a one-token value or an enum literal starting at `start`.
fn simpleValueEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    if (start + 1 >= tokens.len) return null;
    if (tokens[start].tag == .period) return if (tokens[start + 1].tag == .identifier) start + 2 else null;
    return switch (tokens[start].tag) {
        .identifier, .number_literal, .string_literal, .char_literal => start + 1,
        else => null,
    };
}

/// The spelled type the chain at `head` produces: the return type of the
/// enclosing function for `return if ...`, or the annotation of
/// `const name: V = if ...`, when it is a plain dotted path. Values coerce to
/// it in the chain as they do in the map.
fn chainResultType(context: RuleRun, head: usize) ?[]const u8 {
    const tokens = context.tokens;
    if (head < 4) return null;
    switch (tokens[head - 1].tag) {
        .keyword_return => {
            const body = context.scopes.enclosingFunctionBody(head) orelse return null;
            var start = body;
            while (start > 1 and tokens[start - 1].tag == .identifier) {
                start -= 1;
                if (tokens[start - 1].tag != .period) break;
                start -= 1;
            }
            if (start == body or !tokens_module.isDottedPath(tokens, start, body)) return null;
            return switch (tokens[start - 1].tag) {
                .r_paren, .bang, .question_mark => context.source[tokens[start].loc.start..tokens[body - 1].loc.end],
                else => null,
            };
        },
        .equal => {
            var start = head - 1;
            while (start > 0 and tokens[start - 1].tag != .colon) : (start -= 1) {
                if (tokens[start - 1].tag != .identifier and tokens[start - 1].tag != .period) return null;
            }
            if (start < 3 or start == head - 1 or (tokens[start - 3].tag != .keyword_const and tokens[start - 3].tag != .keyword_var) or
                !tokens_module.isDottedPath(tokens, start, head - 1)) return null;
            return context.source[tokens[start].loc.start..tokens[head - 2].loc.end];
        },
        else => return null,
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

fn fixedFor(allocator: std.mem.Allocator, source: [:0]const u8) !?[]const u8 {
    const found = try support.findings(allocator, run, source, support.only(&.{.prefer_string_switch}, .information));
    try std.testing.expectEqual(@as(usize, 1), found.len);
    if (found[0].fixes.len == 0) return null;
    return try support.applyFix(allocator, source, found[0].fixes[0]);
}

test "a string comparison chain becomes a StaticStringMap lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\nconst Command = enum { start, stop, status, unknown };\n" ++
            "fn parse(cmd: []const u8) Command {\n" ++
            "    return std.StaticStringMap(Command).initComptime(.{ .{ \"start\", .start }, .{ \"stop\", .stop }, .{ \"status\", .status } }).get(cmd) orelse .unknown;\n" ++
            "}",
        (try fixedFor(allocator, "const std = @import(\"std\");\nconst Command = enum { start, stop, status, unknown };\n" ++
            "fn parse(cmd: []const u8) Command {\n" ++
            "    return if (std.mem.eql(u8, cmd, \"start\")) .start\n" ++
            "    else if (std.mem.eql(u8, cmd, \"stop\")) .stop\n" ++
            "    else if (std.mem.eql(u8, cmd, \"status\")) .status\n" ++
            "    else .unknown;\n" ++
            "}")).?,
    );
    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\nfn f(self: Self) void {\n" ++
            "    const code: u8 = std.StaticStringMap(u8).initComptime(.{ .{ \"a\", 1 }, .{ \"b\", 2 }, .{ \"c\", 3 } }).get(self.name) orelse fallback;\n" ++
            "    _ = code;\n}",
        (try fixedFor(allocator, "const std = @import(\"std\");\nfn f(self: Self) void {\n" ++
            "    const code: u8 = if (std.mem.eql(u8, self.name, \"a\")) 1 else if (std.mem.eql(u8, self.name, \"b\")) 2 else if (std.mem.eql(u8, self.name, \"c\")) 3 else fallback;\n" ++
            "    _ = code;\n}")).?,
    );
}

test "a string comparison chain the map cannot express keeps its ifs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const arms = "if (std.mem.eql(u8, cmd, \"a\")) .a else if (std.mem.eql(u8, cmd, \"b\")) .b else if (std.mem.eql(u8, cmd, \"c\")) .c";
    for ([_][:0]const u8{
        // No spelled result type for the map.
        "const std = @import(\"std\");\nfn f(cmd: []const u8) void { const v = " ++ arms ++ " else .d; use(v); }",
        "const std = @import(\"std\");\nfn f(cmd: []const u8) ?Kind { return " ++ arms ++ " else null orelse .d; }",
        // A fallback or arm that is not a simple value, or a chain that does not end in else.
        "const std = @import(\"std\");\nfn f(cmd: []const u8) Kind { return " ++ arms ++ " else pick(cmd); }",
        "const std = @import(\"std\");\nfn f(cmd: []const u8, other: []const u8) Kind { return " ++ arms ++
            " else if (std.mem.eql(u8, other, \"d\")) .d else .e; }",
        // A comment would be lost; std is not the standard library.
        "const std = @import(\"std\");\nfn f(cmd: []const u8) Kind { return " ++ arms ++ " // none\n else .d; }",
        "const std = @import(\"other\");\nfn f(cmd: []const u8) Kind { return " ++ arms ++ " else .d; }",
    }) |source| {
        errdefer std.debug.print("fixed: {s}\n", .{source});
        try std.testing.expectEqual(@as(?[]const u8, null), try fixedFor(allocator, source));
    }
}
