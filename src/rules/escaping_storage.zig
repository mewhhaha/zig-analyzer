const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;

pub fn run(context: RuleRun) !void {
    try findDeinitializedViews(context);
    try findArenaReturns(context);
}

fn findDeinitializedViews(context: RuleRun) !void {
    const level = context.level(.returning_deinitialized_view);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!containsManagedContainer(context, declaration_index + 3, declaration_end)) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const container_name = context.tokenText(declaration_index + 1);
        if (!hasDeferredMethod(context, container_name, "deinit", declaration_end + 1, scope_end, scope_opening)) continue;

        var borrowed_name: ?[]const u8 = null;
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |candidate, index| {
            if ((candidate.tag == .keyword_const or candidate.tag == .keyword_var) and index + 6 < scope_end and
                context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .equal and
                context.tokenIs(index + 3, container_name) and context.tokens[index + 4].tag == .period and
                context.tokenIs(index + 5, "items")) borrowed_name = context.tokenText(index + 1);
            if (candidate.tag != .keyword_return or context.enclosingOpeningBrace(index) != scope_opening or index + 1 >= scope_end) continue;
            const returns_direct_view = context.tokenIs(index + 1, container_name) and index + 3 < scope_end and
                context.tokens[index + 2].tag == .period and context.tokenIs(index + 3, "items");
            const returns_borrow = borrowed_name != null and context.tokenIs(index + 1, borrowed_name.?);
            if (!returns_direct_view and !returns_borrow) continue;
            const returned_name = if (returns_borrow) borrowed_name.? else container_name;
            try context.emit(.{
                .rule = .returning_deinitialized_view,
                .level = level,
                .span = context.tokens[index + 1].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "returned view '{s}' borrows container '{s}', but deferred deinit destroys its backing storage before the caller can use it",
                    .{ returned_name, container_name },
                ),
            });
        }
    }
}

fn findArenaReturns(context: RuleRun) !void {
    const level = context.level(.returning_arena_allocation);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!containsName(context, declaration_index + 3, declaration_end, "ArenaAllocator")) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const arena_name = context.tokenText(declaration_index + 1);
        if (!hasDeferredMethod(context, arena_name, "deinit", declaration_end + 1, scope_end, scope_opening)) continue;

        var allocations: std.StringHashMapUnmanaged(void) = .empty;
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |candidate, index| {
            if ((candidate.tag == .keyword_const or candidate.tag == .keyword_var) and index + 3 < scope_end and
                context.tokens[index + 1].tag == .identifier)
            {
                const binding_end = context.statementEnd(index) orelse continue;
                if (expressionUsesArenaAllocation(context, arena_name, index + 3, binding_end)) {
                    try allocations.put(context.allocator, context.tokenText(index + 1), {});
                }
            }
            if (candidate.tag != .keyword_return or context.enclosingOpeningBrace(index) != scope_opening) continue;
            const return_end = context.statementEnd(index) orelse continue;
            var returned_binding: ?[]const u8 = null;
            for (context.tokens[index + 1 .. return_end], index + 1..) |return_token, return_index| {
                if (return_token.tag == .identifier and allocations.contains(context.tokenText(return_index))) {
                    returned_binding = context.tokenText(return_index);
                    break;
                }
            }
            const direct_allocation = expressionUsesArenaAllocation(context, arena_name, index + 1, return_end);
            if (returned_binding == null and !direct_allocation) continue;
            try context.emit(.{
                .rule = .returning_arena_allocation,
                .level = level,
                .span = context.tokens[index].loc,
                .message = if (returned_binding) |name|
                    try std.fmt.allocPrint(
                        context.allocator,
                        "returned value '{s}' is allocated by local arena '{s}', which is deinitialized before return completes",
                        .{ name, arena_name },
                    )
                else
                    try std.fmt.allocPrint(
                        context.allocator,
                        "returned value is allocated by local arena '{s}', which is deinitialized before the caller can use it",
                        .{arena_name},
                    ),
            });
        }
    }
}

fn containsManagedContainer(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{ "ArrayList", "ArrayHashMap", "AutoHashMap", "StringHashMap" };
    for (names) |name| if (containsName(context, start, end, name)) return true;
    return false;
}

fn containsName(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

fn hasDeferredMethod(
    context: RuleRun,
    binding_name: []const u8,
    method: []const u8,
    start: usize,
    end: usize,
    scope_opening: usize,
) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_defer or context.enclosingOpeningBrace(index) != scope_opening) continue;
        const statement_end = context.statementEnd(index) orelse continue;
        var cursor = index + 1;
        while (cursor + 3 < statement_end) : (cursor += 1) {
            if (context.tokenIs(cursor, binding_name) and context.tokens[cursor + 1].tag == .period and
                context.tokenIs(cursor + 2, method) and context.tokens[cursor + 3].tag == .l_paren) return true;
        }
    }
    return false;
}

fn expressionUsesArenaAllocation(context: RuleRun, arena_name: []const u8, start: usize, end: usize) bool {
    const methods = [_][]const u8{ "alloc", "allocSentinel", "alignedAlloc", "dupe", "dupeZ", "create", "realloc" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, arena_name) or index + 6 >= end or
            context.tokens[index + 1].tag != .period or !context.tokenIs(index + 2, "allocator") or
            context.tokens[index + 3].tag != .l_paren or context.tokens[index + 4].tag != .r_paren or
            context.tokens[index + 5].tag != .period) continue;
        for (methods) |method| if (context.tokenIs(index + 6, method)) return true;
    }
    return false;
}

test "returned views and arena allocations cannot outlive local owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn items(allocator: anytype) []u8 { var list = std.ArrayList(u8).empty; defer list.deinit(allocator); return list.items; }\n" ++
        "fn bytes(parent: anytype) ![]u8 { var arena = std.heap.ArenaAllocator.init(parent); defer arena.deinit(); const value = try arena.allocator().dupe(u8, \"x\"); return value; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 2), findings.items.len);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
