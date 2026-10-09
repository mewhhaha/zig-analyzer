const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const rule_types = @import("../types.zig");
const support = @import("../test_support.zig");
const TokenRange = @import("../../syntax/tokens.zig").Range;
const container_types = @import("../container_types.zig");
const reach = @import("reach.zig");

const View = struct {
    name_index: usize,
    declaration_end: usize,
    kind: enum { items, iterator },
};

pub const rules = [_]rule_types.Rule{
    .invalidated_container_view,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.invalidated_container_view);
    if (level == .off) return;

    for (context.tokens, 0..) |token, index| {
        if (token.tag == .keyword_fn) {
            try checkParameters(context, level, index);
            continue;
        }
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or index + 3 >= context.tokens.len or
            context.tokens[index + 1].tag != .identifier) continue;
        const container_end = context.statementEnd(index) orelse continue;
        const kind = container_types.declaredKind(context.source, context.tokens, index, container_end) orelse continue;
        if (!kind.invalidatesViews()) continue;
        const scope_opening = context.enclosingOpeningBrace(index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        try checkContainerViews(context, level, context.tokenText(index + 1), kind, container_end + 1, scope_end);
    }
    try findFieldContainerViews(context, level);
    try findReallocatedViews(context, level);
    try findArenaResetViews(context, level);
    try findSelfAliasingInserts(context, level);
}

/// `list.appendSlice(gpa, list.items)`: growing the list frees the storage the
/// source slice still points into before the elements are copied.
fn findSelfAliasingInserts(context: RuleRun, level: rule_types.Level) !void {
    for (context.tokens, 0..) |token, method_index| {
        if (token.tag != .identifier or method_index < 2 or method_index + 1 >= context.tokens.len or
            context.tokens[method_index - 1].tag != .period or context.tokens[method_index + 1].tag != .l_paren) continue;
        const method = context.tokenText(method_index);
        if (!container_types.isOneOf(method, &.{ "appendSlice", "insertSlice", "replaceRange" })) continue;
        const receiver_start = context.pathStartBefore(method_index - 1) orelse continue;
        const receiver_length = method_index - 1 - receiver_start;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        var cursor = method_index + 2;
        while (cursor + receiver_length + 1 < call_end) : (cursor += 1) {
            if (context.tokens[cursor].tag != .identifier or context.tokens[cursor - 1].tag == .period or
                !context.dottedPathsEqual(receiver_start, method_index - 1, cursor, cursor + receiver_length)) continue;
            const items = cursor + receiver_length;
            if (context.tokens[items].tag != .period or !context.tokenIs(items + 1, "items")) continue;
            if (items + 2 < call_end and context.tokens[items + 2].tag != .comma and context.tokens[items + 2].tag != .l_bracket) continue;
            const path = context.source[context.tokens[receiver_start].loc.start..context.tokens[method_index - 2].loc.end];
            try context.emit(.{
                .rule = .invalidated_container_view,
                .level = level,
                .span = context.tokens[cursor].loc,
                .message = try context.allocator.print(
                    "{s} copies from '{s}.items', but growing '{s}' can free that storage before the copy",
                    .{ method, path, path },
                ),
            });
            break;
        }
    }
}

/// Views of a container passed by pointer: `list: *std.ArrayList(u8)`.
fn checkParameters(context: RuleRun, level: rule_types.Level, fn_index: usize) !void {
    const function = context.functionRange(fn_index) orelse return;
    var index = function.parameters_start;
    while (index + 2 < function.parameters_end) : (index += 1) {
        if (context.tokens[index].tag != .identifier or context.tokens[index + 1].tag != .colon) continue;
        const kind = container_types.kindOfTypeStart(context.source, context.tokens, index + 2, function.parameters_end) orelse continue;
        if (!kind.invalidatesViews()) continue;
        try checkContainerViews(context, level, context.tokenText(index), kind, function.body_start + 1, function.body_end);
    }
}

/// Reports each view of `container_name` taken in `[start, scope_end)` that is
/// used after an operation invalidating it.
fn checkContainerViews(
    context: RuleRun,
    level: rule_types.Level,
    container_name: []const u8,
    kind: container_types.Kind,
    start: usize,
    scope_end: usize,
) !void {
    var index = start;
    while (index < scope_end) : (index += 1) {
        const view = viewDeclaration(context, container_name, index, scope_end) orelse continue;
        const view_name = context.tokenText(view.name_index);
        const invalidation = firstInvalidation(
            context,
            container_name,
            kind,
            view_name,
            view.declaration_end + 1,
            scope_end,
        ) orelse continue;
        try context.emit(.{
            .rule = .invalidated_container_view,
            .level = level,
            .span = context.tokens[view.name_index].loc,
            .message = try context.allocator.print(
                "{s} '{s}' into container '{s}' is used after {s}, which may invalidate the view or its backing storage",
                .{ if (view.kind == .items) "slice" else "iterator", view_name, container_name, invalidation.method },
            ),
        });
        index = view.declaration_end;
    }
}

fn findArenaResetViews(context: RuleRun, level: rule_types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const allocator = allocationReceiver(context, declaration_index + 2, declaration_end) orelse continue;
        const arena = arenaForAllocatorAlias(context, allocator, declaration_index) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const reset_index = arenaResetAfter(context, arena, declaration_end + 1, scope_end, scope_opening) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        if (!bindingUsedAfterReset(context, binding, reset_index + 1, scope_end)) continue;
        try context.emit(.{
            .rule = .invalidated_container_view,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try context.allocator.print(
                "arena allocation '{s}' is used after {s}.reset invalidates it",
                .{ binding, arena },
            ),
        });
    }
}

fn bindingUsedAfterReset(context: RuleRun, binding: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, binding)) continue;
        if (index > start and (context.tokens[index - 1].tag == .keyword_const or
            context.tokens[index - 1].tag == .keyword_var)) return false;
        if (index + 1 < end and context.tokens[index + 1].tag == .equal) return false;
        return true;
    }
    return false;
}

pub fn allocationReceiver(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    const methods = [_][]const u8{ "alloc", "allocSentinel", "alignedAlloc", "dupe", "dupeZ", "dupeSentinel", "print", "printSentinel" };
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or method_index < 2 or context.tokens[method_index - 1].tag != .period or
            context.tokens[method_index - 2].tag != .identifier or method_index + 1 >= end or
            context.tokens[method_index + 1].tag != .l_paren) continue;
        for (methods) |method| if (context.tokenIs(method_index, method)) {
            return context.tokenText(method_index - 2);
        };
    }
    return null;
}

pub fn arenaForAllocatorAlias(context: RuleRun, allocator: []const u8, before: usize) ?[]const u8 {
    var index = before;
    while (index > 1) {
        index -= 1;
        if (!context.tokenIs(index, allocator) or
            (context.tokens[index - 1].tag != .keyword_const and context.tokens[index - 1].tag != .keyword_var) or
            index + 5 >= before or context.tokens[index + 1].tag != .equal or
            context.tokens[index + 2].tag != .identifier or context.tokens[index + 3].tag != .period or
            !context.tokenIs(index + 4, "allocator") or context.tokens[index + 5].tag != .l_paren) continue;
        const alias_scope_end = context.enclosingScopeEnd(index) orelse continue;
        if (alias_scope_end < before) continue;
        const arena = context.tokenText(index + 2);
        if (localArenaDeclaration(context, arena, index)) return arena;
    }
    return null;
}

fn localArenaDeclaration(context: RuleRun, arena: []const u8, before: usize) bool {
    var index = before;
    while (index > 1) {
        index -= 1;
        if (!context.tokenIs(index, arena) or
            (context.tokens[index - 1].tag != .keyword_const and context.tokens[index - 1].tag != .keyword_var)) continue;
        const arena_scope_end = context.enclosingScopeEnd(index) orelse continue;
        if (arena_scope_end < before) continue;
        const declaration_end = context.statementEnd(index - 1) orelse continue;
        if (declaration_end >= before) continue;
        for (context.tokens[index + 1 .. declaration_end], index + 1..) |_, candidate_index| {
            if (context.tokenIs(candidate_index, "ArenaAllocator")) return true;
        }
    }
    return false;
}

fn arenaResetAfter(
    context: RuleRun,
    arena: []const u8,
    start: usize,
    end: usize,
    scope_opening: usize,
) ?usize {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (!context.tokenIs(index, arena) or context.enclosingOpeningBrace(index) != scope_opening or
            context.tokens[index + 1].tag != .period or !context.tokenIs(index + 2, "reset") or
            context.tokens[index + 3].tag != .l_paren) continue;
        return index + 2;
    }
    return null;
}

fn findFieldContainerViews(context: RuleRun, level: rule_types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 8 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal or
            context.tokens[declaration_index + 3].tag != .identifier or context.tokens[declaration_index + 4].tag != .period or
            context.tokens[declaration_index + 5].tag != .identifier or context.tokens[declaration_index + 6].tag != .period or
            !context.tokenIs(declaration_index + 7, "items") or context.tokens[declaration_index + 8].tag != .semicolon) continue;
        const field_name = context.tokenText(declaration_index + 5);
        const kind = enclosingContainerFieldKind(context, declaration_index, field_name) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const base_name = context.tokenText(declaration_index + 3);
        const view_name = context.tokenText(declaration_index + 1);
        const invalidation = firstFieldInvalidation(
            context,
            base_name,
            field_name,
            kind,
            view_name,
            declaration_index + 9,
            scope_end,
        ) orelse continue;
        try context.emit(.{
            .rule = .invalidated_container_view,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try context.allocator.print(
                "slice '{s}' into container field '{s}.{s}' is used after {s}, which may invalidate its backing storage",
                .{ view_name, base_name, field_name, invalidation.method },
            ),
        });
    }
}

fn enclosingContainerFieldKind(context: RuleRun, target: usize, field_name: []const u8) ?container_types.Kind {
    var container_opening: ?usize = null;
    for (context.tokens[0..target], 0..) |token, struct_index| {
        if (token.tag != .keyword_struct or struct_index + 1 >= target or
            context.tokens[struct_index + 1].tag != .l_brace) continue;
        const closing = context.matchingToken(struct_index + 1, .l_brace, .r_brace) orelse continue;
        if (target < closing) container_opening = struct_index + 1;
    }
    const opening = container_opening orelse return null;
    const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse return null;
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
        const kind = container_types.firstKindIn(context.source, context.tokens, index + 2, field_end) orelse return null;
        return if (kind.invalidatesViews()) kind else null;
    }
    return null;
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
    kind: container_types.Kind,
    view_name: []const u8,
    start: usize,
    end: usize,
) ?Invalidation {
    var index = start;
    while (index + 5 < end) : (index += 1) {
        if (!context.tokenIs(index, base_name) or (index > 0 and context.tokens[index - 1].tag == .period) or
            context.tokens[index + 1].tag != .period or !context.tokenIs(index + 2, field_name) or
            context.tokens[index + 3].tag != .period or context.tokens[index + 4].tag != .identifier or
            context.tokens[index + 5].tag != .l_paren) continue;
        const method = context.tokenText(index + 4);
        if (!invalidatesView(kind, method)) continue;
        const call_end = reach.callEnd(context, index + 4) orelse continue;
        if (reach.firstReachedUse(context, view_name, index + 4, call_end + 1, end) == null) continue;
        return .{ .index = index, .method = method };
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
            if (!rangeContainsBorrowingPath(context, declaration_index + 3, declaration_end, allocation)) continue;
            if (reallocationReplacesBorrowedField(context, view_name, method_index, call_end)) continue;
            if (reach.firstReachedUse(context, view_name, method_index, call_end + 1, scope_end) == null) continue;
            try context.emit(.{
                .rule = .invalidated_container_view,
                .level = level,
                .span = context.tokens[declaration_index + 1].loc,
                .message = try context.allocator.print(
                    "view '{s}' is used after realloc invalidates its source allocation",
                    .{view_name},
                ),
            });
            break;
        }
    }
}

fn reallocationReplacesBorrowedField(context: RuleRun, view_name: []const u8, method_index: usize, call_end: usize) bool {
    var statement_start = method_index;
    while (statement_start > 0) {
        switch (context.tokens[statement_start - 1].tag) {
            .semicolon, .l_brace, .r_brace => break,
            else => statement_start -= 1,
        }
    }
    if (statement_start + 3 >= method_index or !context.tokenIs(statement_start, view_name) or
        context.tokens[statement_start + 1].tag != .period or context.tokens[statement_start + 2].tag != .identifier or
        context.tokens[statement_start + 3].tag != .equal) return false;
    for (context.tokens[statement_start + 4 .. method_index]) |token| switch (token.tag) {
        .keyword_try, .identifier, .period => {},
        else => return false,
    };
    const statement_end = context.statementEnd(method_index) orelse return false;
    if (call_end + 1 != statement_end) return false;
    const field_name = context.tokenText(statement_start + 2);
    var index = statement_start + 4;
    while (index + 4 < call_end) : (index += 1) {
        if (context.tokenIs(index, view_name) and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, field_name) and context.tokens[index + 3].tag == .period and
            context.tokenIs(index + 4, "len")) return true;
    }
    return false;
}

fn allocatorBinding(context: RuleRun, name: []const u8, before: usize) bool {
    if (std.ascii.findIgnoreCase(name, "alloc") != null or std.mem.eql(u8, name, "gpa")) return true;
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

fn rangeContainsBorrowingPath(context: RuleRun, start: usize, end: usize, path: TokenRange) bool {
    const path_length = path.end - path.start;
    if (path_length == 0 or path_length > end - start) return false;
    var candidate = start;
    while (candidate + path_length <= end) : (candidate += 1) {
        for (0..path_length) |offset| {
            if (context.tokens[candidate + offset].tag != context.tokens[path.start + offset].tag or
                !std.mem.eql(u8, context.tokenText(candidate + offset), context.tokenText(path.start + offset))) break;
        } else {
            const after_path = candidate + path_length;
            if (after_path + 1 < end and context.tokens[after_path].tag == .period and
                context.tokenIs(after_path + 1, "len")) continue;
            if (after_path < end and context.tokens[after_path].tag == .l_bracket) {
                const bracket_end = context.matchingToken(after_path, .l_bracket, .r_bracket) orelse continue;
                var is_slice = false;
                for (context.tokens[after_path + 1 .. @min(bracket_end, end)]) |token| {
                    if (token.tag == .ellipsis2 or token.tag == .ellipsis3) {
                        is_slice = true;
                        break;
                    }
                }
                const address_taken = candidate > start and context.tokens[candidate - 1].tag == .ampersand;
                if (!is_slice and !address_taken) continue;
            }
            return true;
        }
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
    if (context.tokenIs(index + 5, "items")) {
        if (context.tokens[index + 6].tag == .semicolon) {
            return .{ .name_index = index + 1, .declaration_end = declaration_end, .kind = .items };
        }
        // A subslice `items[a..b]` borrows the same storage.
        if (context.tokens[index + 6].tag == .l_bracket) {
            const closing = context.matchingToken(index + 6, .l_bracket, .r_bracket) orelse return null;
            if (closing + 1 != declaration_end) return null;
            for (context.tokens[index + 7 .. closing]) |token| {
                if (token.tag == .ellipsis2) return .{ .name_index = index + 1, .declaration_end = declaration_end, .kind = .items };
            }
        }
        return null;
    }
    const call_view = context.tokenIs(index + 5, "iterator") or context.tokenIs(index + 5, "keys") or
        context.tokenIs(index + 5, "values");
    if (call_view and index + 7 < scope_end and context.tokens[index + 6].tag == .l_paren and
        context.tokens[index + 7].tag == .r_paren and index + 8 == declaration_end)
    {
        return .{
            .name_index = index + 1,
            .declaration_end = declaration_end,
            .kind = if (context.tokenIs(index + 5, "iterator")) .iterator else .items,
        };
    }
    return null;
}

const Invalidation = struct { index: usize, method: []const u8 };

/// The first call on `container_name` that can invalidate its views and
/// after which `view_name` is still used.
fn firstInvalidation(
    context: RuleRun,
    container_name: []const u8,
    kind: container_types.Kind,
    view_name: []const u8,
    start: usize,
    end: usize,
) ?Invalidation {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, container_name) or
            (index > 0 and context.tokens[index - 1].tag == .period) or index + 3 >= end or
            context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
            context.tokens[index + 3].tag != .l_paren) continue;
        const method = context.tokenText(index + 2);
        if (!invalidatesView(kind, method)) continue;
        const call_end = reach.callEnd(context, index + 2) orelse continue;
        if (reach.firstReachedUse(context, view_name, index + 2, call_end + 1, end) == null) continue;
        return .{ .index = index, .method = method };
    }
    return null;
}

/// Methods after which a slice, key view or iterator of the container is stale.
fn invalidatesView(kind: container_types.Kind, method: []const u8) bool {
    if (kind.isMap()) {
        return container_types.isOneOf(method, &container_types.map_growth) or
            container_types.isOneOf(method, &container_types.map_removal);
    }
    return container_types.isOneOf(method, &container_types.list_growth);
}

test "container views used after possible reallocation warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn update(allocator: std.mem.Allocator) !void {\n" ++
        "    var list = std.ArrayList(u8).empty;\n" ++
        "    const old_items = list.items;\n" ++
        "    try list.append(allocator, 1);\n" ++
        "    consume(old_items);\n" ++
        "}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "append") != null);
}

test "arena allocations used after reset warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn run(backing: std.mem.Allocator) !void { var scratch = std.heap.ArenaAllocator.init(backing);" ++
        "defer scratch.deinit(); const allocator = scratch.allocator();" ++
        "const retained = try allocator.dupe(u8, \"before\"); _ = scratch.reset(.free_all); consume(.{retained}); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.invalidated_container_view, findings[0].rule);
}

test "arena printing and sentinel copies are invalidated by reset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(backing: std.mem.Allocator) !void { var scratch = std.heap.ArenaAllocator.init(backing);" ++
        "defer scratch.deinit(); const allocator = scratch.allocator();" ++
        "const printed = try allocator.print(\"literal\", .{});" ++
        "const copied = try allocator.dupeSentinel(u8, \"before\", 0);" ++
        "_ = scratch.reset(.free_all); consume(printed, copied); }";
    const found = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), found.len);
    for (found) |finding| try std.testing.expectEqual(rule_types.Rule.invalidated_container_view, finding.rule);
}

test "arena allocations consumed before reset stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn run(backing: std.mem.Allocator) !void { var scratch = std.heap.ArenaAllocator.init(backing);" ++
        "defer scratch.deinit(); const allocator = scratch.allocator();" ++
        "const temporary = try allocator.dupe(u8, \"before\"); consume(temporary); _ = scratch.reset(.retain_capacity); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "arena provenance ignores allocator aliases from closed sibling scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn run(backing: std.mem.Allocator, other: std.mem.Allocator, inspect: bool) !void {" ++
        "var scratch = std.heap.ArenaAllocator.init(backing); defer scratch.deinit();" ++
        "if (inspect) { const allocator = scratch.allocator(); consume(allocator); }" ++
        "const allocator = other; const retained = try allocator.dupe(u8, \"outside\");" ++
        "defer allocator.free(retained); _ = scratch.reset(.free_all); consume(retained); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .invalidated_container_view);
}

test "container field views used after possible reallocation warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "const Serializer = struct { output: std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator," ++
        "fn finish(self: *Serializer) ![]u8 { const view = self.output.items;" ++
        "try self.output.appendSlice(self.allocator, \"END\"); return view; } };";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "self.output") != null);
}

test "views not used after mutation stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn update(allocator: std.mem.Allocator) !void {\n" ++
        "    var list = std.ArrayList(u8).empty;\n" ++
        "    const old_items = list.items;\n" ++
        "    consume(old_items);\n" ++
        "    try list.append(allocator, 1);\n" ++
        "}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "reassigning the view after mutation refreshes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn update(allocator: std.mem.Allocator) !void {\n" ++
        "    var list = std.ArrayList(u8).empty;\n" ++
        "    var view = list.items;\n" ++
        "    try list.append(allocator, 1);\n" ++
        "    view = list.items;\n" ++
        "    consume(view);\n" ++
        "}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "views returned after their source allocation is reallocated report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn resize(frame: *Frame, width: usize) !View {\n" ++
        "    const previous = View{ .pixels = frame.pixels };\n" ++
        "    frame.pixels = try frame.allocator.realloc(frame.pixels, width);\n" ++
        "    return previous;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.invalidated_container_view, findings[0].rule);
}

test "custom realloc methods do not imply allocator invalidation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn resize(frame: *Frame, width: usize) !View {\n" ++
        "    const previous = View{ .pixels = frame.pixels };\n" ++
        "    frame.pixels = try frame.buffer.realloc(frame.pixels, width);\n" ++
        "    return previous;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "scalar metadata read before realloc is not a container view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn resize(allocator: std.mem.Allocator, pixels: []u8) !usize {" ++
        "const new_len = pixels.len * 2; pixels = try allocator.realloc(pixels, new_len); return new_len; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "scalar element read before realloc is not a container view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn pop(allocator: std.mem.Allocator, queue: []usize) !usize {" ++
        "const current = queue[0]; queue = try allocator.realloc(queue, queue.len - 1); return current; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "reallocating into the borrowed struct field replaces the stale view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn resize(allocator: std.mem.Allocator, source: []const u8) !Result {" ++
        "const buffer = try allocator.alloc(u8, source.len); var result = try parse(source, buffer);" ++
        "result.bytes = try allocator.realloc(buffer, result.bytes.len); return result; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "nested realloc results do not prove that a borrowed field was replaced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn resize(allocator: std.mem.Allocator, source: []const u8) !Result {" ++
        "const buffer = try allocator.alloc(u8, source.len); var result = try parse(source, buffer);" ++
        "result.bytes = normalize(try allocator.realloc(buffer, result.bytes.len)); return result; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

fn expectViews(source: [:0]const u8, expected: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());
    try std.testing.expectEqual(expected, found.len);
}

test "views of containers declared by type annotation are tracked" {
    try expectViews("fn f(g: A) !u8 { var l: std.ArrayList(u8) = .empty; const v = l.items; try l.append(g, 1); return v[0]; }", 1);
    try expectViews("fn f(g: A) !u8 { var l: std.ArrayList(u8) = try .initCapacity(g, 2); const v = l.items[0..1]; try l.append(g, 1); return v[0]; }", 1);
    try expectViews("fn f(g: A) !u8 { var m: std.AutoArrayHashMapUnmanaged(u8, u8) = .empty; const k = m.keys(); try m.put(g, 1, 1); return k[0]; }", 1);
}

test "reading only the length or comparing the pointer of a stale view is quiet" {
    try expectViews("fn f(g: A) !usize { var l: std.ArrayList(u8) = .empty; const v = l.items; try l.append(g, 1); return v.len; }", 0);
    try expectViews("fn f(g: A) !bool { var l: std.ArrayList(u8) = .empty; const old = l.items; try l.append(g, 1); return old.ptr == l.items.ptr; }", 0);
}

test "a view used only in the sibling branch of a returning mutation is quiet" {
    try expectViews("fn f(g: A, c: bool) !u8 { var l: std.ArrayList(u8) = .empty; const v = l.items; if (c) { try l.append(g, 1); return 0; } else { return v[0]; } }", 0);
    try expectViews("fn f(g: A, c: bool) !u8 { var l: std.ArrayList(u8) = .empty; const v = l.items; if (c) { try l.append(g, 1); } return v[0]; }", 1);
}

test "appending a container's own items to itself reports" {
    try expectViews("fn f(g: A) !void { var l: std.ArrayList(u8) = .empty; try l.appendSlice(g, l.items); }", 1);
    try expectViews("fn f(g: A, s: *S) !void { try s.list.appendSlice(g, s.list.items[1..]); }", 1);
    try expectViews("fn f(g: A, o: *std.ArrayList(u8)) !void { var l: std.ArrayList(u8) = .empty; try l.appendSlice(g, o.items); }", 0);
}

test "views of a container passed by pointer are tracked" {
    try expectViews("fn f(g: A, l: *std.ArrayList(u8)) !u8 { const v = l.items; try l.append(g, 1); return v[0]; }", 1);
    try expectViews("fn f(g: A, l: *std.ArrayList(u8)) !u8 { const v = l.items; return v[0]; }", 0);
    try expectViews("fn f(self: *const Page, y: usize) *Row { return &self.rows.ptr(m)[y]; }", 0);
}
