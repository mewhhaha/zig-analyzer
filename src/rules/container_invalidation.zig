const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;

pub fn run(context: RuleRun) !void {
    try findInvalidatedPointers(context);
    try findMutatedIteration(context);
}

fn findInvalidatedPointers(context: RuleRun) !void {
    const level = context.level(.invalidated_element_pointer);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!containsKnownContainer(context, declaration_index + 3, declaration_end)) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const container_name = context.tokenText(declaration_index + 1);
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |candidate, pointer_declaration| {
            if ((candidate.tag != .keyword_const and candidate.tag != .keyword_var) or pointer_declaration + 8 >= scope_end or
                context.tokens[pointer_declaration + 1].tag != .identifier or
                context.tokens[pointer_declaration + 2].tag != .equal or
                context.tokens[pointer_declaration + 3].tag != .ampersand or
                !context.tokenIs(pointer_declaration + 4, container_name) or
                context.tokens[pointer_declaration + 5].tag != .period or
                !context.tokenIs(pointer_declaration + 6, "items") or
                context.tokens[pointer_declaration + 7].tag != .l_bracket) continue;
            const pointer_end = context.statementEnd(pointer_declaration) orelse continue;
            const invalidation = firstInvalidation(context, container_name, pointer_end + 1, scope_end, scope_opening) orelse continue;
            const pointer_name = context.tokenText(pointer_declaration + 1);
            if (!usedAfter(context, pointer_name, invalidation.index + 1, scope_end)) continue;
            try context.emit(.{
                .rule = .invalidated_element_pointer,
                .level = level,
                .span = context.tokens[pointer_declaration + 1].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "pointer '{s}' into '{s}.items' is used after {s}, which may move the container's backing allocation",
                    .{ pointer_name, container_name, invalidation.method },
                ),
            });
        }
    }
}

fn findMutatedIteration(context: RuleRun) !void {
    const level = context.level(.iterator_invalidated_during_loop);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 7 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal or
            context.tokens[declaration_index + 3].tag != .identifier or context.tokens[declaration_index + 4].tag != .period or
            !context.tokenIs(declaration_index + 5, "iterator") or context.tokens[declaration_index + 6].tag != .l_paren or
            context.tokens[declaration_index + 7].tag != .r_paren) continue;
        const map_name = context.tokenText(declaration_index + 3);
        const iterator_name = context.tokenText(declaration_index + 1);
        const declaration_scope = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(declaration_scope, .l_brace, .r_brace) orelse continue;
        for (context.tokens[declaration_index + 8 .. scope_end], declaration_index + 8..) |candidate, while_index| {
            if (candidate.tag != .keyword_while or while_index + 1 >= scope_end or context.tokens[while_index + 1].tag != .l_paren) continue;
            const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
            if (!containsMethodCall(context, iterator_name, "next", while_index + 2, condition_end)) continue;
            var body_start = condition_end + 1;
            while (body_start < scope_end and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
            if (body_start >= scope_end) continue;
            const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
            const mutation = firstMapMutation(context, map_name, body_start + 1, body_end) orelse continue;
            try context.emit(.{
                .rule = .iterator_invalidated_during_loop,
                .level = level,
                .span = context.tokens[mutation.index].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "{s} mutates map '{s}' while iterator '{s}' is active; the next iteration may use invalid iterator state",
                    .{ mutation.method, map_name, iterator_name },
                ),
            });
        }
    }
}

const Mutation = struct { index: usize, method: []const u8 };

fn firstInvalidation(context: RuleRun, name: []const u8, start: usize, end: usize, scope: usize) ?Mutation {
    const methods = [_][]const u8{ "append", "appendSlice", "insert", "resize", "ensureTotalCapacity", "ensureUnusedCapacity", "addOne", "addManyAsArray" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or context.enclosingOpeningBrace(index) != scope or
            index + 3 >= end or context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
            context.tokens[index + 3].tag != .l_paren) continue;
        const method = context.tokenText(index + 2);
        for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return .{ .index = index, .method = method };
    }
    return null;
}

fn firstMapMutation(context: RuleRun, name: []const u8, start: usize, end: usize) ?Mutation {
    const methods = [_][]const u8{ "put", "putNoClobber", "fetchPut", "remove", "clearAndFree", "clearRetainingCapacity", "rehash" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index + 3 >= end or
            context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
            context.tokens[index + 3].tag != .l_paren) continue;
        const method = context.tokenText(index + 2);
        for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return .{ .index = index + 2, .method = method };
    }
    return null;
}

fn containsKnownContainer(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{ "ArrayList", "ArrayHashMap", "AutoHashMap", "StringHashMap" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        for (names) |name| if (context.tokenIs(index, name)) return true;
    }
    return false;
}

fn containsMethodCall(context: RuleRun, receiver: []const u8, method: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (context.tokenIs(index, receiver) and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, method) and context.tokens[index + 3].tag == .l_paren) return true;
    }
    return false;
}

fn usedAfter(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

test "element pointers and active map iterators are invalidated by mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn list(allocator: anytype) !void { var values = std.ArrayList(u8).empty; const first = &values.items[0]; try values.append(allocator, 1); use(first); }\n" ++
        "fn map() !void { var values = std.AutoHashMap(u8, u8).init(a); var iterator = values.iterator(); while (iterator.next()) |_| { try values.put(1, 2); } }";
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
