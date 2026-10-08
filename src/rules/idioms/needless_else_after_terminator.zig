//! `else` branches after an `if` branch that always returns, breaks or continues.
const std = @import("std");

const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
const matchingOpeningToken = @import("../../syntax/tokens.zig").matchingOpeningToken;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Edit = types.Edit;
const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .needless_else_after_terminator,
};

pub fn run(context: RuleRun) !void {
    try findNeedlessElse(context);
}

fn findNeedlessElse(context: RuleRun) !void {
    const tokens = context.tokens;
    const level = context.level(.needless_else_after_terminator);
    if (level == .off) return;
    for (tokens, 0..) |token, else_index| {
        if (token.tag != .keyword_else or else_index == 0 or else_index + 1 >= tokens.len or tokens[else_index + 1].tag != .l_brace) continue;
        if (tokens[else_index - 1].tag != .r_brace) continue;
        const preceding_open = matchingOpeningToken(tokens, else_index - 1, .l_brace, .r_brace) orelse continue;
        // A loop's else runs when the loop exits without break, so it is never removable.
        if (!precedingBlockIsIfStatement(tokens, preceding_open)) continue;
        if (blockBelongsToElseIf(tokens, preceding_open)) continue;
        if (!blockAlwaysTerminates(tokens, preceding_open, else_index - 1)) continue;
        const else_close = matchingToken(tokens, else_index + 1, .l_brace, .r_brace) orelse continue;
        const declares_bindings = blockDeclaresBindings(tokens, else_index + 1, else_close);
        const fixes = if (declares_bindings) blk: {
            const f = try Fix.single(context.allocator, .{
                .title = "Remove else keyword after terminating branch",
                .span = .{ .start = token.loc.start, .end = tokens[else_index + 1].loc.start },
                .replacement = "",
                .preferred = true,
            });
            break :blk f;
        } else if (try dedentedElseBody(context, else_index, else_close)) |flattened| blk: {
            const f = try Fix.single(context.allocator, .{
                .title = "Flatten else after terminating branch",
                .span = .{ .start = tokens[else_index - 1].loc.end, .end = tokens[else_close].loc.end },
                .replacement = flattened,
                .preferred = true,
            });
            break :blk f;
        } else blk: {
            const edits = try context.allocator.alloc(Edit, 2);
            edits[0] = .{ .span = .{ .start = token.loc.start, .end = tokens[else_index + 1].loc.end }, .replacement = "" };
            edits[1] = .{ .span = tokens[else_close].loc, .replacement = "" };
            const f = try context.allocator.alloc(Fix, 1);
            f[0] = .{ .title = "Flatten else after terminating branch", .kind = .quickfix, .edits = edits, .preferred = true };
            break :blk f;
        };
        try context.emit(.{
            .rule = .needless_else_after_terminator,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(u8, "else is unnecessary because the preceding branch always terminates"),
            .fixes = fixes,
        });
    }
}

/// The else body as statements one level out, starting with the newline that
/// follows the `if` block's closing brace; null unless the usual `} else {`
/// layout with the body on its own lines holds.
fn dedentedElseBody(context: RuleRun, else_index: usize, else_close: usize) !?[]const u8 {
    const tokens = context.tokens;
    const source = context.source;
    if (!std.mem.eql(u8, source[tokens[else_index - 1].loc.end..tokens[else_index].loc.start], " ")) return null;
    const body = source[tokens[else_index + 1].loc.end..tokens[else_close].loc.start];
    const first_newline = std.mem.findScalar(u8, body, '\n') orelse return null;
    if (std.mem.trim(u8, body[0..first_newline], " \t").len != 0) return null;
    const text = std.mem.trimEnd(u8, body[first_newline + 1 ..], " \t\r\n");
    if (text.len == 0) return null;
    var writer: std.Io.Writer.Allocating = .init(context.allocator);
    defer writer.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try writer.writer.writeByte('\n');
        const indent = if (std.mem.startsWith(u8, line, "    ")) line[4..] else line;
        try writer.writer.writeAll(indent);
    }
    return try writer.toOwnedSlice();
}

fn blockDeclaresBindings(tokens: []const std.zig.Token, opening: usize, closing: usize) bool {
    var depth: usize = 0;
    for (tokens[opening + 1 .. closing]) |tok| {
        switch (tok.tag) {
            .l_brace, .l_paren, .l_bracket => depth += 1,
            .r_brace, .r_paren, .r_bracket => if (depth > 0) {
                depth -= 1;
            },
            .keyword_const, .keyword_var => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn precedingBlockIsIfStatement(tokens: []const std.zig.Token, opening: usize) bool {
    const condition_open = ifConditionOpenForBlock(tokens, opening) orelse return false;
    if (condition_open < 2) return false;
    return switch (tokens[condition_open - 2].tag) {
        .l_brace, .r_brace, .semicolon => true,
        else => false,
    };
}

fn blockBelongsToElseIf(tokens: []const std.zig.Token, opening: usize) bool {
    const condition_open = ifConditionOpenForBlock(tokens, opening) orelse return false;
    return condition_open >= 2 and tokens[condition_open - 2].tag == .keyword_else;
}

fn ifConditionOpenForBlock(tokens: []const std.zig.Token, opening: usize) ?usize {
    var cursor = opening;
    if (cursor > 0 and tokens[cursor - 1].tag == .pipe) {
        cursor -= 1;
        while (cursor > 0 and tokens[cursor - 1].tag != .pipe) cursor -= 1;
        if (cursor == 0) return null;
        cursor -= 1;
    }
    if (cursor == 0 or tokens[cursor - 1].tag != .r_paren) return null;
    const condition_open = matchingOpeningToken(tokens, cursor - 1, .l_paren, .r_paren) orelse return null;
    if (condition_open == 0 or tokens[condition_open - 1].tag != .keyword_if) return null;
    return condition_open;
}

fn blockAlwaysTerminates(tokens: []const std.zig.Token, opening: usize, closing: usize) bool {
    // Only the last statement decides: a terminator earlier in the block (for
    // example 'orelse unreachable' in its first line) does not end the branch.
    if (closing <= opening + 1) return false;
    if (tokens[closing - 1].tag != .semicolon) return false;
    var depth: usize = 0;
    var cursor = closing - 1;
    var statement_start = opening + 1;
    while (cursor > opening + 1) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace, .r_paren, .r_bracket => depth += 1,
            .l_brace, .l_paren, .l_bracket => {
                if (depth == 0) {
                    statement_start = cursor + 1;
                    break;
                }
                depth -= 1;
            },
            .semicolon => if (depth == 0) {
                statement_start = cursor + 1;
                break;
            },
            else => {},
        }
    }
    return switch (tokens[statement_start].tag) {
        .keyword_return, .keyword_break, .keyword_continue, .keyword_unreachable => true,
        else => false,
    };
}

test "else after one terminating branch stays inside an else-if chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn scan(first: bool, second: bool) void {\n" ++
        "    if (first) { consume(); } else if (second) { return; } else { consume(); }\n" ++
        "}\n" ++
        "fn simple(first: bool) void { if (first) { return; } else { consume(); } }\n";
    const configuration = support.only(&.{.needless_else_after_terminator}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .needless_else_after_terminator) {
        warning_count += 1;
        try std.testing.expect(finding.span.start > std.mem.find(u8, source, "fn simple").?);
    };
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "needless else after terminator preserves braces when bindings are declared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn testBindings(first: bool) void {\n" ++
        "    if (first) { return; } else {\n" ++
        "        const x: u32 = 1;\n" ++
        "        consume(x);\n" ++
        "    }\n" ++
        "}\n";
    const configuration = support.only(&.{.needless_else_after_terminator}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var matched = false;
    for (found) |finding| {
        if (finding.rule == .needless_else_after_terminator) {
            matched = true;
            try std.testing.expectEqual(@as(usize, 1), finding.fixes[0].edits.len);
        }
    }
    try std.testing.expect(matched);
}

test "else stays when the branch terminator is not the last statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(stack: anytype, model: anytype, c: bool) !void {\n" ++
        "    if (c) {\n" ++
        "        const top = stack.peek() orelse unreachable;\n" ++
        "        try model.append(top);\n" ++
        "    } else {\n" ++
        "        model.clear();\n" ++
        "    }\n" ++
        "}\n";
    const configuration = support.only(&.{.needless_else_after_terminator}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .needless_else_after_terminator);
}

test "a loop else runs on normal exit and is never needless" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(values: []const u8) void {\n" ++
        "    for (values) |value| {\n" ++
        "        _ = value;\n" ++
        "        break;\n" ++
        "    } else {\n" ++
        "        mark();\n" ++
        "    }\n" ++
        "}\n";
    const configuration = support.only(&.{.needless_else_after_terminator}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .needless_else_after_terminator);
}

test "else in a switch prong remains part of the if expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(order: std.math.Order, found: bool) u8 {\n" ++
        "    return switch (order) {\n" ++
        "        .gt => if (found) { return 1; } else { return 2; },\n" ++
        "        else => 0,\n" ++
        "    };\n" ++
        "}\n";
    const configuration = support.only(&.{.needless_else_after_terminator}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .needless_else_after_terminator);
}
