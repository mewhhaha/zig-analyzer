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
                context.tokenIs(index + 5, "items") and
                context.tokens[index + 6].tag == .semicolon) borrowed_name = context.tokenText(index + 1);
            if (candidate.tag != .keyword_return or context.enclosingOpeningBrace(index) != scope_opening or index + 1 >= scope_end) continue;
            const returns_direct_view = context.tokenIs(index + 1, container_name) and index + 4 < scope_end and
                context.tokens[index + 2].tag == .period and context.tokenIs(index + 3, "items") and
                context.tokens[index + 4].tag == .semicolon;
            const returns_borrow = borrowed_name != null and context.tokenIs(index + 1, borrowed_name.?) and
                index + 2 < scope_end and context.tokens[index + 2].tag == .semicolon;
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
        var allocator_bindings: std.StringHashMapUnmanaged(void) = .empty;
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |candidate, index| {
            if ((candidate.tag == .keyword_const or candidate.tag == .keyword_var) and index + 3 < scope_end and
                context.tokens[index + 1].tag == .identifier)
            {
                const binding_end = context.statementEnd(index) orelse continue;
                if (derivesArenaAllocator(context, arena_name, index + 3, binding_end)) {
                    try allocator_bindings.put(context.allocator, context.tokenText(index + 1), {});
                } else if (expressionUsesArenaAllocation(context, arena_name, index + 3, binding_end) or
                    expressionUsesDerivedAllocation(context, allocator_bindings, index + 3, binding_end))
                {
                    try allocations.put(context.allocator, context.tokenText(index + 1), {});
                }
            }
            if (candidate.tag != .keyword_return or context.enclosingOpeningBrace(index) != scope_opening) continue;
            const return_end = context.statementEnd(index) orelse continue;
            var value_start = index + 1;
            if (value_start < return_end and context.tokens[value_start].tag == .keyword_try) value_start += 1;
            const returned_binding: ?[]const u8 = if (value_start < return_end and
                context.tokens[value_start].tag == .identifier and
                allocations.contains(context.tokenText(value_start)) and
                (value_start + 1 == return_end or context.tokens[value_start + 1].tag == .l_bracket))
                context.tokenText(value_start)
            else
                null;
            const direct_allocation = expressionUsesArenaAllocation(context, arena_name, index + 1, return_end) or
                expressionUsesDerivedAllocation(context, allocator_bindings, index + 1, return_end);
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

const allocation_methods = [_][]const u8{ "alloc", "allocSentinel", "alignedAlloc", "dupe", "dupeZ", "create", "realloc" };

fn expressionUsesArenaAllocation(context: RuleRun, arena_name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, arena_name) or index + 6 >= end or
            context.tokens[index + 1].tag != .period or !context.tokenIs(index + 2, "allocator") or
            context.tokens[index + 3].tag != .l_paren or context.tokens[index + 4].tag != .r_paren or
            context.tokens[index + 5].tag != .period) continue;
        for (allocation_methods) |method| if (context.tokenIs(index + 6, method)) return true;
    }
    return false;
}

fn derivesArenaAllocator(context: RuleRun, arena_name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, arena_name) or index + 4 >= end or
            context.tokens[index + 1].tag != .period or !context.tokenIs(index + 2, "allocator") or
            context.tokens[index + 3].tag != .l_paren or context.tokens[index + 4].tag != .r_paren) continue;
        if (index + 5 >= end or context.tokens[index + 5].tag == .semicolon) return true;
    }
    return false;
}

fn expressionUsesDerivedAllocation(
    context: RuleRun,
    allocator_bindings: std.StringHashMapUnmanaged(void),
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 2 >= end or context.tokens[index + 1].tag != .period or
            !allocator_bindings.contains(context.tokenText(index))) continue;
        for (allocation_methods) |method| if (context.tokenIs(index + 2, method)) return true;
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

test "returning a value read out of a container view is not a dangling view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn count(allocator: anytype) usize { var list = std.ArrayList(u8).empty; defer list.deinit(allocator); return list.items.len; }\n" ++
        "fn first(allocator: anytype) u8 { var list = std.ArrayList(u8).empty; defer list.deinit(allocator); return list.items[0]; }\n" ++
        "fn borrowed(allocator: anytype) usize { var list = std.ArrayList(u8).empty; defer list.deinit(allocator); const n = list.items.len; return n; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "copying arena scratch out through another allocator is not an arena return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn out(gpa: anytype, parent: anytype) ![]u8 { var arena = std.heap.ArenaAllocator.init(parent); defer arena.deinit(); const aa = arena.allocator(); const scratch = try aa.dupe(u8, \"x\"); return try gpa.dupe(u8, scratch); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "allocations through a binding derived from the arena are arena returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn bytes(parent: anytype) ![]u8 { var arena = std.heap.ArenaAllocator.init(parent); defer arena.deinit(); const aa = arena.allocator(); const value = try aa.dupe(u8, \"x\"); return value; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
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
