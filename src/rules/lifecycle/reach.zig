//! Whether a mutation of a container can affect a later use of a view into it.
//! Shared by the invalidation rules so they agree on what a "use after" is.

const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;

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
    if (after < tokens.len and isComparison(tokens[after].tag)) return true;
    return use > 0 and isComparison(tokens[use - 1].tag);
}

fn isComparison(tag: std.zig.Token.Tag) bool {
    return tag == .equal_equal or tag == .bang_equal;
}

/// The first use of `name` in `[start, end)` that the mutation at `mutation`
/// can affect; a reassignment or redeclaration of `name` ends the search.
pub fn firstReachedUse(context: RuleRun, name: []const u8, mutation: usize, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > start and context.tokens[index - 1].tag == .period) continue;
        if (!mutationReaches(context, mutation, index)) continue;
        if (index > start and (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var)) return null;
        if (index + 1 < end and context.tokens[index + 1].tag == .equal) return null;
        if (harmlessUse(context, index)) continue;
        return index;
    }
    return null;
}
