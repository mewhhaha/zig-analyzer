const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const IdentifierTable = @import("../../syntax/scope.zig").IdentifierTable;
const resources = @import("../resources.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .returning_released_value,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.returning_released_value);
    if (level == .off) return;
    // Built by the first acquisition, so files without one never pay for them.
    var identifiers: ?*const IdentifierTable = null;
    var defers: ?BlockDefers = null;
    defer if (defers) |*built| built.deinit(context.allocator);

    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const release_method = releaseForAcquisition(context, declaration_index + 3, declaration_end) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        const table = identifiers orelse try context.scopes.identifiers();
        identifiers = table;
        if (defers == null) defers = try .init(context);
        const deferred_release = findDeferredRelease(
            context,
            table,
            defers.?,
            binding_name,
            release_method,
            declaration_end + 1,
            scope_end,
            scope_opening,
        ) orelse continue;

        // `return name;` holds the name right after the keyword.
        for (table.within(binding_name, deferred_release.statement_end + 2, scope_end)) |name_index| {
            const return_index = name_index - 1;
            if (context.tokens[return_index].tag != .keyword_return or return_index + 2 >= scope_end or
                context.tokens[return_index + 2].tag != .semicolon or
                bindingShadowed(context, table, binding_name, declaration_index + 2, return_index)) continue;
            const related = try context.allocator.alloc(types.RelatedSpan, 1);
            related[0] = .{
                .span = context.tokens[deferred_release.method_index].loc,
                .message = try context.allocator.print(
                    "deferred {s} runs as this scope exits",
                    .{release_method},
                ),
            };
            try context.emit(.{
                .rule = .returning_released_value,
                .level = level,
                .span = context.tokens[return_index + 1].loc,
                .message = try context.allocator.print(
                    "returned value '{s}' is released by deferred {s} before the caller can use it",
                    .{ binding_name, release_method },
                ),
                .related = related,
            });
        }
    }
}

const DeferredRelease = struct {
    method_index: usize,
    statement_end: usize,
};

fn releaseForAcquisition(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const name = context.tokenText(index);
        if (resources.uniqueAllocationRelease(name)) |release| return release;
        const pair = resources.lookup(context.configuration, name, resources.callReceiver(context.source, context.tokens, index)) orelse continue;
        if (pair.kind != .managed) return pair.release;
    }
    return null;
}

/// The first `defer` directly in the scope after `start` whose statement
/// releases `binding_name` unconditionally.
fn findDeferredRelease(
    context: RuleRun,
    identifiers: *const IdentifierTable,
    defers: BlockDefers,
    binding_name: []const u8,
    release_method: []const u8,
    start: usize,
    end: usize,
    scope_opening: usize,
) ?DeferredRelease {
    const candidates = defers.after(scope_opening, start);
    if (candidates.len == 0) return null;
    if (!candidates[0].disjoint) {
        for (candidates) |candidate| if (deferredRelease(context, binding_name, release_method, candidate)) |found| return found;
        return null;
    }
    // A matching release names the binding inside its defer's statement, and
    // with disjoint statements only the last defer before a use can hold it, so
    // the defers holding a use are the only candidates, still visited in order.
    var visited: ?usize = null;
    for (identifiers.within(binding_name, start + 1, end)) |use| {
        const preceding = std.sort.partitionPoint(BlockDefers.Entry, candidates, @as(usize, use), BlockDefers.Entry.startsBefore);
        if (preceding == 0) continue;
        const holder = preceding - 1;
        if (holder == visited or use >= candidates[holder].end) continue;
        visited = holder;
        if (deferredRelease(context, binding_name, release_method, candidates[holder])) |found| return found;
    }
    return null;
}

fn deferredRelease(
    context: RuleRun,
    binding_name: []const u8,
    release_method: []const u8,
    candidate: BlockDefers.Entry,
) ?DeferredRelease {
    const defer_index: usize = candidate.keyword;
    const statement_end: usize = candidate.end;
    for (context.tokens[defer_index + 1 .. statement_end], defer_index + 1..) |method, method_index| {
        if (method.tag != .identifier or !context.tokenIs(method_index, release_method) or
            !releaseReferencesBinding(context, binding_name, method_index, statement_end)) continue;
        if (containsTag(context.tokens, defer_index + 1, method_index, .keyword_if)) return null;
        return .{ .method_index = method_index, .statement_end = statement_end };
    }
    return null;
}

/// The `defer` statements directly inside each block, built once per run,
/// with the token ending each: the `}` of a braced body, else the `;`.
/// Defers whose end is unknown are left out, since nothing searches them.
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
            const end = (if (context.tokens[keyword + 1].tag == .l_brace)
                context.matchingToken(keyword + 1, .l_brace, .r_brace)
            else
                context.statementEnd(keyword)) orelse continue;
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

fn containsTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) bool {
    for (tokens[start..end]) |token| if (token.tag == tag) return true;
    return false;
}

fn releaseReferencesBinding(context: RuleRun, binding_name: []const u8, method_index: usize, end: usize) bool {
    if (method_index >= 2 and context.tokens[method_index - 1].tag == .period and
        context.tokenIs(method_index - 2, binding_name)) return true;
    if (method_index + 1 >= end or context.tokens[method_index + 1].tag != .l_paren) return false;
    const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse return false;
    for (context.tokens[method_index + 2 .. @min(closing, end)], method_index + 2..) |argument, argument_index| {
        if (argument.tag == .identifier and context.tokenIs(argument_index, binding_name)) return true;
    }
    return false;
}

fn bindingShadowed(context: RuleRun, identifiers: *const IdentifierTable, name: []const u8, start: usize, end: usize) bool {
    // `const name`, `var name` or `|name` in `[start, end)` puts the name right after.
    for (identifiers.within(name, start + 1, end)) |name_index| switch (context.tokens[name_index - 1].tag) {
        .keyword_const, .keyword_var, .pipe => return true,
        else => {},
    };
    return false;
}

test "returning a deferred allocation or file reports the expired value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn bytes(allocator: anytype) ![]u8 { const value = try allocator.alloc(u8, 8); defer allocator.free(value); return value; }\n" ++
        "fn file(directory: anytype) !File { const opened = try directory.openFile(\"x\", .{}); defer opened.close(); return opened; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("value", source[findings[0].span.start..findings[0].span.end]);
    try std.testing.expectEqual(@as(usize, 1), findings[0].related.len);
}

test "ownership returns and error-only cleanup remain valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn owned(allocator: anytype) ![]u8 { const value = try allocator.alloc(u8, 8); errdefer allocator.free(value); return value; }\n" ++
        "fn length(allocator: anytype) !usize { const value = try allocator.alloc(u8, 8); defer allocator.free(value); return value.len; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a conditionally guarded defer can transfer ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn bytes(a: anytype) ![]u8 { var done = false; const value = try a.alloc(u8, 8); defer if (!done) a.free(value); done = true; return value; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a block-bodied defer still releases the returned value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn bytes(allocator: anytype) ![]u8 { const value = try allocator.alloc(u8, 8); defer { allocator.free(value); } return value; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("value", source[findings[0].span.start..findings[0].span.end]);
}

test "a declared resource pair reports returning a deferred release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const source: [:0]const u8 =
        "fn open() !Connection { const connection = try Db.open(); defer connection.close(); return connection; }";
    const declared = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), declared.len);
    const builtin = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), builtin.len);
}

test "a defer statement running into the next defer still yields its unconditional release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Without a `;` after its block, the first defer's statement runs through the second.
    const source: [:0]const u8 =
        "fn bytes(a: anytype, c: bool) ![]u8 { const value = try a.alloc(u8, 1); defer if (c) { log(); } defer a.free(value); return value; }\n" ++
        "fn guarded(a: anytype, c: bool) ![]u8 { const value = try a.alloc(u8, 1); defer if (c) { a.free(value); } defer log(); return value; }\n" ++
        "fn log() void {}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(findings[0].span.start < std.mem.findScalar(u8, source, '\n').?);
}
