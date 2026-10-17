const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const rule_types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const TokenRange = tokens_util.Range;
const IdentifierTable = @import("../../syntax/scope.zig").IdentifierTable;
const container_types = @import("../container_types.zig");
const reach = @import("reach.zig");

const View = struct {
    name_index: usize,
    declaration_end: usize,
    kind: enum { items, pointer, iterator },

    fn noun(view: View) []const u8 {
        return switch (view.kind) {
            .items => "slice",
            .pointer => "pointer",
            .iterator => "iterator",
        };
    }
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
    const identifiers = try context.scopes.identifiers();
    // `const view = container.items;` names the container in its fourth token;
    // the rest of a reported view's declaration is skipped.
    var resume_at = start;
    for (identifiers.within(container_name, start + 3, scope_end)) |position| {
        const index: usize = position - 3;
        if (index < resume_at) continue;
        const view = viewDeclaration(context, container_name, index, scope_end) orelse continue;
        const view_name = context.tokenText(view.name_index);
        const invalidation = firstInvalidation(
            context,
            identifiers,
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
                .{ view.noun(), view_name, container_name, invalidation.method },
            ),
        });
        resume_at = view.declaration_end + 1;
    }
}

fn findArenaResetViews(context: RuleRun, level: rule_types.Level) !void {
    var aliases: AllocatorAliases = .{};
    defer aliases.deinit(context.allocator);
    // The file's allocating calls in order, so that a declaration's first one is a lookup.
    var allocations: std.ArrayList(u32) = .empty;
    defer allocations.deinit(context.allocator);
    for (0..context.tokens.len) |method_index| {
        if (allocationCall(context, method_index)) try allocations.append(context.allocator, @intCast(method_index));
    }
    if (allocations.items.len == 0) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        // `allocationReceiver(context, declaration_index + 2, declaration_end)`.
        const first = positionsWithin(allocations.items, declaration_index + 2, declaration_end);
        if (first.len == 0 or first[0] + 1 >= declaration_end) continue;
        const allocator = context.tokenText(first[0] - 2);
        const arena = try arenaForAllocatorAlias(context, &aliases, allocator, declaration_index) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const identifiers = try context.scopes.identifiers();
        const reset_index = arenaResetAfter(context, identifiers, arena, declaration_end + 1, scope_end, scope_opening) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        if (!bindingUsedAfterReset(context, identifiers, binding, reset_index + 1, scope_end)) continue;
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

fn bindingUsedAfterReset(context: RuleRun, identifiers: *const IdentifierTable, binding: []const u8, start: usize, end: usize) bool {
    const index = identifiers.firstWithin(binding, start, end) orelse return false;
    if (index > start and (context.tokens[index - 1].tag == .keyword_const or
        context.tokens[index - 1].tag == .keyword_var)) return false;
    if (index + 1 < end and context.tokens[index + 1].tag == .equal) return false;
    return true;
}

pub fn allocationReceiver(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (start..end) |method_index| {
        if (method_index + 1 < end and allocationCall(context, method_index)) return context.tokenText(method_index - 2);
    }
    return null;
}

/// Whether `receiver.alloc(`, `.dupe(`, `.print(` or a sibling allocating
/// method is called at `method_index`.
fn allocationCall(context: RuleRun, method_index: usize) bool {
    const methods = [_][]const u8{ "alloc", "allocSentinel", "alignedAlloc", "dupe", "dupeZ", "dupeSentinel", "print", "printSentinel" };
    const tokens = context.tokens;
    if (tokens[method_index].tag != .identifier or method_index < 2 or tokens[method_index - 1].tag != .period or
        tokens[method_index - 2].tag != .identifier or method_index + 1 >= tokens.len or
        tokens[method_index + 1].tag != .l_paren) return false;
    return container_types.isOneOf(context.tokenText(method_index), &methods);
}

/// The `const name = arena.allocator(` declarations of a file by name (the
/// name), found in one pass the first time `arenaForAllocatorAlias` asks.
pub const AllocatorAliases = struct {
    declarations: ?std.StringHashMapUnmanaged(std.ArrayList(u32)) = null,

    pub fn deinit(aliases: *AllocatorAliases, allocator: std.mem.Allocator) void {
        var declarations = aliases.declarations orelse return;
        var lists = declarations.valueIterator();
        while (lists.next()) |list| list.deinit(allocator);
        declarations.deinit(allocator);
    }

    fn named(aliases: *AllocatorAliases, context: RuleRun, name: []const u8) ![]const u32 {
        if (aliases.declarations == null) {
            var declarations: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
            errdefer {
                var lists = declarations.valueIterator();
                while (lists.next()) |list| list.deinit(context.allocator);
                declarations.deinit(context.allocator);
            }
            const tokens = context.tokens;
            for (1..tokens.len -| 5) |index| {
                if ((tokens[index - 1].tag != .keyword_const and tokens[index - 1].tag != .keyword_var) or
                    tokens[index + 1].tag != .equal or tokens[index + 2].tag != .identifier or tokens[index + 3].tag != .period or
                    !context.tokenIs(index + 4, "allocator") or tokens[index + 5].tag != .l_paren) continue;
                const entry = try declarations.getOrPut(context.allocator, context.tokenText(index));
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(context.allocator, @intCast(index));
            }
            aliases.declarations = declarations;
        }
        return if (aliases.declarations.?.get(name)) |list| list.items else &.{};
    }
};

/// The arena whose allocator the alias `allocator` declared nearest before
/// `before` comes from, when the arena is a local `ArenaAllocator`.
pub fn arenaForAllocatorAlias(context: RuleRun, aliases: *AllocatorAliases, allocator: []const u8, before: usize) !?[]const u8 {
    const declarations = try aliases.named(context, allocator);
    // The aliases with `index + 5 < before`, nearest first, from the
    // outermost block open at `before` on.
    const outermost = outermostOpenBrace(context, before) orelse return null;
    const first = std.sort.partitionPoint(u32, declarations, outermost, positionBefore);
    var position = std.sort.partitionPoint(u32, declarations, before -| 5, positionBefore);
    if (position <= first) return null;
    const identifiers = try context.scopes.identifiers();
    while (position > first) {
        position -= 1;
        const index: usize = declarations[position];
        const alias_scope_end = context.enclosingScopeEnd(index) orelse continue;
        if (alias_scope_end < before) continue;
        const arena = context.tokenText(index + 2);
        if (localArenaDeclaration(context, identifiers, arena, index)) return arena;
    }
    return null;
}

fn localArenaDeclaration(context: RuleRun, identifiers: *const IdentifierTable, arena: []const u8, before: usize) bool {
    const outermost = outermostOpenBrace(context, before) orelse return false;
    const positions = identifiers.within(arena, @max(1, outermost), before);
    var position = positions.len;
    while (position > 0) {
        position -= 1;
        const index: usize = positions[position];
        if (context.tokens[index - 1].tag != .keyword_const and context.tokens[index - 1].tag != .keyword_var) continue;
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

/// The outermost `{` still open at `index`. A name declared before it is
/// outside every block open at `index`: its block closed before `index` or
/// it has none, so `enclosingScopeEnd` rules it out.
fn outermostOpenBrace(context: RuleRun, index: usize) ?usize {
    var outermost: ?usize = null;
    var brace = context.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) outermost = opening;
    return outermost;
}

fn arenaResetAfter(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    arena: []const u8,
    start: usize,
    end: usize,
    scope_opening: usize,
) ?usize {
    for (identifiers.within(arena, start, end)) |position| {
        const index: usize = position;
        if (index + 3 >= end or context.enclosingOpeningBrace(index) != scope_opening or
            context.tokens[index + 1].tag != .period or !context.tokenIs(index + 2, "reset") or
            context.tokens[index + 3].tag != .l_paren) continue;
        return index + 2;
    }
    return null;
}

fn findFieldContainerViews(context: RuleRun, level: rule_types.Level) !void {
    var fields: StructFields = .{};
    defer fields.deinit(context.allocator);
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 8 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal or
            context.tokens[declaration_index + 3].tag != .identifier or context.tokens[declaration_index + 4].tag != .period or
            context.tokens[declaration_index + 5].tag != .identifier or context.tokens[declaration_index + 6].tag != .period or
            !context.tokenIs(declaration_index + 7, "items") or context.tokens[declaration_index + 8].tag != .semicolon) continue;
        const field_name = context.tokenText(declaration_index + 5);
        const kind = try enclosingContainerFieldKind(context, &fields, declaration_index, field_name) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const base_name = context.tokenText(declaration_index + 3);
        const view_name = context.tokenText(declaration_index + 1);
        const invalidation = firstFieldInvalidation(
            context,
            try context.scopes.identifiers(),
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

/// The container kind of the field `field_name` of the innermost `struct`
/// around `target`, when it invalidates views.
fn enclosingContainerFieldKind(
    context: RuleRun,
    fields: *StructFields,
    target: usize,
    field_name: []const u8,
) !?container_types.Kind {
    // The open braces around `target`, innermost first; the first matched
    // `struct {` among them is the latest one that closes after `target`.
    var brace = context.enclosingOpeningBrace(target);
    const opening = while (brace) |candidate| : (brace = context.enclosingOpeningBrace(candidate)) {
        if (candidate > 0 and context.tokens[candidate - 1].tag == .keyword_struct and
            context.scopes.matchingToken(candidate) != null) break candidate;
    } else return null;
    const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse return null;
    const index = try fields.first(context, opening, closing, field_name) orelse return null;
    const field_end = tokens_util.fieldTypeEnd(context.tokens, index + 2, closing);
    const kind = container_types.firstKindIn(context.source, context.tokens, index + 2, field_end) orelse return null;
    return if (kind.invalidatesViews()) kind else null;
}

/// The `name:` declarations directly in each `struct` body asked about, the
/// first of each name, found in one pass over the body when it is first asked.
const StructFields = struct {
    bodies: std.AutoHashMapUnmanaged(u32, std.StringHashMapUnmanaged(u32)) = .empty,

    fn deinit(fields: *StructFields, allocator: std.mem.Allocator) void {
        var names = fields.bodies.valueIterator();
        while (names.next()) |map| map.deinit(allocator);
        fields.bodies.deinit(allocator);
    }

    /// The first `name:` outside nested braces of the body `{` at `opening`.
    /// Only identifiers are spelled like the field names asked for.
    fn first(fields: *StructFields, context: RuleRun, opening: usize, closing: usize, name: []const u8) !?usize {
        const entry = try fields.bodies.getOrPut(context.allocator, @intCast(opening));
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
            var depth: usize = 0;
            var index = opening + 1;
            while (index + 2 < closing) : (index += 1) switch (context.tokens[index].tag) {
                .l_brace => depth += 1,
                .r_brace => depth -|= 1,
                .identifier => if (depth == 0 and context.tokens[index + 1].tag == .colon) {
                    const field = try entry.value_ptr.getOrPut(context.allocator, context.tokenText(index));
                    if (!field.found_existing) field.value_ptr.* = @intCast(index);
                },
                else => {},
            };
        }
        const index = entry.value_ptr.get(name) orelse return null;
        return index;
    }
};

fn firstFieldInvalidation(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    base_name: []const u8,
    field_name: []const u8,
    kind: container_types.Kind,
    view_name: []const u8,
    start: usize,
    end: usize,
) ?Invalidation {
    // A call from the view's last mention on leaves no use of it to reach.
    const last = reach.lastMention(identifiers, view_name, start, end);
    for (identifiers.within(base_name, start, last)) |position| {
        const index: usize = position;
        if (index + 5 >= end or (index > 0 and context.tokens[index - 1].tag == .period) or
            context.tokens[index + 1].tag != .period or !context.tokenIs(index + 2, field_name) or
            context.tokens[index + 3].tag != .period or context.tokens[index + 4].tag != .identifier or
            context.tokens[index + 5].tag != .l_paren) continue;
        const method = context.tokenText(index + 4);
        if (!invalidatesView(kind, method)) continue;
        const call_end = reach.callEnd(context, index + 4) orelse continue;
        if (reach.firstReachedUse(context, identifiers, view_name, index + 4, call_end + 1, end) == null) continue;
        return .{ .index = index, .method = method };
    }
    return null;
}

fn findReallocatedViews(context: RuleRun, level: rule_types.Level) !void {
    var reallocations: Reallocations = .{};
    defer reallocations.deinit(context.allocator);
    try reallocations.collect(context);
    if (reallocations.calls.items.len == 0) return;
    const identifiers = try context.scopes.identifiers();
    var calls: std.ArrayList(u32) = .empty;
    defer calls.deinit(context.allocator);
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 3 >= context.tokens.len or context.tokens[declaration_index + 1].tag != .identifier or
            context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const view_name = context.tokenText(declaration_index + 1);
        // The other calls after the declaration cannot find their allocation in it.
        try reallocations.spelledIn(context.allocator, declaration_index + 3, declaration_end, scope_end, &calls);
        for (calls.items) |call_index| {
            const call = reallocations.calls.items[call_index];
            const method_index = call.method_index;
            const call_end = call.call_end;
            const recurrences = if (call.recurrences) |range| reallocations.recurrences.items[range.start..range.end] else null;
            if (!rangeContainsBorrowingPath(context, recurrences, declaration_index + 3, declaration_end, call.allocation)) continue;
            if (reallocationReplacesBorrowedField(context, view_name, method_index, call_end)) continue;
            if (reach.firstReachedUse(context, identifiers, view_name, method_index, call_end + 1, scope_end) == null) continue;
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

/// The file's `allocator.realloc(allocation, ..)` calls in order, with where
/// the tokens of each allocation recur, so that a declaration meets only the
/// later calls whose allocation it spells.
const Reallocations = struct {
    calls: std.ArrayList(Call) = .empty,
    /// The recurrences of each call's allocation, call after call.
    recurrences: std.ArrayList(u32) = .empty,
    /// Every recurrence with its call, by position.
    spellings: std.ArrayList(Spelling) = .empty,
    /// The calls whose allocation names no identifier to find it by.
    unindexed: std.ArrayList(u32) = .empty,

    const Call = struct {
        method_index: usize,
        call_end: usize,
        allocation: TokenRange,
        /// Its part of `recurrences`, null when the call is unindexed.
        recurrences: ?struct { start: usize, end: usize },
    };

    const Spelling = struct { position: u32, call: u32 };

    fn deinit(reallocations: *Reallocations, allocator: std.mem.Allocator) void {
        reallocations.calls.deinit(allocator);
        reallocations.recurrences.deinit(allocator);
        reallocations.spellings.deinit(allocator);
        reallocations.unindexed.deinit(allocator);
    }

    fn collect(reallocations: *Reallocations, context: RuleRun) !void {
        const tokens = context.tokens;
        const allocator = context.allocator;
        var identifiers: ?*const IdentifierTable = null;
        for (tokens, 0..) |token, method_index| {
            if (token.tag != .identifier or !context.tokenIs(method_index, "realloc") or
                method_index + 1 >= tokens.len or tokens[method_index + 1].tag != .l_paren) continue;
            if (method_index < 2 or tokens[method_index - 1].tag != .period or tokens[method_index - 2].tag != .identifier) continue;
            const table = identifiers orelse try context.scopes.identifiers();
            identifiers = table;
            if (!allocatorBinding(context, table, context.tokenText(method_index - 2), method_index)) continue;
            const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
            const allocation = firstArgument(context, method_index + 2, call_end) orelse continue;
            const call: u32 = @intCast(reallocations.calls.items.len);
            const first = reallocations.recurrences.items.len;
            const indexed = try appendRecurrences(context, table, allocation, &reallocations.recurrences);
            try reallocations.calls.append(allocator, .{
                .method_index = method_index,
                .call_end = call_end,
                .allocation = allocation,
                .recurrences = if (indexed) .{ .start = first, .end = reallocations.recurrences.items.len } else null,
            });
            if (!indexed) try reallocations.unindexed.append(allocator, call);
            for (reallocations.recurrences.items[first..]) |position| {
                try reallocations.spellings.append(allocator, .{ .position = position, .call = call });
            }
        }
        std.mem.sort(Spelling, reallocations.spellings.items, {}, struct {
            fn lessThan(_: void, left: Spelling, right: Spelling) bool {
                return left.position < right.position;
            }
        }.lessThan);
    }

    /// The calls in `(declaration_end, scope_end)` whose allocation recurs at
    /// a position in `[start, declaration_end)`, or is unindexed, in order.
    fn spelledIn(
        reallocations: *const Reallocations,
        allocator: std.mem.Allocator,
        start: usize,
        declaration_end: usize,
        scope_end: usize,
        calls: *std.ArrayList(u32),
    ) !void {
        calls.clearRetainingCapacity();
        const spellings = reallocations.spellings.items;
        const first = std.sort.partitionPoint(Spelling, spellings, start, struct {
            fn before(bound: usize, spelling: Spelling) bool {
                return spelling.position < bound;
            }
        }.before);
        for (spellings[first..]) |spelling| {
            if (spelling.position >= declaration_end) break;
            const method_index = reallocations.calls.items[spelling.call].method_index;
            if (method_index > declaration_end and method_index < scope_end) try calls.append(allocator, spelling.call);
        }
        // Rare: a first argument such as `.{}` or a string literal.
        for (reallocations.unindexed.items) |call| {
            const method_index = reallocations.calls.items[call].method_index;
            if (method_index >= scope_end) break;
            if (method_index > declaration_end) try calls.append(allocator, call);
        }
        std.mem.sort(u32, calls.items, {}, std.sort.asc(u32));
        var kept: usize = 0;
        for (calls.items) |call| {
            if (kept > 0 and calls.items[kept - 1] == call) continue;
            calls.items[kept] = call;
            kept += 1;
        }
        calls.shrinkRetainingCapacity(kept);
    }
};

/// Appends the positions where the tokens of `path` recur, found from the
/// identifiers spelled like its rarest identifier; false when it has none.
fn appendRecurrences(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    path: TokenRange,
    positions: *std.ArrayList(u32),
) !bool {
    var anchor: ?usize = null;
    var anchor_positions: []const u32 = &.{};
    for (path.start..path.end) |index| {
        if (context.tokens[index].tag != .identifier) continue;
        const spelled = identifiers.all(context.tokenText(index));
        if (anchor == null or spelled.len < anchor_positions.len) {
            anchor = index - path.start;
            anchor_positions = spelled;
        }
    }
    const offset = anchor orelse return false;
    const path_length = path.end - path.start;
    for (anchor_positions) |position| {
        if (position < offset or position - offset + path_length > context.tokens.len) continue;
        if (spelledAt(context, path, position - offset)) try positions.append(context.allocator, @intCast(position - offset));
    }
    return true;
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

fn allocatorBinding(context: RuleRun, identifiers: *const IdentifierTable, name: []const u8, before: usize) bool {
    if (std.ascii.findIgnoreCase(name, "alloc") != null or std.mem.eql(u8, name, "gpa")) return true;
    const positions = identifiers.within(name, 0, before);
    var position = positions.len;
    while (position > 0) {
        position -= 1;
        const name_index: usize = positions[position];
        if (name_index + 2 >= before or context.tokens[name_index + 1].tag != .colon) continue;
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

/// Whether `[start, end)` spells `path` as an operand borrowing its storage.
/// `recurrences` lists every position where the tokens of `path` recur, when
/// known; it is an existence question, so only those positions are tried.
fn rangeContainsBorrowingPath(context: RuleRun, recurrences: ?[]const u32, start: usize, end: usize, path: TokenRange) bool {
    const path_length = path.end - path.start;
    if (path_length == 0 or path_length > end - start) return false;
    if (recurrences) |positions| {
        for (positionsWithin(positions, start, end - path_length + 1)) |candidate| {
            if (borrowsAt(context, start, end, path, candidate)) return true;
        }
        return false;
    }
    var candidate = start;
    while (candidate + path_length <= end) : (candidate += 1) {
        if (borrowsAt(context, start, end, path, candidate)) return true;
    }
    return false;
}

/// Whether `path` is spelled at `candidate` as more than its `.len`, an
/// element read or a by-value loop operand.
fn borrowsAt(context: RuleRun, start: usize, end: usize, path: TokenRange, candidate: usize) bool {
    if (!spelledAt(context, path, candidate)) return false;
    const after_path = candidate + (path.end - path.start);
    if (after_path + 1 < end and context.tokens[after_path].tag == .period and
        context.tokenIs(after_path + 1, "len")) return false;
    var operand_end = after_path;
    if (after_path < end and context.tokens[after_path].tag == .l_bracket) {
        const bracket_end = context.matchingToken(after_path, .l_bracket, .r_bracket) orelse return false;
        var is_slice = false;
        for (context.tokens[after_path + 1 .. @min(bracket_end, end)]) |token| {
            if (token.tag == .ellipsis2 or token.tag == .ellipsis3) {
                is_slice = true;
                break;
            }
        }
        const address_taken = candidate > start and context.tokens[candidate - 1].tag == .ampersand;
        if (!is_slice and !address_taken) return false;
        operand_end = bracket_end + 1;
    }
    return !(candidate > start and byValueLoopOperand(context, candidate, operand_end));
}

/// Whether the tokens of `path` recur at `candidate`.
fn spelledAt(context: RuleRun, path: TokenRange, candidate: usize) bool {
    for (0..path.end - path.start) |offset| {
        if (context.tokens[candidate + offset].tag != context.tokens[path.start + offset].tag or
            !std.mem.eql(u8, context.tokenText(candidate + offset), context.tokenText(path.start + offset))) return false;
    }
    return true;
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

/// Whether `[start, end)` is an operand of a `for` that captures its elements
/// by value, `for (items) |item|`: the loop copies each element, so neither
/// the copy nor an index it yields points into the operand's storage.
fn byValueLoopOperand(context: RuleRun, start: usize, end: usize) bool {
    const tokens = context.tokens;
    if (end >= tokens.len or (tokens[end].tag != .comma and tokens[end].tag != .r_paren) or
        (tokens[start - 1].tag != .comma and tokens[start - 1].tag != .l_paren)) return false;
    // The `(` of the operand list, counting the operands before this one.
    var position: usize = 0;
    var cursor = start - 1;
    while (tokens[cursor].tag != .l_paren) {
        switch (tokens[cursor].tag) {
            .comma => position += 1,
            .r_paren, .r_bracket, .r_brace => cursor = context.scopes.matchingToken(cursor) orelse return false,
            .l_bracket, .l_brace, .semicolon => return false,
            else => {},
        }
        if (cursor == 0) return false;
        cursor -= 1;
    }
    if (cursor == 0 or tokens[cursor - 1].tag != .keyword_for) return false;
    const closing = context.scopes.matchingToken(cursor) orelse return false;
    if (closing + 2 >= tokens.len or tokens[closing + 1].tag != .pipe) return false;
    var capture = closing + 2;
    while (position > 0) : (position -= 1) {
        capture = (tokens_util.nextTagBefore(tokens, capture, .comma, .pipe) orelse return false) + 1;
    }
    // `|*item|` captures a pointer into the operand.
    return capture < tokens.len and tokens[capture].tag == .identifier;
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
        // `items.ptr` points at the same storage.
        if (context.tokens[index + 6].tag == .period and context.tokenIs(index + 7, "ptr") and index + 8 == declaration_end) {
            return .{ .name_index = index + 1, .declaration_end = declaration_end, .kind = .pointer };
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
    identifiers: *const IdentifierTable,
    container_name: []const u8,
    kind: container_types.Kind,
    view_name: []const u8,
    start: usize,
    end: usize,
) ?Invalidation {
    // A call from the view's last mention on leaves no use of it to reach.
    const last = reach.lastMention(identifiers, view_name, start, end);
    for (identifiers.within(container_name, start, last)) |position| {
        const index: usize = position;
        if ((index > 0 and context.tokens[index - 1].tag == .period) or index + 3 >= end or
            context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
            context.tokens[index + 3].tag != .l_paren) continue;
        const method = context.tokenText(index + 2);
        if (!invalidatesView(kind, method)) continue;
        const call_end = reach.callEnd(context, index + 2) orelse continue;
        if (reach.firstReachedUse(context, identifiers, view_name, index + 2, call_end + 1, end) == null) continue;
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
    try expectViews("fn f(g: A, l: *std.ArrayList(u8)) !u8 { const p = l.items.ptr; try l.ensureTotalCapacity(g, 9); return p[0]; }", 1);
    try expectViews("fn f(g: A, l: *std.ArrayList(u8)) !u8 { try l.ensureTotalCapacity(g, 9); const p = l.items.ptr; l.appendAssumeCapacity(1); return p[0]; }", 0);
    try expectViews("fn f(g: A, l: *std.ArrayList(u8)) !bool { const p = l.items.ptr; try l.append(g, 1); return p == l.items.ptr; }", 0);
    try expectViews("fn f(self: *const Page, y: usize) *Row { return &self.rows.ptr(m)[y]; }", 0);
}

test "values and indices a by-value for capture yields are not views of a reallocated slice" {
    try expectViews("fn f(gpa: Allocator, g: *G) !void { const n = for (g.nodes) |node| { if (node.t) break node; } else return; " ++
        "g.nodes = try gpa.realloc(g.nodes, 4); g.nodes[3] = n; }", 0);
    try expectViews("fn f(gpa: Allocator, g: *G) !void { const i = for (g.nodes, 0..) |node, id| { if (node.t) break id; } else return; " ++
        "g.nodes = try gpa.realloc(g.nodes, 4); g.nodes[3].a = i; }", 0);
    try expectViews("fn f(gpa: Allocator, g: *G) !void { const n = for (g.nodes[1..]) |node| { if (node.t) break node; } else return; " ++
        "g.nodes = try gpa.realloc(g.nodes, 4); g.nodes[3] = n; }", 0);
    try expectViews("fn f(gpa: Allocator, g: *G) !void { const n = for (g.nodes) |*node| { if (node.t) break node; } else return; " ++
        "g.nodes = try gpa.realloc(g.nodes, 4); n.t = false; }", 1);
    try expectViews("fn f(gpa: Allocator, g: *G) !void { const n = for (0.., g.nodes) |i, *node| { if (i == 1) break node; } else return; " ++
        "g.nodes = try gpa.realloc(g.nodes, 4); n.t = false; }", 1);
    try expectViews("fn f(gpa: Allocator, g: *G) !void { const n = for (g.nodes, 0..) |node, i| { if (node.t) break &g.nodes[i]; } else return; " ++
        "g.nodes = try gpa.realloc(g.nodes, 4); n.t = false; }", 1);
}

test "a declaration borrows from each later reallocation whose source it spells" {
    try expectViews("fn f(gpa: Allocator, b: []u8, c: []u8) !void { const v = b; const w = c; " ++
        "c = try gpa.realloc(c, 8); b = try gpa.realloc(b, 8); use(v, w); }", 2);
    try expectViews("fn f(gpa: Allocator, b: []u8) !void { const v = .{ b.len, b }; b = try gpa.realloc(b, 8); use(v); }", 1);
    try expectViews("fn f(gpa: Allocator, b: []u8) !void { const v = .{ b.len, b[0] }; b = try gpa.realloc(b, 8); use(v); }", 0);
    try expectViews("fn f(gpa: Allocator, b: []u8) !void { b = try gpa.realloc(b, 8); const v = b; use(v); }", 0);
    // A source without an identifier is still compared token by token.
    try expectViews("fn f(gpa: Allocator) !void { const v = \"abc\"; _ = try gpa.realloc(\"abc\", 4); use(v); }", 1);
}

test "field views resolve the field in the innermost enclosing struct" {
    const source =
        "const Outer = struct { output: std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, " ++
        "const Nested = struct { names: std.ArrayListUnmanaged(u8), " ++
        "fn finish(self: *Outer, n: *Nested) ![]u8 { const view = self.output.items; const names = n.names.items; " ++
        "try self.output.appendSlice(self.allocator, \"END\"); try n.names.appendSlice(self.allocator, \"END\"); return .{ view, names }; } }; };";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try support.findings(arena.allocator(), run, source, rule_types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(std.mem.find(u8, found[0].message, "'n.names'") != null);
}
