//! The tables the ownership walk and the scans keep per block: block nodes by
//! their `{`, the spans the scans of a binding visit (`StatementReach`,
//! `bindingSpans`), and how each statement acts on a binding it does not name
//! (`StatementEffects`).
const std = @import("std");

const syntax_scope = @import("../../../syntax/scope.zig");
const summaries = @import("../../summaries.zig");
const TokenRange = @import("../../../syntax/tokens.zig").Range;
const Allocation = @import("allocation.zig").Allocation;
const usesSpan = @import("scans.zig").usesSpan;
const paths = @import("paths.zig");
const analyzeOwnershipNode = paths.analyzeOwnershipNode;
const ownership_live_with_errdefer = paths.ownership_live_with_errdefer;
const ownership_safe = paths.ownership_safe;

fn blockNodeForOpening(tree: *const std.zig.Ast, opening: usize) ?std.zig.Ast.Node.Index {
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeMainToken(node) != opening) continue;
        switch (tree.nodeTag(node)) {
            .block_two, .block_two_semicolon, .block, .block_semicolon => return node,
            else => {},
        }
    }
    return null;
}

/// What the ownership walk keeps of a file, so that the walk for each
/// allocation neither searches the tree for its block nor re-walks every
/// statement after it: block nodes by their `{`, and for each block entered,
/// how its statements act on a binding they do not name.
pub const OwnershipCache = struct {
    allocator: std.mem.Allocator,
    /// Built on the first lookup.
    blocks: ?std.AutoHashMapUnmanaged(u32, std.zig.Ast.Node.Index) = null,
    effects: std.AutoHashMapUnmanaged(std.zig.Ast.Node.Index, *const StatementEffects) = .empty,
    /// Null for a block whose statements do not make up its tokens.
    reaches: std.AutoHashMapUnmanaged(std.zig.Ast.Node.Index, ?*const StatementReach) = .empty,
    /// Set when an allocation fails; the walk then goes without the tables.
    failed: bool = false,

    pub fn deinit(cache: *OwnershipCache) void {
        if (cache.blocks) |*blocks| blocks.deinit(cache.allocator);
        var effects = cache.effects.valueIterator();
        while (effects.next()) |block_effects| block_effects.*.deinit(cache.allocator);
        cache.effects.deinit(cache.allocator);
        var reaches = cache.reaches.valueIterator();
        while (reaches.next()) |block_reach| if (block_reach.*) |reach| reach.deinit(cache.allocator);
        cache.reaches.deinit(cache.allocator);
    }

    /// The block node whose `{` is `opening`, as `blockNodeForOpening` finds it.
    pub fn blockNode(cache: *OwnershipCache, tree: *const std.zig.Ast, opening: usize) ?std.zig.Ast.Node.Index {
        if (cache.blocks == null and !cache.failed) cache.indexBlocks(tree) catch {
            cache.failed = true;
        };
        const blocks = cache.blocks orelse return blockNodeForOpening(tree, opening);
        return blocks.get(std.math.cast(u32, opening) orelse return null);
    }

    fn indexBlocks(cache: *OwnershipCache, tree: *const std.zig.Ast) !void {
        var blocks: std.AutoHashMapUnmanaged(u32, std.zig.Ast.Node.Index) = .empty;
        errdefer blocks.deinit(cache.allocator);
        for (0..tree.nodes.len) |raw_node| {
            const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
            switch (tree.nodeTag(node)) {
                .block_two, .block_two_semicolon, .block, .block_semicolon => {},
                else => continue,
            }
            // The first block node opened by a brace wins, as in the scan.
            const entry = try blocks.getOrPut(cache.allocator, tree.nodeMainToken(node));
            if (!entry.found_existing) entry.value_ptr.* = node;
        }
        cache.blocks = blocks;
    }

    /// The `StatementReach` of the block declaring `declaration_index`, or null
    /// when the file does not parse or the block's statements do not make up
    /// its tokens.
    fn statementReach(
        cache: *OwnershipCache,
        tree: *const std.zig.Ast,
        tokens: []const std.zig.Token,
        scope_index: *const syntax_scope.Index,
        declaration_index: usize,
    ) ?*const StatementReach {
        if (cache.failed or tree.errors.len != 0) return null;
        const opening = scope_index.enclosingOpeningBrace(declaration_index) orelse return null;
        const block = cache.blockNode(tree, opening) orelse return null;
        if (cache.reaches.get(block)) |reach| return reach;
        cache.reaches.ensureUnusedCapacity(cache.allocator, 1) catch {
            cache.failed = true;
            return null;
        };
        const reach = buildStatementReach(cache.allocator, tree, tokens, scope_index, block, opening) catch {
            cache.failed = true;
            return null;
        };
        cache.reaches.putAssumeCapacity(block, reach);
        return reach;
    }
};

/// The statements of a block as the release, escape and transfer scans of a
/// binding declared in it see them (`bindingSpans`).
const StatementReach = struct {
    first_tokens: []u32,
    /// One past each statement's last token.
    ends: []u32,
    /// One past the last token where a mention of the binding lets a site
    /// of the statement count: further than `ends` for a `return` or `x = `
    /// whose statement end, as `Index.statementEnd` finds it, lies in a later
    /// statement, and `unbounded` when it finds none.
    reaches: []u32,
    /// One past the last site a mention in the statement can let count: the
    /// body of an `if (...) |capture|` whose capture a release frees.
    influences: []u32,
    /// The statements reaching past their end, in order.
    reaching: []u32,

    const unbounded = std.math.maxInt(u32);

    fn deinit(reach: *const StatementReach, allocator: std.mem.Allocator) void {
        allocator.free(reach.first_tokens);
        allocator.free(reach.ends);
        allocator.free(reach.reaches);
        allocator.free(reach.influences);
        allocator.free(reach.reaching);
        allocator.destroy(reach);
    }

    /// The statement holding token `index`.
    fn holding(reach: *const StatementReach, index: usize) ?usize {
        var low: usize = 0;
        var high = reach.first_tokens.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (reach.first_tokens[middle] <= index) low = middle + 1 else high = middle;
        }
        if (low == 0 or index >= reach.ends[low - 1]) return null;
        return low - 1;
    }
};

/// The token ranges the release, escape and transfer scans of the binding
/// declared at `declaration_index` visit within `[start, end)`, in order. A
/// site those scans accept names the binding in its own statement of the
/// declaration's block, or in a later one its statement reaches
/// (`StatementReach.reaches`), or it lies where the capture of an `if` naming
/// the binding is freed (`StatementReach.influences`); so the statements that
/// name the binding, with what they influence, and the reaching statements a
/// mention lies within, hold every site. Without the block's statements the
/// one span runs to `usesEnd`.
pub fn bindingSpans(
    cache: *OwnershipCache,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    declaration_index: usize,
    binding_name: []const u8,
    start: usize,
    end: usize,
    spans: *std.ArrayList(TokenRange),
) ![]const TokenRange {
    const allocator = cache.allocator;
    spans.clearRetainingCapacity();
    const reach = cache.statementReach(tree, tokens, scope_index, declaration_index) orelse {
        try spans.appendSlice(allocator, &usesSpan(scope_index, binding_name, start, end));
        return spans.items;
    };
    var uses = scope_index.identifiersNamed(binding_name, start, end);
    while (uses.next()) |use| {
        const statement = reach.holding(use) orelse {
            spans.clearRetainingCapacity();
            try spans.appendSlice(allocator, &usesSpan(scope_index, binding_name, start, end));
            return spans.items;
        };
        try spans.append(allocator, .{
            .start = reach.first_tokens[statement],
            .end = @max(reach.ends[statement], reach.influences[statement]),
        });
    }
    const first_reaching = std.sort.partitionPoint(u32, reach.reaching, ReachingBefore{ .reach = reach, .start = start }, ReachingBefore.endsBefore);
    for (reach.reaching[first_reaching..]) |statement| {
        if (reach.first_tokens[statement] >= end) break;
        var reached = scope_index.identifiersNamed(binding_name, @max(start, reach.first_tokens[statement]), @min(end, reach.reaches[statement]));
        if (reached.next() == null) continue;
        try spans.append(allocator, .{ .start = reach.first_tokens[statement], .end = reach.ends[statement] });
    }
    std.mem.sort(TokenRange, spans.items, {}, struct {
        fn lessThan(_: void, left: TokenRange, right: TokenRange) bool {
            return left.start < right.start;
        }
    }.lessThan);
    // Merge overlapping spans and keep them inside `[start, end)`.
    var merged: usize = 0;
    for (spans.items) |span| {
        const clipped: TokenRange = .{ .start = @max(span.start, start), .end = @min(span.end, end) };
        if (clipped.start >= clipped.end) continue;
        if (merged != 0 and clipped.start <= spans.items[merged - 1].end) {
            spans.items[merged - 1].end = @max(spans.items[merged - 1].end, clipped.end);
            continue;
        }
        spans.items[merged] = clipped;
        merged += 1;
    }
    spans.shrinkRetainingCapacity(merged);
    return spans.items;
}

const ReachingBefore = struct {
    reach: *const StatementReach,
    start: usize,

    fn endsBefore(context: ReachingBefore, statement: u32) bool {
        return context.reach.ends[statement] <= context.start;
    }
};

fn buildStatementReach(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    block: std.zig.Ast.Node.Index,
    opening: usize,
) !?*const StatementReach {
    const closing = scope_index.matchingToken(opening) orelse return null;
    if (closing > std.math.maxInt(u32) - 1) return null;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, block) orelse return null;
    // The statements and the `;` between them make up the block.
    var cursor = opening + 1;
    for (statements) |statement| {
        const first: usize = tree.firstToken(statement);
        const last: usize = tree.lastToken(statement);
        if (first < cursor or last >= closing) return null;
        for (tokens[cursor..first]) |token| if (token.tag != .semicolon) return null;
        cursor = last + 1;
    }
    for (tokens[cursor..closing]) |token| if (token.tag != .semicolon) return null;

    var statement_ends = try scope_index.statementEndsIn(allocator, opening);
    defer statement_ends.deinit(allocator);

    const count = statements.len;
    const first_tokens = try allocator.alloc(u32, count);
    errdefer allocator.free(first_tokens);
    const ends = try allocator.alloc(u32, count);
    errdefer allocator.free(ends);
    const reaches = try allocator.alloc(u32, count);
    errdefer allocator.free(reaches);
    const influences = try allocator.alloc(u32, count);
    errdefer allocator.free(influences);
    var reaching: std.ArrayList(u32) = .empty;
    errdefer reaching.deinit(allocator);
    for (statements, 0..) |statement, index| {
        const first: usize = tree.firstToken(statement);
        const last: usize = tree.lastToken(statement);
        first_tokens[index] = @intCast(first);
        ends[index] = @intCast(last + 1);
        var reach: u32 = ends[index];
        var influence: u32 = ends[index];
        for (tokens[first .. last + 1], first..) |token, site| switch (token.tag) {
            // `controlFlowValueContainsBinding`: the value up to its statement's end.
            .keyword_return, .keyword_break => {
                const value_end = statement_ends.at(scope_index, site + 1) orelse StatementReach.unbounded;
                reach = if (value_end == StatementReach.unbounded) StatementReach.unbounded else @max(reach, @as(u32, @intCast(value_end)));
            },
            // `bindingEscapes`: an assignment's value up to its statement's end.
            .equal => if (statement_ends.at(scope_index, site)) |value_end| {
                reach = @max(reach, @as(u32, @intCast(value_end)));
            },
            // `releaseArgumentContainsOptionalCapture`: the capture's body.
            .pipe => if (site + 3 < closing and tokens[site + 1].tag == .identifier and tokens[site + 2].tag == .pipe) {
                const body_end = if (tokens[site + 3].tag == .l_brace)
                    scope_index.matchingToken(site + 3) orelse continue
                else
                    statement_ends.at(scope_index, site + 3) orelse continue;
                influence = @max(influence, @as(u32, @intCast(body_end + 1)));
            },
            else => {},
        };
        reaches[index] = reach;
        influences[index] = influence;
        if (reach > ends[index]) try reaching.append(allocator, @intCast(index));
    }
    const reaching_statements = try reaching.toOwnedSlice(allocator);
    errdefer allocator.free(reaching_statements);
    const reach = try allocator.create(StatementReach);
    reach.* = .{
        .first_tokens = first_tokens,
        .ends = ends,
        .reaches = reaches,
        .influences = influences,
        .reaching = reaching_statements,
    };
    return reach;
}

/// How each statement of a block acts on the ownership walk for a binding it
/// does not name. Such a statement cannot release, move or alias the binding,
/// so it either stops the walk (`null`, or no path continues past it) or
/// passes the states through, at most adding a return that keeps them or an
/// error exit; which of these does not depend on the binding or the states.
/// `unnamedStatementEffect` finds it by walking the statement with a name no
/// identifier has.
pub const StatementEffects = struct {
    first_tokens: []u32,
    last_tokens: []u32,
    /// For each statement, the first one at or after it that is not a
    /// pass-through, or the statement count; one entry past the end.
    next_stop: []u32,
    /// How many pass-through statements before each one return, and how many
    /// exit with an error; one entry past the end.
    returns_before: []u32,
    errors_before: []u32,

    fn deinit(effects: *const StatementEffects, allocator: std.mem.Allocator) void {
        allocator.free(effects.first_tokens);
        allocator.free(effects.last_tokens);
        allocator.free(effects.next_stop);
        allocator.free(effects.returns_before);
        allocator.free(effects.errors_before);
        allocator.destroy(effects);
    }

    /// The first statement at or after `from` that names `binding_name`, or
    /// the statement count.
    pub fn nextNaming(effects: *const StatementEffects, scope_index: *const syntax_scope.Index, binding_name: []const u8, from: usize) usize {
        const count = effects.first_tokens.len;
        if (from >= count) return count;
        var uses = scope_index.identifiersNamed(binding_name, effects.first_tokens[from], @as(usize, effects.last_tokens[count - 1]) + 1);
        while (uses.next()) |use| {
            var low = from;
            var high = count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (effects.first_tokens[middle] <= use) low = middle + 1 else high = middle;
            }
            const holding = low - 1;
            if (use <= effects.last_tokens[holding]) return holding;
        }
        return count;
    }
};

/// The probe `unnamedStatementEffect` walks with: it tells a return, which
/// keeps `ownership_live_with_errdefer`, from an error exit, which makes it safe.
const unnamed_probe_states = ownership_live_with_errdefer;
const unnamed_allocation: Allocation = .{ .method = "", .release = "", .receiver = null, .allocator_source = null };

pub fn statementEffects(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    block: std.zig.Ast.Node.Index,
    statements: []const std.zig.Ast.Node.Index,
    summary_index: summaries.Index,
    cache: *OwnershipCache,
) ?*const StatementEffects {
    if (cache.failed) return null;
    if (cache.effects.get(block)) |effects| return effects;
    const effects = buildStatementEffects(source, tree, tokens, scope_index, statements, summary_index, cache) catch {
        cache.failed = true;
        return null;
    };
    cache.effects.put(cache.allocator, block, effects) catch {
        effects.deinit(cache.allocator);
        cache.failed = true;
        return null;
    };
    return effects;
}

fn buildStatementEffects(
    source: []const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    statements: []const std.zig.Ast.Node.Index,
    summary_index: summaries.Index,
    cache: *OwnershipCache,
) !*const StatementEffects {
    const allocator = cache.allocator;
    const count = statements.len;
    const first_tokens = try allocator.alloc(u32, count);
    errdefer allocator.free(first_tokens);
    const last_tokens = try allocator.alloc(u32, count);
    errdefer allocator.free(last_tokens);
    const next_stop = try allocator.alloc(u32, count + 1);
    errdefer allocator.free(next_stop);
    const returns_before = try allocator.alloc(u32, count + 1);
    errdefer allocator.free(returns_before);
    const errors_before = try allocator.alloc(u32, count + 1);
    errdefer allocator.free(errors_before);
    const passes = try allocator.alloc(bool, count);
    defer allocator.free(passes);
    returns_before[0] = 0;
    errors_before[0] = 0;
    for (statements, 0..) |statement, position| {
        first_tokens[position] = tree.firstToken(statement);
        last_tokens[position] = tree.lastToken(statement);
        // Probing nested blocks fills their own entries first.
        const effect = analyzeOwnershipNode(
            source,
            tree,
            tokens,
            scope_index,
            statement,
            unnamed_probe_states,
            "",
            std.math.maxInt(usize),
            unnamed_allocation,
            summary_index,
            null,
            cache,
        );
        const exits = if (effect) |flow| flow.exiting else 0;
        passes[position] = if (effect) |flow|
            flow.continuing == unnamed_probe_states and flow.breaking == 0 and flow.repeating == 0 and
                exits & ~(unnamed_probe_states | ownership_safe) == 0
        else
            false;
        const returns = passes[position] and exits & unnamed_probe_states != 0;
        const fails = passes[position] and exits & ownership_safe != 0;
        returns_before[position + 1] = returns_before[position] + @intFromBool(returns);
        errors_before[position + 1] = errors_before[position] + @intFromBool(fails);
    }
    next_stop[count] = @intCast(count);
    var position = count;
    while (position > 0) {
        position -= 1;
        next_stop[position] = if (passes[position]) next_stop[position + 1] else @intCast(position);
    }
    const effects = try allocator.create(StatementEffects);
    effects.* = .{
        .first_tokens = first_tokens,
        .last_tokens = last_tokens,
        .next_stop = next_stop,
        .returns_before = returns_before,
        .errors_before = errors_before,
    };
    return effects;
}
