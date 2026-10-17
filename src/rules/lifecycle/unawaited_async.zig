//! `std.Io` tasks that are never awaited or cancelled. A `Future` from
//! `io.async` or `io.concurrent`, and the tasks a local `Group` or `Select`
//! spawns, hold resources, and often pointers into the caller's frame, until
//! `await` or `cancel` runs; a task left pending can outlive the scope that
//! started it.
//!
//! An early exit (`try`, `return`) between starting a task and finishing it
//! is reported too, unless a `defer` or `errdefer` registered before it
//! finishes the task. That check skips test blocks, where a failed `try`
//! already fails the test.
//!
//! The same task-spawn recognition reports `concurrent` calls whose
//! `error.ConcurrencyUnavailable` is asserted away with `catch unreachable`:
//! the error is a runtime condition (a single-threaded `Io`, no thread or
//! memory left for the task), not a programming error.

const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const resources = @import("../resources.zig");
const reach = @import("reach.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const TaskOwner = resources.TaskOwner;

pub const rules = [_]types.Rule{ .unawaited_async, .assumed_concurrency };

pub fn run(context: RuleRun) !void {
    try findAssumedConcurrency(context);
    const level = context.level(.unawaited_async);
    if (level == .off) return;
    // Groups and selects already checked, by declaration.
    var checked: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer checked.deinit(context.allocator);
    const tokens = context.tokens;
    for (tokens, 0..) |token, method| {
        if (token.tag != .identifier or method < 2 or tokens[method - 1].tag != .period or
            tokens[method + 1].tag != .l_paren or !resources.spawnsTask(context.tokenText(method))) continue;
        const closing = context.matchingToken(method + 1, .l_paren, .r_paren) orelse continue;
        if (argumentCount(tokens, method + 1, closing) == 2 and receiverIsIo(context, method)) {
            try checkFuture(context, level, method);
            continue;
        }
        // `group.async(io, function, args)` on a group or select declared in this function.
        if (tokens[method - 2].tag != .identifier or (method >= 3 and tokens[method - 3].tag == .period)) continue;
        const binding = context.scopes.findBinding(method - 2) orelse continue;
        if ((try checked.getOrPut(context.allocator, binding.token_index)).found_existing) continue;
        const owner = taskOwner(context, binding.token_index) orelse continue;
        try checkTasks(context, level, binding.token_index, owner, (context.statementEnd(binding.token_index - 1) orelse continue) + 1);
    }
}

/// `io.concurrent(f, .{}) catch unreachable` and the same on a `Group` or
/// `Select`.
fn findAssumedConcurrency(context: RuleRun) !void {
    const level = context.level(.assumed_concurrency);
    if (level == .off) return;
    const tokens = context.tokens;
    for (tokens, 0..) |token, method| {
        if (token.tag != .identifier or method < 2 or tokens[method - 1].tag != .period or
            tokens[method + 1].tag != .l_paren or !context.tokenIs(method, "concurrent")) continue;
        const closing = context.matchingToken(method + 1, .l_paren, .r_paren) orelse continue;
        if (tokens[closing + 1].tag != .keyword_catch or tokens[closing + 2].tag != .keyword_unreachable) continue;
        if (!spawnsOnIo(context, method, closing)) continue;
        try context.emit(.{
            .rule = .assumed_concurrency,
            .level = level,
            .span = tokens[closing + 2].loc,
            .message = "'concurrent' fails with error.ConcurrencyUnavailable when the Io cannot run the task concurrently (a single-threaded Io, or no thread or memory left), and 'catch unreachable' makes that illegal behavior; handle the error or use 'async'",
        });
    }
}

/// Whether the `concurrent` call at `method` spawns an `std.Io` task:
/// `io.concurrent(f, args)`, `group.concurrent(io, f, args)` or
/// `select.concurrent(.field, f, args)` on a local `Io.Select`.
fn spawnsOnIo(context: RuleRun, method: usize, closing: usize) bool {
    const tokens = context.tokens;
    switch (argumentCount(tokens, method + 1, closing)) {
        2 => return receiverIsIo(context, method),
        3 => {
            const comma = tokens_util.topLevelComma(tokens, method + 2, closing) orelse return false;
            if (tokens[comma - 1].tag == .identifier and context.namesIo(comma - 1)) return true;
            if (tokens[method - 2].tag != .identifier or (method >= 3 and tokens[method - 3].tag == .period)) return false;
            const binding = context.scopes.findBinding(method - 2) orelse return false;
            return taskOwner(context, binding.token_index) == .select;
        },
        else => return false,
    }
}

fn argumentCount(tokens: []const std.zig.Token, opening: usize, closing: usize) usize {
    const end = tokens_util.argumentsEnd(tokens, opening, closing) orelse return 0;
    var count: usize = 1;
    var start = opening + 1;
    while (tokens_util.topLevelComma(tokens, start, end)) |comma| : (start = comma + 1) count += 1;
    return count;
}

/// Whether the receiver of the call at `method` is an `Io`: `io.async(`,
/// `self.io.async(`, `global.io().async(`.
fn receiverIsIo(context: RuleRun, method: usize) bool {
    var last = method - 2;
    if (context.tokens[last].tag == .r_paren) {
        const opening = context.scopes.matchingToken(last) orelse return false;
        if (opening == 0) return false;
        last = opening - 1;
    }
    return context.namesIo(last);
}

/// `var future = io.async(..);` and `_ = io.async(..);`; a future assigned
/// anywhere else is owned by that place.
fn checkFuture(context: RuleRun, level: types.Level, method: usize) !void {
    const tokens = context.tokens;
    var value = if (tokens[method - 2].tag == .r_paren)
        tokens_util.callExpressionStart(tokens, context.scopes.matchingToken(method - 2) orelse return) orelse return
    else
        (tokens_util.pathBefore(tokens, method - 1) orelse return).start;
    if (tokens[value - 1].tag == .keyword_try) value -= 1;
    if (tokens[value - 1].tag != .equal) return;
    const head = tokens_util.statementStart(tokens, method);
    if (head + 2 == value and context.tokenIs(head, "_")) {
        try context.emit(.{
            .rule = .unawaited_async,
            .level = level,
            .span = tokens[method].loc,
            .message = try context.allocator.print(
                "the future of this '{s}' call is discarded, so its task is never awaited or cancelled",
                .{context.tokenText(method)},
            ),
        });
        return;
    }
    if ((tokens[head].tag != .keyword_var and tokens[head].tag != .keyword_const) or tokens[head + 1].tag != .identifier) return;
    if (tokens_util.findTag(tokens, head + 2, value, .equal) != value - 1) return;
    if (!context.scopes.insideFunctionOrTestBody(head)) return;
    const statement_end = context.statementEnd(head) orelse return;
    try checkTasks(context, level, head + 1, .future, statement_end + 1);
}

/// Whether the `var` named at `name` declares an `Io.Group` or `Io.Select`,
/// by its type or its initializer, in a function body.
fn taskOwner(context: RuleRun, name: usize) ?TaskOwner {
    const tokens = context.tokens;
    if (name == 0 or tokens[name - 1].tag != .keyword_var or !context.scopes.insideFunctionOrTestBody(name)) return null;
    if (tokens[name + 1].tag == .equal) return ioMember(context, name + 2, name + 7);
    if (tokens[name + 1].tag != .colon) return null;
    const equal = tokens_util.findTag(tokens, name + 2, context.statementEnd(name - 1) orelse return null, .equal) orelse return null;
    if (ioMember(context, name + 2, equal)) |owner| return owner;
    // `var select: Select = .init(io, &buffer);` under `const Select = Io.Select(U);`
    if (equal != name + 3 or tokens[name + 2].tag != .identifier) return null;
    const alias = context.scopes.findBinding(name + 2) orelse return null;
    if (alias.token_index == 0 or tokens[alias.token_index - 1].tag != .keyword_const or
        tokens[alias.token_index + 1].tag != .equal) return null;
    return ioMember(context, alias.token_index + 2, alias.token_index + 7);
}

/// `Io.Group` or `Io.Select` named in `[start, end)`.
fn ioMember(context: RuleRun, start: usize, end: usize) ?TaskOwner {
    var index = start;
    while (index + 2 < @min(end, context.tokens.len)) : (index += 1) {
        if (!context.tokenIs(index, "Io") or context.tokens[index + 1].tag != .period) continue;
        if (context.tokenIs(index + 2, "Group")) return .group;
        if (context.tokenIs(index + 2, "Select")) return .select;
    }
    return null;
}

const TaskUse = enum { ignored, spawn, release, escape };

/// What the mention of a task owner at `index` does with it.
fn taskUse(context: RuleRun, index: usize, owner: TaskOwner) TaskUse {
    const tokens = context.tokens;
    switch (tokens[index + 1].tag) {
        .period => {
            if (tokens[index + 2].tag != .identifier or tokens[index + 3].tag != .l_paren) return .ignored;
            const method = context.tokenText(index + 2);
            if (resources.finishesTask(owner, method)) return .release;
            if (owner != .future and resources.spawnsTask(method)) return .spawn;
            return .ignored;
        },
        .period_asterisk => return .ignored,
        // `_ = future;` and `_ = &future;` only silence the unused-variable error.
        .semicolon => {
            const start = if (tokens[index - 1].tag == .ampersand) index - 1 else index;
            if (tokens[start - 1].tag == .equal and context.tokenIs(start - 2, "_")) return .ignored;
        },
        else => {},
    }
    return .escape;
}

/// Deferred finishes remembered for the early-exit check; more defers than
/// this read as covering everything.
const max_defers = 8;

const Mentions = struct {
    first_spawn: ?usize = null,
    /// The first `await` or `cancel` outside a `defer`.
    first_release: ?usize = null,
    released: bool = false,
    defers: [max_defers]usize = undefined,
    defer_count: usize = 0,
};

/// Checks the owner declared at `name` from `start` to the end of its scope.
fn checkTasks(context: RuleRun, level: types.Level, name: usize, owner: TaskOwner, start: usize) !void {
    const tokens = context.tokens;
    const scope_end = context.enclosingScopeEnd(name) orelse return;
    const text = context.tokenText(name);
    var mentions: Mentions = .{};
    for (start..scope_end) |index| {
        if (tokens[index].tag != .identifier or tokens[index - 1].tag == .period or !context.tokenIs(index, text)) continue;
        if (context.scopes.resolve(index)) |binding| if (binding.token_index != name) continue;
        switch (taskUse(context, index, owner)) {
            .ignored => {},
            .spawn => if (mentions.first_spawn == null) {
                mentions.first_spawn = index;
            },
            .release => {
                mentions.released = true;
                if (reach.deferKeyword(context, index)) |keyword| {
                    if (mentions.defer_count == max_defers) return;
                    mentions.defers[mentions.defer_count] = keyword;
                    mentions.defer_count += 1;
                } else if (mentions.first_release == null) mentions.first_release = index;
            },
            .escape => return,
        }
    }
    const noun = switch (owner) {
        .future => "future",
        .group => "group",
        .select => "select",
    };
    if (owner != .future and mentions.first_spawn == null) return;
    if (!mentions.released) {
        try context.emit(.{
            .rule = .unawaited_async,
            .level = level,
            .span = tokens[name].loc,
            .message = if (owner == .future)
                try context.allocator.print("future '{s}' is never awaited or cancelled, so its task can outlive this scope", .{text})
            else
                try context.allocator.print("{s} '{s}' spawns tasks that are never awaited or cancelled", .{ noun, text }),
        });
        return;
    }
    const exit = uncoveredExit(context, name, owner, start, &mentions, scope_end) orelse return;
    try context.emit(.{
        .rule = .unawaited_async,
        .level = level,
        .span = tokens[exit].loc,
        .message = try context.allocator.print(
            "this '{s}' can leave {s} '{s}' with a pending task; cancel it in a defer or errdefer registered before this exit",
            .{ context.tokenText(exit), noun, text },
        ),
    });
}

/// The first `try` or `return` that can leave the function while a task is
/// pending: after the task starts and before the first `await` or `cancel`,
/// with no deferred finish registered before it.
fn uncoveredExit(context: RuleRun, name: usize, owner: TaskOwner, start: usize, mentions: *const Mentions, scope_end: usize) ?usize {
    const tokens = context.tokens;
    const function_body = context.scopes.enclosingFunctionBody(name) orelse return null;
    if (isTestBody(context, function_body)) return null;
    const end = mentions.first_release orelse scope_end;
    var region_start = start;
    if (owner != .future) {
        const spawn = mentions.first_spawn.?;
        region_start = (context.statementEnd(tokens_util.statementStart(tokens, spawn)) orelse return null) + 1;
        // Tasks spawned in a loop are still pending while its later iterations run.
        if (outermostLoop(context, spawn, name, end)) |keyword| region_start = keyword;
    }
    if (region_start >= end) return null;
    for (region_start..end) |index| {
        if (tokens[index].tag != .keyword_try and tokens[index].tag != .keyword_return) continue;
        if (context.scopes.enclosingFunctionBody(index) != function_body) continue;
        if (finishesWithin(context, name, owner, index)) continue;
        if (coveredByDefer(context, mentions, index)) continue;
        return index;
    }
    return null;
}

fn isTestBody(context: RuleRun, body: usize) bool {
    var cursor = body;
    while (cursor > 0 and body - cursor < 3) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .keyword_test) return true;
    }
    return false;
}

/// The outermost loop around `spawn` that ends before `end` and starts after
/// the owner's declaration at `name`.
fn outermostLoop(context: RuleRun, spawn: usize, name: usize, end: usize) ?usize {
    var selected: ?usize = null;
    var brace = context.enclosingOpeningBrace(spawn);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening < name) break;
        const keyword = context.loopKeyword(opening) orelse continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse break;
        if (closing < end) selected = keyword;
    }
    return selected;
}

/// Whether the operand of the `try` or `return` at `exit` finishes the task
/// itself, as in `return future.await(io)`.
fn finishesWithin(context: RuleRun, name: usize, owner: TaskOwner, exit: usize) bool {
    const tokens = context.tokens;
    const text = context.tokenText(name);
    var cursor = exit + 1;
    while (cursor < tokens.len) : (cursor += 1) switch (tokens[cursor].tag) {
        .l_paren, .l_bracket => cursor = context.scopes.matchingToken(cursor) orelse return false,
        .l_brace => switch (tokens[cursor - 1].tag) {
            // A block after a condition or capture ends the operand.
            .r_paren, .pipe => return false,
            else => cursor = context.scopes.matchingToken(cursor) orelse return false,
        },
        .semicolon, .comma, .r_paren, .r_bracket, .r_brace, .keyword_else, .eof => return false,
        .identifier => if (context.tokenIs(cursor, text) and tokens[cursor - 1].tag != .period and
            taskUse(context, cursor, owner) == .release) return true,
        else => {},
    };
    return false;
}

fn coveredByDefer(context: RuleRun, mentions: *const Mentions, exit: usize) bool {
    for (mentions.defers[0..mentions.defer_count]) |keyword| {
        if (keyword > exit) continue;
        const opening = context.enclosingOpeningBrace(keyword) orelse continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        if (exit < closing) return true;
    }
    return false;
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.unawaited_async}, .warning));
}

fn concurrencyFindings(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.assumed_concurrency}, .warning));
}

test "concurrent calls asserted not to fail report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Io = std.Io;
        \\fn work() void {}
        \\const Done = union(enum) { done: void };
        \\fn future(io: Io) void {
        \\    var pending = io.concurrent(work, .{}) catch unreachable;
        \\    pending.await(io);
        \\}
        \\fn group(self: *Server, buffer: []Done) void {
        \\    var workers: Io.Group = .init;
        \\    defer workers.cancel(self.io);
        \\    workers.concurrent(self.io, work, .{}) catch unreachable;
        \\    var racing: Io.Select(Done) = .init(self.io, buffer);
        \\    defer racing.cancelDiscard();
        \\    racing.concurrent(.done, work, .{}) catch unreachable;
        \\}
        \\const Server = struct { io: Io };
    ;
    const found = try concurrencyFindings(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "unreachable", "unreachable", "unreachable" });
}

test "handled concurrency errors and other concurrent methods stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Io = std.Io;
        \\fn work() void {}
        \\fn propagated(io: Io) !void {
        \\    var pending = try io.concurrent(work, .{});
        \\    pending.await(io);
        \\}
        \\fn fallback(io: Io) void {
        \\    var pending = io.concurrent(work, .{}) catch return work();
        \\    pending.await(io);
        \\}
        \\fn grouped(io: Io) void {
        \\    var workers: Io.Group = .init;
        \\    defer workers.cancel(io);
        \\    workers.concurrent(io, work, .{}) catch workers.async(io, work, .{});
        \\}
        \\fn unrelated(pool: anytype) void {
        \\    pool.concurrent(work, .{}) catch unreachable;
        \\    pool.queue.concurrent(1, work, .{}) catch unreachable;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try concurrencyFindings(arena.allocator(), source)).len);
}

test "futures, groups and selects that never finish report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Io = std.Io;
        \\fn work() void {}
        \\const Done = union(enum) { done: void };
        \\fn future(io: Io) void {
        \\    var pending = io.async(work, .{});
        \\    _ = &pending;
        \\}
        \\fn discarded(io: Io) !void {
        \\    _ = try io.concurrent(work, .{});
        \\}
        \\fn group(io: Io) void {
        \\    var workers: Io.Group = .init;
        \\    for (0..3) |_| workers.async(io, work, .{});
        \\}
        \\fn select(io: Io, buffer: []Done) void {
        \\    const Select = Io.Select(Done);
        \\    var racing: Select = .init(io, buffer);
        \\    racing.async(.done, work, .{});
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "pending", "concurrent", "workers", "racing" });
}

test "awaited, cancelled, deferred and returned tasks stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Io = std.Io;
        \\fn work() void {}
        \\const Done = union(enum) { done: void };
        \\fn awaited(io: Io) void {
        \\    var pending = io.async(work, .{});
        \\    pending.await(io);
        \\}
        \\fn deferred(io: Io) !void {
        \\    var pending = try io.concurrent(work, .{});
        \\    defer pending.cancel(io);
        \\    try other();
        \\}
        \\fn group(io: Io) !void {
        \\    var workers: Io.Group = .init;
        \\    defer workers.cancel(io);
        \\    for (0..3) |_| try workers.concurrent(io, work, .{});
        \\    try workers.await(io);
        \\}
        \\fn returned(io: Io) !Io.Future(void) {
        \\    const worker = try io.concurrent(work, .{});
        \\    errdefer comptime unreachable;
        \\    return worker;
        \\}
        \\fn stored(io: Io, slot: *Io.Future(void)) void {
        \\    slot.* = io.async(work, .{});
        \\}
        \\fn select(io: Io, buffer: []Done) !void {
        \\    var racing: Io.Select(Done) = .init(io, buffer);
        \\    defer racing.cancelDiscard();
        \\    racing.async(.done, work, .{});
        \\    _ = try racing.await();
        \\}
        \\fn queue(q: anytype) void {
        \\    q.async(work, .{});
        \\}
        \\fn other() !void {}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}

test "an exit between starting a task and finishing it reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Io = std.Io;
        \\fn work() void {}
        \\fn early(io: Io, fail: bool) !void {
        \\    var pending = io.async(work, .{});
        \\    if (fail) return error.Failed;
        \\    pending.await(io);
        \\}
        \\fn looped(io: Io, walker: anytype) !void {
        \\    var group: Io.Group = .init;
        \\    while (try walker.next(io)) |entry| {
        \\        group.async(io, work, .{});
        \\        _ = entry;
        \\    }
        \\    try group.await(io);
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "return", "try" });
}

test "exits that finish the task, or sit in tests, stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Io = std.Io;
        \\fn work() void {}
        \\fn finishing(io: Io) !void {
        \\    var pending = io.async(work, .{});
        \\    return pending.await(io);
        \\}
        \\fn branch(io: Io, fail: bool) !void {
        \\    var pending = io.async(work, .{});
        \\    if (fail) {
        \\        pending.cancel(io);
        \\        return error.Failed;
        \\    }
        \\    pending.await(io);
        \\}
        \\fn inner(io: Io, items: []const u8) !void {
        \\    var group: Io.Group = .init;
        \\    for (items) |_| group.async(io, work, .{});
        \\    try group.await(io);
        \\    try other();
        \\}
        \\fn other() !void {}
        \\test "expectation" {
        \\    const io = std.testing.io;
        \\    var pending = io.async(work, .{});
        \\    try other();
        \\    pending.await(io);
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}
