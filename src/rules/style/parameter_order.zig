//! Parameter ordering conventions: allocators first, comptime parameters before runtime ones.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const topLevelComma = @import("../../syntax/tokens.zig").topLevelComma;
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;

pub const rules = [_]types.Rule{ .allocator_first_parameter, .comptime_parameter_order };

pub fn run(context: RuleRun) !void {
    const allocator_level = context.level(.allocator_first_parameter);
    const comptime_level = context.level(.comptime_parameter_order);
    if (allocator_level == .off and comptime_level == .off) return;
    for (context.tokens, 0..) |_, fn_index| {
        if (!context.isNamedFunction(fn_index) or externallyConstrained(context, fn_index)) continue;
        const opening = nextTagBefore(context.tokens, fn_index + 1, .l_paren, .semicolon) orelse continue;
        const closing = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        if (nextTagBefore(context.tokens, closing + 1, .l_brace, .semicolon) == null) continue;
        var parameter_start = opening + 1;
        var position: usize = 0;
        var saw_runtime = false;
        while (parameter_start < closing) {
            const comma = topLevelComma(context.tokens, parameter_start, closing) orelse closing;
            if (parameter_start < comma) {
                const is_self = position == 0 and context.tokens[parameter_start].tag == .identifier and context.tokenIs(parameter_start, "self");
                const is_comptime = context.tokens[parameter_start].tag == .keyword_comptime;
                if (is_comptime and saw_runtime and comptime_level != .off) try context.emit(.{
                    .rule = .comptime_parameter_order,
                    .level = comptime_level,
                    .span = context.tokens[parameter_start].loc,
                    .message = "comptime parameters configure the function and should precede runtime parameters",
                });
                if (!is_comptime and !is_self) saw_runtime = true;
                const allocator_type = findAllocatorType(context, parameter_start, comma);
                const expected_position: usize = if (firstParameterIsSelf(context, opening + 1, closing)) 1 else 0;
                if (allocator_type != null and position != expected_position and allocator_level != .off) try context.emit(.{
                    .rule = .allocator_first_parameter,
                    .level = allocator_level,
                    .span = context.tokens[allocator_type.?].loc,
                    .message = "std.mem.Allocator should be the first parameter after an optional self parameter",
                });
                position += 1;
            }
            if (comma == closing) break;
            parameter_start = comma + 1;
        }
    }
}

fn externallyConstrained(context: RuleRun, fn_index: usize) bool {
    var cursor = fn_index;
    while (cursor > 0 and fn_index - cursor < 5) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .keyword_extern or context.tokens[cursor].tag == .keyword_export) return true;
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) break;
    }
    return false;
}

fn findAllocatorType(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "Allocator") and index >= start + 4 and
            context.tokenIs(index - 4, "std") and context.tokenIs(index - 2, "mem")) return index;
    }
    return null;
}

fn firstParameterIsSelf(context: RuleRun, start: usize, end: usize) bool {
    const comma = topLevelComma(context.tokens, start, end) orelse end;
    return start < comma and context.tokens[start].tag == .identifier and context.tokenIs(start, "self");
}

test "misplaced allocator and comptime parameters report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn configure(value: u8, comptime T: type, other: u8, allocator: std.mem.Allocator) void { _ = T; _ = value; _ = other; _ = allocator; }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{ .allocator_first_parameter, .comptime_parameter_order }, .information));
    try support.expectRules(found, &.{ .comptime_parameter_order, .allocator_first_parameter });
}
