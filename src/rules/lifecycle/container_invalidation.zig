const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const rule_types = @import("../types.zig");
const support = @import("../test_support.zig");
const IdentifierTable = @import("../../syntax/scope.zig").IdentifierTable;
const container_types = @import("../container_types.zig");
const reach = @import("reach.zig");

pub const rules = [_]rule_types.Rule{
    .invalidated_element_pointer,
    .iterator_invalidated_during_loop,
    .stale_index_map,
};

pub fn run(context: RuleRun) !void {
    try findInvalidatedPointers(context);
    try findMutatedIteration(context);
    try findMutatedViewLoops(context);
    try findInvalidatedMapEntryPointers(context);
    try findStaleIndexMaps(context);
}

/// Methods that return a pointer into the list's current storage.
const pointer_producers = [_][]const u8{ "addOne", "addOneAssumeCapacity", "addManyAsArray", "addManyAsSlice" };

const oneOf = container_types.isOneOf;

/// List methods that can move or shift the storage behind `items`.
fn isListMutation(method: []const u8) bool {
    return oneOf(method, &container_types.list_growth) or oneOf(method, &container_types.list_removal);
}

/// Map methods that can rehash, or move or remove entries.
fn isMapMutation(method: []const u8) bool {
    return oneOf(method, &container_types.map_growth) or oneOf(method, &container_types.map_removal);
}

/// A declaration whose value points into a list: `&path.items[i]` or the
/// result of `path.addOne(..)`.
const ElementPointer = struct {
    name_index: usize,
    path_start: usize,
    path_end: usize,
    from_items: bool,
    /// The element index when it is a plain integer literal.
    index_literal: ?u64,
};

fn elementPointer(context: RuleRun, declaration: usize, declaration_end: usize) ?ElementPointer {
    const tokens = context.tokens;
    if ((tokens[declaration].tag != .keyword_const and tokens[declaration].tag != .keyword_var) or
        declaration + 2 >= declaration_end or tokens[declaration + 1].tag != .identifier or
        (tokens[declaration + 2].tag != .equal and tokens[declaration + 2].tag != .colon)) return null;
    var start = container_types.initializerStart(tokens, declaration, declaration_end) orelse return null;
    if (start < declaration_end and tokens[start].tag == .keyword_try) start += 1;
    if (start + 2 >= declaration_end) return null;
    if (tokens[start].tag == .ampersand) {
        const items_index = itemsField(context, start + 1, declaration_end) orelse return null;
        var literal: ?u64 = null;
        if (items_index + 3 < declaration_end and tokens[items_index + 2].tag == .number_literal and
            tokens[items_index + 3].tag == .r_bracket)
        {
            literal = literalIndex(context, items_index + 2);
        }
        return .{
            .name_index = declaration + 1,
            .path_start = start + 1,
            .path_end = items_index - 2,
            .from_items = true,
            .index_literal = literal,
        };
    }
    var method = start;
    while (method + 1 < declaration_end and tokens[method].tag == .identifier and tokens[method + 1].tag == .period) method += 2;
    if (method == start or tokens[method].tag != .identifier or method + 1 >= declaration_end or
        tokens[method + 1].tag != .l_paren or !oneOf(context.tokenText(method), &pointer_producers)) return null;
    const call_end = context.matchingToken(method + 1, .l_paren, .r_paren) orelse return null;
    if (call_end + 1 != declaration_end) return null;
    return .{
        .name_index = declaration + 1,
        .path_start = start,
        .path_end = method - 2,
        .from_items = false,
        .index_literal = null,
    };
}

/// What the file says about each name asked about: whether a `name: Type`
/// gives it a list type, and its first `const name` declaring a list.
const ListNames = struct {
    names: std.StringHashMapUnmanaged(Facts) = .empty,

    const Facts = struct { typed: bool = false, first_declaration: ?usize = null };

    fn deinit(lists: *ListNames, allocator: std.mem.Allocator) void {
        lists.names.deinit(allocator);
    }

    /// Whether the last name of the path is a list: declared locally before
    /// `before`, or a field or parameter with a list type.
    fn pathIsList(lists: *ListNames, context: RuleRun, identifiers: *const IdentifierTable, path_end: usize, before: usize) !bool {
        const name = context.tokenText(path_end);
        const entry = try lists.names.getOrPut(context.allocator, name);
        if (!entry.found_existing) entry.value_ptr.* = listFacts(context, identifiers.all(name));
        const facts = entry.value_ptr.*;
        const declared = if (facts.first_declaration) |index| index < before else false;
        return facts.typed or declared;
    }
};

/// The facts of `ListNames` for the identifiers at `positions`, in one pass.
fn listFacts(context: RuleRun, positions: []const u32) ListNames.Facts {
    var facts: ListNames.Facts = .{};
    for (positions) |position| {
        const index: usize = position;
        if (index + 2 < context.tokens.len and context.tokens[index + 1].tag == .colon) {
            const type_end = @min(index + 12, context.tokens.len);
            if (container_types.kindOfTypeStart(context.source, context.tokens, index + 2, type_end)) |kind| {
                if (kind.hasItems()) facts.typed = true;
            }
        }
        // A list type makes every use a list.
        if (facts.typed) break;
        if (facts.first_declaration == null and index > 0 and
            (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var))
        {
            const declaration_end = context.statementEnd(index - 1) orelse continue;
            if (container_types.declaredKind(context.source, context.tokens, index - 1, declaration_end)) |kind| {
                if (kind.hasItems()) facts.first_declaration = index;
            }
        }
    }
    return facts;
}

fn findInvalidatedPointers(context: RuleRun) !void {
    const level = context.level(.invalidated_element_pointer);
    if (level == .off) return;
    var lists: ListNames = .{};
    defer lists.deinit(context.allocator);
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_const and token.tag != .keyword_var) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const pointer = elementPointer(context, declaration_index, declaration_end) orelse continue;
        const identifiers = try context.scopes.identifiers();
        if (!pointer.from_items and !try lists.pathIsList(context, identifiers, pointer.path_end, declaration_index)) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const invalidation = firstPathInvalidation(context, identifiers, pointer, declaration_end + 1, scope_end) orelse continue;
        const pointer_name = context.tokenText(pointer.name_index);
        const path = context.source[context.tokens[pointer.path_start].loc.start..context.tokens[pointer.path_end].loc.end];
        try context.emit(.{
            .rule = .invalidated_element_pointer,
            .level = level,
            .span = context.tokens[pointer.name_index].loc,
            .message = if (pointer.from_items)
                try context.allocator.print(
                    "pointer '{s}' into '{s}.items' is used after {s}, which invalidates or may move the referenced element",
                    .{ pointer_name, path, invalidation.method },
                )
            else
                try context.allocator.print(
                    "pointer '{s}' returned by '{s}.{s}' is used after {s}, which invalidates or may move the referenced element",
                    .{ pointer_name, path, context.tokenText(pointer.path_end + 2), invalidation.method },
                ),
        });
    }
}

fn itemsField(context: RuleRun, start: usize, end: usize) ?usize {
    var index = start;
    while (index + 1 < end) : (index += 1) {
        if (!context.tokenIs(index, "items") or index == start or context.tokens[index - 1].tag != .period or
            context.tokens[index + 1].tag != .l_bracket) continue;
        var cursor = start;
        while (cursor < index - 1) : (cursor += 1) {
            const expected: std.zig.Token.Tag = if ((cursor - start) % 2 == 0) .identifier else .period;
            if (context.tokens[cursor].tag != expected) return null;
        }
        return index;
    }
    return null;
}

/// The first mutation of the pointer's list after `start` that a later use of
/// the pointer can observe.
fn firstPathInvalidation(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    pointer: ElementPointer,
    start: usize,
    end: usize,
) ?Mutation {
    const pointer_name = context.tokenText(pointer.name_index);
    // `samePath` compares spellings, so the path can only start at an
    // identifier spelled like its first token; a call from the pointer's
    // last mention on leaves no use of it to reach.
    const last = reach.lastMention(identifiers, pointer_name, start, end);
    for (identifiers.within(context.tokenText(pointer.path_start), start, last)) |position| {
        const index: usize = position;
        if (!samePath(context, pointer.path_start, pointer.path_end, index, end)) continue;
        const method_index = index + (pointer.path_end - pointer.path_start) + 2;
        if (method_index + 1 >= end or context.tokens[method_index - 1].tag != .period or
            context.tokens[method_index].tag != .identifier or context.tokens[method_index + 1].tag != .l_paren) continue;
        const method = context.tokenText(method_index);
        if (!isListMutation(method)) continue;
        if (removesAfterElement(context, pointer, method_index)) continue;
        const call_end = reach.callEnd(context, method_index) orelse continue;
        if (reach.firstReachedUse(context, identifiers, pointer_name, method_index, call_end + 1, end) == null) continue;
        return .{ .index = method_index, .method = method };
    }
    return null;
}

fn literalIndex(context: RuleRun, index: usize) ?u64 {
    if (std.fmt.parseInt(u64, context.tokenText(index), 10)) |value| return value else |_| return null;
}

/// `orderedRemove(k)` and `swapRemove(k)` leave elements below index `k` in
/// place; provable only when both indices are integer literals.
fn removesAfterElement(context: RuleRun, pointer: ElementPointer, method_index: usize) bool {
    const element = pointer.index_literal orelse return false;
    if (!context.tokenIs(method_index, "orderedRemove") and !context.tokenIs(method_index, "swapRemove")) return false;
    if (method_index + 3 >= context.tokens.len or context.tokens[method_index + 2].tag != .number_literal or
        context.tokens[method_index + 3].tag != .r_paren) return false;
    const removed = literalIndex(context, method_index + 2) orelse return false;
    return element < removed;
}

fn findMutatedIteration(context: RuleRun) !void {
    const level = context.level(.iterator_invalidated_during_loop);
    if (level == .off) return;
    const tokens = context.tokens;
    // Built for the first iterator: the innermost `(` open at each token and
    // the file's `{` in order.
    var parentheses: ?[]const u32 = null;
    defer if (parentheses) |enclosing| context.allocator.free(enclosing);
    var braces: std.ArrayList(u32) = .empty;
    defer braces.deinit(context.allocator);
    var loops: std.ArrayList(u32) = .empty;
    defer loops.deinit(context.allocator);
    for (tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 7 >= tokens.len or
            tokens[declaration_index + 1].tag != .identifier or tokens[declaration_index + 2].tag != .equal or
            tokens[declaration_index + 3].tag != .identifier or tokens[declaration_index + 4].tag != .period or
            !context.tokenIs(declaration_index + 5, "iterator") or tokens[declaration_index + 6].tag != .l_paren or
            tokens[declaration_index + 7].tag != .r_paren) continue;
        const map_name = context.tokenText(declaration_index + 3);
        const iterator_name = context.tokenText(declaration_index + 1);
        const declaration_scope = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(declaration_scope, .l_brace, .r_brace) orelse continue;
        const identifiers = try context.scopes.identifiers();
        const enclosing = parentheses orelse try openParentheses(context, &braces);
        parentheses = enclosing;
        // The `while (` loops after the declaration whose condition calls
        // `iterator.next(`, found as the parentheses around each call. A loop
        // whose condition closes past `scope_end - 2` has no body in the scope.
        loops.clearRetainingCapacity();
        for (identifiers.within(iterator_name, declaration_index + 8, scope_end)) |position| {
            const call: usize = position;
            if (call + 3 >= tokens.len or tokens[call + 1].tag != .period or !context.tokenIs(call + 2, "next") or
                tokens[call + 3].tag != .l_paren) continue;
            var opening = enclosing[call];
            while (opening != no_parenthesis and opening >= declaration_index + 9) : (opening = enclosing[opening]) {
                if (tokens[opening - 1].tag != .keyword_while) continue;
                const condition_end = context.scopes.matchingToken(opening) orelse continue;
                if (call + 3 < condition_end) try loops.append(context.allocator, opening - 1);
            }
        }
        std.mem.sort(u32, loops.items, {}, std.sort.asc(u32));
        for (loops.items, 0..) |while_position, order| {
            if (order > 0 and loops.items[order - 1] == while_position) continue;
            const while_index: usize = while_position;
            const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
            // The first `{` after the condition.
            const body = positionsWithin(braces.items, condition_end + 1, scope_end);
            if (body.len == 0) continue;
            const body_start: usize = body[0];
            const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
            const mutation = firstMapMutation(context, identifiers, map_name, body_start + 1, body_end) orelse continue;
            try context.emit(.{
                .rule = .iterator_invalidated_during_loop,
                .level = level,
                .span = context.tokens[mutation.index].loc,
                .message = try context.allocator.print(
                    "{s} mutates map '{s}' while iterator '{s}' is active; the next iteration may use invalid iterator state",
                    .{ mutation.method, map_name, iterator_name },
                ),
            });
        }
    }
}

const no_parenthesis = std.math.maxInt(u32);

/// The innermost `(` open at each token, kept by the stack that pairs
/// parentheses in the scope index, and the positions of the file's `{`.
fn openParentheses(context: RuleRun, braces: *std.ArrayList(u32)) ![]const u32 {
    const enclosing = try context.allocator.alloc(u32, context.tokens.len);
    errdefer context.allocator.free(enclosing);
    var open: std.ArrayList(u32) = .empty;
    defer open.deinit(context.allocator);
    for (context.tokens, 0..) |token, index| {
        switch (token.tag) {
            .r_paren => _ = open.pop(),
            .l_brace => try braces.append(context.allocator, @intCast(index)),
            else => {},
        }
        enclosing[index] = open.last() orelse no_parenthesis;
        if (token.tag == .l_paren) try open.append(context.allocator, @intCast(index));
    }
    return enclosing;
}

/// `for (list.items) |x| try list.append(..)`: the loop walks a slice or key
/// view of a container that its own body grows or reshapes.
fn findMutatedViewLoops(context: RuleRun) !void {
    const level = context.level(.iterator_invalidated_during_loop);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 1 >= context.tokens.len or context.tokens[for_index + 1].tag != .l_paren) continue;
        const header_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        const view = iteratedView(context, for_index + 2, header_end) orelse continue;
        var body_start = header_end + 1;
        if (body_start < context.tokens.len and context.tokens[body_start].tag == .pipe) {
            body_start += 1;
            while (body_start < context.tokens.len and context.tokens[body_start].tag != .pipe) : (body_start += 1) {}
            body_start += 1;
        }
        if (body_start >= context.tokens.len) continue;
        const body_end = if (context.tokens[body_start].tag == .l_brace)
            context.matchingToken(body_start, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(body_start) orelse continue;
        const mutation = firstViewMutation(context, view, body_start, body_end) orelse continue;
        const path = context.source[context.tokens[view.path_start].loc.start..context.tokens[view.path_end].loc.end];
        try context.emit(.{
            .rule = .iterator_invalidated_during_loop,
            .level = level,
            .span = context.tokens[mutation.index].loc,
            .message = try context.allocator.print(
                "{s} mutates '{s}' while this loop iterates its {s}; growth or removal invalidates the iterated storage",
                .{ mutation.method, path, view.what },
            ),
        });
    }
}

const IteratedView = struct { path_start: usize, path_end: usize, what: []const u8 };

/// The first loop operand shaped like `path.items`, `path.items[a..b]`,
/// `path.keys()` or `path.values()`.
fn iteratedView(context: RuleRun, start: usize, end: usize) ?IteratedView {
    var operand = start;
    while (operand < end) {
        var cursor = operand;
        while (cursor + 1 < end and context.tokens[cursor].tag == .identifier and context.tokens[cursor + 1].tag == .period) cursor += 2;
        if (cursor > operand and cursor < end and context.tokens[cursor].tag == .identifier) {
            const after = cursor + 1;
            if (context.tokenIs(cursor, "items") and (after >= end or context.tokens[after].tag == .comma or
                context.tokens[after].tag == .l_bracket))
            {
                return .{ .path_start = operand, .path_end = cursor - 2, .what = "items" };
            }
            if ((context.tokenIs(cursor, "keys") or context.tokenIs(cursor, "values")) and after + 1 < end and
                context.tokens[after].tag == .l_paren and context.tokens[after + 1].tag == .r_paren)
            {
                return .{ .path_start = operand, .path_end = cursor - 2, .what = context.tokenText(cursor) };
            }
        }
        while (operand < end and context.tokens[operand].tag != .comma) : (operand += 1) {}
        operand += 1;
    }
    return null;
}

fn firstViewMutation(context: RuleRun, view: IteratedView, start: usize, end: usize) ?Mutation {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !samePath(context, view.path_start, view.path_end, index, end)) continue;
        const method_index = index + (view.path_end - view.path_start) + 2;
        if (method_index + 1 >= end or context.tokens[method_index - 1].tag != .period or
            context.tokens[method_index + 1].tag != .l_paren) continue;
        const method = context.tokenText(method_index);
        const layout = isListMutation(method) or isMapMutation(method);
        if (!layout or std.mem.eql(u8, method, "clearRetainingCapacity") or mutationExitsLoop(context, method_index, end)) continue;
        return .{ .index = method_index, .method = method };
    }
    return null;
}

const Mutation = struct { index: usize, method: []const u8 };

fn firstMapMutation(context: RuleRun, identifiers: *const IdentifierTable, name: []const u8, start: usize, end: usize) ?Mutation {
    const methods = [_][]const u8{
        "put",        "putNoClobber",  "fetchPut",        "getOrPut",           "remove",       "fetchRemove",
        "swapRemove", "orderedRemove", "fetchSwapRemove", "fetchOrderedRemove", "clearAndFree", "clearRetainingCapacity",
        "rehash",
    };
    for (identifiers.within(name, start, end)) |position| {
        const index: usize = position;
        if (index + 3 >= end or context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
            context.tokens[index + 3].tag != .l_paren) continue;
        const method = context.tokenText(index + 2);
        var mutates = false;
        for (methods) |candidate| {
            if (std.mem.eql(u8, method, candidate)) mutates = true;
        }
        if (!mutates or mutationExitsLoop(context, index, end)) continue;
        return .{ .index = index + 2, .method = method };
    }
    return null;
}

/// Whether the loop is left right after the mutation: a `break` or `return`
/// follows it in the same block without any branching in between.
fn mutationExitsLoop(context: RuleRun, mutation_index: usize, body_end: usize) bool {
    const block = context.enclosingOpeningBrace(mutation_index) orelse return false;
    const statement_end = context.statementEnd(mutation_index) orelse return false;
    var cursor = statement_end + 1;
    while (cursor < body_end) : (cursor += 1) {
        if (context.enclosingOpeningBrace(cursor) != block) continue;
        switch (context.tokens[cursor].tag) {
            .keyword_break, .keyword_return => switch (context.tokens[cursor - 1].tag) {
                .semicolon, .l_brace, .r_brace => return true,
                else => {},
            },
            .keyword_continue => return false,
            else => {},
        }
    }
    return false;
}

fn findInvalidatedMapEntryPointers(context: RuleRun) !void {
    const level = context.level(.invalidated_element_pointer);
    if (level == .off) return;
    var lookups: std.ArrayList(u32) = .empty;
    defer lookups.deinit(context.allocator);
    for (0..context.tokens.len) |index| {
        if (mapLookup(context, index)) try lookups.append(context.allocator, @intCast(index));
    }
    if (lookups.items.len == 0) return;
    var aliases: PathAliases = .{};
    defer aliases.deinit(context.allocator);
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 6 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            (context.tokens[declaration_index + 2].tag != .equal and context.tokens[declaration_index + 2].tag != .colon)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const initializer = container_types.initializerStart(context.tokens, declaration_index, declaration_end) orelse continue;
        const lookup_index = mapLookupInRange(lookups.items, initializer, declaration_end) orelse continue;
        const path_end = lookup_index - 2;
        const path_start = receiverPathStart(context, path_end, initializer);
        // The lookup must be the initializer itself, not a call buried in a block or switch.
        if (path_start != initializer and !(path_start == initializer + 1 and context.tokens[initializer].tag == .keyword_try)) continue;
        if (path_start > path_end) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const pointer_name = context.tokenText(declaration_index + 1);
        const key = firstArgumentText(context, lookup_index + 1);
        const identifiers = try context.scopes.identifiers();
        const mutation = try mapPathMutation(context, identifiers, &aliases, path_start, path_end, pointer_name, key, declaration_end + 1, scope_end) orelse continue;
        const path = context.source[context.tokens[path_start].loc.start..context.tokens[path_end].loc.end];
        try context.emit(.{
            .rule = .invalidated_element_pointer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try context.allocator.print(
                "map entry pointer '{s}' from '{s}' is used after {s}, which may rehash, move or remove it",
                .{ pointer_name, path, mutation.method },
            ),
        });
    }
}

fn findStaleIndexMaps(context: RuleRun) !void {
    const level = context.level(.stale_index_map);
    if (level == .off) return;
    var type_bodies: TypeBodies = .{};
    defer type_bodies.deinit(context.allocator);
    for (context.tokens, 0..) |token, removal_index| {
        if (token.tag != .identifier or (!context.tokenIs(removal_index, "swapRemove") and
            !context.tokenIs(removal_index, "orderedRemove"))) continue;
        const sequence_field = selfFieldBeforeMethod(context, removal_index) orelse continue;
        const function_body = context.scopes.functionBodyContaining(removal_index) orelse continue;
        const type_body = context.enclosingOpeningBrace(function_body) orelse continue;
        const type_end = context.matchingToken(type_body, .l_brace, .r_brace) orelse continue;
        const identifiers = try context.scopes.identifiers();
        const sequence = try type_bodies.sequence(context, identifiers, type_body, type_end, sequence_field);
        if (!sequence.list) continue;
        const function_end = context.matchingToken(function_body, .l_brace, .r_brace) orelse continue;
        if (sequence.index_field) |index_field| {
            if (pathMutated(context, identifiers, index_field, removal_index + 1, function_end)) continue;
            try context.emit(.{
                .rule = .stale_index_map,
                .level = level,
                .span = token.loc,
                .message = try context.allocator.print(
                    "{s} changes indices in '{s}' without updating sibling index map '{s}'",
                    .{ context.tokenText(removal_index), sequence_field, index_field },
                ),
            });
            continue;
        }
        if (!context.tokenIs(removal_index, "orderedRemove")) continue;
        if (sequence.reference_field == null) {
            sequence.reference_field = sequenceIndexElementField(context, identifiers, sequence_field, type_body + 1, type_end);
        }
        const reference_field = sequence.reference_field.? orelse continue;
        const removed_index = singleIdentifierArgument(context, removal_index) orelse continue;
        if (selfReferencesRepaired(
            context,
            reference_field,
            removed_index,
            removal_index + 1,
            function_end,
        )) continue;
        try context.emit(.{
            .rule = .stale_index_map,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "orderedRemove changes indices in '{s}' without removing and reindexing references stored in element field '{s}'",
                .{ sequence_field, reference_field },
            ),
        });
    }
}

/// The first of the file's sorted `lookups` with `start < index` and
/// `index + 1 < end`.
fn mapLookupInRange(lookups: []const u32, start: usize, end: usize) ?usize {
    const later = positionsWithin(lookups, start + 1, end);
    if (later.len == 0 or later[0] + 1 >= end) return null;
    return later[0];
}

/// Whether `.getEntry(`, `.getPtr(` or `.getOrPut(` is called at `index`.
fn mapLookup(context: RuleRun, index: usize) bool {
    const tokens = context.tokens;
    return tokens[index].tag == .identifier and (context.tokenIs(index, "getEntry") or context.tokenIs(index, "getPtr") or
        context.tokenIs(index, "getOrPut")) and
        index > 0 and tokens[index - 1].tag == .period and index + 1 < tokens.len and tokens[index + 1].tag == .l_paren;
}

fn receiverPathStart(context: RuleRun, path_end: usize, lower_bound: usize) usize {
    var start = path_end;
    while (start >= lower_bound + 2 and context.tokens[start - 1].tag == .period and
        context.tokens[start - 2].tag == .identifier) start -= 2;
    return start;
}

fn mapPathMutation(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    aliases: *PathAliases,
    path_start: usize,
    path_end: usize,
    pointer_name: []const u8,
    key: []const u8,
    start: usize,
    end: usize,
) !?Mutation {
    // `samePath` compares spellings, so the path can only start at an
    // identifier spelled like its first token; a call from the pointer's
    // last mention on leaves no use of it to reach.
    const last = reach.lastMention(identifiers, pointer_name, start, end);
    for (identifiers.within(context.tokenText(path_start), start, last)) |position| {
        const index: usize = position;
        if (!samePath(context, path_start, path_end, index, end)) continue;
        const method_index = index + (path_end - path_start) + 2;
        if (method_index + 1 >= end or context.tokens[method_index - 1].tag != .period or
            context.tokens[method_index + 1].tag != .l_paren) continue;
        if (entryMutation(context, identifiers, method_index, pointer_name, key, end)) |mutation| return mutation;
    }
    if (path_start == path_end) {
        const alias = try pointerAliasForPath(context, identifiers, aliases, path_start, start, end) orelse return null;
        for (identifiers.within(alias, start, last)) |position| {
            const index: usize = position;
            if (index + 3 >= end or context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
                context.tokens[index + 3].tag != .l_paren) continue;
            if (entryMutation(context, identifiers, index + 2, pointer_name, key, end)) |mutation| return mutation;
        }
    }
    return null;
}

/// The mutation at `method_index` when it can invalidate the entry pointer and
/// a later use observes it. `remove` and `fetchRemove` of another key keep the
/// entry in place.
fn entryMutation(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    method_index: usize,
    pointer_name: []const u8,
    key: []const u8,
    end: usize,
) ?Mutation {
    const method = context.tokenText(method_index);
    if (!isMapMutation(method)) return null;
    if ((std.mem.eql(u8, method, "remove") or std.mem.eql(u8, method, "fetchRemove")) and
        !std.mem.eql(u8, firstArgumentText(context, method_index + 1), key)) return null;
    const call_end = reach.callEnd(context, method_index) orelse return null;
    if (reach.firstReachedUse(context, identifiers, pointer_name, method_index, call_end + 1, end) == null) return null;
    return .{ .index = method_index, .method = method };
}

/// Source text of the first argument of the call opened at `open`.
fn firstArgumentText(context: RuleRun, open: usize) []const u8 {
    const close = context.matchingToken(open, .l_paren, .r_paren) orelse return "";
    var depth: usize = 0;
    var argument_end = close;
    for (context.tokens[open + 1 .. close], open + 1..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            argument_end = index;
            break;
        },
        else => {},
    };
    if (argument_end == open + 1) return "";
    return context.source[context.tokens[open + 1].loc.start..context.tokens[argument_end - 1].loc.end];
}

/// The first `const alias = &path` in `[start, end)` for the one-token path
/// at `path_index`.
fn pointerAliasForPath(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    aliases: *PathAliases,
    path_index: usize,
    start: usize,
    end: usize,
) !?[]const u8 {
    const path = context.tokenText(path_index);
    // Only identifiers are spelled like an identifier.
    if (context.tokens[path_index].tag == .identifier) {
        const later = positionsWithin(try aliases.of(context, identifiers, path), start, end);
        if (later.len == 0 or later[0] + 4 >= end) return null;
        return context.tokenText(later[0] + 1);
    }
    for (start..end) |declaration_index| {
        if (declaration_index + 4 < end and aliasDeclaration(context, declaration_index, path)) {
            return context.tokenText(declaration_index + 1);
        }
    }
    return null;
}

/// The `const alias = &name` declarations of each name asked about, in order.
const PathAliases = struct {
    names: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,

    fn deinit(aliases: *PathAliases, allocator: std.mem.Allocator) void {
        var lists = aliases.names.valueIterator();
        while (lists.next()) |list| list.deinit(allocator);
        aliases.names.deinit(allocator);
    }

    fn of(aliases: *PathAliases, context: RuleRun, identifiers: *const IdentifierTable, name: []const u8) ![]const u32 {
        const entry = try aliases.names.getOrPut(context.allocator, name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
            for (identifiers.all(name)) |position| {
                if (position >= 4 and aliasDeclaration(context, position - 4, name)) {
                    try entry.value_ptr.append(context.allocator, position - 4);
                }
            }
        }
        return entry.value_ptr.items;
    }
};

fn aliasDeclaration(context: RuleRun, declaration_index: usize, path: []const u8) bool {
    const tokens = context.tokens;
    return (tokens[declaration_index].tag == .keyword_const or tokens[declaration_index].tag == .keyword_var) and
        tokens[declaration_index + 1].tag == .identifier and tokens[declaration_index + 2].tag == .equal and
        tokens[declaration_index + 3].tag == .ampersand and context.tokenIs(declaration_index + 4, path);
}

fn samePath(context: RuleRun, expected_start: usize, expected_end: usize, candidate_start: usize, end: usize) bool {
    const token_count = expected_end - expected_start + 1;
    if (candidate_start + token_count > end) return false;
    if (candidate_start > 0 and context.tokens[candidate_start - 1].tag == .period) return false;
    for (0..token_count) |offset| {
        const expected = context.source[context.tokens[expected_start + offset].loc.start..context.tokens[expected_start + offset].loc.end];
        if (!std.mem.eql(u8, expected, context.tokenText(candidate_start + offset))) return false;
    }
    return true;
}

fn selfFieldBeforeMethod(context: RuleRun, method_index: usize) ?[]const u8 {
    if (method_index < 4 or context.tokens[method_index - 1].tag != .period or
        context.tokens[method_index - 2].tag != .identifier or context.tokens[method_index - 3].tag != .period or
        !context.tokenIs(method_index - 4, "self")) return null;
    return context.tokenText(method_index - 2);
}

fn fieldIsList(context: RuleRun, identifiers: *const IdentifierTable, field: []const u8, start: usize, end: usize) bool {
    for (identifiers.within(field, start, end)) |position| {
        const field_index: usize = position;
        if (field_index + 2 >= end or context.tokens[field_index + 1].tag != .colon) continue;
        const field_end = fieldTypeEnd(context.tokens, field_index + 2, end);
        if (container_types.firstKindIn(context.source, context.tokens, field_index + 2, field_end)) |kind| {
            if (kind.hasItems()) return true;
        }
    }
    return false;
}

/// The first of the type's `map_fields` that stores `sequence_field` indices.
fn indexMapField(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    map_fields: []const u32,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) ?[]const u8 {
    for (map_fields) |field_index| {
        const map_field = context.tokenText(field_index);
        if (mapStoresSequenceIndex(context, identifiers, map_field, sequence_field, start, end)) return map_field;
    }
    return null;
}

/// What each type body asked about says about the sequence fields asked
/// about, each fact found once: its `name: ...HashMap...usize...`
/// declarations in order and, per sequence field, whether it is a list, the
/// index map storing its indices and the element field storing them.
const TypeBodies = struct {
    bodies: std.AutoHashMapUnmanaged(u32, Body) = .empty,

    const Body = struct {
        map_fields: std.ArrayList(u32) = .empty,
        sequences: std.StringHashMapUnmanaged(Sequence) = .empty,
    };

    const Sequence = struct {
        list: bool,
        index_field: ?[]const u8,
        /// Null until an `orderedRemove` asks for it.
        reference_field: ??[]const u8 = null,
    };

    fn deinit(type_bodies: *TypeBodies, allocator: std.mem.Allocator) void {
        var bodies = type_bodies.bodies.valueIterator();
        while (bodies.next()) |body| {
            body.map_fields.deinit(allocator);
            body.sequences.deinit(allocator);
        }
        type_bodies.bodies.deinit(allocator);
    }

    /// The facts of `field` in the type body `{` at `type_body`, valid until
    /// the next call.
    fn sequence(
        type_bodies: *TypeBodies,
        context: RuleRun,
        identifiers: *const IdentifierTable,
        type_body: usize,
        type_end: usize,
        field: []const u8,
    ) !*Sequence {
        const allocator = context.allocator;
        const body_entry = try type_bodies.bodies.getOrPut(allocator, @intCast(type_body));
        const body = body_entry.value_ptr;
        if (!body_entry.found_existing) {
            body.* = .{};
            for (context.tokens[type_body + 1 .. type_end], type_body + 1..) |token, field_index| {
                if (token.tag != .identifier or field_index + 2 >= type_end or context.tokens[field_index + 1].tag != .colon) continue;
                const field_end = fieldTypeEnd(context.tokens, field_index + 2, type_end);
                var saw_map = false;
                var saw_usize = false;
                for (context.tokens[field_index + 2 .. field_end], field_index + 2..) |type_token, index| {
                    if (type_token.tag != .identifier) continue;
                    const name = context.tokenText(index);
                    if (std.mem.find(u8, name, "HashMap") != null) saw_map = true;
                    if (std.mem.eql(u8, name, "usize")) saw_usize = true;
                }
                if (saw_map and saw_usize) try body.map_fields.append(allocator, @intCast(field_index));
            }
        }
        const entry = try body.sequences.getOrPut(allocator, field);
        if (!entry.found_existing) {
            const list = fieldIsList(context, identifiers, field, type_body + 1, type_end);
            entry.value_ptr.* = .{
                .list = list,
                .index_field = if (list) indexMapField(context, identifiers, body.map_fields.items, field, type_body + 1, type_end) else null,
            };
        }
        return entry.value_ptr;
    }
};

fn mapStoresSequenceIndex(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    map_field: []const u8,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) bool {
    // `self.map_field.put(`, found from the field name.
    for (identifiers.within(map_field, start + 2, end)) |position| {
        const index: usize = position - 2;
        if (index + 5 >= end or !context.tokenIs(index, "self") or context.tokens[index + 1].tag != .period or
            context.tokens[index + 3].tag != .period or
            (!context.tokenIs(index + 4, "put") and !context.tokenIs(index + 4, "putNoClobber")) or
            context.tokens[index + 5].tag != .l_paren) continue;
        const call_end = context.matchingToken(index + 5, .l_paren, .r_paren) orelse continue;
        var argument_index = index + 6;
        while (argument_index + 4 < call_end) : (argument_index += 1) {
            const has_self = context.tokenIs(argument_index, "self") and context.tokens[argument_index + 1].tag == .period;
            const field_index = argument_index + @as(usize, if (has_self) 2 else 0);
            if (field_index + 2 < call_end and context.tokenIs(field_index, sequence_field) and
                context.tokens[field_index + 1].tag == .period and context.tokenIs(field_index + 2, "items")) return true;
        }
    }
    return false;
}

fn fieldTypeEnd(tokens: []const std.zig.Token, start: usize, end: usize) usize {
    var nesting: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        switch (tokens[index].tag) {
            .l_paren, .l_bracket => nesting += 1,
            .r_paren, .r_bracket => nesting -|= 1,
            .comma => if (nesting == 0) return index,
            .equal, .semicolon, .l_brace => if (nesting == 0) return index,
            else => {},
        }
    }
    return end;
}

fn pathMutated(context: RuleRun, identifiers: *const IdentifierTable, field: []const u8, start: usize, end: usize) bool {
    const methods = [_][]const u8{ "put", "putNoClobber", "fetchPut", "getOrPut", "clearRetainingCapacity", "clearAndFree" };
    for (identifiers.within(field, start + 2, end)) |position| {
        const index: usize = position - 2;
        if (index + 5 >= end or !context.tokenIs(index, "self") or context.tokens[index + 1].tag != .period or
            context.tokens[index + 3].tag != .period or
            context.tokens[index + 4].tag != .identifier or context.tokens[index + 5].tag != .l_paren) continue;
        for (methods) |method| if (context.tokenIs(index + 4, method)) return true;
    }
    return false;
}

fn sequenceIndexElementField(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) ?[]const u8 {
    for (identifiers.within(sequence_field, start + 2, end)) |position| {
        const self_index: usize = position - 2;
        if (self_index + 5 >= end or !context.tokenIs(self_index, "self") or context.tokens[self_index + 1].tag != .period or
            context.tokens[self_index + 3].tag != .period or
            !context.tokenIs(self_index + 4, "items") or context.tokens[self_index + 5].tag != .l_bracket) continue;
        const bracket_end = context.matchingToken(self_index + 5, .l_bracket, .r_bracket) orelse continue;
        if (bracket_end + 5 >= end or context.tokens[bracket_end + 1].tag != .period or
            context.tokens[bracket_end + 2].tag != .identifier or context.tokens[bracket_end + 3].tag != .period or
            !context.tokenIs(bracket_end + 4, "append") or context.tokens[bracket_end + 5].tag != .l_paren) continue;
        const call_end = context.matchingToken(bracket_end + 5, .l_paren, .r_paren) orelse continue;
        const value_index = lastSingleIdentifierArgument(context, bracket_end + 6, call_end) orelse continue;
        if (!valueHasSequenceBound(
            context,
            context.tokenText(value_index),
            sequence_field,
            bracket_end + 4,
        )) continue;
        return context.tokenText(bracket_end + 2);
    }
    return null;
}

fn lastSingleIdentifierArgument(context: RuleRun, start: usize, end: usize) ?usize {
    var argument_start = start;
    var depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            argument_start = index + 1;
        },
        else => {},
    };
    return if (argument_start + 1 == end and context.tokens[argument_start].tag == .identifier)
        argument_start
    else
        null;
}

fn valueHasSequenceBound(
    context: RuleRun,
    value_name: []const u8,
    sequence_field: []const u8,
    before: usize,
) bool {
    const function_body = context.scopes.functionBodyContaining(before) orelse return false;
    for (context.tokens[function_body + 1 .. before], function_body + 1..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 1 >= before or context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end >= before or !context.rangeContainsName(value_name, if_index + 2, condition_end) or
            !rangeContainsSequenceLength(context, sequence_field, if_index + 2, condition_end) or
            !rangeContainsComparison(context, if_index + 2, condition_end)) continue;
        const guard_end = @min(context.statementEnd(if_index) orelse before, before);
        if (rangeTerminates(context, condition_end + 1, guard_end)) return true;
    }
    return false;
}

fn rangeContainsSequenceLength(context: RuleRun, sequence_field: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 6 < end) : (index += 1) {
        if (context.tokenIs(index, "self") and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, sequence_field) and context.tokens[index + 3].tag == .period and
            context.tokenIs(index + 4, "items") and context.tokens[index + 5].tag == .period and
            context.tokenIs(index + 6, "len")) return true;
    }
    return false;
}

fn rangeContainsComparison(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| switch (token.tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        => return true,
        else => {},
    };
    return false;
}

fn rangeTerminates(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| switch (token.tag) {
        .keyword_return, .keyword_break, .keyword_continue, .keyword_unreachable => return true,
        else => {},
    };
    return false;
}

fn singleIdentifierArgument(context: RuleRun, method_index: usize) ?[]const u8 {
    if (method_index + 3 >= context.tokens.len or context.tokens[method_index + 1].tag != .l_paren or
        context.tokens[method_index + 2].tag != .identifier or context.tokens[method_index + 3].tag != .r_paren) return null;
    return context.tokenText(method_index + 2);
}

fn selfReferencesRepaired(
    context: RuleRun,
    reference_field: []const u8,
    removed_index: []const u8,
    start: usize,
    end: usize,
) bool {
    if (callsOpaqueSelfRepair(context, removed_index, start, end)) return true;
    if (referenceFieldCleared(context, reference_field, start, end)) return true;
    return comparesReferenceWithRemovedIndex(context, reference_field, removed_index, .equal_equal, start, end) and
        referenceFieldRemoval(context, reference_field, start, end) and
        comparesReferenceWithRemovedIndex(context, reference_field, removed_index, .angle_bracket_right, start, end) and
        decrementsReference(context, start, end);
}

fn callsOpaqueSelfRepair(context: RuleRun, removed_index: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (!context.tokenIs(index, "self") or context.tokens[index + 1].tag != .period or
            context.tokens[index + 2].tag != .identifier or context.tokens[index + 3].tag != .l_paren) continue;
        const call_end = context.matchingToken(index + 3, .l_paren, .r_paren) orelse continue;
        if (call_end < end and context.rangeContainsName(removed_index, index + 4, call_end)) return true;
    }
    return false;
}

fn referenceFieldCleared(context: RuleRun, reference_field: []const u8, start: usize, end: usize) bool {
    const methods = [_][]const u8{ "clearRetainingCapacity", "clearAndFree" };
    for (context.tokens[start..end], start..) |token, field_index| {
        if (token.tag != .identifier or !context.tokenIs(field_index, reference_field) or
            field_index + 3 >= end or context.tokens[field_index + 1].tag != .period or
            context.tokens[field_index + 2].tag != .identifier or context.tokens[field_index + 3].tag != .l_paren) continue;
        for (methods) |method| if (context.tokenIs(field_index + 2, method)) return true;
    }
    return false;
}

fn comparesReferenceWithRemovedIndex(
    context: RuleRun,
    reference_field: []const u8,
    removed_index: []const u8,
    comparison: std.zig.Token.Tag,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, comparison_index| {
        if (token.tag != comparison or comparison_index == start or comparison_index + 1 >= end) continue;
        if (storedIndexOperand(context, reference_field, comparison_index - 1, start) and
            context.tokenIs(comparison_index + 1, removed_index)) return true;
        if (context.tokenIs(comparison_index - 1, removed_index) and
            storedIndexOperand(context, reference_field, comparison_index + 1, start)) return true;
    }
    return false;
}

fn storedIndexOperand(context: RuleRun, reference_field: []const u8, operand_index: usize, start: usize) bool {
    const tag = context.tokens[operand_index].tag;
    if (tag == .identifier or tag == .asterisk or tag == .period_asterisk) return true;
    if (tag != .r_bracket) return false;
    const receiver_start = @max(start, operand_index -| 16);
    for (context.tokens[receiver_start..operand_index], receiver_start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, reference_field)) return true;
    }
    return false;
}

fn referenceFieldRemoval(context: RuleRun, reference_field: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or (!context.tokenIs(method_index, "orderedRemove") and
            !context.tokenIs(method_index, "swapRemove")) or method_index < start + 2 or
            context.tokens[method_index - 1].tag != .period or
            !context.tokenIs(method_index - 2, reference_field)) continue;
        return true;
    }
    return false;
}

fn decrementsReference(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .minus_equal and index + 1 < end and
            context.tokens[index + 1].tag == .number_literal and context.tokenIs(index + 1, "1")) return true;
    }
    return false;
}

/// The positions in `[start, end)` of a sorted list.
fn positionsWithin(positions: []const u32, start: usize, end: usize) []const u32 {
    const first = std.sort.partitionPoint(u32, positions, start, positionBefore);
    const last = first + std.sort.partitionPoint(u32, positions[first..], end, positionBefore);
    return positions[first..last];
}

fn positionBefore(bound: usize, position: u32) bool {
    return position < bound;
}

test "element pointers and active map iterators are invalidated by mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn list(allocator: anytype) !void { var values = std.ArrayList(u8).empty; const first = &values.items[0]; try values.append(allocator, 1); use(first); }\n" ++
        "fn map() !void { var values = std.AutoHashMap(u8, u8).init(a); var iterator = values.iterator(); while (iterator.next()) |_| { try values.put(1, 2); } }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "refreshing the element pointer after mutation is not a stale use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn list(allocator: anytype) !void { var values = std.ArrayList(u8).empty; var first = &values.items[0]; try values.append(allocator, 1); first = &values.items[0]; use(first); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "removing an entry and immediately leaving the loop is safe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn evict() !void { var values = std.AutoHashMap(u8, u8).init(a); var iterator = values.iterator(); while (iterator.next()) |entry| { if (match(entry)) { _ = values.remove(1); break; } } }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "getOrPut during iteration invalidates the iterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn map() !void { var values = std.AutoHashMap(u8, u8).init(a); var iterator = values.iterator(); while (iterator.next()) |_| { _ = try values.getOrPut(1); } }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "getOrPut") != null);
}

test "returning a field element pointer after removal reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn begin(self: *Queue) ?*Job {\n" ++
        "    const job = &self.jobs.items[0];\n" ++
        "    _ = self.jobs.orderedRemove(0);\n" ++
        "    return job;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "returning an element pointer from a container parameter after growth reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn first(list: *std.ArrayList(u8), allocator: anytype) !*u8 {\n" ++
        "    const element = &list.items[0];\n" ++
        "    try list.appendNTimes(allocator, 1, 2);\n" ++
        "    return element;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.invalidated_element_pointer, findings[0].rule);
}

test "map entry pointers expire when a later insertion can rehash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn update(registry: *Registry) !usize { const entry = registry.by_name.getEntry(\"old\") orelse return 0; try registry.by_name.put(\"new\", 1); return entry.value_ptr.*; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.invalidated_element_pointer, findings[0].rule);
}

test "map entry pointers expire when an alias mutates the map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(map: anytype) !void { const entry = map.getEntry(\"a\") orelse return;" ++
        "const alias = &map; try alias.put(\"b\", 2); consume(entry.value_ptr); }";
    const findings = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(rule_types.Rule.invalidated_element_pointer, findings[0].rule);
}

test "parallel index maps must be updated after sequence removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "const Registry = struct { rows: std.ArrayList(Row), by_name: std.StringHashMapUnmanaged(usize), " ++
        "fn add(self: *Registry, name: []const u8) !void { try self.by_name.put(name, self.rows.items.len); try self.rows.append(.{}); } " ++
        "fn remove(self: *Registry, index: usize) void { _ = self.rows.swapRemove(index); } };";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.stale_index_map, findings[0].rule);
}

test "removing only the deleted key does not reindex a swap-removed element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Registry = struct { rows: std.ArrayList(Row), positions: std.AutoHashMap(u32, usize)," ++
        "fn add(self: *Registry, key: u32) !void { try self.positions.put(key, self.rows.items.len); try self.rows.append(.{}); }" ++
        "fn remove(self: *Registry, key: u32) void { const index = self.positions.get(key) orelse return;" ++
        "_ = self.rows.swapRemove(index); _ = self.positions.remove(key); } };";
    const findings = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());
    var warning_count: usize = 0;
    for (findings) |finding| {
        if (finding.rule == .stale_index_map) warning_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "nested removal and getOrPut entries retain container invalidation facts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "const Catalog = struct { records: std.ArrayList([]u8), positions: std.StringHashMap(usize), " ++
        "fn remove(self: *Catalog, key: []const u8) void { if (self.positions.get(key)) |index| { _ = self.records.swapRemove(index); } } " ++
        "fn cache(self: *Catalog, key: []const u8) !void { const entry = try self.positions.getOrPut(key); " ++
        "entry.value_ptr.* = self.records.items.len; try self.positions.put(\"other\", self.records.items.len); _ = entry.value_ptr.*; } };";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqual(types.Rule.invalidated_element_pointer, findings[0].rule);
    try std.testing.expectEqual(types.Rule.stale_index_map, findings[1].rule);
}

test "stored sequence indices must remove references to an ordered-removed element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Node = struct { links: std.ArrayList(u32) }; " ++
        "const Graph = struct { nodes: std.ArrayList(Node), " ++
        "fn addEdge(self: *Graph, from: u32, to: u32) !void { " ++
        "if (to >= self.nodes.items.len) return error.UnknownNode; " ++
        "try self.nodes.items[from].links.append(a, to); } " ++
        "fn removeNode(self: *Graph, id: u32) void { _ = self.nodes.orderedRemove(id); " ++
        "for (self.nodes.items) |*node| for (node.links.items) |*link| { " ++
        "if (link.* > id) link.* -= 1; } } };";
    const findings = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(rule_types.Rule.stale_index_map, findings[0].rule);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "links") != null);
}

test "removing equal references and shifting later indices repairs ordered removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Node = struct { links: std.ArrayList(u32) }; " ++
        "const Graph = struct { nodes: std.ArrayList(Node), " ++
        "fn addEdge(self: *Graph, from: u32, to: u32) !void { " ++
        "if (to >= self.nodes.items.len) return error.UnknownNode; " ++
        "try self.nodes.items[from].links.append(a, to); } " ++
        "fn removeNode(self: *Graph, id: u32) void { _ = self.nodes.orderedRemove(id); " ++
        "for (self.nodes.items) |*node| { var link_index: usize = 0; " ++
        "while (link_index < node.links.items.len) { " ++
        "if (node.links.items[link_index] == id) { _ = node.links.orderedRemove(link_index); continue; } " ++
        "if (node.links.items[link_index] > id) node.links.items[link_index] -= 1; link_index += 1; } } } };";
    const findings = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());

    var stale_count: usize = 0;
    for (findings) |finding| {
        if (finding.rule == .stale_index_map) stale_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), stale_count);
}

test "an explicit self repair call keeps self-referential indices opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Node = struct { links: std.ArrayList(u32) }; " ++
        "const Graph = struct { nodes: std.ArrayList(Node), " ++
        "fn addEdge(self: *Graph, from: u32, to: u32) !void { " ++
        "if (to >= self.nodes.items.len) return error.UnknownNode; " ++
        "try self.nodes.items[from].links.append(a, to); } " ++
        "fn removeNode(self: *Graph, id: u32) void { _ = self.nodes.orderedRemove(id); self.repairLinks(id); } };";
    const findings = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "removing from an unrelated list does not repair stored indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Node = struct { links: std.ArrayList(u32) }; " ++
        "const Graph = struct { nodes: std.ArrayList(Node), " ++
        "fn addEdge(self: *Graph, from: u32, to: u32) !void { " ++
        "if (to >= self.nodes.items.len) return error.UnknownNode; " ++
        "try self.nodes.items[from].links.append(a, to); } " ++
        "fn removeNode(self: *Graph, id: u32, scratch: *std.ArrayList(u32)) void { " ++
        "_ = self.nodes.orderedRemove(id); for (self.nodes.items) |*node| { " ++
        "if (node.links.items[0] == id) log(id); _ = scratch.orderedRemove(0); " ++
        "if (node.links.items[0] > id) node.links.items[0] -= 1; } } };";
    const findings = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());

    var stale_count: usize = 0;
    for (findings) |finding| {
        if (finding.rule == .stale_index_map) stale_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), stale_count);
}

test "index map writes before removal do not repair changed indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Store = struct { rows: std.ArrayList(Row), by_key: std.AutoHashMap(Key, usize), " ++
        "fn replace(self: *Store, allocator: anytype, key: Key, index: usize) !void { " ++
        "try self.by_key.put(allocator, key, self.rows.items.len); _ = self.rows.swapRemove(index); } };";
    const findings = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(rule_types.Rule.stale_index_map, findings[0].rule);
}

fn expectInvalidations(source: [:0]const u8, expected: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());
    try std.testing.expectEqual(expected, found.len);
}

test "element pointers into containers declared by type annotation are tracked" {
    try expectInvalidations("fn f(g: A) !void { var l: std.ArrayList(u8) = .empty; const p = &l.items[0]; try l.append(g, 1); p.* = 2; }", 1);
    try expectInvalidations("fn f(g: A) !void { var l: std.ArrayList(u8) = try .initCapacity(g, 4); const p = &l.items[0]; try l.append(g, 1); p.* = 2; }", 1);
    try expectInvalidations("fn f(g: A) !void { var l = std.ArrayList(u8).empty; const p = &l.items[0]; try l.append(g, 1); p.* = 2; }", 1);
}

test "the first of two addOne pointers is stale after the second" {
    try expectInvalidations("fn f(g: A) !void { var l: std.ArrayList(u8) = .empty; const a = try l.addOne(g); const b = try l.addOne(g); b.* = 1; a.* = 2; }", 1);
    try expectInvalidations("fn f(g: A) !void { var l: std.ArrayList(u8) = .empty; const a = try l.addOne(g); a.* = 2; const b = try l.addOne(g); b.* = 1; }", 0);
    // MultiArrayList.addOne returns an index, not a pointer.
    try expectInvalidations("fn f(g: A) !void { var l: std.MultiArrayList(S) = .empty; const a = try l.addOne(g); const b = try l.addOne(g); use(a, b); }", 0);
}

test "comparing only the pointer is not a use of the stale element" {
    try expectInvalidations("fn f(g: A) !bool { var l: std.ArrayList(u8) = .empty; const p = &l.items[0]; try l.append(g, 1); return p == &l.items[0]; }", 0);
}

test "a mutation that returns from its own branch does not taint the sibling branch" {
    try expectInvalidations("fn f(g: A, c: bool) !void { var l: std.ArrayList(u8) = .empty; const p = &l.items[0]; if (c) { try l.append(g, 1); return; } else { p.* = 1; } }", 0);
    try expectInvalidations("fn f(g: A, c: bool) !void { var l: std.ArrayList(u8) = .empty; const p = &l.items[0]; if (c) { try l.append(g, 1); } else { p.* = 1; } }", 0);
    try expectInvalidations("fn f(g: A, c: bool) !void { var l: std.ArrayList(u8) = .empty; const p = &l.items[0]; if (c) { try l.append(g, 1); } p.* = 1; }", 1);
}

test "removal after a literal element index leaves the earlier element valid" {
    try expectInvalidations("fn f() void { var l: std.ArrayList(u8) = .empty; const p = &l.items[0]; _ = l.orderedRemove(3); p.* = 1; }", 0);
    try expectInvalidations("fn f() void { var l: std.ArrayList(u8) = .empty; const p = &l.items[3]; _ = l.orderedRemove(0); p.* = 1; }", 1);
}

test "assume-capacity appends after reserving stay quiet" {
    try expectInvalidations("fn f(g: A) !void { var l: std.ArrayList(u8) = .empty; try l.ensureUnusedCapacity(g, 2); const p = &l.items[0]; l.appendAssumeCapacity(2); p.* = 3; }", 0);
}

test "map entry pointers go stale after removal and rehash" {
    try expectInvalidations("fn f() void { var m: std.AutoHashMapUnmanaged(u32, u32) = .empty; const e = m.getPtr(1).?; _ = m.remove(1); e.* = 3; }", 1);
    try expectInvalidations("fn f() void { var m: std.AutoHashMapUnmanaged(u32, u32) = .empty; const e = m.getPtr(1).?; _ = m.remove(2); e.* = 3; }", 0);
    try expectInvalidations("fn f() void { var m: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty; const e = m.getPtr(1).?; _ = m.swapRemove(2); e.* = 3; }", 1);
}

test "loops over a container view must not grow or shrink that container" {
    try expectInvalidations("fn f(g: A) !void { var l: std.ArrayList(u8) = .empty; for (l.items) |x| try l.append(g, x); }", 1);
    try expectInvalidations("fn f() void { var l: std.ArrayList(u8) = .empty; for (l.items, 0..) |x, i| { if (x == 0) _ = l.orderedRemove(i); } }", 1);
    try expectInvalidations("fn f() void { var m: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty; for (m.keys()) |k| _ = m.swapRemove(k); }", 1);
    try expectInvalidations("fn f() void { var m: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty; for (m.values()) |v| { _ = m.orderedRemove(v); } }", 1);
    try expectInvalidations("fn f() void { var l: std.ArrayList(u8) = .empty; for (l.items, 0..) |x, i| { if (x == 0) { _ = l.orderedRemove(i); break; } } }", 0);
    try expectInvalidations("fn f(g: A, o: *std.ArrayList(u8)) !void { var l: std.ArrayList(u8) = .empty; for (l.items) |x| try o.append(g, x); }", 0);
}

test "a removal followed by other statements and a break leaves the loop" {
    try expectInvalidations("fn f(a: A) void { var l: std.ArrayList(u8) = .empty; for (l.items, 0..) |x, i| { if (x == 0) { var r = l.swapRemove(i); r.deinit(a); log(r); break; } } }", 0);
}

test "deferred mutations and lookups buried in larger expressions do not report" {
    try expectInvalidations("fn f(m: *std.AutoHashMapUnmanaged(u32, u32), a: A) !void { const gop = try m.getOrPut(a, 1); errdefer m.swapRemoveAt(gop.index); gop.value_ptr.* = 1; }", 0);
    try expectInvalidations("fn f(m: *std.AutoHashMapUnmanaged(u32, u32), a: A, c: bool) !u32 { const r = if (c) try m.getOrPut(a, 1) else null; try m.put(a, 2, 2); return r.?.value_ptr.*; }", 0);
}

test "const pointer parameter types are not declarations" {
    try expectInvalidations("fn f(self: *const Page, y: usize) *Row { assert(y < 3); return &self.rows.ptr(self.m)[y]; }", 0);
}

test "each removal in a type with an index map reports" {
    try expectInvalidations("const R = struct { rows: std.ArrayList(Row), by_name: std.StringHashMapUnmanaged(usize), " ++
        "fn add(self: *R, name: []const u8) !void { try self.by_name.put(name, self.rows.items.len); } " ++
        "fn a(self: *R, i: usize) void { _ = self.rows.swapRemove(i); } fn b(self: *R, i: usize) void { _ = self.rows.orderedRemove(i); } };", 2);
}

test "every loop driven by the iterator is checked" {
    try expectInvalidations("fn f() !void { var m = std.AutoHashMap(u8, u8).init(a); var it = m.iterator(); " ++
        "while (it.next()) |_| { try m.put(1, 2); } while (it.next()) |_| { _ = m.remove(1); } }", 2);
}

test "addOne pointers are tracked into list parameters only" {
    try expectInvalidations("fn f(l: *std.ArrayList(u8), g: A) !void { const p = try l.addOne(g); try l.append(g, 1); p.* = 1; }", 1);
    try expectInvalidations("fn f(l: *Other, g: A) !void { const p = try l.addOne(g); try l.append(g, 1); p.* = 1; }", 0);
}
