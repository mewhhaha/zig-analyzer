const std = @import("std");
const action_context = @import("context.zig");

const ActionRun = action_context.ActionRun;

pub fn run(context: ActionRun) !void {
    try addOwnedSliceReturn(context);
    try addReturnedOwnershipTransfer(context);
    try addCheckedAllocationSize(context);
    try addPoisonAfterDeinit(context);
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
        const function = action_context.containingFunction(context, return_index) orelse continue;
        const allocator = deinitAllocator(context, container, function.body_start, return_index) orelse continue;
        if (!isArrayListBinding(context, container, function.body_start, return_index)) continue;
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

fn isArrayListBinding(context: ActionRun, name: []const u8, lower: usize, before: usize) bool {
    var index = before;
    while (index > lower) {
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

fn deinitAllocator(context: ActionRun, name: []const u8, lower: usize, before: usize) ?[]const u8 {
    for (context.tokens[lower..before], lower..) |token, index| {
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
        if (defer_index + 1 >= context.tokens.len or context.tokens[defer_index + 1].tag == .l_brace) continue;
        const defer_end = context.statementEnd(defer_index) orelse continue;
        const binding = cleanupBinding(context, defer_index + 1, defer_end) orelse continue;
        const function = action_context.containingFunction(context, defer_index) orelse continue;
        if (!function.returnsError(context) or
            !everyReturnTransfersOwnership(context, binding, defer_end + 1, function.body_end)) continue;
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

fn everyReturnTransfersOwnership(context: ActionRun, name: []const u8, start: usize, end: usize) bool {
    var transfers = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_return) continue;
        if (index + 2 < end and context.tokenIs(index + 1, name) and
            context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .semicolon)
        {
            transfers = true;
            continue;
        }
        if (index + 3 < end and context.tokens[index + 1].tag == .keyword_error and
            context.tokens[index + 2].tag == .period and context.tokens[index + 3].tag == .identifier) continue;
        return false;
    }
    return transfers;
}

fn addCheckedAllocationSize(context: ActionRun) !void {
    const allocation_methods = [_][]const u8{ "alloc", "allocSentinel", "alignedAlloc", "realloc" };
    for (context.tokens, 0..) |token, multiplication_index| {
        if (token.tag != .asterisk or multiplication_index == 0 or multiplication_index + 1 >= context.tokens.len) continue;
        const left = context.tokens[multiplication_index - 1];
        const right = context.tokens[multiplication_index + 1];
        if (!simpleOperand(left.tag) or !simpleOperand(right.tag)) continue;
        if (multiplication_index >= 2 and context.tokens[multiplication_index - 2].tag == .period) continue;
        if (multiplication_index + 2 < context.tokens.len and switch (context.tokens[multiplication_index + 2].tag) {
            .period, .l_bracket, .l_paren => true,
            else => false,
        }) continue;
        const product_span = std.zig.Token.Loc{ .start = left.loc.start, .end = right.loc.end };
        if (!context.selected(product_span) or !insideAllocationCall(context, multiplication_index, &allocation_methods)) continue;
        try context.oneEdit(
            "Check allocation size overflow",
            .refactor_rewrite,
            product_span,
            try std.fmt.allocPrint(
                context.allocator,
                "(@import(\"std\").math.mul(usize, {s}, {s}) catch @panic(\"allocation size overflow\"))",
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

fn addPoisonAfterDeinit(context: ActionRun) !void {
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 6 >= context.tokens.len or
            !context.tokenIs(fn_index + 1, "deinit") or context.tokens[fn_index + 2].tag != .l_paren) continue;
        if (!context.tokenIs(fn_index + 3, "self") or context.tokens[fn_index + 4].tag != .colon or
            context.tokens[fn_index + 5].tag != .asterisk or context.tokens[fn_index + 6].tag == .keyword_const) continue;
        const parameters_end = context.matchingToken(fn_index + 2, .l_paren, .r_paren) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= context.tokens.len) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        const function_span = std.zig.Token.Loc{ .start = token.loc.start, .end = context.tokens[body_end].loc.end };
        if (!context.selected(function_span)) continue;
        if (endsWithSelfPoison(context, body_end)) continue;
        // '_ = self;' plus a real use of self is a "pointless discard" error.
        if (discardsSelf(context, body_start + 1, body_end)) continue;
        const indentation = context.lineIndentation(context.tokens[body_end].loc.start);
        try context.oneEdit(
            "Poison after deinit",
            .refactor_rewrite,
            .{ .start = context.tokens[body_end].loc.start, .end = context.tokens[body_end].loc.start },
            try std.fmt.allocPrint(context.allocator, "{s}    self.* = undefined;\n", .{indentation}),
            false,
        );
    }
}

fn discardsSelf(context: ActionRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "_") and index + 3 < end and
            context.tokens[index + 1].tag == .equal and context.tokenIs(index + 2, "self") and
            context.tokens[index + 3].tag == .semicolon) return true;
    }
    return false;
}

fn endsWithSelfPoison(context: ActionRun, body_end: usize) bool {
    if (body_end < 5) return false;
    return context.tokens[body_end - 5].tag == .identifier and context.tokenIs(body_end - 5, "self") and
        context.tokens[body_end - 4].tag == .period_asterisk and
        context.tokens[body_end - 3].tag == .equal and context.tokenIs(body_end - 2, "undefined") and
        context.tokens[body_end - 1].tag == .semicolon;
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

test "checked allocation sizes keep trailing addends out of the catch" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: anytype, count: usize, header_len: usize) !void { _ = try a.alloc(u8, count * 4 + header_len); }";
    const start = std.mem.indexOf(u8, source, "count * 4") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 9 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings(
        "(@import(\"std\").math.mul(usize, count, 4) catch @panic(\"allocation size overflow\"))",
        actions[0].edits[0].replacement,
    );
}

test "field-access operands get no size check rewrite" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run(a: anytype, hdr: anytype) !void { _ = try a.alloc(u8, hdr.count * 4); }";
    const start = std.mem.indexOf(u8, source, "count * 4") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 9 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "defer blocks and extra success returns keep their defer" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const block_source: [:0]const u8 =
        "fn both(a: anytype) ![]u8 { const one = try a.dupe(u8, \"x\"); const two = try a.dupe(u8, \"y\"); " ++
        "defer { a.free(one); a.free(two); } return one; }";
    const block_defer = std.mem.indexOf(u8, block_source, "defer") orelse unreachable;
    const block = try registry.actions(arena.allocator(), block_source, .{ .start = block_defer, .end = block_defer + 5 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), block.len);

    const branch_source: [:0]const u8 =
        "fn pick(a: anytype, flag: bool) ![]u8 { const value = try a.dupe(u8, \"x\"); defer a.free(value); " ++
        "if (flag) return try a.dupe(u8, \"y\"); return value; }";
    const branch_defer = std.mem.indexOf(u8, branch_source, "defer") orelse unreachable;
    const branch = try registry.actions(arena.allocator(), branch_source, .{ .start = branch_defer, .end = branch_defer + 5 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), branch.len);

    const error_source: [:0]const u8 =
        "fn load(a: anytype, flag: bool) ![]u8 { const value = try a.dupe(u8, \"x\"); defer a.free(value); " ++
        "if (flag) return error.Missing; return value; }";
    const error_defer = std.mem.indexOf(u8, error_source, "defer") orelse unreachable;
    const propagated = try registry.actions(arena.allocator(), error_source, .{ .start = error_defer, .end = error_defer + 5 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), propagated.len);
    try std.testing.expectEqualStrings("errdefer", propagated[0].edits[0].replacement);
}

test "owned slice returns ignore same-named lists in other functions" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn first(a: anytype) ![]u8 { var values = std.ArrayList(u8).empty; defer values.deinit(a); return values.items; } " ++
        "fn second() ![]u8 { return values.items; }";
    const items = std.mem.lastIndexOf(u8, source, "values.items") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = items, .end = items + 12 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "deinit methods offer poisoning self as their final statement" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Buffer = struct {\n" ++
        "    bytes: []u8,\n" ++
        "    fn deinit(self: *Buffer, a: anytype) void {\n" ++
        "        a.free(self.bytes);\n" ++
        "    }\n" ++
        "};";
    const name = std.mem.indexOf(u8, source, "deinit") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = name, .end = name + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Poison after deinit", actions[0].title);
    try std.testing.expectEqualStrings("        self.* = undefined;\n", actions[0].edits[0].replacement);
}

test "deinit stubs that discard self get no poison action" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Tight = struct { fn deinit(self: *Tight) void { _ = self; } };";
    const name = std.mem.indexOf(u8, source, "deinit") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = name, .end = name + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "const-self and already-poisoned deinit methods get no poison action" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const const_source: [:0]const u8 =
        "const Buffer = struct { fn deinit(self: *const Buffer) void { _ = self; } };";
    const const_name = std.mem.indexOf(u8, const_source, "deinit") orelse unreachable;
    const const_actions = try registry.actions(arena.allocator(), const_source, .{ .start = const_name, .end = const_name + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), const_actions.len);

    const poisoned_source: [:0]const u8 =
        "const Buffer = struct { bytes: []u8, fn deinit(self: *Buffer, a: anytype) void { a.free(self.bytes); self.* = undefined; } };";
    const poisoned_name = std.mem.indexOf(u8, poisoned_source, "deinit") orelse unreachable;
    const poisoned_actions = try registry.actions(arena.allocator(), poisoned_source, .{ .start = poisoned_name, .end = poisoned_name + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), poisoned_actions.len);
}
