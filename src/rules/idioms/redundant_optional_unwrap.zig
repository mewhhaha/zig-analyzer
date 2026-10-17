const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const lineEnd = @import("../../syntax/tokens.zig").lineEnd;
const lineStart = @import("../../syntax/tokens.zig").lineStart;
const removedLinesSpan = @import("../../syntax/tokens.zig").removedLinesSpan;

pub const rules = [_]types.Rule{
    .redundant_optional_unwrap,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.redundant_optional_unwrap);
    if (level == .off) return;

    for (context.tokens, 0..) |token, condition_index| {
        if ((token.tag != .keyword_if and token.tag != .keyword_while) or condition_index + 7 >= context.tokens.len or
            context.tokens[condition_index + 1].tag != .l_paren or
            context.tokens[condition_index + 2].tag != .identifier or
            context.tokens[condition_index + 3].tag != .r_paren or
            context.tokens[condition_index + 4].tag != .pipe or
            context.tokens[condition_index + 5].tag != .identifier or
            context.tokens[condition_index + 6].tag != .pipe or
            context.tokens[condition_index + 7].tag != .l_brace) continue;
        const body_end = context.matchingToken(condition_index + 7, .l_brace, .r_brace) orelse continue;
        const optional_name = context.tokenText(condition_index + 2);
        const capture_name = context.tokenText(condition_index + 5);
        if (bindingChangesOrIsShadowed(context, optional_name, condition_index + 8, body_end)) continue;
        if (bindingIsMutatedThroughUnwrap(context, optional_name, condition_index + 8, body_end)) continue;

        var edits: std.ArrayList(types.Edit) = .empty;
        errdefer edits.deinit(context.allocator);
        for (context.tokens[condition_index + 8 .. body_end], condition_index + 8..) |body_token, index| {
            if (body_token.tag != .identifier or !context.refersToBinding(index, optional_name) or index + 2 >= body_end or
                context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .question_mark) continue;
            try edits.append(context.allocator, .{
                .span = .{ .start = body_token.loc.start, .end = context.tokens[index + 2].loc.end },
                .replacement = capture_name,
            });
        }
        if (edits.items.len == 0) continue;
        // Once the capture is used, a `_ = capture;` that kept it alive is a
        // pointless discard, which does not compile.
        const removable = try appendCaptureDiscardRemovals(context, &edits, capture_name, condition_index + 8, body_end);
        std.mem.sort(types.Edit, edits.items, {}, struct {
            fn lessThan(_: void, left: types.Edit, right: types.Edit) bool {
                return left.span.start < right.span.start;
            }
        }.lessThan);
        const fixes: []const types.Fix = if (removable) fixes: {
            const allocated = try context.allocator.alloc(types.Fix, 1);
            allocated[0] = .{
                .title = "Use the optional capture",
                .kind = .quickfix,
                .edits = try edits.toOwnedSlice(context.allocator),
                .preferred = true,
                .fix_all = true,
            };
            break :fixes allocated;
        } else &.{};
        try context.emit(.{
            .rule = .redundant_optional_unwrap,
            .level = level,
            .span = context.tokens[condition_index + 2].loc,
            .message = try context.allocator.print(
                "optional '{s}' is already available as capture '{s}'; forcing it again obscures the proven non-null value",
                .{ optional_name, capture_name },
            ),
            .fixes = fixes,
        });
    }
}

/// Appends edits deleting each `_ = capture;` statement in `[start, end)`.
/// False when one is not a block statement that can be deleted.
fn appendCaptureDiscardRemovals(
    context: RuleRun,
    edits: *std.ArrayList(types.Edit),
    capture_name: []const u8,
    start: usize,
    end: usize,
) !bool {
    const source = context.source;
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (context.tokens[index].tag != .identifier or !context.tokenIs(index, "_") or
            context.tokens[index + 1].tag != .equal or !context.refersToBinding(index + 2, capture_name) or
            context.tokens[index + 3].tag != .semicolon) continue;
        switch (context.tokens[index - 1].tag) {
            .l_brace, .r_brace, .semicolon => {},
            else => return false,
        }
        const span: std.zig.Token.Loc = .{ .start = context.tokens[index].loc.start, .end = context.tokens[index + 3].loc.end };
        // A discard alone on its line goes with the line, so no blank one is left behind.
        const alone = std.mem.trim(u8, source[lineStart(source, span.start)..span.start], " \t").len == 0 and
            std.mem.trim(u8, source[span.end..lineEnd(source, span.end)], " \t\r\n").len == 0;
        try edits.append(context.allocator, .{
            .span = if (alone) removedLinesSpan(source, span.start, span.end) else span,
            .replacement = "",
        });
    }
    return true;
}

fn bindingChangesOrIsShadowed(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > start and (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var)) return true;
        if (index + 1 < end and context.tokens[index + 1].tag == .equal) return true;
    }
    return false;
}

fn bindingIsMutatedThroughUnwrap(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.refersToBinding(index, name)) continue;
        if (index > start and context.tokens[index - 1].tag == .ampersand) return true;
        if (index + 3 < end and context.tokens[index + 1].tag == .period and
            context.tokens[index + 2].tag == .question_mark and
            isAssignmentOperator(context.tokens[index + 3].tag)) return true;
    }
    return false;
}

fn isAssignmentOperator(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal,
        .plus_equal,
        .minus_equal,
        .asterisk_equal,
        .slash_equal,
        .percent_equal,
        .ampersand_equal,
        .pipe_equal,
        .caret_equal,
        .plus_percent_equal,
        .minus_percent_equal,
        .asterisk_percent_equal,
        .plus_pipe_equal,
        .minus_pipe_equal,
        .asterisk_pipe_equal,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left_pipe_equal,
        .angle_bracket_angle_bracket_right_equal,
        => true,
        else => false,
    };
}

test "optional captures replace repeated force unwraps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (optional) |value| { consume(optional.?); }";
    const configuration = support.only(&.{.redundant_optional_unwrap}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("value", findings[0].fixes[0].edits[0].replacement);
}

test "the capture rewrite deletes a discard that kept the capture alive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn use(optional: ?u32) void {\n" ++
        "    if (optional) |value| {\n" ++
        "        consume(optional.?);\n" ++
        "        _ = value;\n" ++
        "    }\n" ++
        "}\n";
    const configuration = support.only(&.{.redundant_optional_unwrap}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    const edits = findings[0].fixes[0].edits;
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqualStrings("value", edits[0].replacement);
    try std.testing.expectEqualStrings("        _ = value;\n", source[edits[1].span.start..edits[1].span.end]);
    try std.testing.expectEqualStrings("", edits[1].replacement);
}

test "a discard outside a block statement withholds the capture rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (optional) |value| { consume(optional.?); if (ready) _ = value; }";
    const configuration = support.only(&.{.redundant_optional_unwrap}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(@as(usize, 0), findings[0].fixes.len);
}

test "reassigned optionals do not produce capture rewrites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (optional) |value| { optional = other; consume(optional.?); _ = value; }";
    const configuration = support.only(&.{.redundant_optional_unwrap}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a field named like the optional binding is not the binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (optional) |value| { consume(config.optional.?); _ = value; }";
    const configuration = support.only(&.{.redundant_optional_unwrap}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "assigning through the forced unwrap disqualifies the capture rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (optional) |value| { optional.? = compute(value); consume(optional.?); }";
    const configuration = support.only(&.{.redundant_optional_unwrap}, .information);
    const findings = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
