//! Draining an `ArrayList` with `orderedRemove(0)` in a loop.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const container_types = @import("../container_types.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const PathRange = @import("../../syntax/tokens.zig").Range;

pub const rules = [_]types.Rule{.quadratic_front_removal};

pub fn run(context: RuleRun) !void {
    const level = context.level(.quadratic_front_removal);
    if (level == .off) return;

    for (context.tokens, 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 1 >= context.tokens.len or
            context.tokens[while_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        const drained = drainedArrayListPath(context, while_index + 2, condition_end, while_index) orelse continue;
        const body_open = context.whileBodyOpening(condition_end) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        const removal = frontOrderedRemoval(context, drained.start, drained.end, body_open + 1, body_end) orelse continue;
        const path = context.source[context.tokens[drained.start].loc.start..context.tokens[drained.end - 1].loc.end];
        try context.emit(.{
            .rule = .quadratic_front_removal,
            .level = level,
            .span = context.tokens[removal].loc,
            .message = try context.allocator.print(
                "draining ArrayList '{s}' with orderedRemove(0) shifts every remaining element and takes quadratic time",
                .{path},
            ),
        });
    }
}

fn drainedArrayListPath(context: RuleRun, start: usize, end: usize, before: usize) ?PathRange {
    for (context.tokens[start..end], start..) |token, items_index| {
        if (token.tag != .identifier or !context.tokenIs(items_index, "items") or items_index < start + 2 or
            items_index + 3 >= end or context.tokens[items_index - 1].tag != .period or
            context.tokens[items_index + 1].tag != .period or !context.tokenIs(items_index + 2, "len") or
            !lengthComparedWithZero(context, items_index + 2, start, end)) continue;
        const path_end = items_index - 1;
        const path_start = context.pathStartBefore(path_end) orelse continue;
        if (!arrayListPathVisible(context, path_start, path_end, before)) continue;
        return .{ .start = path_start, .end = path_end };
    }
    return null;
}

fn frontOrderedRemoval(
    context: RuleRun,
    expected_start: usize,
    expected_end: usize,
    start: usize,
    end: usize,
) ?usize {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, "orderedRemove") or
            method_index < start + 2 or context.tokens[method_index - 1].tag != .period or
            method_index + 3 >= end or context.tokens[method_index + 1].tag != .l_paren or
            context.tokens[method_index + 2].tag != .number_literal or !context.tokenIs(method_index + 2, "0") or
            context.tokens[method_index + 3].tag != .r_paren) continue;
        const candidate_end = method_index - 1;
        const candidate_start = context.pathStartBefore(candidate_end) orelse continue;
        if (context.dottedPathsEqual(expected_start, expected_end, candidate_start, candidate_end)) return method_index;
    }
    return null;
}

fn arrayListPathVisible(context: RuleRun, path_start: usize, path_end: usize, before: usize) bool {
    if (path_end == path_start + 1) {
        return localBindingIsArrayList(context, context.tokenText(path_start), before);
    }
    if (path_end == path_start + 3 and context.tokenIs(path_start, "self")) {
        return selfFieldIsArrayList(context, context.tokenText(path_start + 2), before);
    }
    return false;
}

fn lengthComparedWithZero(context: RuleRun, length_index: usize, start: usize, end: usize) bool {
    if (length_index + 2 < end and lengthExceedsZero(context.tokens[length_index + 1].tag) and
        context.tokens[length_index + 2].tag == .number_literal and context.tokenIs(length_index + 2, "0")) return true;
    return length_index >= start + 2 and context.tokens[length_index - 2].tag == .number_literal and
        context.tokenIs(length_index - 2, "0") and zeroBelowLength(context.tokens[length_index - 1].tag);
}

fn localBindingIsArrayList(context: RuleRun, name: []const u8, before: usize) bool {
    var name_index = before;
    while (name_index > 0) {
        name_index -= 1;
        if (!context.tokenIs(name_index, name) or name_index + 1 >= before) continue;
        if (context.tokens[name_index + 1].tag == .colon) {
            return rangeNamesArrayList(context, name_index + 2, before);
        }
        if (name_index > 0 and
            (context.tokens[name_index - 1].tag == .keyword_const or context.tokens[name_index - 1].tag == .keyword_var) and
            context.tokens[name_index + 1].tag == .equal)
        {
            const declaration_end = @min(context.statementEnd(name_index - 1) orelse before, before);
            return rangeNamesArrayList(context, name_index + 2, declaration_end);
        }
    }
    return false;
}

fn selfFieldIsArrayList(context: RuleRun, field_name: []const u8, before: usize) bool {
    const function_body = functionBodyContaining(context, before) orelse return false;
    const type_body = context.enclosingOpeningBrace(function_body) orelse return false;
    for (context.tokens[type_body + 1 .. function_body], type_body + 1..) |token, field_index| {
        if (token.tag != .identifier or !context.tokenIs(field_index, field_name) or
            field_index + 2 >= function_body or context.tokens[field_index + 1].tag != .colon or
            context.enclosingOpeningBrace(field_index) != type_body) continue;
        return rangeNamesArrayList(context, field_index + 2, function_body);
    }
    return false;
}

fn lengthExceedsZero(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .angle_bracket_right,
        .bang_equal,
        => true,
        else => false,
    };
}

fn zeroBelowLength(tag: std.zig.Token.Tag) bool {
    return tag == .angle_bracket_left or tag == .bang_equal;
}

fn rangeNamesArrayList(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (container_types.kindOfToken(context.source, context.tokens, index) == .list) return true;
        if (token.tag == .comma or token.tag == .equal or token.tag == .r_paren or token.tag == .semicolon) return false;
    }
    return false;
}

fn functionBodyContaining(context: RuleRun, target_index: usize) ?usize {
    var selected: ?usize = null;
    for (context.tokens[0..target_index], 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        var body_start = function_index + 1;
        while (body_start < target_index and context.tokens[body_start].tag != .l_brace and
            context.tokens[body_start].tag != .semicolon) : (body_start += 1)
        {}
        if (body_start >= target_index or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (target_index < body_end) selected = body_start;
    }
    return selected;
}

test "draining an array list with ordered front removal reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn drain(allocator: std.mem.Allocator) void { " ++
        "var queue: std.ArrayList(u32) = .empty; defer queue.deinit(allocator); " ++
        "while (queue.items.len > 0) { consume(queue.orderedRemove(0)); } }";
    const configuration = support.only(&.{.quadratic_front_removal}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.quadratic_front_removal, found[0].rule);
}

test "one-off and non-front array list removals remain clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Unrelated = struct { queue: std.ArrayList(u32) }; " ++
        "fn removeOne(queue: *std.ArrayList(u32)) void { _ = queue.orderedRemove(0); } " ++
        "fn drainBack(allocator: std.mem.Allocator) void { " ++
        "var queue = std.ArrayList(u32).empty; defer queue.deinit(allocator); " ++
        "while (queue.items.len != 0) { _ = queue.orderedRemove(queue.items.len - 1); } } " ++
        "fn custom(queue: *CustomQueue) void { " ++
        "while (queue.items.len != 0) { _ = queue.orderedRemove(0); } } " ++
        "fn empty(queue: *std.ArrayList(u32)) void { " ++
        "while (queue.items.len <= 0) { _ = queue.orderedRemove(0); } }";
    const configuration = support.only(&.{.quadratic_front_removal}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}
