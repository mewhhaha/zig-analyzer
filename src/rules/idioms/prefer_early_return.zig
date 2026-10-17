const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const containsComment = tokens_util.containsComment;
const lineIndentation = tokens_util.lineIndentation;
const lineStart = tokens_util.lineStart;

pub const rules = [_]types.Rule{
    .prefer_early_return,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_early_return);
    if (level == .off) return;

    for (context.tokens, 0..) |token, if_index| {
        // The last link of an `else if` chain has no single condition to
        // invert, and its block is already the chain's fallback.
        if (token.tag != .keyword_if or if_index + 7 >= context.tokens.len or
            context.tokens[if_index + 1].tag != .l_paren or
            (if_index > 0 and context.tokens[if_index - 1].tag == .keyword_else)) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        const body_start = condition_end + 1;
        if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (body_end + 2 >= context.tokens.len or context.tokens[body_end + 1].tag != .keyword_else or
            context.tokens[body_end + 2].tag != .l_brace) continue;
        const else_end = context.matchingToken(body_end + 2, .l_brace, .r_brace) orelse continue;
        if (!singleReturn(context.tokens, body_end + 3, else_end)) continue;
        // When the main path leaves too, the branches are two exits and
        // nothing would move out of a block.
        if (blockDiverges(context, body_start, body_end)) continue;

        try context.emit(.{
            .rule = .prefer_early_return,
            .level = level,
            .span = token.loc,
            .message = "the else branch only returns; invert the condition and return early to keep the main path unindented",
            .fixes = try earlyReturnFix(context, if_index, body_start, body_end, else_end),
        });
    }
}

fn singleReturn(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    if (start >= end or tokens[start].tag != .keyword_return or tokens[end - 1].tag != .semicolon) return false;
    for (tokens[start + 1 .. end - 1]) |token| switch (token.tag) {
        .semicolon, .l_brace, .r_brace => return false,
        else => {},
    };
    return true;
}

/// Whether the block between `opening` and `closing` never completes: its
/// last statement diverges, or is an `if`/`else` chain every branch of which
/// does.
fn blockDiverges(context: RuleRun, opening: usize, closing: usize) bool {
    if (closing <= opening + 1) return false;
    return switch (context.tokens[closing - 1].tag) {
        .semicolon => context.statementDiverges(lastStatementStart(context, opening, closing) orelse return false),
        .r_brace => chainDiverges(context, closing - 1),
        else => false,
    };
}

/// Whether the `if`/`else` chain whose final `else` block closes at `close`
/// leaves in every branch.
fn chainDiverges(context: RuleRun, close: usize) bool {
    const tokens = context.tokens;
    var block_close = close;
    var branches: usize = 0;
    while (true) : (branches += 1) {
        const block_open = context.scopes.matchingToken(block_close) orelse return false;
        if (block_open < 2 or !blockDiverges(context, block_open, block_close)) return false;
        switch (tokens[block_open - 1].tag) {
            .keyword_else => {
                if (tokens[block_open - 2].tag != .r_brace) return false;
                block_close = block_open - 2;
            },
            // The final block must be an `else`; an `if` block ends the walk
            // unless an `else` leads into it.
            .r_paren => {
                if (branches == 0) return false;
                const condition_open = context.scopes.matchingToken(block_open - 1) orelse return false;
                if (condition_open < 3 or tokens[condition_open - 1].tag != .keyword_if) return false;
                if (tokens[condition_open - 2].tag != .keyword_else) return true;
                if (tokens[condition_open - 3].tag != .r_brace) return false;
                block_close = condition_open - 3;
            },
            else => return false,
        }
    }
}

/// First token of the last statement of the block `{` at `opening`, when that
/// statement ends with `;`.
fn lastStatementStart(context: RuleRun, opening: usize, closing: usize) ?usize {
    const tokens = context.tokens;
    if (closing <= opening + 1 or tokens[closing - 1].tag != .semicolon) return null;
    var cursor = closing - 1;
    while (cursor > opening + 1) {
        const previous = cursor - 1;
        switch (tokens[previous].tag) {
            .semicolon => return cursor,
            .r_paren, .r_bracket => cursor = context.scopes.matchingToken(previous) orelse return null,
            .r_brace => {
                const brace = context.scopes.matchingToken(previous) orelse return null;
                // A block statement ends before the next statement starts; an
                // initializer or a switch expression continues into it.
                const expression = tokens[brace - 1].tag == .period or switch (tokens[cursor].tag) {
                    .semicolon, .comma, .period, .period_asterisk, .keyword_else, .keyword_catch, .keyword_orelse, .r_paren, .r_bracket => true,
                    else => false,
                };
                if (!expression) return cursor;
                cursor = brace;
            },
            else => cursor = previous,
        }
    }
    return cursor;
}

/// Inverts the condition and moves the main path after the early return, when
/// the move cannot change meaning or layout: the `if` is a statement on a line
/// of its own, the condition fits on one line, no comment sits between the
/// rearranged pieces, and the main path holds no `defer` and no declaration
/// that the rest of the enclosing block could collide with.
fn earlyReturnFix(context: RuleRun, if_index: usize, body_start: usize, body_end: usize, else_end: usize) ![]const types.Fix {
    const tokens = context.tokens;
    const source = context.source;
    if (if_index == 0) return &.{};
    switch (tokens[if_index - 1].tag) {
        .semicolon, .l_brace, .r_brace => {},
        else => return &.{},
    }
    const indent = lineIndentation(source, tokens[if_index].loc.start);
    if (lineStart(source, tokens[if_index].loc.start) + indent.len != tokens[if_index].loc.start) return &.{};
    const condition = source[tokens[if_index + 1].loc.end..tokens[body_start - 1].loc.start];
    if (std.mem.findScalar(u8, condition, '\n') != null or containsComment(condition)) return &.{};
    if (containsComment(source[tokens[body_start - 1].loc.start..tokens[body_start].loc.end]) or
        containsComment(source[tokens[body_end].loc.start..tokens[body_end + 2].loc.end])) return &.{};

    const rest_end = context.enclosingScopeEnd(if_index) orelse return &.{};
    for (tokens[body_start + 1 .. body_end], body_start + 1..) |token, index| {
        if (context.enclosingOpeningBrace(index) != body_start) continue;
        switch (token.tag) {
            .keyword_defer, .keyword_errdefer => return &.{},
            .keyword_const, .keyword_var => {
                if (index + 1 >= body_end or tokens[index + 1].tag != .identifier) return &.{};
                if (context.rangeContainsName(context.tokenText(index + 1), else_end + 1, rest_end)) return &.{};
            },
            else => {},
        }
    }

    // The main path must be whole lines one level in, so moving it out is a
    // dedent; the else block keeps its lines as they are.
    const closing_line = try context.allocator.print("\n{s}", .{indent});
    const main_path = source[tokens[body_start].loc.end..tokens[body_end].loc.start];
    const early = source[tokens[body_end + 2].loc.end..tokens[else_end].loc.start];
    if (early.len == 0 or early[0] != '\n' or !std.mem.endsWith(u8, early, closing_line)) return &.{};
    var moved: std.ArrayList(u8) = .empty;
    defer moved.deinit(context.allocator);
    if (main_path.len != 0) {
        if (main_path[0] != '\n' or !std.mem.endsWith(u8, main_path, closing_line)) return &.{};
        const nested = try context.allocator.print("{s}    ", .{indent});
        var lines = std.mem.splitScalar(u8, main_path[1 .. main_path.len - closing_line.len], '\n');
        while (lines.next()) |line| {
            try moved.append(context.allocator, '\n');
            if (std.mem.trim(u8, line, " \t").len == 0) continue;
            if (!std.mem.startsWith(u8, line, nested)) return &.{};
            try moved.print(context.allocator, "{s}{s}", .{ indent, line[nested.len..] });
        }
    }
    return context.singleFix(.{
        .title = "Invert the condition and return early",
        .kind = .refactor_rewrite,
        .span = .{ .start = tokens[if_index + 1].loc.start, .end = tokens[else_end].loc.end },
        .replacement = try context.allocator.print("({s}) {{{s}}}{s}", .{
            try invertedCondition(context, if_index + 1, body_start - 1),
            early,
            moved.items,
        }),
    });
}

/// The negation of the condition between the parentheses at `open` and
/// `close`: an equality flips, a negated operand loses its `!`, a plain
/// operand gains one, and anything else is negated as a group.
fn invertedCondition(context: RuleRun, open: usize, close: usize) ![]const u8 {
    const tokens = context.tokens;
    const source = context.source;
    const condition = std.mem.trim(u8, source[tokens[open].loc.end..tokens[close].loc.start], " ");
    // The one top-level `==` or `!=`; `close` once an `and`/`or` or a second
    // equality rules a flip out.
    var equality: ?usize = null;
    var operand = true;
    var cursor = open + 1;
    while (cursor < close) : (cursor += 1) {
        switch (tokens[cursor].tag) {
            .l_paren, .l_bracket, .l_brace => cursor = context.scopes.matchingToken(cursor) orelse close,
            .identifier, .period, .period_asterisk, .question_mark, .builtin, .number_literal, .string_literal, .char_literal => {},
            .bang => operand = operand and cursor == open + 1,
            .equal_equal, .bang_equal => {
                equality = if (equality == null) cursor else close;
                operand = false;
            },
            .keyword_and, .keyword_or => {
                equality = close;
                operand = false;
            },
            else => operand = false,
        }
    }
    if (equality) |operator| if (operator != close) {
        return context.allocator.print("{s}{s}{s}", .{
            std.mem.trimStart(u8, source[tokens[open].loc.end..tokens[operator].loc.start], " "),
            if (tokens[operator].tag == .equal_equal) "!=" else "==",
            std.mem.trimEnd(u8, source[tokens[operator].loc.end..tokens[close].loc.start], " "),
        });
    };
    if (!operand) return context.allocator.print("!({s})", .{condition});
    if (tokens[open + 1].tag == .bang) return std.mem.trimStart(u8, source[tokens[open + 1].loc.end..tokens[close].loc.start], " ");
    return context.allocator.print("!{s}", .{condition});
}

test "a returning else branch prefers an early return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(ready: bool) void {\n" ++
        "    if (ready) {\n" ++
        "        work();\n" ++
        "\n" ++
        "        rest();\n" ++
        "    } else {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "    done();\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(@as(usize, 1), findings[0].fixes.len);
    try std.testing.expect(!findings[0].fixes[0].fix_all);
    try std.testing.expectEqualStrings(
        "fn run(ready: bool) void {\n" ++
            "    if (!ready) {\n" ++
            "        return;\n" ++
            "    }\n" ++
            "    work();\n" ++
            "\n" ++
            "    rest();\n" ++
            "    done();\n" ++
            "}",
        try applied(arena.allocator(), source, findings[0].fixes[0]),
    );
}

test "the early-return fix inverts equalities, negations and compound conditions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][2][]const u8{
        .{ "count == 0", "count != 0" },
        .{ "items.len != limit(1)", "items.len == limit(1)" },
        .{ "!self.ready()", "self.ready()" },
        .{ "map.get(key).?", "!map.get(key).?" },
        .{ "a and b == c", "!(a and b == c)" },
        .{ "count > 0", "!(count > 0)" },
        .{ "!a or b", "!(!a or b)" },
    };
    for (cases) |case| {
        const source = try arena.allocator().printSentinel(
            \\fn run() u32 {{
            \\    if ({s}) {{
            \\        work();
            \\    }} else {{
            \\        return 1;
            \\    }}
            \\    return 0;
            \\}}
        , .{case[0]}, 0);
        const findings = try findingsFor(arena.allocator(), source);
        try std.testing.expectEqual(@as(usize, 1), findings.len);
        const fixed = try applied(arena.allocator(), source, findings[0].fixes[0]);
        const expected = try arena.allocator().print("    if ({s}) {{\n        return 1;\n    }}\n    work();\n", .{case[1]});
        try std.testing.expect(std.mem.find(u8, fixed, expected) != null);
    }
}

test "the early-return fix is declined when moving the main path could change meaning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn deferred(ready: bool) void {\n    if (ready) {\n        defer close();\n        work();\n    } else {\n        return;\n    }\n    done();\n}\n" ++
        "fn collides(ready: bool) void {\n    if (ready) {\n        const value = 1;\n        use(value);\n    } else {\n        return;\n    }\n    const value = 2;\n    use(value);\n}\n" ++
        "fn commented(ready: bool) void {\n    if (ready) {\n        work();\n    } // the slow path\n    else {\n        return;\n    }\n}\n" ++
        "fn spread(ready: bool, other: bool) void {\n    if (ready and\n        other)\n    {\n        work();\n    } else {\n        return;\n    }\n}\n" ++
        "fn pick(ready: bool) void {\n    const run = switch (ready) {\n        true => if (ready) {\n            work();\n        } else {\n            return;\n        },\n        false => {},\n    };\n    _ = run;\n}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 5), findings.len);
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
}

test "else branches with cleanup before returning stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (ready) { work(); } else { cleanup(); return; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "branches that both leave have no main path to unindent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn decode(u: u32) i32 {\n    if (u & 1 != 0) {\n        return -1;\n    } else {\n        return 1;\n    }\n}\n" ++
        "fn pick(flag: bool) Choice {\n    if (flag) {\n        log();\n        return .{ .single = true };\n    } else {\n        return .{ .single = false };\n    }\n}\n" ++
        "fn scan(items: []const u8) void {\n    for (items) |item| {\n        if (item == 0) {\n            if (item > 1) {\n                log();\n            }\n            continue;\n        } else {\n            return;\n        }\n    }\n}\n" ++
        "fn fail(flag: bool) void {\n    if (flag) {\n        @panic(\"flag\");\n    } else {\n        return;\n    }\n}\n" ++
        "fn nested(wide: bool, aligned: bool) u32 {\n    if (wide) {\n        if (aligned) {\n            return 6;\n        } else if (!wide) {\n            return 5;\n        } else {\n            return 4;\n        }\n    } else {\n        return 3;\n    }\n}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a main path ending in an if without an else still continues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn partial(wide: bool, aligned: bool) u32 {\n    if (wide) {\n        if (aligned) {\n            return 6;\n        }\n    } else {\n        return 3;\n    }\n    return 0;\n}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "the last link of an else-if chain is not an early-return candidate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn search(items: []const u32, wanted: u32, low: *usize, high: *usize, middle: usize) ?usize {\n" ++
        "    if (items[middle] < wanted) {\n" ++
        "        low.* = middle + 1;\n" ++
        "    } else if (items[middle] > wanted) {\n" ++
        "        high.* = middle;\n" ++
        "    } else {\n" ++
        "        return middle;\n" ++
        "    }\n" ++
        "    return null;\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn applied(allocator: std.mem.Allocator, source: []const u8, fix: types.Fix) ![]const u8 {
    const edit = fix.edits[0];
    return std.mem.concat(allocator, u8, &.{ source[0..edit.span.start], edit.replacement, source[edit.span.end..] });
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.prefer_early_return}, .information));
}
