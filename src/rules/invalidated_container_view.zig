const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const rule_types = @import("types.zig");

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
    try findFieldContainerViews(context, level);
    try findReallocatedViews(context, level);
}

fn findFieldContainerViews(context: RuleRun, level: rule_types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 8 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal or
            context.tokens[declaration_index + 3].tag != .identifier or context.tokens[declaration_index + 4].tag != .period or
            context.tokens[declaration_index + 5].tag != .identifier or context.tokens[declaration_index + 6].tag != .period or
            !context.tokenIs(declaration_index + 7, "items") or context.tokens[declaration_index + 8].tag != .semicolon) continue;
        const field_name = context.tokenText(declaration_index + 5);
        if (!enclosingContainerFieldIsManaged(context, declaration_index, field_name)) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const base_name = context.tokenText(declaration_index + 3);
        const invalidation = firstFieldInvalidation(
            context,
            base_name,
            field_name,
            declaration_index + 9,
            scope_end,
            scope_opening,
        ) orelse continue;
        const view_name = context.tokenText(declaration_index + 1);
        if (!viewUsedAfter(context, view_name, invalidation.index + 1, scope_end, scope_opening)) continue;
        try context.emit(.{
            .rule = .invalidated_container_view,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "slice '{s}' into container field '{s}.{s}' is used after {s}, which may invalidate its backing storage",
                .{ view_name, base_name, field_name, invalidation.method },
            ),
        });
    }
}

fn enclosingContainerFieldIsManaged(context: RuleRun, target: usize, field_name: []const u8) bool {
    var container_opening: ?usize = null;
    for (context.tokens[0..target], 0..) |token, struct_index| {
        if (token.tag != .keyword_struct or struct_index + 1 >= target or
            context.tokens[struct_index + 1].tag != .l_brace) continue;
        const closing = context.matchingToken(struct_index + 1, .l_brace, .r_brace) orelse continue;
        if (target < closing) container_opening = struct_index + 1;
    }
    const opening = container_opening orelse return false;
    const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse return false;
    var depth: usize = 0;
    var index = opening + 1;
    while (index + 2 < closing) : (index += 1) {
        switch (context.tokens[index].tag) {
            .l_brace => {
                depth += 1;
                continue;
            },
            .r_brace => {
                depth -|= 1;
                continue;
            },
            else => {},
        }
        if (depth != 0 or !context.tokenIs(index, field_name) or context.tokens[index + 1].tag != .colon) continue;
        const field_end = fieldTypeEnd(context.tokens, index + 2, closing);
        return declarationNamesKnownContainer(context, index + 2, field_end);
    }
    return false;
}

fn fieldTypeEnd(tokens: []const std.zig.Token, start: usize, end: usize) usize {
    var depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) switch (tokens[index].tag) {
        .l_paren, .l_bracket => depth += 1,
        .r_paren, .r_bracket => depth -|= 1,
        .comma, .equal => if (depth == 0) return index,
        .l_brace, .r_brace, .semicolon => if (depth == 0) return index,
        else => {},
    };
    return end;
}

fn firstFieldInvalidation(
    context: RuleRun,
    base_name: []const u8,
    field_name: []const u8,
    start: usize,
    end: usize,
    scope_opening: usize,
) ?Invalidation {
    const methods = [_][]const u8{
        "append",               "appendNTimes", "appendSlice",    "insert",       "resize",                 "ensureTotalCapacity",
        "ensureUnusedCapacity", "addOne",       "addManyAsArray", "clearAndFree", "clearRetainingCapacity",
    };
    var index = start;
    while (index + 5 < end) : (index += 1) {
        if (!context.tokenIs(index, base_name) or context.enclosingOpeningBrace(index) != scope_opening or
            context.tokens[index + 1].tag != .period or !context.tokenIs(index + 2, field_name) or
            context.tokens[index + 3].tag != .period or context.tokens[index + 4].tag != .identifier or
            context.tokens[index + 5].tag != .l_paren) continue;
        const method = context.tokenText(index + 4);
        for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return .{ .index = index, .method = method };
    }
    return null;
}

fn findReallocatedViews(context: RuleRun, level: rule_types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 3 >= context.tokens.len or context.tokens[declaration_index + 1].tag != .identifier or
            context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const view_name = context.tokenText(declaration_index + 1);
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or !context.tokenIs(method_index, "realloc") or
                method_index + 1 >= scope_end or context.tokens[method_index + 1].tag != .l_paren) continue;
            if (method_index < 2 or context.tokens[method_index - 1].tag != .period or
                context.tokens[method_index - 2].tag != .identifier or
                !allocatorBinding(context, context.tokenText(method_index - 2), method_index)) continue;
            const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
            const allocation = firstArgument(context, method_index + 2, call_end) orelse continue;
            if (!rangeContainsPath(context, declaration_index + 3, declaration_end, allocation)) continue;
            if (!viewUsedAfter(context, view_name, call_end + 1, scope_end, scope_opening)) continue;
            try context.emit(.{
                .rule = .invalidated_container_view,
                .level = level,
                .span = context.tokens[declaration_index + 1].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "view '{s}' is used after realloc invalidates its source allocation",
                    .{view_name},
                ),
            });
            break;
        }
    }
}

fn allocatorBinding(context: RuleRun, name: []const u8, before: usize) bool {
    if (std.ascii.indexOfIgnoreCase(name, "alloc") != null or std.mem.eql(u8, name, "gpa")) return true;
    var name_index = before;
    while (name_index > 0) {
        name_index -= 1;
        if (!context.tokenIs(name_index, name) or name_index + 2 >= before or
            context.tokens[name_index + 1].tag != .colon) continue;
        var type_index = name_index + 2;
        while (type_index < before) : (type_index += 1) {
            if (context.tokens[type_index].tag == .identifier and context.tokenIs(type_index, "Allocator")) return true;
            if (context.tokens[type_index].tag == .comma or context.tokens[type_index].tag == .r_paren or
                context.tokens[type_index].tag == .equal or context.tokens[type_index].tag == .semicolon) return false;
        }
    }
    return false;
}

const TokenRange = struct { start: usize, end: usize };

fn firstArgument(context: RuleRun, start: usize, end: usize) ?TokenRange {
    if (start >= end) return null;
    var depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) return .{ .start = start, .end = index },
        else => {},
    };
    return .{ .start = start, .end = end };
}

fn rangeContainsPath(context: RuleRun, start: usize, end: usize, path: TokenRange) bool {
    const path_length = path.end - path.start;
    if (path_length == 0 or path_length > end - start) return false;
    var candidate = start;
    while (candidate + path_length <= end) : (candidate += 1) {
        for (0..path_length) |offset| {
            if (context.tokens[candidate + offset].tag != context.tokens[path.start + offset].tag or
                !std.mem.eql(u8, context.tokenText(candidate + offset), context.tokenText(path.start + offset))) break;
        } else return true;
    }
    return false;
}

fn declarationNamesKnownContainer(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{
        "ArrayList",
        "ArrayListUnmanaged",
        "ArrayHashMap",
        "ArrayHashMapUnmanaged",
        "AutoHashMap",
        "AutoHashMapUnmanaged",
        "StringHashMap",
        "StringHashMapUnmanaged",
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
        "appendNTimes",
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
        if (index + 1 < end and context.tokens[index + 1].tag == .equal) return false;
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

test "container field views used after possible reallocation warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "const Serializer = struct { output: std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator," ++
        "fn finish(self: *Serializer) ![]u8 { const view = self.output.items;" ++
        "try self.output.appendSlice(self.allocator, \"END\"); return view; } };";
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
    try std.testing.expect(std.mem.indexOf(u8, findings.items[0].message, "self.output") != null);
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

test "reassigning the view after mutation refreshes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn update(allocator: std.mem.Allocator) !void {\n" ++
        "    var list = std.ArrayList(u8).empty;\n" ++
        "    var view = list.items;\n" ++
        "    try list.append(allocator, 1);\n" ++
        "    view = list.items;\n" ++
        "    consume(view);\n" ++
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

test "views returned after their source allocation is reallocated report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn resize(frame: *Frame, width: usize) !View {\n" ++
        "    const previous = View{ .pixels = frame.pixels };\n" ++
        "    frame.pixels = try frame.allocator.realloc(frame.pixels, width);\n" ++
        "    return previous;\n" ++
        "}\n";
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
    try std.testing.expectEqual(types.Rule.invalidated_container_view, findings.items[0].rule);
}

test "custom realloc methods do not imply allocator invalidation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn resize(frame: *Frame, width: usize) !View {\n" ++
        "    const previous = View{ .pixels = frame.pixels };\n" ++
        "    frame.pixels = try frame.buffer.realloc(frame.pixels, width);\n" ++
        "    return previous;\n" ++
        "}\n";
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
