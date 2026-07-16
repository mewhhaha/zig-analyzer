const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;

const View = struct {
    name_index: usize,
    declaration_end: usize,
    kind: enum { items, iterator },
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.invalidated_container_view);
    if (level == .off) return;

    for (context.tokens, 0..) |token, container_declaration| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or container_declaration + 3 >= context.tokens.len or
            context.tokens[container_declaration + 1].tag != .identifier or
            context.tokens[container_declaration + 2].tag != .equal) continue;
        const container_end = context.statementEnd(container_declaration) orelse continue;
        if (!declarationNamesKnownContainer(context, container_declaration + 3, container_end)) continue;
        const scope_opening = context.enclosingOpeningBrace(container_declaration) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const container_name = context.tokenText(container_declaration + 1);

        var index = container_end + 1;
        while (index < scope_end) : (index += 1) {
            const view = viewDeclaration(context, container_name, index, scope_end) orelse continue;
            const invalidation = firstInvalidation(
                context,
                container_name,
                view.declaration_end + 1,
                scope_end,
                scope_opening,
            ) orelse continue;
            const view_name = context.tokenText(view.name_index);
            if (!viewUsedAfter(context, view_name, invalidation.index + 1, scope_end, scope_opening)) continue;
            try context.emit(.{
                .rule = .invalidated_container_view,
                .level = level,
                .span = context.tokens[view.name_index].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "{s} '{s}' into container '{s}' is used after {s}, which may invalidate the view or its backing storage",
                    .{ if (view.kind == .items) "slice" else "iterator", view_name, container_name, invalidation.method },
                ),
            });
            index = view.declaration_end;
        }
    }
}

fn declarationNamesKnownContainer(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{
        "ArrayList",
        "ArrayHashMap",
        "AutoHashMap",
        "StringHashMap",
    };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        for (names) |name| if (context.tokenIs(index, name)) return true;
    }
    return false;
}

fn viewDeclaration(context: RuleRun, container_name: []const u8, index: usize, scope_end: usize) ?View {
    if (index + 6 >= scope_end or
        (context.tokens[index].tag != .keyword_const and context.tokens[index].tag != .keyword_var) or
        context.tokens[index + 1].tag != .identifier or context.tokens[index + 2].tag != .equal or
        !context.tokenIs(index + 3, container_name) or context.tokens[index + 4].tag != .period or
        context.tokens[index + 5].tag != .identifier) return null;
    const declaration_end = context.statementEnd(index) orelse return null;
    if (context.tokenIs(index + 5, "items") and context.tokens[index + 6].tag == .semicolon) {
        return .{ .name_index = index + 1, .declaration_end = declaration_end, .kind = .items };
    }
    if (context.tokenIs(index + 5, "iterator") and index + 7 < scope_end and
        context.tokens[index + 6].tag == .l_paren and context.tokens[index + 7].tag == .r_paren)
    {
        return .{ .name_index = index + 1, .declaration_end = declaration_end, .kind = .iterator };
    }
    return null;
}

const Invalidation = struct { index: usize, method: []const u8 };

fn firstInvalidation(
    context: RuleRun,
    container_name: []const u8,
    start: usize,
    end: usize,
    scope_opening: usize,
) ?Invalidation {
    const methods = [_][]const u8{
        "append",
        "appendSlice",
        "insert",
        "resize",
        "ensureTotalCapacity",
        "ensureUnusedCapacity",
        "addOne",
        "addManyAsArray",
        "put",
        "putNoClobber",
        "fetchPut",
        "remove",
        "clearAndFree",
        "clearRetainingCapacity",
        "rehash",
    };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, container_name) or
            context.enclosingOpeningBrace(index) != scope_opening or index + 3 >= end or
            context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
            context.tokens[index + 3].tag != .l_paren) continue;
        const method = context.tokenText(index + 2);
        for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return .{ .index = index, .method = method };
    }
    return null;
}

fn viewUsedAfter(context: RuleRun, view_name: []const u8, start: usize, end: usize, scope_opening: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, view_name) or
            context.enclosingOpeningBrace(index) != scope_opening) continue;
        if (index > start and (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var)) return false;
        return true;
    }
    return false;
}

test "container views used after possible reallocation warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn update(allocator: std.mem.Allocator) !void {\n" ++
        "    var list = std.ArrayList(u8).empty;\n" ++
        "    const old_items = list.items;\n" ++
        "    try list.append(allocator, 1);\n" ++
        "    consume(old_items);\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, findings.items[0].message, "append") != null);
}

test "views not used after mutation stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn update(allocator: std.mem.Allocator) !void {\n" ++
        "    var list = std.ArrayList(u8).empty;\n" ++
        "    const old_items = list.items;\n" ++
        "    consume(old_items);\n" ++
        "    try list.append(allocator, 1);\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
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
