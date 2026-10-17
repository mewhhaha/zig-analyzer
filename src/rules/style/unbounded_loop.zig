//! `while` loops whose condition and body state no iteration bound or exhaustion.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;
const syntax_scope = @import("../../syntax/scope.zig");

pub const rules = [_]types.Rule{.unbounded_loop};

pub fn run(context: RuleRun) !void {
    const level = context.level(.unbounded_loop);
    if (level == .off) return;
    var test_only: ?syntax_scope.TestOnlyBodies = null;
    defer if (test_only) |*bodies| bodies.deinit(context.allocator);
    for (context.tokens, 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 2 >= context.tokens.len or context.tokens[while_index + 1].tag != .l_paren) continue;
        if (context.scopes.insideTestBlock(while_index)) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        const condition = context.source[context.tokens[while_index + 2].loc.start..context.tokens[condition_end - 1].loc.end];
        const body_open = context.whileBodyOpening(condition_end) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (std.mem.findAny(u8, condition, "<>") != null or
            conditionRepeatsStep(context, while_index + 2, condition_end, body_open, body_end) or
            conditionDrainsLength(context, while_index + 2, condition_end) or
            conditionAwaitsEnd(context, while_index + 2, condition_end) or
            conditionStatesExhaustion(context, while_index + 2, condition_end, body_open, body_end) or
            optionalCaptureStatesExhaustion(context, while_index + 2, condition_end, body_open, body_end) or
            equalityConditionHasUpdate(context, while_index + 2, condition_end, body_open, body_end) or
            callConditionHasUpdate(context, while_index + 2, condition_end, body_open, body_end) or
            bodyHasExhaustionExit(context, body_open + 1, body_end) or
            bodyHasBoundAssertion(context, while_index + 2, condition_end, body_open + 1, body_end) or
            bodyHasExhaustionPredicate(context, body_open + 1, body_end) or
            bodyDrainsCollection(context, body_open + 1, body_end) or
            bodyRetriesSystemCall(context, while_index, body_open, body_end)) continue;
        if (eventLoopHasBlockingDispatch(context, body_open + 1, body_end)) continue;
        if (bodyHasCounterGuard(context, body_open + 1, body_end) or
            bodyHasDerivedCounterGuard(context, body_open + 1, body_end)) continue;
        if (test_only == null) test_only = try syntax_scope.testOnlyBodies(context.allocator, context.source, context.tokens);
        if (test_only.?.contains(while_index)) continue;
        try context.emit(.{
            .rule = .unbounded_loop,
            .level = level,
            .span = token.loc,
            .message = "loop has no statically visible iteration bound; state a maximum and handle exhaustion explicitly",
        });
    }
}

/// `while (queue.items.len != 0)` drains a collection as `> 0` does.
fn conditionDrainsLength(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .bang_equal or index < start + 2 or index + 1 >= end) continue;
        if (context.tokenIs(index - 1, "len") and context.tokens[index - 2].tag == .period and
            context.tokenIs(index + 1, "0")) return true;
        if (index + 3 < end and context.tokenIs(index - 1, "0") and context.tokens[index + 2].tag == .period and
            context.tokenIs(index + 3, "len")) return true;
    }
    return false;
}

/// A condition naming the `.eof` tag consumes a token or byte stream until
/// it is exhausted, as `while (!parser.at(.eof))` does.
fn conditionAwaitsEnd(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .period or index + 1 >= end or !context.tokenIs(index + 1, "eof")) continue;
        if (index == start) return true;
        switch (context.tokens[index - 1].tag) {
            .identifier, .r_paren, .r_bracket => {},
            else => return true,
        }
    }
    return false;
}

fn bodyDrainsCollection(context: RuleRun, start: usize, end: usize) bool {
    if (!rangeCanExitLoop(context.tokens, start, end)) return false;
    var continues = false;
    for (context.tokens[start..end]) |token| if (token.tag == .keyword_continue) {
        continues = true;
        break;
    };
    if (!continues) return false;
    return bodyCalls(context, start, end, "swapRemove") or bodyCalls(context, start, end, "orderedRemove");
}

fn bodyHasBoundAssertion(context: RuleRun, condition_start: usize, condition_end: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren or
            (!context.tokenIs(index, "assert") and !context.tokenIs(index, "expect"))) continue;
        const call_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end > end) continue;
        if (hasOrderingComparison(context.tokens[index + 2 .. call_end])) return true;
        if (hasEqualityComparison(context.tokens[index + 2 .. call_end]) and
            rangesShareConditionVariable(context, condition_start, condition_end, index + 2, call_end)) return true;
    }
    return false;
}

fn bodyHasCounterGuard(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_if or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end >= end or !hasBoundComparison(context.tokens[index + 2 .. condition_end])) continue;
        var branch_start = condition_end + 1;
        if (context.tokens[branch_start].tag == .pipe) {
            branch_start = nextTagBefore(context.tokens, branch_start + 1, .pipe, .semicolon) orelse continue;
            branch_start += 1;
        }
        const branch_end = if (context.tokens[branch_start].tag == .l_brace)
            context.matchingToken(branch_start, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(branch_start) orelse continue;
        if (rangeCanExitLoop(context.tokens, branch_start, branch_end)) return true;
    }
    return false;
}

fn bodyHasDerivedCounterGuard(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, declaration| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration + 3 >= end or
            context.tokens[declaration + 1].tag != .identifier or context.tokens[declaration + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration) orelse continue;
        if (declaration_end >= end or !hasBoundComparison(context.tokens[declaration + 3 .. declaration_end])) continue;
        const name = context.tokenText(declaration + 1);
        for (context.tokens[declaration_end + 1 .. end], declaration_end + 1..) |candidate, if_index| {
            if (candidate.tag != .keyword_if or if_index + 3 >= end or context.tokens[if_index + 1].tag != .l_paren or
                !context.tokenIs(if_index + 2, name) or context.tokens[if_index + 3].tag != .r_paren) continue;
            const branch_start = if_index + 4;
            if (branch_start >= end) continue;
            const branch_end = if (context.tokens[branch_start].tag == .l_brace)
                context.matchingToken(branch_start, .l_brace, .r_brace) orelse continue
            else
                context.statementEnd(branch_start) orelse continue;
            if (branch_end <= end and rangeCanExitLoop(context.tokens, branch_start, branch_end)) return true;
        }
    }
    return false;
}

fn bodyHasExhaustionExit(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_orelse) continue;
        var branch_start = index + 1;
        if (branch_start >= end) continue;
        if (context.tokens[branch_start].tag == .pipe) {
            branch_start = nextTagBefore(context.tokens, branch_start + 1, .pipe, .semicolon) orelse continue;
            branch_start += 1;
        }
        if (branch_start >= end) continue;
        if (context.tokens[branch_start].tag == .keyword_break or context.tokens[branch_start].tag == .keyword_return) return true;
        const branch_end = if (context.tokens[branch_start].tag == .l_brace)
            context.matchingToken(branch_start, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(branch_start) orelse continue;
        if (branch_end <= end and rangeCanExitLoop(context.tokens, branch_start + 1, branch_end)) return true;
    }
    return false;
}

fn bodyHasExhaustionPredicate(context: RuleRun, start: usize, end: usize) bool {
    if (!rangeCanExitLoop(context.tokens, start, end)) return false;
    return bodyCalls(context, start, end, "eof") or
        bodyCalls(context, start, end, "takeDelimiterExclusive") or
        bodyCalls(context, start, end, "streamDelimiterEnding");
}

/// `while (try ops[0].toLea(cg)) {}` repeats a fallible step that reports
/// whether it changed anything, so the step itself is the progress.
fn conditionRepeatsStep(context: RuleRun, condition_start: usize, condition_end: usize, body_open: usize, body_end: usize) bool {
    if (body_open != condition_end + 1 or body_end != body_open + 1) return false;
    var cursor = condition_start;
    while (cursor < condition_end) {
        if (context.tokens[cursor].tag != .keyword_try) return false;
        cursor += 1;
        // The called path, `ops[0].toLea`, then its arguments.
        var called = false;
        while (cursor < condition_end) : (cursor += 1) switch (context.tokens[cursor].tag) {
            .identifier, .period => called = false,
            .l_bracket, .l_paren => |tag| {
                cursor = context.scopes.matchingToken(cursor) orelse return false;
                called = tag == .l_paren;
            },
            else => break,
        };
        if (!called) return false;
        if (cursor == condition_end) return true;
        if (context.tokens[cursor].tag != .keyword_or) return false;
        cursor += 1;
    }
    return false;
}

/// How deep `branchExits` follows nested blocks, `if`s and `switch`es.
const exit_depth = 4;

/// A system call retried while it reports an interruption: every `continue`
/// of the loop retries (see `retryContinue`), at least one path retries, and
/// the body leaves the loop on every other path, because one of its
/// statements returns or breaks, or is a `switch` or `if`-`else` whose
/// branches all do except the prongs that retry, as
/// `while (true) switch (errno(rc)) { .SUCCESS => return, .INTR => {}, else => return error.Unexpected }`
/// and `while (true) { const rc = waitpid(pid); if (errno(rc) == .INTR) continue; break rc; }` do.
fn bodyRetriesSystemCall(context: RuleRun, while_index: usize, body_open: usize, body_end: usize) bool {
    var leaves = false;
    var retries = false;
    var previous: std.zig.Token.Tag = .l_brace;
    var cursor = body_open + 1;
    while (cursor < body_end) : (cursor += 1) {
        const tag = context.tokens[cursor].tag;
        if (startsStatement(previous)) switch (tag) {
            .keyword_return, .keyword_break, .keyword_unreachable => leaves = true,
            .keyword_switch => if (switchExits(context, cursor, exit_depth, &retries)) {
                leaves = true;
            },
            .keyword_if => if (ifExits(context, cursor, body_end, exit_depth, &retries)) {
                leaves = true;
            },
            else => {},
        };
        switch (tag) {
            .l_brace, .l_paren, .l_bracket => cursor = context.scopes.matchingToken(cursor) orelse return false,
            else => {},
        }
        previous = context.tokens[cursor].tag;
    }
    if (!leaves) return false;
    const label: ?[]const u8 = if (while_index >= 2 and context.tokens[while_index - 1].tag == .colon and
        context.tokens[while_index - 2].tag == .identifier) context.tokenText(while_index - 2) else null;
    for (context.tokens[body_open + 1 .. body_end], body_open + 1..) |token, index| {
        if (token.tag != .keyword_continue) continue;
        if (index + 2 < body_end and context.tokens[index + 1].tag == .colon) {
            // A labeled `continue` repeats this loop only when it names it.
            const own = if (label) |name| context.tokenIs(index + 2, name) else false;
            if (!own) continue;
        } else if (insideInnerLoop(context, index, body_open)) continue;
        if (!retryContinue(context, index, body_open)) return false;
        retries = true;
    }
    return retries;
}

fn startsStatement(previous: std.zig.Token.Tag) bool {
    return previous == .l_brace or previous == .semicolon or previous == .r_brace;
}

/// A prong for `.INTR` or `.AGAIN`, or one that checks for cancellation
/// before trying again.
fn retryProng(context: RuleRun, prong: Prongs.Prong) bool {
    return namesRetryCode(context, prong.start, prong.arrow) or bodyCalls(context, prong.arrow + 1, prong.end, "checkCancel");
}

fn namesRetryCode(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index == start or context.tokens[index - 1].tag != .period) continue;
        if (context.tokenIs(index, "INTR") or context.tokenIs(index, "AGAIN")) return true;
    }
    return false;
}

/// Whether the `continue` at `index` retries an interrupted call: it lies in
/// the body of a retrying prong (`.INTR => continue`) or of an `if` testing
/// for `.INTR` or `.AGAIN`.
fn retryContinue(context: RuleRun, index: usize, body_open: usize) bool {
    switch (context.tokens[index - 1].tag) {
        .equal_angle_bracket_right, .r_paren => if (retryBranch(context, index)) return true,
        else => {},
    }
    var brace = context.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening <= body_open) return false;
        if (retryBranch(context, opening)) return true;
    }
    return false;
}

/// Whether the branch starting at `branch` is the body of a retrying prong
/// or of an `if` testing for `.INTR` or `.AGAIN`.
fn retryBranch(context: RuleRun, branch: usize) bool {
    const tokens = context.tokens;
    const before = branch - 1;
    switch (tokens[before].tag) {
        .equal_angle_bracket_right => {
            const switch_open = context.enclosingOpeningBrace(before) orelse return false;
            if (switch_open < 2 or tokens[switch_open - 1].tag != .r_paren) return false;
            const operand_open = context.scopes.matchingToken(switch_open - 1) orelse return false;
            if (operand_open == 0 or tokens[operand_open - 1].tag != .keyword_switch) return false;
            var prongs = Prongs.init(context, operand_open - 1) orelse return false;
            while (prongs.next()) |prong| {
                if (prong.arrow == before) return retryProng(context, prong);
            }
            return false;
        },
        .r_paren => {
            const condition_open = context.scopes.matchingToken(before) orelse return false;
            if (condition_open == 0 or tokens[condition_open - 1].tag != .keyword_if) return false;
            return namesRetryCode(context, condition_open + 1, before);
        },
        else => return false,
    }
}

/// The prongs of a `switch`, each as its items, `=>` and the end of its body
/// (the separating `,` or the closing brace).
const Prongs = struct {
    context: RuleRun,
    cursor: usize,
    close: usize,
    /// Set when a prong has no `=>`, as in code that does not parse.
    malformed: bool = false,

    const Prong = struct { start: usize, arrow: usize, end: usize };

    fn init(context: RuleRun, switch_index: usize) ?Prongs {
        const tokens = context.tokens;
        if (switch_index + 1 >= tokens.len or tokens[switch_index + 1].tag != .l_paren) return null;
        const operand_end = context.scopes.matchingToken(switch_index + 1) orelse return null;
        if (operand_end + 1 >= tokens.len or tokens[operand_end + 1].tag != .l_brace) return null;
        const close = context.scopes.matchingToken(operand_end + 1) orelse return null;
        return .{ .context = context, .cursor = operand_end + 2, .close = close };
    }

    fn next(prongs: *Prongs) ?Prong {
        if (prongs.cursor >= prongs.close) return null;
        const start = prongs.cursor;
        const arrow = topLevelTag(prongs.context, start, prongs.close, .equal_angle_bracket_right) orelse {
            prongs.malformed = true;
            prongs.cursor = prongs.close;
            return null;
        };
        const end = topLevelTag(prongs.context, arrow + 1, prongs.close, .comma) orelse prongs.close;
        prongs.cursor = end + 1;
        return .{ .start = start, .arrow = arrow, .end = end };
    }
};

/// The first `tag` token in `[start, end)` outside nested brackets, stopping
/// at a `;`.
fn topLevelTag(context: RuleRun, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    var cursor = start;
    while (cursor < end) : (cursor += 1) {
        const current = context.tokens[cursor].tag;
        if (current == tag) return cursor;
        switch (current) {
            .l_brace, .l_paren, .l_bracket => cursor = context.scopes.matchingToken(cursor) orelse return null,
            .semicolon => return null,
            else => {},
        }
    }
    return null;
}

/// Whether the branch in `[start, end)` always leaves the loop: it returns,
/// breaks, is unreachable, panics, or is a block, `if`-`else` or `switch`
/// whose every path does. With `retries`, a `switch` prong that retries an
/// interrupted call (see `retryProng`) is accepted too and sets it. `depth`
/// bounds how far nested branches are followed.
fn branchExits(context: RuleRun, start: usize, end: usize, depth: u8, retries: ?*bool) bool {
    var cursor = start;
    if (cursor < end and context.tokens[cursor].tag == .pipe) {
        cursor = (nextTagBefore(context.tokens, cursor + 1, .pipe, .semicolon) orelse return false) + 1;
    }
    if (cursor >= end) return false;
    return switch (context.tokens[cursor].tag) {
        .keyword_return, .keyword_break, .keyword_unreachable => true,
        .builtin => context.tokenIs(cursor, "@panic") or context.tokenIs(cursor, "@trap"),
        .keyword_switch => depth > 0 and switchExits(context, cursor, depth - 1, retries),
        .keyword_if => depth > 0 and ifExits(context, cursor, end, depth - 1, retries),
        .l_brace => depth > 0 and blockExits(context, cursor, depth - 1, retries),
        else => false,
    };
}

/// Whether every prong of the `switch` at `switch_index` leaves the loop or,
/// with `retries`, retries. The other prongs must leave it for good.
fn switchExits(context: RuleRun, switch_index: usize, depth: u8, retries: ?*bool) bool {
    var prongs = Prongs.init(context, switch_index) orelse return false;
    var retrying = false;
    while (prongs.next()) |prong| {
        if (retries != null and retryProng(context, prong)) {
            retrying = true;
        } else if (!branchExits(context, prong.arrow + 1, prong.end, depth, null)) return false;
    }
    if (prongs.malformed) return false;
    if (retrying) retries.?.* = true;
    return true;
}

/// Whether both branches of the `if` at `if_index`, which ends before `end`,
/// leave the loop.
fn ifExits(context: RuleRun, if_index: usize, end: usize, depth: u8, retries: ?*bool) bool {
    const tokens = context.tokens;
    if (if_index + 1 >= end or tokens[if_index + 1].tag != .l_paren) return false;
    var then_start = (context.scopes.matchingToken(if_index + 1) orelse return false) + 1;
    if (then_start < end and tokens[then_start].tag == .pipe) {
        then_start = (nextTagBefore(tokens, then_start + 1, .pipe, .semicolon) orelse return false) + 1;
    }
    if (then_start >= end) return false;
    const else_index = if (tokens[then_start].tag == .l_brace)
        (context.scopes.matchingToken(then_start) orelse return false) + 1
    else
        topLevelTag(context, then_start, end, .keyword_else) orelse return false;
    if (else_index >= end or tokens[else_index].tag != .keyword_else) return false;
    return branchExits(context, then_start, else_index, depth, retries) and
        branchExits(context, else_index + 1, end, depth, retries);
}

/// Whether a statement of the block at `open` always leaves the loop.
fn blockExits(context: RuleRun, open: usize, depth: u8, retries: ?*bool) bool {
    const close = context.scopes.matchingToken(open) orelse return false;
    var previous: std.zig.Token.Tag = .l_brace;
    var cursor = open + 1;
    while (cursor < close) : (cursor += 1) {
        const tag = context.tokens[cursor].tag;
        if (startsStatement(previous)) switch (tag) {
            .keyword_return, .keyword_break, .keyword_unreachable => return true,
            .keyword_switch => if (switchExits(context, cursor, depth, retries)) return true,
            .keyword_if => if (ifExits(context, cursor, close, depth, retries)) return true,
            .builtin => if (context.tokenIs(cursor, "@panic") or context.tokenIs(cursor, "@trap")) return true,
            else => {},
        };
        switch (tag) {
            .l_brace, .l_paren, .l_bracket => cursor = context.scopes.matchingToken(cursor) orelse return false,
            else => {},
        }
        previous = context.tokens[cursor].tag;
    }
    return false;
}

/// Whether the body of a loop nested in the body at `body_open` encloses `index`.
fn insideInnerLoop(context: RuleRun, index: usize, body_open: usize) bool {
    var brace = context.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening <= body_open) return false;
        if (context.loopKeyword(opening) != null) return true;
    }
    return false;
}

fn callConditionHasUpdate(
    context: RuleRun,
    condition_start: usize,
    condition_end: usize,
    body_open: usize,
    body_end: usize,
) bool {
    var has_call = false;
    for (context.tokens[condition_start..condition_end], condition_start..) |token, index| {
        if ((token.tag == .identifier or token.tag == .builtin) and index + 1 < condition_end and
            context.tokens[index + 1].tag == .l_paren)
        {
            has_call = true;
            break;
        }
    }
    return has_call and conditionVariableUpdated(context, condition_start, condition_end, body_open + 1, body_end);
}

fn conditionStatesExhaustion(context: RuleRun, start: usize, end: usize, body_open: usize, body_end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const name = context.tokenText(index);
        if (std.mem.eql(u8, name, "next") or std.mem.endsWith(u8, name, "_next") or
            consumingNextCall(name) or std.mem.eql(u8, name, "iteration")) return true;
        if (std.mem.eql(u8, name, "isClosed") or std.mem.eql(u8, name, "isRunning") or
            std.mem.eql(u8, name, "shouldStop") or std.mem.eql(u8, name, "isShutdown")) return true;
        if (std.mem.eql(u8, name, "eof") and bodyCalls(context, body_open + 1, body_end, "advance")) return true;
    }
    return false;
}

fn equalityConditionHasUpdate(
    context: RuleRun,
    condition_start: usize,
    condition_end: usize,
    body_open: usize,
    body_end: usize,
) bool {
    var has_equality = false;
    for (context.tokens[condition_start..condition_end]) |token| {
        if (token.tag == .equal_equal or token.tag == .bang_equal) {
            has_equality = true;
            break;
        }
    }
    if (!has_equality) return false;
    if (condition_end + 2 < body_open and context.tokens[condition_end + 1].tag == .colon and
        conditionVariableUpdated(context, condition_start, condition_end, condition_end + 2, body_open)) return true;
    return conditionVariableUpdated(context, condition_start, condition_end, body_open + 1, body_end);
}

fn eventLoopHasBlockingDispatch(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        if (context.tokenIs(index, "wait") or context.tokenIs(index, "run") or context.tokenIs(index, "dispatch") or
            context.tokenIs(index, "accept") or context.tokenIs(index, "pollEvent")) return true;
    }
    return false;
}

fn optionalCaptureStatesExhaustion(
    context: RuleRun,
    condition_start: usize,
    condition_end: usize,
    body_open: usize,
    body_end: usize,
) bool {
    if (condition_end + 2 >= body_open or context.tokens[condition_end + 1].tag != .pipe) return false;
    const capture_end = nextTagBefore(context.tokens, condition_end + 2, .pipe, .semicolon) orelse return false;
    if (capture_end >= body_open) return false;

    for (context.tokens[condition_start..condition_end], condition_start..) |token, index| {
        if ((token.tag == .identifier or token.tag == .builtin) and index + 1 < condition_end and
            context.tokens[index + 1].tag == .l_paren) return true;
    }

    return conditionVariableUpdated(context, condition_start, condition_end, capture_end + 1, body_open) or
        conditionVariableUpdated(context, condition_start, condition_end, body_open + 1, body_end);
}

fn bodyCalls(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index + 1 < end and
            context.tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

fn rangeCanExitLoop(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| if (token.tag == .keyword_break or token.tag == .keyword_return) return true;
    return false;
}

fn hasEqualityComparison(tokens: []const std.zig.Token) bool {
    for (tokens) |token| if (token.tag == .equal_equal or token.tag == .bang_equal) return true;
    return false;
}

fn hasOrderingComparison(tokens: []const std.zig.Token) bool {
    for (tokens) |token| switch (token.tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        => return true,
        else => {},
    };
    return false;
}

fn rangesShareConditionVariable(context: RuleRun, left_start: usize, left_end: usize, right_start: usize, right_end: usize) bool {
    for (context.tokens[left_start..left_end], left_start..) |left, left_index| {
        if (left.tag != .identifier or context.tokenIs(left_index, "true") or context.tokenIs(left_index, "false")) continue;
        for (context.tokens[right_start..right_end], right_start..) |right, right_index| {
            if (right.tag == .identifier and context.tokenIs(right_index, context.tokenText(left_index))) return true;
        }
    }
    return false;
}

fn hasBoundComparison(tokens: []const std.zig.Token) bool {
    for (tokens) |token| switch (token.tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .equal_equal,
        => return true,
        else => {},
    };
    return false;
}

fn conditionVariableUpdated(context: RuleRun, condition_start: usize, condition_end: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, operator_index| {
        if (!isAssignmentOperator(token.tag) or operator_index == start or context.tokens[operator_index - 1].tag != .identifier) continue;
        const assigned_path_start = context.pathStartBefore(operator_index) orelse continue;
        if (dottedPathOccurs(context, assigned_path_start, operator_index, condition_start, condition_end)) return true;
        if (assigned_path_start != operator_index - 1) continue;
        for (context.tokens[condition_start..condition_end], condition_start..) |condition_token, condition_index| {
            if (condition_token.tag == .identifier and
                (condition_index == condition_start or context.tokens[condition_index - 1].tag != .period) and
                context.tokenIs(condition_index, context.tokenText(operator_index - 1))) return true;
        }
    }
    return false;
}

fn consumingNextCall(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, "Next")) return false;
    const verbs = [_][]const u8{ "consume", "parse", "poll", "process", "read", "remove", "run", "take" };
    for (verbs) |verb| if (std.mem.startsWith(u8, name, verb)) return true;
    return false;
}

fn dottedPathOccurs(context: RuleRun, path_start: usize, path_end: usize, start: usize, end: usize) bool {
    const path_length = path_end - path_start;
    if (path_length == 0 or path_length > end - start) return false;
    var candidate = start;
    while (candidate + path_length <= end) : (candidate += 1) {
        if (context.dottedPathsEqual(path_start, path_end, candidate, candidate + path_length)) return true;
    }
    return false;
}

fn isAssignmentOperator(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal,
        .plus_equal,
        .minus_equal,
        .asterisk_equal,
        .slash_equal,
        .percent_equal,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_right_equal,
        .ampersand_equal,
        .caret_equal,
        .pipe_equal,
        => true,
        else => false,
    };
}

test "a queue pop loop states exhaustion through its optional capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn drain(mailbox: *Mailbox) void {\n" ++
        "while (mailbox.pop()) |message| {\n" ++
        "consume(message);\n" ++
        "}\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "optional-producing calls state exhaustion through their captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn decode(iterator: *Iterator) !void {\n" ++
        "while (iterator.nextCodepoint()) |codepoint| consume(codepoint);\n" ++
        "while (try parseOneItem(iterator)) |value| consume(value);\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "boolean next calls and orelse exits state iterator exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn visit(iterator: *Iterator) !void {\n" ++
        "while (iterator.next()) { consume(iterator.value()); }\n" ++
        "while (placement_iterator_next(iterator)) { consume(iterator.value()); }\n" ++
        "while (true) { const value = (try iterator.nextValue()) orelse break; consume(value); }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "consuming camel case next calls state exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn drain(scheduler: *Scheduler, cursor: *Cursor) void {\n" ++
        "while (scheduler.runNext()) {}\n" ++
        "while (cursor.hasNext()) {}\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "optional traversal must visibly advance its condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn visit(first: ?*Node, state: *State) void {\n" ++
        "var node = first;\n" ++
        "while (node) |value| : (node = value.next) { consume(value); }\n" ++
        "while (state.row) |row| { state.row = row.next; }\n" ++
        "while (first) |value| { consume(value); }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "equality loop updates state used by its condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn scan(bytes: []const u8, end: usize) void {\n" ++
        "var offset: usize = 0;\n" ++
        "while (offset != end) : (offset += 1) { consume(bytes[offset]); }\n" ++
        "while (bytes.len == end) { consume(bytes); }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "body guards and blocking waits state loop termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn consumeAll(input: []const u8, pipeline: *Pipeline) void {\n" ++
        "var index: usize = 0;\n" ++
        "while (true) { if (index >= input.len) break; consume(input[index]); index += 1; }\n" ++
        "while (pipeline.count == 0) { pipeline.ready.wait(&pipeline.mutex); }\n" ++
        "while (glib.MainContext.iteration(null, 0) != 0) {}\n" ++
        "while (!pipeline.done) { pipeline.loop.pollEvent(); }\n" ++
        "while (!pipeline.isClosed()) { pipeline.handleOne(); }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "input exhaustion and compound sentinel updates state loop termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(parser: *Parser, state: *State, input: []const u8) !void {\n" ++
        "while (!parser.eof()) { parser.advance(); }\n" ++
        "while (state.current != state.active and state.current != state.last) { state.current = state.current.next.?; }\n" ++
        "while (state.current.isUsed()) { state.current = state.current.next.?; }\n" ++
        "var index: usize = 0;\n" ++
        "while (true) { try testing.expect(index < input.len); index += 1; if (input[index] == 0) return; }\n" ++
        "while (true) { parser.advance(); if (parser.eof()) break; }\n" ++
        "drain: while (true) { if (state.expired()) { _ = state.entries.swapRemove(0); continue :drain; } break :drain; }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "unbraced while expressions do not borrow nested braces as their body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(reader: *Reader) void {\n" ++
        "while (true) switch (reader.readByte() catch ',') { ',' => break, else => {}, };\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an unrelated equality assertion does not bound a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn generate(value: usize) void {\n" ++
        "while (true) { assert(value == value); consume(value); }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "derived bounds readers and interrupted calls state loop termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(reader: *Reader, duration: usize) !void {\n" ++
        "while (true) { const finished = elapsed() >= duration; if (finished) return; step(); }\n" ++
        "while (reader.seek != reader.end) { _ = reader.streamDelimiterEnding('\\n') catch return; if (reader.empty()) break; }\n" ++
        "while (true) { switch (posix.errno(retry())) { .SUCCESS => break, .INTR => continue, else => return error.Failed, } }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "loops inside test blocks are not held to the production bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn poll() bool { return false; }\n" ++
        "fn production(flag: *bool) void { while (flag.*) { flag.* = poll(); } }\n" ++
        "test \"drain\" {\n" ++
        "    var flag = true;\n" ++
        "    while (flag) { flag = poll(); }\n" ++
        "}\n" ++
        "test {\n" ++
        "    const Spin = struct { fn spin(flag: *bool) void { while (flag.*) { flag.* = poll(); } } };\n" ++
        "    _ = Spin;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.unbounded_loop}, .information));
    try support.expectRules(found, &.{.unbounded_loop});
    try std.testing.expect(found[0].span.start < std.mem.find(u8, source, "test").?);
}

test "a loop on an unchanged flag reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn spin(flag: bool) void { while (flag) {} }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.unbounded_loop}, .information));
    try support.expectRules(found, &.{.unbounded_loop});
}

test "length drains, end-of-input scans and helpers only tests call state termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn walk(stack: *Stack) void { while (stack.items.len != 0) { visit(stack.pop().?); } }\n" ++
        "fn parse(parser: *Parser) void { while (!parser.at(.eof)) { parser.statement(); } }\n" ++
        "fn scenario(flag: *bool) void { while (flag.*) { flag.* = poll(); } }\n" ++
        "fn spin(flag: *bool) void { while (flag.*) { flag.* = poll(); } }\n" ++
        "test \"scenario\" { var flag = true; scenario(&flag); }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.unbounded_loop}, .information));
    try support.expectRules(found, &.{.unbounded_loop});
    try std.testing.expect(found[0].span.start > std.mem.find(u8, source, "fn spin").?);
}

test "system call retries repeat only while the call is interrupted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn mkdir(dir: Dir, path: [*:0]const u8, syscall: *Syscall) !void {
        \\    while (true) {
        \\        switch (c.errno(c.mkdirat(dir.handle, path, 0o755))) {
        \\            .SUCCESS => return,
        \\            .INTR => {},
        \\            .ACCES => return error.AccessDenied,
        \\            else => |err| return unexpectedErrno(err),
        \\        }
        \\    }
        \\    while (true) {
        \\        try syscall.checkCancel();
        \\        switch (wasi.path_create_directory(dir.handle, path)) {
        \\            .SUCCESS => {
        \\                syscall.finish();
        \\                return;
        \\            },
        \\            .INTR => continue,
        \\            else => |e| {
        \\                syscall.finish();
        \\                switch (e) {
        \\                    .ACCES => return error.AccessDenied,
        \\                    else => |err| return unexpectedErrno(err),
        \\                }
        \\            },
        \\        }
        \\    }
        \\    while (true) {
        \\        switch (windows.ntdll.NtFlushBuffersFile(dir.handle)) {
        \\            .SUCCESS => break syscall.finish(),
        \\            .CANCELLED => {
        \\                try syscall.checkCancel();
        \\                continue;
        \\            },
        \\            .INVALID_HANDLE => unreachable,
        \\            else => |status| return syscall.unexpectedNtstatus(status),
        \\        }
        \\    }
        \\}
        \\
    ;
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.unbounded_loop}, .information));
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a retry switch does not bound a loop another path repeats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn serve(fd: i32, buffer: []u8) !void {
        \\    while (true) {
        \\        switch (c.errno(c.read(fd, buffer.ptr, buffer.len))) {
        \\            .SUCCESS => {},
        \\            .INTR => {},
        \\            else => return error.Unexpected,
        \\        }
        \\        consume(buffer);
        \\    }
        \\    while (true) {
        \\        if (pending()) continue;
        \\        switch (c.errno(c.read(fd, buffer.ptr, buffer.len))) {
        \\            .SUCCESS => return,
        \\            .AGAIN => {},
        \\            else => return error.Unexpected,
        \\        }
        \\    }
        \\    while (true) {
        \\        switch (c.errno(c.read(fd, buffer.ptr, buffer.len))) {
        \\            .SUCCESS => {
        \\                if (buffer[0] == 0) continue;
        \\                return;
        \\            },
        \\            .INTR => {},
        \\            else => return error.Unexpected,
        \\        }
        \\    }
        \\}
        \\
    ;
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.unbounded_loop}, .information));
    try std.testing.expectEqual(@as(usize, 3), found.len);
}

test "an empty loop repeating a fallible step makes progress through the step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn lower(ops: []Temp, cg: *CodeGen, lock: *Lock) !void {
        \\    while (try ops[0].toLea(cg)) {}
        \\    while (try ops[0].toBase(false, cg) or
        \\        try ops[1].toRegClass(true, .general_purpose, cg))
        \\    {}
        \\    while (lock.isHeld()) {}
        \\    while (try lock.poll()) {
        \\        lock.spin();
        \\    }
        \\}
        \\
    ;
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.unbounded_loop}, .information));
    try std.testing.expectEqual(@as(usize, 2), found.len);
}

test "retries returned from a switch or guarded by an interruption test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn open(op: *Op, pid: i32, syscall: *Syscall) !i32 {
        \\    while (true) {
        \\        const rc = posix.system.openat(op.dir_fd, op.file_path, op.flags, op.mode);
        \\        return switch (posix.errno(rc)) {
        \\            .SUCCESS => @intCast(rc),
        \\            .INTR => continue,
        \\            else => error.Unexpected,
        \\        };
        \\    }
        \\    const result = while (true) {
        \\        const rc = posix.system.waitpid(pid, null, 0);
        \\        if (posix.errno(rc) == .INTR) continue;
        \\        break rc;
        \\    };
        \\    while (true) {
        \\        switch (posix.errno(posix.system.open("/dev/null", .{}, 0))) {
        \\            .SUCCESS => {
        \\                if (op.shared) {
        \\                    return op.fd;
        \\                } else {
        \\                    return result;
        \\                }
        \\            },
        \\            .INTR => {
        \\                try syscall.checkCancel();
        \\                continue;
        \\            },
        \\            else => |err| return unexpectedErrno(err),
        \\        }
        \\    }
        \\    while (true) {
        \\        if (std.c.realpath(op.file_path, &op.buffer)) |resolved| {
        \\            break syscall.finish();
        \\        } else switch (@as(std.c.E, @fromBackingInt(std.c._errno().*))) {
        \\            .INTR => {
        \\                try syscall.checkCancel();
        \\                continue;
        \\            },
        \\            else => |err| return unexpectedErrno(err),
        \\        }
        \\    }
        \\    while (true) {
        \\        switch (linux.errno(linux.flock(op.fd, LOCK.NB))) {
        \\            .SUCCESS => return,
        \\            .AGAIN => {
        \\                try wait(op);
        \\                switch (op.blocking) {
        \\                    .blocking => continue,
        \\                    .nonblocking => return error.WouldBlock,
        \\                }
        \\            },
        \\            else => |err| return unexpectedErrno(err),
        \\        }
        \\    }
        \\}
        \\
    ;
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.unbounded_loop}, .information));
    try std.testing.expectEqual(@as(usize, 0), found.len);
}
