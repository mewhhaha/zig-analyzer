const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const ArgumentRange = @import("../../syntax/tokens.zig").Range;
const parseSingleByteLiteral = @import("../../syntax/tokens.zig").parseSingleByteLiteral;

pub const rules = [_]types.Rule{
    .prefer_write_byte,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_write_byte);
    if (level == .off) return;

    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or call_index < 2 or
            context.tokens[call_index - 1].tag != .period or
            call_index + 1 >= context.tokens.len or
            context.tokens[call_index + 1].tag != .l_paren) continue;

        const method_name = context.tokenText(call_index);
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;

        if (std.mem.eql(u8, method_name, "writeAll")) {
            try checkWriteAll(context, level, call_index, call_end);
        } else if (std.mem.eql(u8, method_name, "print")) {
            try checkPrint(context, level, call_index, call_end);
        }
    }
}

fn checkWriteAll(context: RuleRun, level: types.Level, call_index: usize, call_end: usize) !void {
    // Expected arguments: 1 argument: a 1-character string literal
    // Check if there are no top-level commas in arguments
    if (hasTopLevelComma(context, call_index + 2, call_end)) return;
    if (call_index + 2 >= call_end) return;

    const arg_token = context.tokens[call_index + 2];
    if (arg_token.tag != .string_literal or call_index + 3 != call_end) return;

    const text = context.tokenText(call_index + 2);
    const char_lit = try parseSingleByteLiteral(context.allocator, text) orelse return;

    const edits = try context.allocator.alloc(types.Edit, 2);
    edits[0] = .{
        .span = context.tokens[call_index].loc,
        .replacement = "writeByte",
    };
    edits[1] = .{
        .span = arg_token.loc,
        .replacement = char_lit,
    };

    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{
        .title = try context.allocator.print("Use 'writeByte({s})'", .{char_lit}),
        .kind = .quickfix,
        .edits = edits,
        .preferred = true,
        .fix_all = true,
    };

    try context.emit(.{
        .rule = .prefer_write_byte,
        .level = level,
        .span = context.tokens[call_index].loc,
        .message = try context.allocator.print(
            "writing a single character via 'writeAll' incurs slice overhead; use 'writeByte({s})'",
            .{char_lit},
        ),
        .fixes = fixes,
    });
}

fn checkPrint(context: RuleRun, level: types.Level, call_index: usize, call_end: usize) !void {
    // print has 2 arguments: format string, and tuple .{}
    const args = twoArguments(context, call_index + 1, call_end) orelse return;

    if (args[0].end != args[0].start + 1) return;
    const fmt_token = context.tokens[args[0].start];
    if (fmt_token.tag != .string_literal) return;

    const fmt_text = context.tokenText(args[0].start);

    // Case 1: fmt is a 1-character string literal and second arg is empty tuple .{}
    if (try parseSingleByteLiteral(context.allocator, fmt_text)) |char_lit| {
        if (isEmptyTuple(context, args[1].start, args[1].end)) {
            const edits = try context.allocator.alloc(types.Edit, 2);
            edits[0] = .{
                .span = context.tokens[call_index].loc,
                .replacement = "writeByte",
            };
            edits[1] = .{
                .span = .{
                    .start = context.tokens[args[0].start].loc.start,
                    .end = context.tokens[args[1].end - 1].loc.end,
                },
                .replacement = char_lit,
            };

            const fixes = try context.allocator.alloc(types.Fix, 1);
            fixes[0] = .{
                .title = try context.allocator.print("Use 'writeByte({s})'", .{char_lit}),
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
                .fix_all = true,
            };

            try context.emit(.{
                .rule = .prefer_write_byte,
                .level = level,
                .span = context.tokens[call_index].loc,
                .message = try context.allocator.print(
                    "writing a single character via 'print' incurs format parsing overhead; use 'writeByte({s})'",
                    .{char_lit},
                ),
                .fixes = fixes,
            });
            return;
        }
    }

    // Case 2: fmt is "{c}" and second arg is a single element tuple .{val}
    if (std.mem.eql(u8, fmt_text, "\"{c}\"")) {
        if (extractSingleTupleElement(context, args[1].start, args[1].end)) |val_expr| {
            const edits = try context.allocator.alloc(types.Edit, 2);
            edits[0] = .{
                .span = context.tokens[call_index].loc,
                .replacement = "writeByte",
            };
            edits[1] = .{
                .span = .{
                    .start = context.tokens[args[0].start].loc.start,
                    .end = context.tokens[args[1].end - 1].loc.end,
                },
                .replacement = val_expr,
            };

            const fixes = try context.allocator.alloc(types.Fix, 1);
            fixes[0] = .{
                .title = try context.allocator.print("Use 'writeByte({s})'", .{val_expr}),
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
                .fix_all = true,
            };

            try context.emit(.{
                .rule = .prefer_write_byte,
                .level = level,
                .span = context.tokens[call_index].loc,
                .message = try context.allocator.print(
                    "formatting a single character via 'print(\"{{c}}\", ...)' incurs format parsing overhead; use 'writeByte({s})'",
                    .{val_expr},
                ),
                .fixes = fixes,
            });
        }
    }
}

fn twoArguments(context: RuleRun, opening: usize, closing: usize) ?[2]ArgumentRange {
    var comma_idx: ?usize = null;
    var depth: usize = 0;

    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, i| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (comma_idx != null) return null; // more than 2 args
                comma_idx = i;
            },
            else => {},
        }
    }

    const c = comma_idx orelse return null;
    if (c == opening + 1 or c + 1 == closing) return null;

    return .{
        .{ .start = opening + 1, .end = c },
        .{ .start = c + 1, .end = closing },
    };
}

fn hasTopLevelComma(context: RuleRun, start: usize, end: usize) bool {
    var depth: usize = 0;
    for (context.tokens[start..end]) |token| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn isEmptyTuple(context: RuleRun, start: usize, end: usize) bool {
    // Expected: . { }
    if (end < start + 3) return false;
    return context.tokens[start].tag == .period and
        context.tokens[start + 1].tag == .l_brace and
        context.tokens[start + 2].tag == .r_brace and
        start + 3 == end;
}

fn extractSingleTupleElement(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    // Expected: . { expr }
    if (end < start + 4) return null;
    if (context.tokens[start].tag != .period or context.tokens[start + 1].tag != .l_brace or
        context.tokens[end - 1].tag != .r_brace) return null;

    const inner_start = start + 2;
    const inner_end = end - 1;

    // Must not have top-level commas inside the tuple
    if (hasTopLevelComma(context, inner_start, inner_end)) return null;

    return std.mem.trim(u8, context.source[context.tokens[inner_start].loc.start..context.tokens[inner_end - 1].loc.end], " \t\r\n");
}

test "prefer write byte detects writeAll with single character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn writeClosing(writer: anytype) !void {
        \\    try writer.writeAll("}");
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_write_byte, findings[0].rule);
    try std.testing.expectEqual(2, findings[0].fixes[0].edits.len);
    try std.testing.expectEqualStrings("writeByte", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("'}'", findings[0].fixes[0].edits[1].replacement);
}

test "prefer write byte detects print with single character literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn writeNewline(writer: anytype) !void {
        \\    try writer.print("\n", .{});
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_write_byte, findings[0].rule);
    try std.testing.expectEqualStrings("writeByte", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("'\\n'", findings[0].fixes[0].edits[1].replacement);
}

test "prefer write byte detects print {c} format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn writeChar(writer: anytype, ch: u8) !void {
        \\    try writer.print("{c}", .{ch});
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_write_byte, findings[0].rule);
    try std.testing.expectEqualStrings("writeByte", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("ch", findings[0].fixes[0].edits[1].replacement);
}

test "prefer write byte ignores multi-byte string in writeAll" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn writeWord(writer: anytype) !void {
        \\    try writer.writeAll("hello");
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(0, findings.len);
}

fn testConfiguration() types.Configuration {
    const configuration = support.only(&.{.prefer_write_byte}, .warning);
    return configuration;
}
