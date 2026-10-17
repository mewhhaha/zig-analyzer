//! Whether a mutation of a container can affect a later use of a view into it,
//! and whether a statement runs on every path through a block. Shared by the
//! lifecycle rules so they agree on what a "use after" and a "release before"
//! are.

const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const Syntax = @import("../context.zig").Syntax;
const types = @import("../types.zig");
const syntax_scope = @import("../../syntax/scope.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const Token = std.zig.Token;

/// The innermost block that holds both `first` and `second`.
pub fn commonBlock(scopes: *const syntax_scope.Index, first: usize, second: usize) ?usize {
    var opening = scopes.enclosingOpeningBrace(first);
    while (opening) |brace| : (opening = scopes.enclosingOpeningBrace(brace)) {
        const closing = scopes.matchingToken(brace) orelse return null;
        if (second > brace and second < closing) return brace;
    }
    return null;
}

/// Whether the statement holding `index` runs whenever control passes through
/// the block opened at `opening` up to it: no branch, prong, handler, defer or
/// nested declaration guards it on the way down. Loop bodies are taken to run.
pub fn runsWithin(tokens: []const Token, scopes: *const syntax_scope.Index, index: usize, opening: usize) bool {
    var cursor = index;
    while (true) {
        if (!statementReaches(tokens, cursor)) return false;
        const enclosing = scopes.enclosingOpeningBrace(cursor) orelse return false;
        if (enclosing == opening) return true;
        if (enclosing < opening) return false;
        cursor = enclosing;
    }
}

/// Whether the part of its statement before `index` always gets there.
fn statementReaches(tokens: []const Token, index: usize) bool {
    var start = tokens_util.statementStart(tokens, index);
    if (start + 1 < index and tokens[start].tag == .identifier and tokens[start + 1].tag == .colon) start += 2;
    if (start < index and tokens[start].tag == .keyword_inline) start += 1;
    if (start < index and (tokens[start].tag == .keyword_while or tokens[start].tag == .keyword_for)) return true;
    return unguarded(tokens, start, index);
}

/// Whether control at `start` always gets to `index`: nothing between them
/// branches, handles an error, defers or declares.
pub fn unguarded(tokens: []const Token, start: usize, index: usize) bool {
    for (tokens[start..index]) |token| switch (token.tag) {
        .keyword_if,
        .keyword_else,
        .keyword_switch,
        .equal_angle_bracket_right,
        .keyword_catch,
        .keyword_orelse,
        .keyword_and,
        .keyword_or,
        .keyword_while,
        .keyword_for,
        .keyword_defer,
        .keyword_errdefer,
        .keyword_suspend,
        .keyword_fn,
        .keyword_test,
        .keyword_struct,
        .keyword_union,
        .keyword_enum,
        .keyword_opaque,
        => return false,
        else => {},
    };
    return true;
}

/// The `)` closing the call whose method name sits at `method_index`.
pub fn callEnd(context: RuleRun, method_index: usize) ?usize {
    if (method_index + 1 >= context.tokens.len or context.tokens[method_index + 1].tag != .l_paren) return null;
    return context.matchingToken(method_index + 1, .l_paren, .r_paren);
}

/// The `defer` or `errdefer` keyword of the statement containing `index`, or
/// of the `defer { .. }` / `errdefer |err| { .. }` block around it.
pub fn deferKeyword(context: RuleRun, index: usize) ?usize {
    if (statementHead(context, index)) |head| if (isDefer(context, head)) return head;
    var opening = context.enclosingOpeningBrace(index);
    while (opening) |brace| {
        // `defer if (c) { .. }` and `errdefer |err| { .. }` head their block.
        if (statementHead(context, brace)) |head| if (isDefer(context, head)) return head;
        if (brace == 0) break;
        opening = context.enclosingOpeningBrace(brace - 1);
    }
    return null;
}

fn isDefer(context: RuleRun, index: usize) bool {
    return context.tokens[index].tag == .keyword_defer or context.tokens[index].tag == .keyword_errdefer;
}

/// First token of the statement that contains `index`.
fn statementHead(context: RuleRun, index: usize) ?usize {
    var cursor = index;
    while (cursor > 0) {
        switch (context.tokens[cursor - 1].tag) {
            .semicolon, .l_brace, .r_brace => break,
            else => cursor -= 1,
        }
    }
    return cursor;
}

/// True when a use at `use` can run after the mutation at `mutation`. Control
/// flow decides: a mutation whose own block returns afterwards never reaches
/// uses outside that block, and neither a mutation in an `if` branch nor one
/// in a `switch` prong reaches the sibling branches.
pub fn mutationReaches(context: RuleRun, mutation: usize, use: usize) bool {
    // A mutation deferred to scope exit runs after every later statement.
    if (deferKeyword(context, mutation)) |keyword| {
        if (use < keyword or use > (context.statementEnd(keyword) orelse keyword)) return false;
    }
    var opening = context.enclosingOpeningBrace(mutation) orelse return true;
    var exclusive_parent = false;
    while (true) {
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse return true;
        if (use < closing) return !exclusive_parent;
        if (leavesFunctionAfter(context, mutation, opening, closing)) return false;
        if (closing + 1 < context.tokens.len and context.tokens[closing + 1].tag == .keyword_else) {
            const else_end = elseChainEnd(context, closing + 1) orelse return true;
            if (use <= else_end) return false;
        }
        exclusive_parent = opening > 0 and context.tokens[opening - 1].tag == .equal_angle_bracket_right;
        if (opening == 0) return true;
        opening = context.enclosingOpeningBrace(opening - 1) orelse return true;
    }
}

/// The last token of the `else` branch (and further `else if` branches)
/// starting at `else_index`.
fn elseChainEnd(context: RuleRun, else_index: usize) ?usize {
    var cursor = else_index + 1;
    while (cursor < context.tokens.len) {
        if (context.tokens[cursor].tag == .keyword_if) {
            if (cursor + 1 >= context.tokens.len or context.tokens[cursor + 1].tag != .l_paren) return null;
            cursor = (context.matchingToken(cursor + 1, .l_paren, .r_paren) orelse return null) + 1;
        }
        if (cursor < context.tokens.len and context.tokens[cursor].tag == .pipe) {
            cursor += 1;
            while (cursor < context.tokens.len and context.tokens[cursor].tag != .pipe) : (cursor += 1) {}
            cursor += 1;
        }
        if (cursor >= context.tokens.len) return null;
        const branch_end = if (context.tokens[cursor].tag == .l_brace)
            context.matchingToken(cursor, .l_brace, .r_brace) orelse return null
        else
            context.statementEnd(cursor) orelse return null;
        if (branch_end + 1 < context.tokens.len and context.tokens[branch_end + 1].tag == .keyword_else) {
            cursor = branch_end + 2;
            continue;
        }
        return branch_end;
    }
    return null;
}

fn leavesFunctionAfter(context: RuleRun, mutation: usize, opening: usize, closing: usize) bool {
    const statement_end = context.statementEnd(mutation) orelse return false;
    if (statement_end >= closing) return false;
    for (context.tokens[statement_end + 1 .. closing], statement_end + 1..) |token, index| {
        if (token.tag != .keyword_return and token.tag != .keyword_unreachable) continue;
        if (context.enclosingOpeningBrace(index) != opening) continue;
        switch (context.tokens[index - 1].tag) {
            .semicolon, .l_brace, .r_brace => return true,
            else => {},
        }
    }
    return false;
}

/// Reads that cannot touch a dangling view: comparing the pointer value and
/// reading the length of a slice header already copied.
pub fn harmlessUse(context: RuleRun, use: usize) bool {
    const tokens = context.tokens;
    var after = use + 1;
    if (after + 1 < tokens.len and tokens[after].tag == .period and tokens[after + 1].tag == .identifier) {
        if (context.tokenIs(after + 1, "len")) return true;
        if (!context.tokenIs(after + 1, "ptr")) return false;
        after += 2;
    }
    if (after < tokens.len and isEquality(tokens[after].tag)) return true;
    return use > 0 and isEquality(tokens[use - 1].tag);
}

fn isEquality(tag: std.zig.Token.Tag) bool {
    return tag == .equal_equal or tag == .bang_equal;
}

/// The first use of `name` in `[start, end)` that the mutation at `mutation`
/// can affect; a reassignment or redeclaration of `name` ends the search.
/// `identifiers` is the file's table, which lists the identifiers spelled `name`.
pub fn firstReachedUse(
    context: RuleRun,
    identifiers: *const syntax_scope.IdentifierTable,
    name: []const u8,
    mutation: usize,
    start: usize,
    end: usize,
) ?usize {
    for (identifiers.within(name, start, end)) |position| {
        const index: usize = position;
        if (index > start and context.tokens[index - 1].tag == .period) continue;
        if (!mutationReaches(context, mutation, index)) continue;
        if (index > start and (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var)) return null;
        if (index + 1 < end and context.tokens[index + 1].tag == .equal) return null;
        if (harmlessUse(context, index)) continue;
        return index;
    }
    return null;
}

/// The last mention of `name` in `[start, end)`, or `start` when there is
/// none: a mutation at or after it ends after every mention, so
/// `firstReachedUse` finds no use after it.
pub fn lastMention(identifiers: *const syntax_scope.IdentifierTable, name: []const u8, start: usize, end: usize) usize {
    const mentions = identifiers.within(name, start, end);
    return if (mentions.len == 0) start else mentions[mentions.len - 1];
}

/// A `RuleRun` over `source` whose inputs live in `arena`.
fn testRun(arena: std.mem.Allocator, source: [:0]const u8) !RuleRun {
    const tokens = try tokens_util.tokenize(arena, source);
    const syntax = try arena.create(Syntax);
    syntax.* = try Syntax.init(arena, source, tokens);
    const found = try arena.create(std.ArrayList(types.Finding));
    found.* = .empty;
    return syntax.ruleRun(arena, types.Configuration.defaults(), found);
}

/// The `occurrence`-th token spelled `text`.
fn at(context: RuleRun, text: []const u8, occurrence: usize) usize {
    var seen: usize = 0;
    for (0..context.tokens.len) |index| {
        if (!std.mem.eql(u8, context.tokenText(index), text)) continue;
        if (seen == occurrence) return index;
        seen += 1;
    }
    unreachable;
}

test "commonBlock is the innermost block holding both tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const context = try testRun(arena.allocator(), "fn f() void { { a(); b(); } c(); }");
    const body = at(context, "{", 0);
    const inner = at(context, "{", 1);
    try std.testing.expectEqual(@as(?usize, inner), commonBlock(context.scopes, at(context, "a", 0), at(context, "b", 0)));
    try std.testing.expectEqual(@as(?usize, body), commonBlock(context.scopes, at(context, "a", 0), at(context, "c", 0)));
    try std.testing.expectEqual(@as(?usize, null), commonBlock(context.scopes, at(context, "fn", 0), at(context, "a", 0)));
}

test "runsWithin follows loop bodies but not branches, defers or nested declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const context = try testRun(arena.allocator(),
        \\fn f(c: bool) void {
        \\    a();
        \\    if (c) { b(); }
        \\    while (c) { d(); }
        \\    defer e();
        \\    const g = struct { fn h() void { i(); } };
        \\}
    );
    const body = at(context, "{", 0);
    try std.testing.expect(runsWithin(context.tokens, context.scopes, at(context, "a", 0), body));
    try std.testing.expect(!runsWithin(context.tokens, context.scopes, at(context, "b", 0), body));
    try std.testing.expect(runsWithin(context.tokens, context.scopes, at(context, "d", 0), body));
    try std.testing.expect(!runsWithin(context.tokens, context.scopes, at(context, "e", 0), body));
    try std.testing.expect(!runsWithin(context.tokens, context.scopes, at(context, "i", 0), body));
}

test "unguarded rejects a range that branches or handles an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const context = try testRun(arena.allocator(), "fn f() void { a(); b(); c() catch {}; d(); if (x) e(); }");
    try std.testing.expect(unguarded(context.tokens, at(context, "a", 0), at(context, "b", 0)));
    try std.testing.expect(!unguarded(context.tokens, at(context, "c", 0), at(context, "d", 0)));
    try std.testing.expect(!unguarded(context.tokens, at(context, "d", 0), at(context, "e", 0)));
}

test "callEnd is the parenthesis that closes a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const context = try testRun(arena.allocator(), "fn f() void { list.append(g(1), 2); _ = list.items; }");
    try std.testing.expectEqual(@as(?usize, at(context, ")", 2)), callEnd(context, at(context, "append", 0)));
    try std.testing.expectEqual(@as(?usize, null), callEnd(context, at(context, "items", 0)));
}

test "deferKeyword finds the defer of a statement or of the block around it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const context = try testRun(arena.allocator(), "fn f() !void { defer list.deinit(); errdefer |err| { log(err); } work(); }");
    try std.testing.expectEqual(@as(?usize, at(context, "defer", 0)), deferKeyword(context, at(context, "deinit", 0)));
    try std.testing.expectEqual(@as(?usize, at(context, "errdefer", 0)), deferKeyword(context, at(context, "log", 0)));
    try std.testing.expectEqual(@as(?usize, null), deferKeyword(context, at(context, "work", 0)));
}

test "mutationReaches stops at a return, a sibling branch or prong, and a deferred mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const context = try testRun(arena.allocator(),
        \\fn f(list: *List, c: bool, n: u8) void {
        \\    list.append(0);
        \\    use(view);
        \\    if (c) {
        \\        list.append(1);
        \\        return;
        \\    }
        \\    use(view);
        \\    if (c) {
        \\        list.append(2);
        \\    } else {
        \\        use(view);
        \\    }
        \\    switch (n) {
        \\        0 => {
        \\            list.append(3);
        \\        },
        \\        else => {
        \\            use(view);
        \\        },
        \\    }
        \\    defer list.append(4);
        \\    use(view);
        \\}
    );
    try std.testing.expect(mutationReaches(context, at(context, "append", 0), at(context, "view", 0)));
    try std.testing.expect(!mutationReaches(context, at(context, "append", 1), at(context, "view", 1)));
    try std.testing.expect(!mutationReaches(context, at(context, "append", 2), at(context, "view", 2)));
    try std.testing.expect(mutationReaches(context, at(context, "append", 2), at(context, "view", 4)));
    try std.testing.expect(!mutationReaches(context, at(context, "append", 3), at(context, "view", 3)));
    try std.testing.expect(!mutationReaches(context, at(context, "append", 4), at(context, "view", 4)));
}

test "harmlessUse accepts length reads and pointer comparisons only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const context = try testRun(
        arena.allocator(),
        "fn f() void { _ = view.len; _ = view.ptr == other; _ = other != view; _ = view == other; _ = view[0]; _ = view.ptr[0]; _ = view.items; }",
    );
    for ([_]bool{ true, true, true, true, false, false, false }, 0..) |harmless, occurrence| {
        try std.testing.expectEqual(harmless, harmlessUse(context, at(context, "view", occurrence)));
    }
}

test "firstReachedUse skips harmless and field uses and stops at a reassignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const context = try testRun(arena.allocator(),
        \\fn f(list: *List, other: Other) void {
        \\    var view = list.items;
        \\    list.append(1);
        \\    _ = other.view;
        \\    _ = view.len;
        \\    _ = view[0];
        \\    view = list.items;
        \\    _ = view[1];
        \\}
    );
    const identifiers = try context.scopes.identifiers();
    const mutation = at(context, "append", 0);
    const body_end = context.scopes.matchingToken(at(context, "{", 0)).?;
    try std.testing.expectEqual(@as(?usize, at(context, "view", 3)), firstReachedUse(context, identifiers, "view", mutation, mutation, body_end));
    try std.testing.expectEqual(@as(?usize, null), firstReachedUse(context, identifiers, "view", mutation, at(context, "view", 3) + 1, body_end));
}

test "lastMention is the last mention in the range or its start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const context = try testRun(arena.allocator(), "fn f() void { a(view); b(view); c(); }");
    const identifiers = try context.scopes.identifiers();
    const body = at(context, "{", 0);
    const body_end = context.scopes.matchingToken(body).?;
    try std.testing.expectEqual(at(context, "view", 1), lastMention(identifiers, "view", body, body_end));
    try std.testing.expectEqual(at(context, "view", 0), lastMention(identifiers, "view", body, at(context, "b", 0)));
    try std.testing.expectEqual(body, lastMention(identifiers, "missing", body, body_end));
}
