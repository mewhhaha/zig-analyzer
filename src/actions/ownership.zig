const std = @import("std");
const action_context = @import("context.zig");

const ActionRun = action_context.ActionRun;

pub fn run(context: ActionRun) !void {
    try addOwnedSliceReturn(context);
    try addReturnedOwnershipTransfer(context);
    try addCheckedAllocationSize(context);
}

fn addOwnedSliceReturn(context: ActionRun) !void {
    for (context.tokens, 0..) |token, return_index| {
        if (token.tag != .keyword_return or return_index + 3 >= context.tokens.len or
            context.tokens[return_index + 1].tag != .identifier or context.tokens[return_index + 2].tag != .period or
            !context.tokenIs(return_index + 3, "items")) continue;
        const expression_span = std.zig.Token.Loc{
            .start = context.tokens[return_index + 1].loc.start,
            .end = context.tokens[return_index + 3].loc.end,
        };
        if (!context.selected(expression_span)) continue;
        const container = context.tokenText(return_index + 1);
        const allocator = deinitAllocator(context, container, return_index) orelse continue;
        if (!isArrayListBinding(context, container, return_index)) continue;
        const function = action_context.containingFunction(context, return_index) orelse continue;
        const prefix = if (function.returnsError(context)) "try " else "";
        const suffix = if (function.returnsError(context)) "" else " catch @panic(\"out of memory\")";
        try context.oneEdit(
            "Return owned container storage",
            .quickfix,
            expression_span,
            try std.fmt.allocPrint(
                context.allocator,
                "{s}{s}.toOwnedSlice({s}){s}",
                .{ prefix, container, allocator, suffix },
            ),
            false,
        );
    }
}

fn isArrayListBinding(context: ActionRun, name: []const u8, before: usize) bool {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, name) or index == 0 or
            (context.tokens[index - 1].tag != .keyword_const and context.tokens[index - 1].tag != .keyword_var)) continue;
        const end = context.statementEnd(index - 1) orelse return false;
        for (context.tokens[index + 1 .. @min(end, before)], index + 1..) |token, declaration_index| {
            if (token.tag == .identifier and context.tokenIs(declaration_index, "ArrayList")) return true;
        }
        return false;
    }
    return false;
}

fn deinitAllocator(context: ActionRun, name: []const u8, before: usize) ?[]const u8 {
    for (context.tokens[0..before], 0..) |token, index| {
        if (token.tag != .keyword_defer or index + 6 >= before or !context.tokenIs(index + 1, name) or
            context.tokens[index + 2].tag != .period or !context.tokenIs(index + 3, "deinit") or
            context.tokens[index + 4].tag != .l_paren or context.tokens[index + 5].tag != .identifier or
            context.tokens[index + 6].tag != .r_paren) continue;
        return context.tokenText(index + 5);
    }
    return null;
}

fn addReturnedOwnershipTransfer(context: ActionRun) !void {
    for (context.tokens, 0..) |token, defer_index| {
        if (token.tag != .keyword_defer or !context.selected(token.loc)) continue;
        const defer_end = context.statementEnd(defer_index) orelse continue;
        const binding = cleanupBinding(context, defer_index + 1, defer_end) orelse continue;
        const function = action_context.containingFunction(context, defer_index) orelse continue;
        if (!function.returnsError(context) or !directlyReturned(context, binding, defer_end + 1, function.body_end)) continue;
        try context.oneEdit(
            try std.fmt.allocPrint(context.allocator, "Transfer ownership of '{s}' on success", .{binding}),
            .refactor_rewrite,
            token.loc,
            "errdefer",
            false,
        );
    }
}

fn cleanupBinding(context: ActionRun, start: usize, end: usize) ?[]const u8 {
    const cleanup_methods = [_][]const u8{ "free", "destroy", "close", "deinit", "join", "detach" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        var cleanup = false;
        for (cleanup_methods) |method| if (context.tokenIs(index, method)) {
            cleanup = true;
        };
        if (!cleanup) continue;
        if (index >= 2 and context.tokens[index - 1].tag == .period and context.tokens[index - 2].tag == .identifier and
            (context.tokenIs(index, "close") or context.tokenIs(index, "deinit") or context.tokenIs(index, "join") or
                context.tokenIs(index, "detach"))) return context.tokenText(index - 2);
        if (index + 2 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        for (context.tokens[index + 2 .. end], index + 2..) |argument, argument_index| {
            if (argument.tag == .identifier) return context.tokenText(argument_index);
            if (argument.tag == .r_paren) break;
        }
    }
    return null;
}

fn directlyReturned(context: ActionRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_return and index + 2 < end and context.tokenIs(index + 1, name) and
            context.tokens[index + 2].tag == .semicolon) return true;
    }
    return false;
}

fn addCheckedAllocationSize(context: ActionRun) !void {
    const allocation_methods = [_][]const u8{ "alloc", "allocSentinel", "alignedAlloc", "realloc" };
    for (context.tokens, 0..) |token, multiplication_index| {
        if (token.tag != .asterisk or multiplication_index == 0 or multiplication_index + 1 >= context.tokens.len) continue;
        const left = context.tokens[multiplication_index - 1];
        const right = context.tokens[multiplication_index + 1];
        if (!simpleOperand(left.tag) or !simpleOperand(right.tag)) continue;
        const product_span = std.zig.Token.Loc{ .start = left.loc.start, .end = right.loc.end };
        if (!context.selected(product_span) or !insideAllocationCall(context, multiplication_index, &allocation_methods)) continue;
        try context.oneEdit(
            "Check allocation size overflow",
            .refactor_rewrite,
            product_span,
            try std.fmt.allocPrint(
                context.allocator,
                "@import(\"std\").math.mul(usize, {s}, {s}) catch @panic(\"allocation size overflow\")",
                .{ context.tokenText(multiplication_index - 1), context.tokenText(multiplication_index + 1) },
            ),
            false,
        );
    }
}

fn simpleOperand(tag: std.zig.Token.Tag) bool {
    return tag == .identifier or tag == .number_literal;
}

fn insideAllocationCall(context: ActionRun, index: usize, methods: []const []const u8) bool {
    var cursor = index;
    var depth: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .r_paren => depth += 1,
            .l_paren => {
                if (depth != 0) {
                    depth -= 1;
                    continue;
                }
                if (cursor == 0 or context.tokens[cursor - 1].tag != .identifier) return false;
                for (methods) |method| if (context.tokenIs(cursor - 1, method)) return true;
                return false;
            },
            .semicolon => if (depth == 0) return false,
            else => {},
        }
    }
    return false;
}

test "owned slices and successful ownership transfers are explicit" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn list(a: anytype) ![]u8 { var values = std.ArrayList(u8).empty; defer values.deinit(a); return values.items; } " ++
        "fn bytes(a: anytype) ![]u8 { const value = try a.alloc(u8, 1); defer a.free(value); return value; }";
    const items = std.mem.indexOf(u8, source, "values.items") orelse unreachable;
    const owned = try registry.actions(arena.allocator(), source, .{ .start = items, .end = items + 12 }, &.{});
    try std.testing.expectEqualStrings("try values.toOwnedSlice(a)", owned[0].edits[0].replacement);
    const defer_start = std.mem.lastIndexOf(u8, source, "defer") orelse unreachable;
    const transfer = try registry.actions(arena.allocator(), source, .{ .start = defer_start, .end = defer_start + 5 }, &.{});
    try std.testing.expectEqualStrings("errdefer", transfer[0].edits[0].replacement);
}

test "allocation products get an overflow-checking refactor" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run(a: anytype, count: usize) !void { _ = try a.alloc(u8, count * 4); }";
    const start = std.mem.indexOf(u8, source, "count * 4") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 9 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].edits[0].replacement, "math.mul") != null);
}
