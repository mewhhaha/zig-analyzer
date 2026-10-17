const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const support = @import("../test_support.zig");
const container_types = @import("../container_types.zig");
const IdentifierTable = @import("../../syntax/scope.zig").IdentifierTable;

pub const rules = [_]@import("../types.zig").Rule{
    .returning_deinitialized_view,
    .returning_arena_allocation,
};

pub fn run(context: RuleRun) !void {
    // Built by the first owner with a deferred `deinit` candidate.
    var defers: ?BlockDefers = null;
    defer if (defers) |*built| built.deinit(context.allocator);
    try findDeinitializedViews(context, &defers);
    try findArenaReturns(context, &defers);
}

fn findDeinitializedViews(context: RuleRun, defers: *?BlockDefers) !void {
    const level = context.level(.returning_deinitialized_view);
    if (level == .off) return;
    var identifiers: ?*const IdentifierTable = null;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const kind = container_types.declaredKind(context.source, context.tokens, declaration_index, declaration_end) orelse continue;
        if (!kind.hasItems()) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const container_name = context.tokenText(declaration_index + 1);
        const table = identifiers orelse try context.scopes.identifiers();
        identifiers = table;
        if (defers.* == null) defers.* = try .init(context);
        if (!hasDeferredMethod(context, table, defers.*.?, container_name, "deinit", declaration_end + 1, scope_end, scope_opening)) continue;

        // A reported return names the container right after its keyword, or a
        // view whose declaration names the container three tokens after its `const`.
        var returns: std.ArrayList(u32) = .empty;
        defer returns.deinit(context.allocator);
        for (table.within(context.tokenText(declaration_index + 1), declaration_end + 2, scope_end)) |use| {
            const index = use - 1;
            if (context.tokens[index].tag == .keyword_return and context.enclosingOpeningBrace(index) == scope_opening and
                index + 4 < scope_end and context.tokens[index + 2].tag == .period and context.tokenIs(index + 3, "items") and
                itemsViewEnd(context, index + 4, scope_end) != null) try returns.append(context.allocator, @intCast(index));
            if (use < declaration_end + 4) continue;
            const view = use - 3;
            if ((context.tokens[view].tag != .keyword_const and context.tokens[view].tag != .keyword_var) or view + 6 >= scope_end or
                context.tokens[view + 1].tag != .identifier or context.tokens[view + 2].tag != .equal or
                context.tokens[view + 4].tag != .period or !context.tokenIs(view + 5, "items") or
                itemsViewEnd(context, view + 6, scope_end) == null) continue;
            for (table.within(context.tokenText(view + 1), view + 2, scope_end)) |returned| {
                const return_index = returned - 1;
                if (context.tokens[return_index].tag == .keyword_return and context.enclosingOpeningBrace(return_index) == scope_opening and
                    return_index + 2 < scope_end and context.tokens[return_index + 2].tag == .semicolon)
                    try returns.append(context.allocator, @intCast(return_index));
            }
        }
        std.mem.sort(u32, returns.items, {}, std.sort.asc(u32));
        for (returns.items, 0..) |index, position| {
            if (position > 0 and returns.items[position - 1] == index) continue;
            try context.emit(.{
                .rule = .returning_deinitialized_view,
                .level = level,
                .span = context.tokens[index + 1].loc,
                .message = try context.allocator.print(
                    "returned view '{s}' borrows container '{s}', but deferred deinit destroys its backing storage before the caller can use it",
                    // The returned name is the view's, or the container's for its own items.
                    .{ context.tokenText(index + 1), container_name },
                ),
            });
        }
    }
}

/// The `;` ending a borrowed `items` view that starts at `start`: either
/// directly or after a subslice such as `[0..n]`.
fn itemsViewEnd(context: RuleRun, start: usize, end: usize) ?usize {
    if (start >= end) return null;
    if (context.tokens[start].tag == .semicolon) return start;
    if (context.tokens[start].tag != .l_bracket) return null;
    const closing = context.matchingToken(start, .l_bracket, .r_bracket) orelse return null;
    if (closing + 1 >= end or context.tokens[closing + 1].tag != .semicolon) return null;
    for (context.tokens[start + 1 .. closing]) |token| if (token.tag == .ellipsis2) return closing + 1;
    return null;
}

fn findArenaReturns(context: RuleRun, defers: *?BlockDefers) !void {
    const level = context.level(.returning_arena_allocation);
    if (level == .off) return;
    const identifiers = try context.scopes.identifiers();
    if (identifiers.all("ArenaAllocator").len == 0) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (identifiers.firstWithin("ArenaAllocator", declaration_index + 3, declaration_end) == null) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const arena_name = context.tokenText(declaration_index + 1);
        if (defers.* == null) defers.* = try .init(context);
        if (!hasDeferredMethod(context, identifiers, defers.*.?, arena_name, "deinit", declaration_end + 1, scope_end, scope_opening)) continue;

        var allocations: std.StringHashMapUnmanaged(void) = .empty;
        defer allocations.deinit(context.allocator);
        var allocator_bindings: std.StringHashMapUnmanaged(void) = .empty;
        defer allocator_bindings.deinit(context.allocator);
        // A statement only adds a name or reports when it uses a name tracked
        // so far (the arena, an allocator from it, an allocation from either)
        // after its first token, so the scan ends after the last such use.
        var tracked_until = lastUse(identifiers, arena_name, declaration_end + 1, scope_end);
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |candidate, index| {
            if (index > tracked_until) break;
            if ((candidate.tag == .keyword_const or candidate.tag == .keyword_var) and index + 3 < scope_end and
                context.tokens[index + 1].tag == .identifier)
            {
                const binding_end = context.statementEnd(index) orelse continue;
                const binding_name = context.tokenText(index + 1);
                if (derivesArenaAllocator(context, arena_name, index + 3, binding_end)) {
                    try allocator_bindings.put(context.allocator, binding_name, {});
                    tracked_until = @max(tracked_until, lastUse(identifiers, binding_name, declaration_end + 1, scope_end));
                } else if (expressionUsesArenaAllocation(context, arena_name, index + 3, binding_end) or
                    expressionUsesDerivedAllocation(context, allocator_bindings, index + 3, binding_end))
                {
                    try allocations.put(context.allocator, binding_name, {});
                    tracked_until = @max(tracked_until, lastUse(identifiers, binding_name, declaration_end + 1, scope_end));
                }
            }
            if (candidate.tag != .keyword_return or context.enclosingOpeningBrace(index) != scope_opening) continue;
            const return_end = context.statementEnd(index) orelse continue;
            var value_start = index + 1;
            if (value_start < return_end and context.tokens[value_start].tag == .keyword_try) value_start += 1;
            const returned_binding = returnedAllocationBinding(context, allocations, value_start, return_end);
            const direct_allocation = expressionUsesArenaAllocation(context, arena_name, index + 1, return_end) or
                expressionUsesDerivedAllocation(context, allocator_bindings, index + 1, return_end);
            if (returned_binding == null and !direct_allocation) continue;
            try context.emit(.{
                .rule = .returning_arena_allocation,
                .level = level,
                .span = context.tokens[index].loc,
                .message = if (returned_binding) |name|
                    try context.allocator.print(
                        "returned value '{s}' is allocated by local arena '{s}', which is deinitialized before return completes",
                        .{ name, arena_name },
                    )
                else
                    try context.allocator.print(
                        "returned value is allocated by local arena '{s}', which is deinitialized before the caller can use it",
                        .{arena_name},
                    ),
            });
        }
    }
}

/// The last use of `name` in `[start, end)`, or `start` when there is none.
fn lastUse(identifiers: *const IdentifierTable, name: []const u8, start: usize, end: usize) usize {
    const uses = identifiers.within(name, start, end);
    return if (uses.len == 0) start else uses[uses.len - 1];
}

fn returnedAllocationBinding(
    context: RuleRun,
    allocations: std.StringHashMapUnmanaged(void),
    start: usize,
    end: usize,
) ?[]const u8 {
    var parenthesis_depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren => {
                parenthesis_depth += 1;
                continue;
            },
            .r_paren => {
                parenthesis_depth -|= 1;
                continue;
            },
            else => {},
        }
        if (parenthesis_depth != 0) continue;
        if (token.tag != .identifier or !allocations.contains(context.tokenText(index)) or
            (index > start and context.tokens[index - 1].tag == .period)) continue;
        if (index + 2 < end and context.tokens[index + 1].tag == .period and context.tokenIs(index + 2, "len")) continue;
        if (index + 1 < end and context.tokens[index + 1].tag == .l_bracket) {
            const slice_end = context.matchingToken(index + 1, .l_bracket, .r_bracket) orelse continue;
            var returns_view = false;
            for (context.tokens[index + 2 .. @min(slice_end, end)]) |slice_token| {
                if (slice_token.tag == .ellipsis2) returns_view = true;
            }
            if (!returns_view) continue;
        }
        return context.tokenText(index);
    }
    return null;
}

/// Whether a `defer` directly in the scope from `start` on calls `binding_name.method(`.
fn hasDeferredMethod(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    defers: BlockDefers,
    binding_name: []const u8,
    method: []const u8,
    start: usize,
    end: usize,
    scope_opening: usize,
) bool {
    const candidates = defers.after(scope_opening, start);
    if (candidates.len == 0) return false;
    if (!candidates[0].disjoint) {
        for (candidates) |candidate| if (deferCallsMethod(context, binding_name, method, candidate)) return true;
        return false;
    }
    // With disjoint statements only the last defer before a call can hold it.
    for (identifiers.within(binding_name, start + 1, end)) |receiver| {
        if (context.tokens[receiver + 1].tag != .period or !context.tokenIs(receiver + 2, method) or
            context.tokens[receiver + 3].tag != .l_paren) continue;
        const preceding = std.sort.partitionPoint(BlockDefers.Entry, candidates, @as(usize, receiver), BlockDefers.Entry.startsBefore);
        if (preceding > 0 and receiver + 3 < candidates[preceding - 1].end) return true;
    }
    return false;
}

fn deferCallsMethod(context: RuleRun, binding_name: []const u8, method: []const u8, candidate: BlockDefers.Entry) bool {
    var cursor: usize = candidate.keyword + 1;
    while (cursor + 3 < candidate.end) : (cursor += 1) {
        if (context.tokenIs(cursor, binding_name) and context.tokens[cursor + 1].tag == .period and
            context.tokenIs(cursor + 2, method) and context.tokens[cursor + 3].tag == .l_paren) return true;
    }
    return false;
}

/// The `defer` statements directly inside each block, built once per run,
/// with the `;` ending each. Defers without one are left out, since nothing
/// searches them.
const BlockDefers = struct {
    /// Sorted by block, then by position.
    entries: []Entry,

    const Entry = struct {
        block: u32,
        keyword: u32,
        end: u32,
        /// Whether every defer of this block ends before the next one starts.
        disjoint: bool = true,

        fn startsBefore(position: usize, entry: Entry) bool {
            return entry.keyword < position;
        }
    };

    fn init(context: RuleRun) !BlockDefers {
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(context.allocator);
        for (context.tokens, 0..) |token, keyword| {
            if (token.tag != .keyword_defer) continue;
            const block = context.enclosingOpeningBrace(keyword) orelse continue;
            const end = context.statementEnd(keyword) orelse continue;
            try entries.append(context.allocator, .{ .block = @intCast(block), .keyword = @intCast(keyword), .end = @intCast(end) });
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, left: Entry, right: Entry) bool {
                return left.block < right.block or left.block == right.block and left.keyword < right.keyword;
            }
        }.lessThan);
        var group_start: usize = 0;
        while (group_start < entries.items.len) {
            var group_end = group_start + 1;
            var disjoint = true;
            while (group_end < entries.items.len and entries.items[group_end].block == entries.items[group_start].block) : (group_end += 1) {
                if (entries.items[group_end - 1].end > entries.items[group_end].keyword) disjoint = false;
            }
            for (entries.items[group_start..group_end]) |*entry| entry.disjoint = disjoint;
            group_start = group_end;
        }
        return .{ .entries = try entries.toOwnedSlice(context.allocator) };
    }

    fn deinit(defers: *BlockDefers, allocator: std.mem.Allocator) void {
        allocator.free(defers.entries);
    }

    /// The defers directly in the block opening at `block` from `start` on.
    fn after(defers: BlockDefers, block: usize, start: usize) []const Entry {
        const first = std.sort.partitionPoint(Entry, defers.entries, block, struct {
            fn before(wanted: usize, entry: Entry) bool {
                return entry.block < wanted;
            }
        }.before);
        const count = std.sort.partitionPoint(Entry, defers.entries[first..], block, struct {
            fn inside(wanted: usize, entry: Entry) bool {
                return entry.block == wanted;
            }
        }.inside);
        const group = defers.entries[first..][0..count];
        return group[std.sort.partitionPoint(Entry, group, start, Entry.startsBefore)..];
    }
};

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
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn items(allocator: anytype) []u8 { var list = std.ArrayList(u8).empty; defer list.deinit(allocator); return list.items; }\n" ++
        "fn bytes(parent: anytype) ![]u8 { var arena = std.heap.ArenaAllocator.init(parent); defer arena.deinit(); const value = try arena.allocator().dupe(u8, \"x\"); return value; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "every alias of a deinitialized container remains borrowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn items(allocator: anytype) []u8 { var list = std.ArrayList(u8).empty; " ++
        "defer list.deinit(allocator); const first = list.items; const second = list.items; " ++
        "_ = second; return first; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "returning a value read out of a container view is not a dangling view" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn count(allocator: anytype) usize { var list = std.ArrayList(u8).empty; defer list.deinit(allocator); return list.items.len; }\n" ++
        "fn first(allocator: anytype) u8 { var list = std.ArrayList(u8).empty; defer list.deinit(allocator); return list.items[0]; }\n" ++
        "fn borrowed(allocator: anytype) usize { var list = std.ArrayList(u8).empty; defer list.deinit(allocator); const n = list.items.len; return n; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "copying arena scratch out through another allocator is not an arena return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn out(gpa: anytype, parent: anytype) ![]u8 { var arena = std.heap.ArenaAllocator.init(parent); defer arena.deinit(); const aa = arena.allocator(); const scratch = try aa.dupe(u8, \"x\"); return try gpa.dupe(u8, scratch); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "allocations through a binding derived from the arena are arena returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn bytes(parent: anytype) ![]u8 { var arena = std.heap.ArenaAllocator.init(parent); defer arena.deinit(); const aa = arena.allocator(); const value = try aa.dupe(u8, \"x\"); return value; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "arena allocations embedded in returned aggregates expire with the arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "const Packet = struct { bytes: []u8, length: usize };" ++
        "fn packet(parent: anytype) !Packet { var local_arena = std.heap.ArenaAllocator.init(parent);" ++
        "defer local_arena.deinit(); const bytes = try local_arena.allocator().alloc(u8, 8);" ++
        "return .{ .bytes = bytes, .length = bytes.len }; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.returning_arena_allocation, findings[0].rule);
}

fn expectViewReturns(source: [:0]const u8, expected: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try support.findings(arena.allocator(), run, source, @import("../types.zig").Configuration.defaults());
    try std.testing.expectEqual(expected, found.len);
}

test "a container declared by type annotation returns a deinitialized view" {
    try expectViewReturns("fn f(gpa: A) ![]u8 { var l: std.ArrayList(u8) = .empty; defer l.deinit(gpa); return l.items; }", 1);
    try expectViewReturns("fn f(gpa: A) ![]u8 { var l: std.ArrayList(u8) = try .initCapacity(gpa, 4); defer l.deinit(gpa); return l.items; }", 1);
    try expectViewReturns("fn f(gpa: A) ![]u8 { var l: std.ArrayList(u8) = .empty; defer l.deinit(gpa); return l.items[0..1]; }", 1);
}

test "a container returned by owned slice has no deinitialized view" {
    try expectViewReturns("fn f(gpa: A) ![]u8 { var l: std.ArrayList(u8) = .empty; defer l.deinit(gpa); return try l.toOwnedSlice(gpa); }", 0);
}

test "a defer statement running into the next defer still finds the deferred deinit" {
    try expectViewReturns("fn f(a: A, c: bool) []u8 { var l = std.ArrayList(u8).empty; defer if (c) { log(); } defer l.deinit(a); return l.items; }", 1);
    try expectViewReturns("fn f(a: A) []u8 { var l = std.ArrayList(u8).empty; defer l.deinit(a); const first = l.items[0..1]; const other = l.items; _ = other; return first; }", 1);
}

test "an allocator taken from an arena keeps the arena's later allocations tracked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("../types.zig");
    const source: [:0]const u8 =
        "fn two(parent: anytype) ![]u8 { var first = std.heap.ArenaAllocator.init(parent); defer first.deinit(); const aa = first.allocator(); " ++
        "var second = std.heap.ArenaAllocator.init(parent); defer second.deinit(); _ = try second.allocator().alloc(u8, 1); " ++
        "const value = try aa.dupe(u8, \"x\"); return value; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "'first'") != null);
}
