//! Acquired resources (files, directories, locks, pipes) with no visible release or ownership transfer in their scope.
const std = @import("std");

const tokens_util = @import("../../syntax/tokens.zig");
const tokenText = tokens_util.tokenText;
const tokenIs = tokens_util.tokenIs;
const lineStart = tokens_util.lineStart;
const findTag = tokens_util.findTag;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const resources = @import("../resources.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Configuration = types.Configuration;
const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .missing_resource_cleanup,
};

pub fn run(context: RuleRun) !void {
    try findMissingResourceCleanup(context);
}

fn findMissingResourceCleanup(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.missing_resource_cleanup);
    if (level == .off) return;
    for (tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= tokens.len or
            tokens[declaration_index + 1].tag != .identifier or tokens[declaration_index + 2].tag != .equal) continue;
        if (!context.scopes.insideFunctionOrTestBody(declaration_index)) continue;
        const statement_end = context.statementEnd(declaration_index) orelse continue;
        const acquisition = initializerAcquisition(context, declaration_index + 3, statement_end) orelse continue;
        const resource = acquisition.pair;
        if (resource.kind == .managed and managedMemoryIsReclaimed(context, declaration_index, statement_end, acquisition.call_index)) continue;
        const release_uses_first_argument = absoluteIoDirectoryCall(source, tokens, acquisition.call_index);
        const release_argument = if (release_uses_first_argument)
            firstSimpleCallArgument(source, tokens, acquisition.call_index)
        else
            null;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const binding_name = tokenText(source, tokens[declaration_index + 1]);
        if (bindingHasRelease(source, tokens, binding_name, statement_end + 1, scope_end, resource.release, resource.alternative_release) or
            bindingObviouslyEscapes(context, binding_name, statement_end + 1, scope_end)) continue;
        const line_start = lineStart(source, tokens[declaration_index].loc.start);
        var indentation_end = line_start;
        while (indentation_end < source.len and (source[indentation_end] == ' ' or source[indentation_end] == '\t')) indentation_end += 1;
        var fixes: []const Fix = &.{};
        if (!release_uses_first_argument or release_argument != null) {
            const title = try context.allocator.print(
                "Insert 'defer {s}.{s}({s})'",
                .{ binding_name, resource.release, release_argument orelse "" },
            );
            errdefer context.allocator.free(title);
            const allocated_fixes = try Fix.single(context.allocator, .{
                .title = title,
                .span = .{ .start = tokens[statement_end].loc.end, .end = tokens[statement_end].loc.end },
                .replacement = try context.allocator.print(
                    "\n{s}defer {s}.{s}({s});",
                    .{ source[line_start..indentation_end], binding_name, resource.release, release_argument orelse "" },
                ),
                .preferred = true,
            });
            fixes = allocated_fixes;
        }
        try context.emit(.{
            .rule = .missing_resource_cleanup,
            .level = level,
            .span = tokens[declaration_index + 1].loc,
            .fixes = fixes,
            .message = try context.allocator.print(
                "resource '{s}' from {s} has no visible {s}{s} or ownership transfer",
                .{
                    binding_name,
                    resource.acquisition,
                    resource.release,
                    if (resource.alternative_release) |alternative| try context.allocator.print("/{s}", .{alternative}) else "",
                },
            ),
        });
    }

    try findLoopReplacedResources(context, level);

    for (tokens, 0..) |token, lock_index| {
        if (token.tag != .identifier or lock_index < 2 or lock_index + 2 >= tokens.len or
            tokens[lock_index - 1].tag != .period or tokens[lock_index - 2].tag != .identifier or
            tokens[lock_index + 1].tag != .l_paren) continue;
        const unlock = resources.lockRelease(tokenText(source, token)) orelse continue;
        const call_end = context.matchingToken(lock_index + 1, .l_paren, .r_paren) orelse continue;
        // `lock()`, or `lock(io)` on a `std.Io` mutex; `File.lock(io, .exclusive)` is not a mutex.
        if (context.topLevelComma(lock_index + 2, call_end) != null) continue;
        var receiver_start = lock_index - 2;
        while (receiver_start >= 2 and tokens[receiver_start - 1].tag == .period and
            tokens[receiver_start - 2].tag == .identifier) receiver_start -= 2;
        const statement_start = if (receiver_start > 0 and tokens[receiver_start - 1].tag == .keyword_try) receiver_start - 1 else receiver_start;
        // A result that is bound, passed on or returned makes this a guard-style
        // lock or an expected failure, not std's void-returning Mutex.lock, and
        // `defer mutex.lock()` restores a lock the caller holds.
        if (statement_start > 0) switch (tokens[statement_start - 1].tag) {
            .equal, .l_paren, .comma, .keyword_return, .keyword_defer, .keyword_errdefer => continue,
            else => {},
        };
        const scope_end = context.enclosingScopeEnd(lock_index) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(lock_index) orelse continue;
        // A lock taken in a branch is often released after it, so the unlock is
        // looked for in the rest of the function.
        const function_body = context.scopes.enclosingFunctionBody(lock_index) orelse continue;
        const function_end = context.matchingToken(function_body, .l_brace, .r_brace) orelse continue;
        // A failed lock holds nothing, so its own `catch` handler is skipped.
        const lock_end = if (call_end + 1 < tokens.len and tokens[call_end + 1].tag == .keyword_catch)
            context.statementEnd(receiver_start) orelse call_end
        else
            call_end;
        const receiver = tokenText(source, tokens[lock_index - 2]);
        if (bindingReleaseIndex(source, tokens, receiver, lock_end + 1, function_end, unlock, null)) |unlock_index| {
            // A test that fails while holding a lock is reported by the test runner.
            const error_exit = if (context.scopes.insideTestBlock(lock_index))
                null
            else
                errorExitBetween(context, lock_index, lock_end + 1, unlock_index);
            if (error_exit) |exit_index| {
                try context.emit(.{
                    .rule = .missing_resource_cleanup,
                    .level = level,
                    .span = tokens[exit_index].loc,
                    .message = try context.allocator.print(
                        "mutex '{s}' remains locked when this error path leaves the scope before {s}",
                        .{ receiver, unlock },
                    ),
                });
            } else if (repeatedUnlock(context, statement_start, receiver_start, lock_index, unlock_index, scope_opening, scope_end)) |repeated| {
                try context.emit(.{
                    .rule = .missing_resource_cleanup,
                    .level = level,
                    .span = tokens[repeated].loc,
                    .message = try context.allocator.print(
                        "mutex '{s}' is unlocked a second time while it is no longer locked",
                        .{receiver},
                    ),
                });
            }
            continue;
        }
        if (bindingHasRelease(source, tokens, receiver, function_body + 1, lock_index, unlock, null)) continue;
        if (lockCleanupIsContract(context, receiver_start, lock_index, function_body, function_end)) continue;
        try context.emit(.{
            .rule = .missing_resource_cleanup,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("mutex '{s}' is locked without a visible {s} before leaving this scope", .{ receiver, unlock }),
        });
    }
}

fn firstSimpleCallArgument(
    source: []const u8,
    tokens: []const std.zig.Token,
    call_index: usize,
) ?[]const u8 {
    if (call_index + 3 >= tokens.len or tokens[call_index + 1].tag != .l_paren or
        tokens[call_index + 2].tag != .identifier or
        (tokens[call_index + 3].tag != .comma and tokens[call_index + 3].tag != .r_paren)) return null;
    return tokenText(source, tokens[call_index + 2]);
}

fn absoluteIoDirectoryCall(source: []const u8, tokens: []const std.zig.Token, call_index: usize) bool {
    return call_index >= 6 and tokens[call_index - 1].tag == .period and
        tokenIs(source, tokens[call_index - 2], "Dir") and tokens[call_index - 3].tag == .period and
        tokenIs(source, tokens[call_index - 4], "Io") and tokens[call_index - 5].tag == .period and
        tokenIs(source, tokens[call_index - 6], "std");
}

const Acquisition = struct {
    pair: resources.Pair,
    call_index: usize,
};

/// The resource acquired by a call at the top level of the initializer `[start, end)`.
fn initializerAcquisition(context: RuleRun, start: usize, end: usize) ?Acquisition {
    const tokens = context.tokens;
    for (tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            // A type definition initializer: any init/openFile inside it is a
            // method declaration or nested body, not an acquisition by this binding.
            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque, .keyword_fn => return null,
            else => {},
        }
        if (token.tag != .identifier or index + 1 >= end or tokens[index + 1].tag != .l_paren) continue;
        if (!initializerCallIsTopLevel(tokens, start, index)) continue;
        const pair = resources.lookup(context.configuration, context.tokenText(index), resources.callReceiver(context.source, tokens, index)) orelse continue;
        if (!resources.acquires(pair, context.source, tokens, start, index)) continue;
        return .{ .pair = pair, .call_index = index };
    }
    return null;
}

/// Managed memory whose release nobody needs to see: memory from an arena or
/// the build graph's allocator, an arena created in `pub fn main`, which process
/// exit reclaims, and memory in a `test` block, where `std.testing.allocator`
/// already reports leaks.
fn managedMemoryIsReclaimed(context: RuleRun, declaration_index: usize, statement_end: usize, call_index: usize) bool {
    if (context.scopes.insideTestBlock(declaration_index)) return true;
    if (context.matchingToken(call_index + 1, .l_paren, .r_paren)) |call_end| {
        const argument_end = context.topLevelComma(call_index + 2, call_end) orelse call_end;
        if (argument_end > call_index + 2) {
            const allocator_name = context.source[context.tokens[call_index + 2].loc.start..context.tokens[argument_end - 1].loc.end];
            if (std.ascii.findIgnoreCase(allocator_name, "arena") != null or
                resources.buildGraphAllocator(context.source, context.tokens, context.scopes, allocator_name, declaration_index)) return true;
        }
    }
    if (!context.rangeContainsName("ArenaAllocator", declaration_index, statement_end)) return false;
    const body = context.scopes.enclosingFunctionBody(declaration_index) orelse return false;
    var cursor = body;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .keyword_fn => return cursor > 0 and context.tokens[cursor - 1].tag == .keyword_pub and context.tokenIs(cursor + 1, "main"),
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

/// `dir = try dir.openDir(...)` in a loop over a binding declared outside it:
/// every iteration replaces the previous resource, which leaks unless the loop
/// body releases or hands it on.
fn findLoopReplacedResources(context: RuleRun, level: types.Level) !void {
    const tokens = context.tokens;
    for (tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index < 2 or tokens[equal_index - 1].tag != .identifier) continue;
        const name_index = equal_index - 1;
        switch (tokens[name_index - 1].tag) {
            .semicolon, .l_brace, .r_brace, .pipe, .r_paren => {},
            else => continue,
        }
        const statement_end = context.statementEnd(equal_index) orelse continue;
        const acquisition = initializerAcquisition(context, equal_index + 1, statement_end) orelse continue;
        const resource = acquisition.pair;
        if (resource.kind == .managed and managedMemoryIsReclaimed(context, name_index, statement_end, acquisition.call_index)) continue;
        const binding = context.scopes.findBinding(name_index) orelse continue;
        const loop = enclosingLoopBody(context, name_index, statement_end, binding.token_index) orelse continue;
        const binding_name = context.tokenText(name_index);
        if (bindingHasRelease(context.source, tokens, binding_name, loop.start, loop.end, resource.release, resource.alternative_release) or
            bindingObviouslyEscapes(context, binding_name, statement_end + 1, loop.end)) continue;
        // A loop that stops once the acquisition succeeds never replaces it.
        if (findTag(tokens, statement_end + 1, loop.end, .keyword_break) != null or
            findTag(tokens, statement_end + 1, loop.end, .keyword_return) != null) continue;
        try context.emit(.{
            .rule = .missing_resource_cleanup,
            .level = level,
            .span = tokens[name_index].loc,
            .message = try context.allocator.print(
                "resource '{s}' from {s} is replaced on every loop iteration without a visible {s} of the previous one",
                .{ binding_name, resource.acquisition, resource.release },
            ),
        });
    }
}

/// Token range of the innermost `for` or `while` body around the statement
/// `[index, statement_end]` that the binding declared at `declaration_index`
/// lives outside of; an unbraced body is the statement itself.
fn enclosingLoopBody(context: RuleRun, index: usize, statement_end: usize, declaration_index: usize) ?tokens_util.Range {
    if (loopHeaderEndsAt(context, index - 1)) return .{ .start = index, .end = statement_end + 1 };
    var brace = context.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        // The binding is declared in this block or inside the loop, so each iteration has its own.
        if (opening < declaration_index or opening == 0) return null;
        if (loopHeaderEndsAt(context, opening - 1)) return .{
            .start = opening + 1,
            .end = context.matchingToken(opening, .l_brace, .r_brace) orelse return null,
        };
    }
    return null;
}

/// Whether the loop header `for (...) |capture|` or `while (...) |capture| : (...)` ends at `end`.
fn loopHeaderEndsAt(context: RuleRun, end: usize) bool {
    const tokens = context.tokens;
    var cursor = end;
    // `while (condition) |capture| : (continue expression)`
    if (tokens[cursor].tag == .r_paren) {
        const opening = context.scopes.matchingToken(cursor) orelse return false;
        if (opening >= 2 and tokens[opening - 1].tag == .colon) cursor = opening - 2;
    }
    if (tokens[cursor].tag == .pipe) {
        if (cursor == 0) return false;
        cursor -= 1;
        while (cursor > 0 and tokens[cursor].tag != .pipe) : (cursor -= 1) switch (tokens[cursor].tag) {
            .identifier, .comma, .asterisk => {},
            else => return false,
        };
        if (cursor == 0) return false;
        cursor -= 1;
    }
    if (tokens[cursor].tag != .r_paren) return false;
    const opening = context.scopes.matchingToken(cursor) orelse return false;
    return opening > 0 and (tokens[opening - 1].tag == .keyword_for or tokens[opening - 1].tag == .keyword_while);
}

/// The first `try` or `return error.X` in `[start, end)` that leaves the
/// function still holding the lock taken at `lock_index`; a nested function
/// body's error paths do not run here.
fn errorExitBetween(context: RuleRun, lock_index: usize, start: usize, end: usize) ?usize {
    const function_body = context.scopes.enclosingFunctionBody(lock_index) orelse return null;
    for (context.tokens[start..end], start..) |token, index| {
        const exits = token.tag == .keyword_try or
            (token.tag == .keyword_return and index + 1 < end and context.tokens[index + 1].tag == .keyword_error);
        if (exits and context.scopes.enclosingFunctionBody(index) == function_body) return index;
    }
    return null;
}

const UnlockStatement = enum { direct, deferred, errdeferred };

/// How the unlock call at `method_index` runs when it is a whole statement of
/// the block opened at `scope_opening`; null under a condition or in a nested block.
fn unlockStatement(context: RuleRun, method_index: usize, scope_opening: usize) ?UnlockStatement {
    if (context.enclosingOpeningBrace(method_index) != scope_opening) return null;
    const path_start = context.pathStartBefore(method_index - 1) orelse return null;
    if (path_start == 0) return null;
    return switch (context.tokens[path_start - 1].tag) {
        .semicolon, .l_brace, .r_brace => .direct,
        .keyword_defer => .deferred,
        .keyword_errdefer => .errdeferred,
        else => null,
    };
}

/// An unlock of the mutex locked at `lock_index` (receiver path from
/// `receiver_start`, statement from `statement_start`) that runs once the lock
/// is already given back: a second plain unlock with no other lock taken since,
/// or a plain unlock after `defer unlock`, which unlocks again when the scope ends.
fn repeatedUnlock(
    context: RuleRun,
    statement_start: usize,
    receiver_start: usize,
    lock_index: usize,
    first_unlock: usize,
    scope_opening: usize,
    scope_end: usize,
) ?usize {
    const tokens = context.tokens;
    // `if (c) mutex.lock()` may take no lock; only a plain statement surely holds it.
    if (statement_start == 0) return null;
    switch (tokens[statement_start - 1].tag) {
        .semicolon, .l_brace, .r_brace => {},
        else => return null,
    }
    if (!sameReceiver(context, receiver_start, lock_index, first_unlock)) return null;
    const first = unlockStatement(context, first_unlock, scope_opening) orelse return null;
    if (first == .errdeferred) return null;
    const unlock = context.tokenText(first_unlock);
    const receiver = context.tokenText(lock_index - 2);
    var index = first_unlock + 1;
    while (index + 1 < scope_end) : (index += 1) {
        if (!context.tokenIs(index, unlock) or tokens[index + 1].tag != .l_paren or
            !sameReceiver(context, receiver_start, lock_index, index)) continue;
        if (unlockStatement(context, index, scope_opening) != .direct) return null;
        // Another lock (a second shared lock, a successful `tryLock`) pairs with the later unlock.
        if (relocks(context, receiver, lock_index + 1, index)) return null;
        if (first == .deferred and relocks(context, receiver, index, scope_end)) return null;
        return index;
    }
    return null;
}

fn sameReceiver(context: RuleRun, receiver_start: usize, lock_index: usize, method_index: usize) bool {
    const path_start = context.pathStartBefore(method_index - 1) orelse return false;
    return context.dottedPathsEqual(receiver_start, lock_index - 1, path_start, method_index - 1);
}

/// Whether `[start, end)` takes a lock on a receiver ending in `receiver`.
fn relocks(context: RuleRun, receiver: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index < 2 or context.tokens[index - 1].tag != .period or
            !context.tokenIs(index - 2, receiver)) continue;
        if (resources.lockRelease(context.tokenText(index)) != null or context.tokenIs(index, "tryLock") or
            context.tokenIs(index, "tryLockShared")) return true;
    }
    return false;
}

fn initializerCallIsTopLevel(tokens: []const std.zig.Token, start: usize, call_index: usize) bool {
    var brace_depth: usize = 0;
    for (tokens[start..call_index]) |token| switch (token.tag) {
        .l_brace => brace_depth += 1,
        .r_brace => brace_depth -|= 1,
        else => {},
    };
    return brace_depth == 0;
}

/// Whether the function holding the lock hands it to its caller or ends the
/// value's life: a private `fn lock(self)` wrapper, a public `lock*` function or
/// one that returns while locked, and `deinit`, after which the mutex is never
/// used again.
fn lockCleanupIsContract(
    context: RuleRun,
    receiver_start: usize,
    lock_index: usize,
    function_body: usize,
    function_end: usize,
) bool {
    const tokens = context.tokens;
    var cursor = function_body;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_fn => {
                if (cursor + 1 >= tokens.len or tokens[cursor + 1].tag != .identifier) return false;
                const function_name = context.tokenText(cursor + 1);
                const private_wrapper = std.mem.eql(u8, function_name, "lock") and context.tokenIs(receiver_start, "self");
                if (private_wrapper or std.mem.eql(u8, function_name, "deinit")) return true;
                if (cursor == 0 or tokens[cursor - 1].tag != .keyword_pub) return false;
                if (std.mem.startsWith(u8, function_name, "lock")) return true;
                return findTag(tokens, lock_index + 1, function_end, .keyword_return) != null;
            },
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn bindingHasRelease(
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_name: []const u8,
    start: usize,
    end: usize,
    release: []const u8,
    alternative_release: ?[]const u8,
) bool {
    return bindingReleaseIndex(source, tokens, binding_name, start, end, release, alternative_release) != null;
}

fn bindingReleaseIndex(
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_name: []const u8,
    start: usize,
    end: usize,
    release: []const u8,
    alternative_release: ?[]const u8,
) ?usize {
    var index = start;
    while (index + 3 < @min(end, tokens.len)) : (index += 1) {
        if (!tokenIs(source, tokens[index], binding_name) or tokens[index + 1].tag != .period or
            tokens[index + 2].tag != .identifier or tokens[index + 3].tag != .l_paren) continue;
        const method = tokenText(source, tokens[index + 2]);
        if (std.mem.eql(u8, method, release)) return index + 2;
        if (alternative_release) |alternative| if (std.mem.eql(u8, method, alternative)) return index + 2;
    }
    return null;
}

fn bindingObviouslyEscapes(
    context: RuleRun,
    binding_name: []const u8,
    start: usize,
    end: usize,
) bool {
    const source = context.source;
    const tokens = context.tokens;
    for (tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_return or token.tag == .keyword_break) {
            const return_end = context.statementEnd(index) orelse continue;
            for (tokens[index + 1 .. @min(return_end, end)], index + 1..) |return_token, use_index| {
                if (tokenIs(source, return_token, binding_name) and useHandsOnResource(source, tokens, use_index)) return true;
            }
        }
        if (token.tag != .l_paren or index == 0) continue;
        const closing = context.matchingToken(index, .l_paren, .r_paren) orelse continue;
        if (closing >= end) continue;
        for (tokens[index + 1 .. closing], index + 1..) |argument_token, use_index| {
            if (tokenIs(source, argument_token, binding_name) and useHandsOnResource(source, tokens, use_index)) return true;
        }
    }
    var index = start;
    while (index < @min(end, tokens.len)) : (index += 1) {
        if (!tokenIs(source, tokens[index], binding_name)) continue;
        if (index > 0 and tokens[index - 1].tag == .keyword_return) return true;
        // `_ = file;` discards the binding; it does not take the resource.
        if (index > 1 and tokens[index - 1].tag == .equal and !tokenIs(source, tokens[index - 2], "_") and
            bindingIsWholeAssignedValue(tokens, index, end)) return true;
    }
    return false;
}

/// Whether the use of the binding at `index` hands the resource itself on: the
/// bare value, one of its fields (`file.handle`), or a method result that keeps
/// the resource (`file.reader(...)`). Any other method result, such as
/// `file.readPositionalAll(...)`, only borrows it, and `.name` is a field of
/// another value.
fn useHandsOnResource(source: []const u8, tokens: []const std.zig.Token, index: usize) bool {
    if (index > 0 and tokens[index - 1].tag == .period) return false;
    if (index + 3 < tokens.len and tokens[index + 1].tag == .period and tokens[index + 2].tag == .identifier and
        tokens[index + 3].tag == .l_paren) return resources.methodTransfersResource(tokenText(source, tokens[index + 2]));
    return true;
}

fn bindingIsWholeAssignedValue(tokens: []const std.zig.Token, index: usize, end: usize) bool {
    if (index + 1 >= end) return true;
    return switch (tokens[index + 1].tag) {
        .semicolon, .comma, .r_brace, .r_paren => true,
        else => false,
    };
}

test "resource diagnostics require visible close unlock or ownership transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn leak(directory: anytype, mutex: anytype) !void {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "    const list = try std.ArrayList(u8).initCapacity(allocator, 4);\n" ++
        "    mutex.lock();\n" ++
        "}\n" ++
        "fn clean(directory: anytype, mutex: anytype) !void {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "    defer file.close();\n" ++
        "    const list = try std.ArrayList(u8).initCapacity(allocator, 4);\n" ++
        "    defer list.deinit(allocator);\n" ++
        "    mutex.lock();\n" ++
        "    defer mutex.unlock();\n" ++
        "}\n" ++
        "fn transfer(directory: anytype) !anytype {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "    return file;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        warning_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), warning_count);
}

test "resource ownership can leave a nested block through break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: anytype) !Step {\n" ++
        "    return .{ .remove = value: {\n" ++
        "        var list = try std.ArrayList(u8).initCapacity(allocator, 0);\n" ++
        "        break :value list;\n" ++
        "    } };\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_resource_cleanup);
}

test "field cleanup satisfies aggregate resource ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(allocator: anytype) void { var owner = Owner{ .values = .empty, .positions = Map.init(allocator) };" ++
        "defer owner.values.deinit(allocator); defer owner.positions.deinit(); }";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_resource_cleanup);
}

test "error return before unlock leaves the mutex locked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn consume(mutex: anytype, fail: bool) !void { mutex.lock();" ++
        "if (fail) return error.NotReady; mutex.unlock(); }" ++
        "fn safe(mutex: anytype, fail: bool) !void { mutex.lock(); defer mutex.unlock();" ++
        "if (fail) return error.NotReady; }";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        warning_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "public lock APIs and temporary unlock restoration do not require local cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn lockDemand(self: *State) void { self.mutex.lock(); }\n" ++
        "pub fn drain(self: *State) Iterator { self.mutex.lock(); return .{ .state = self }; }\n" ++
        "pub fn run(mutex: anytype) void { mutex.lock(); }\n" ++
        "fn lock(self: *State) void { self.writer.lock(); }\n" ++
        "fn lockAndWork(self: *State) void { self.writer.lock(); work(); }\n" ++
        "fn restore(self: *State) void { self.mutex.unlock(); defer self.mutex.lock(); work(); }\n" ++
        "fn leak(mutex: anytype) void { mutex.lock(); }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        warning_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), warning_count);
}

test "bound lock results are guards not mutex locks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn guarded(db: anytype) void {\n" ++
        "    const guard = db.lock();\n" ++
        "    defer guard.deinit();\n" ++
        "}\n" ++
        "fn leaky(mutex: anytype) void {\n" ++
        "    mutex.lock();\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var lock_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        lock_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "'mutex'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), lock_count);
}

test "type definitions inside test bodies are not resource acquisitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "test \"merge\" {\n" ++
        "    const T = struct {\n" ++
        "        output_buf: std.ArrayList(u8),\n" ++
        "        fn init(gpa: std.mem.Allocator) !@This() {\n" ++
        "            return .{ .output_buf = std.ArrayList(u8).init(gpa) };\n" ++
        "        }\n" ++
        "    };\n" ++
        "    _ = T;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_resource_cleanup);
}

test "missing resource cleanup offers inserting a defer after the acquisition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(directory: anytype) !void {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        try std.testing.expect(!finding.fixes[0].fix_all);
        const edit = finding.fixes[0].edits[0];
        try std.testing.expectEqual(edit.span.start, edit.span.end);
        try std.testing.expectEqual(std.mem.findScalar(u8, source, ';').? + 1, edit.span.start);
        try std.testing.expectEqualStrings("\n    defer file.close();", edit.replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "absolute file cleanup preserves the IO argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(io: std.Io) !void {\n" ++
        "    const file = try std.Io.Dir.openFileAbsolute(io, \"/tmp/state\", .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        try std.testing.expectEqualStrings("\n    defer file.close(io);", finding.fixes[0].edits[0].replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "absolute directory cleanup preserves the IO argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(io: std.Io) !void {\n" ++
        "    const directory = try std.Io.Dir.openDirAbsolute(io, \"/tmp/state\", .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqualStrings("\n    defer directory.close(io);", finding.fixes[0].edits[0].replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "legacy absolute directory cleanup does not pass the path to close" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(path: []const u8) !void {\n" ++
        "    const directory = try std.fs.openDirAbsolute(path, .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqualStrings("\n    defer directory.close();", finding.fixes[0].edits[0].replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "absolute file cleanup still reports when the IO argument is not a simple binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(threaded: *Threaded) !void {\n" ++
        "    const file = try std.Io.Dir.openFileAbsolute(threaded.io(), \"/tmp/state\", .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "a declared resource pair needs a visible release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const leaking: [:0]const u8 = "fn load() !void { const connection = try Db.open(); _ = connection.id; }";
    const declared = try support.findings(arena.allocator(), run, leaking, configuration);
    try support.expectRules(declared, &.{.missing_resource_cleanup});
    try std.testing.expect(std.mem.find(u8, declared[0].message, "Db.open") == null);
    try std.testing.expectEqualStrings("Insert 'defer connection.close()'", declared[0].fixes[0].title);
    const builtin = try support.findings(arena.allocator(), run, leaking, types.Configuration.defaults());
    try support.expectRules(builtin, &.{});
    const released: [:0]const u8 = "fn load() !void { const connection = try Db.open(); defer connection.close(); }";
    try support.expectRules(try support.findings(arena.allocator(), run, released, configuration), &.{});
    const other: [:0]const u8 = "fn load() !void { const connection = try Cache.open(); _ = connection.id; }";
    try support.expectRules(try support.findings(arena.allocator(), run, other, configuration), &.{});
}

test "only returning or storing the handle itself transfers a resource" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn readAll(io: std.Io, dir: std.Io.Dir, buffer: []u8) !usize {\n" ++
        "    const read = try dir.openFile(io, \"state\", .{});\n" ++
        "    return try read.readPositionalAll(io, buffer, 0);\n" ++
        "}\n" ++
        "fn discard(io: std.Io, dir: std.Io.Dir) !void {\n" ++
        "    const discarded = try dir.openDir(io, \"sub\", .{});\n" ++
        "    _ = discarded;\n" ++
        "}\n" ++
        "fn checked(io: std.Io, dir: std.Io.Dir) !bool {\n" ++
        "    const probed = try dir.openFile(io, \"state\", .{});\n" ++
        "    return (try probed.stat(io)).size == 0;\n" ++
        "}\n" ++
        "fn open(io: std.Io, dir: std.Io.Dir) !std.Io.File {\n" ++
        "    const returned = try dir.openFile(io, \"state\", .{});\n" ++
        "    return returned;\n" ++
        "}\n" ++
        "fn stream(io: std.Io, dir: std.Io.Dir, buffer: []u8) !std.Io.File.Reader {\n" ++
        "    const viewed = try dir.openFile(io, \"state\", .{});\n" ++
        "    return viewed.reader(io, buffer);\n" ++
        "}\n" ++
        "fn store(io: std.Io, dir: std.Io.Dir, out: *Owner) !void {\n" ++
        "    const stored = try dir.openFile(io, \"state\", .{});\n" ++
        "    out.* = .{ .file = stored };\n" ++
        "}\n" ++
        "fn handOff(io: std.Io, dir: std.Io.Dir, files: *Files) !void {\n" ++
        "    const appended = try dir.openFile(io, \"state\", .{});\n" ++
        "    try files.append(appended);\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    try support.expectSpans(source, found, &.{ "read", "discarded", "probed" });
}

test "std.Io mutexes left locked on an error path or unlocked twice report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn tryInside(io: std.Io, mutex: *std.Io.Mutex) !void {\n" ++
        "    try mutex.lock(io);\n" ++
        "    try work();\n" ++
        "    mutex.unlock(io);\n" ++
        "}\n" ++
        "fn deferred(io: std.Io, mutex: *std.Io.Mutex) !void {\n" ++
        "    try mutex.lock(io);\n" ++
        "    defer mutex.unlock(io);\n" ++
        "    try work();\n" ++
        "}\n" ++
        "fn errdeferred(io: std.Io, state: *State) !void {\n" ++
        "    state.mutex.lockUncancelable(io);\n" ++
        "    errdefer state.mutex.unlock(io);\n" ++
        "    try work();\n" ++
        "    state.mutex.unlock(io);\n" ++
        "}\n" ++
        "fn shared(io: std.Io, lock: *std.Io.RwLock) void {\n" ++
        "    lock.lockSharedUncancelable(io);\n" ++
        "}\n" ++
        "fn fileLock(io: std.Io, file: std.Io.File) !void {\n" ++
        "    try file.lock(io, .exclusive);\n" ++
        "}\n" ++
        "fn twice(mutex: *Mutex) void {\n" ++
        "    mutex.lock();\n" ++
        "    mutex.unlock();\n" ++
        "    mutex.unlock();\n" ++
        "}\n" ++
        "fn deferredTwice(io: std.Io, mutex: *std.Io.Mutex) void {\n" ++
        "    mutex.lockUncancelable(io);\n" ++
        "    defer mutex.unlock(io);\n" ++
        "    mutex.unlock(io);\n" ++
        "}\n" ++
        "fn released(io: std.Io, mutex: *std.Io.Mutex) void {\n" ++
        "    mutex.lockUncancelable(io);\n" ++
        "    defer mutex.unlock(io);\n" ++
        "    mutex.unlock(io);\n" ++
        "    slow();\n" ++
        "    mutex.lockUncancelable(io);\n" ++
        "}\n" ++
        "fn relocked(mutex: *Mutex, other: *Mutex) void {\n" ++
        "    mutex.lock();\n" ++
        "    mutex.unlock();\n" ++
        "    mutex.lock();\n" ++
        "    mutex.unlock();\n" ++
        "    other.lock();\n" ++
        "    other.unlock();\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    try support.expectSpans(source, found, &.{ "try", "lockSharedUncancelable", "unlock", "unlock" });
    try std.testing.expect(std.mem.find(u8, found[1].message, "'lock'") != null);
    try std.testing.expect(std.mem.find(u8, found[2].message, "second time") != null);
}

test "locks released later in the function or handed to the caller stay quiet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn branch(io: std.Io, self: *Self, exclusive: bool) !void {\n" ++
        "    switch (exclusive) {\n" ++
        "        true => self.rwlock.lockUncancelable(io),\n" ++
        "        false => self.rwlock.lockSharedUncancelable(io),\n" ++
        "    }\n" ++
        "    if (exclusive) self.rwlock.unlock(io) else self.rwlock.unlockShared(io);\n" ++
        "}\n" ++
        "fn cancelable(io: std.Io, mutex: *std.Io.Mutex) !void {\n" ++
        "    mutex.lock(io) catch |err| switch (err) {\n" ++
        "        error.Canceled => return error.Canceled,\n" ++
        "    };\n" ++
        "    mutex.unlock(io);\n" ++
        "}\n" ++
        "fn expectCanceled(io: std.Io, rl: *std.Io.RwLock) !void {\n" ++
        "    try std.testing.expectEqual(error.Canceled, rl.lockShared(io));\n" ++
        "}\n" ++
        "pub fn deinit(pool: *Pool, io: std.Io) void {\n" ++
        "    pool.mutex.lockUncancelable(io);\n" ++
        "    pool.connections.clear();\n" ++
        "}\n" ++
        "fn shared(io: std.Io, rl: *std.Io.RwLock) void {\n" ++
        "    rl.lockSharedUncancelable(io);\n" ++
        "    _ = rl.tryLockShared(io);\n" ++
        "    rl.unlockShared(io);\n" ++
        "    rl.unlockShared(io);\n" ++
        "}\n" ++
        "fn yield(io: std.Io, self: *Self, paste: bool) !void {\n" ++
        "    if (paste) {\n" ++
        "        self.mutex.unlock(io);\n" ++
        "        defer self.mutex.lockUncancelable(io);\n" ++
        "        try self.request();\n" ++
        "    } else {\n" ++
        "        self.mutex.unlock(io);\n" ++
        "        defer self.mutex.lockUncancelable(io);\n" ++
        "    }\n" ++
        "}\n" ++
        "test \"holds\" {\n" ++
        "    var rl: std.Io.RwLock = .init;\n" ++
        "    rl.lockUncancelable(std.testing.io);\n" ++
        "    try std.testing.expect(!rl.tryLock(std.testing.io));\n" ++
        "    rl.unlock(std.testing.io);\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    try support.expectRules(found, &.{});
}

test "replacing a resource on every loop iteration reports unless the loop releases it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn descend(io: std.Io, root: std.Io.Dir, parts: []const []const u8) !void {\n" ++
        "    var dir = try root.openDir(io, \".\", .{});\n" ++
        "    defer dir.close(io);\n" ++
        "    for (parts) |part| {\n" ++
        "        dir = try dir.openDir(io, part, .{});\n" ++
        "    }\n" ++
        "}\n" ++
        "fn unbraced(io: std.Io, root: std.Io.Dir, parts: []const []const u8) !void {\n" ++
        "    var current = try root.openDir(io, \".\", .{});\n" ++
        "    defer current.close(io);\n" ++
        "    for (parts) |part| current = try current.openDir(io, part, .{});\n" ++
        "}\n" ++
        "fn closing(io: std.Io, root: std.Io.Dir, parts: []const []const u8) !void {\n" ++
        "    var walked = try root.openDir(io, \".\", .{});\n" ++
        "    defer walked.close(io);\n" ++
        "    for (parts) |part| {\n" ++
        "        const next = try walked.openDir(io, part, .{});\n" ++
        "        walked.close(io);\n" ++
        "        walked = next;\n" ++
        "    }\n" ++
        "}\n" ++
        "fn retry(io: std.Io, root: std.Io.Dir) !void {\n" ++
        "    var file: std.Io.File = undefined;\n" ++
        "    while (true) {\n" ++
        "        file = root.openFile(io, \"state\", .{}) catch continue;\n" ++
        "        break;\n" ++
        "    }\n" ++
        "    defer file.close(io);\n" ++
        "}\n" ++
        "fn released(io: std.Io, root: std.Io.Dir, names: []const []const u8) !void {\n" ++
        "    var file: std.Io.File = undefined;\n" ++
        "    var index: usize = 0;\n" ++
        "    while (index < names.len) : (index += 1) {\n" ++
        "        file = try root.openFile(io, names[index], .{});\n" ++
        "        file.close(io);\n" ++
        "    }\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    try support.expectSpans(source, found, &.{ "dir", "current" });
    try std.testing.expect(std.mem.find(u8, found[0].message, "every loop iteration") != null);
}

test "an arena in main and managed memory in tests need no visible deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn main() !void {\n" ++
        "    var process_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);\n" ++
        "    _ = process_arena.allocator();\n" ++
        "}\n" ++
        "test \"scratch\" {\n" ++
        "    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);\n" ++
        "    _ = scratch.allocator();\n" ++
        "}\n" ++
        "fn run() !void {\n" ++
        "    var leaked = std.heap.ArenaAllocator.init(std.heap.page_allocator);\n" ++
        "    _ = leaked.allocator();\n" ++
        "}\n" ++
        "fn scoped(sema: *Sema, b: *std.Build) !void {\n" ++
        "    var mapping = std.AutoHashMap(u32, u32).init(sema.arena);\n" ++
        "    try mapping.put(1, 2);\n" ++
        "    var steps = std.StringHashMap(u32).init(b.allocator);\n" ++
        "    try steps.put(\"x\", 2);\n" ++
        "}\n" ++
        "test \"handle\" {\n" ++
        "    const file = try std.testing.tmpDir(.{}).dir.openFile(std.testing.io, \"state\", .{});\n" ++
        "    _ = file;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    try support.expectSpans(source, found, &.{ "leaked", "file" });
}
