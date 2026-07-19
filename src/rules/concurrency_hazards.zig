const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

const FunctionRange = struct {
    start: usize,
    body_start: usize,
    body_end: usize,
};

const LockUse = struct {
    field: []const u8,
    index: usize,
};

const LockEdge = struct {
    first: []const u8,
    second: []const u8,
    index: usize,
    owner_scope: ?usize,
};

pub fn run(context: RuleRun) !void {
    try findLockOrderCycles(context);
    try findWaitsWhileHoldingLocks(context);
}

fn findLockOrderCycles(context: RuleRun) !void {
    const level = context.level(.lock_order_cycle);
    if (level == .off) return;

    var edges: std.ArrayList(LockEdge) = .empty;
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = functionRange(context, function_index) orelse continue;
        const owner_scope = context.enclosingOpeningBrace(function.start);
        var held: std.ArrayList(LockUse) = .empty;
        for (context.tokens[function.body_start + 1 .. function.body_end], function.body_start + 1..) |body_token, index| {
            if (body_token.tag != .identifier or index < 4 or context.tokens[index - 1].tag != .period or
                context.tokens[index + 1].tag != .l_paren) continue;
            const field = selfFieldBeforeMethod(context, index) orelse continue;
            if (context.enclosingOpeningBrace(index) != function.body_start) continue;
            if (context.tokenIs(index, "lock")) {
                for (held.items) |earlier| {
                    if (std.mem.eql(u8, earlier.field, field)) continue;
                    for (edges.items) |edge| {
                        if (edge.owner_scope != owner_scope or !std.mem.eql(u8, edge.first, field) or
                            !std.mem.eql(u8, edge.second, earlier.field)) continue;
                        try context.emit(.{
                            .rule = .lock_order_cycle,
                            .level = level,
                            .span = context.tokens[index].loc,
                            .message = try std.fmt.allocPrint(
                                context.allocator,
                                "lock order '{s}' then '{s}' conflicts with an earlier '{s}' then '{s}' acquisition and can deadlock",
                                .{ earlier.field, field, field, earlier.field },
                            ),
                        });
                        return;
                    }
                    try edges.append(context.allocator, .{
                        .first = earlier.field,
                        .second = field,
                        .index = index,
                        .owner_scope = owner_scope,
                    });
                }
                try held.append(context.allocator, .{ .field = field, .index = index });
            } else if (context.tokenIs(index, "unlock") and !precededByDefer(context, index)) {
                var held_index = held.items.len;
                while (held_index > 0) {
                    held_index -= 1;
                    if (!std.mem.eql(u8, held.items[held_index].field, field)) continue;
                    _ = held.orderedRemove(held_index);
                    break;
                }
            }
        }
    }
}

fn findWaitsWhileHoldingLocks(context: RuleRun) !void {
    const level = context.level(.wait_while_holding_lock);
    if (level == .off) return;

    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = functionRange(context, function_index) orelse continue;
        const lock_index = methodInRange(context, "lock", function.body_start + 1, function.body_end) orelse continue;
        const lock_field = selfFieldBeforeMethod(context, lock_index) orelse continue;
        const while_index = tokenTagInRange(context, .keyword_while, lock_index + 1, function.body_end) orelse continue;
        const unlock_index = methodInRange(context, "unlock", lock_index + 1, function.body_end);
        if (unlock_index != null and unlock_index.? < while_index and !precededByDefer(context, unlock_index.?)) continue;
        const state_field = loadedSelfField(context, while_index, function.body_end) orelse continue;
        if (!anotherFunctionSignals(context, function.start, context.enclosingOpeningBrace(function.start), lock_field, state_field)) continue;
        try context.emit(.{
            .rule = .wait_while_holding_lock,
            .level = level,
            .span = context.tokens[while_index].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "loop waits for '{s}' while holding '{s}', but another operation needs that lock to update the state",
                .{ state_field, lock_field },
            ),
        });
    }
}

fn functionRange(context: RuleRun, function_index: usize) ?FunctionRange {
    var body_start = function_index + 1;
    while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace and
        context.tokens[body_start].tag != .semicolon) : (body_start += 1)
    {}
    if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) return null;
    const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse return null;
    return .{ .start = function_index, .body_start = body_start, .body_end = body_end };
}

fn selfFieldBeforeMethod(context: RuleRun, method_index: usize) ?[]const u8 {
    if (method_index < 4 or context.tokens[method_index - 1].tag != .period or
        context.tokens[method_index - 2].tag != .identifier or context.tokens[method_index - 3].tag != .period or
        !context.tokenIs(method_index - 4, "self")) return null;
    return context.tokenText(method_index - 2);
}

fn precededByDefer(context: RuleRun, method_index: usize) bool {
    const start = method_index -| 8;
    for (context.tokens[start..method_index]) |token| if (token.tag == .keyword_defer) return true;
    return false;
}

fn methodInRange(context: RuleRun, method: []const u8, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, method) and index + 1 < end and
            context.tokens[index + 1].tag == .l_paren) return index;
    }
    return null;
}

fn tokenTagInRange(context: RuleRun, tag: std.zig.Token.Tag, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

fn loadedSelfField(context: RuleRun, while_index: usize, end: usize) ?[]const u8 {
    const statement_end = @min(context.statementEnd(while_index) orelse end, end);
    var index = while_index + 1;
    while (index + 4 < statement_end) : (index += 1) {
        if (!context.tokenIs(index, "self") or context.tokens[index + 1].tag != .period or
            context.tokens[index + 2].tag != .identifier or context.tokens[index + 3].tag != .period or
            !context.tokenIs(index + 4, "load")) continue;
        return context.tokenText(index + 2);
    }
    return null;
}

fn anotherFunctionSignals(
    context: RuleRun,
    waiting_function: usize,
    owner_scope: ?usize,
    lock_field: []const u8,
    state_field: []const u8,
) bool {
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index == waiting_function or
            context.enclosingOpeningBrace(function_index) != owner_scope) continue;
        const function = functionRange(context, function_index) orelse continue;
        const lock_index = methodInRange(context, "lock", function.body_start + 1, function.body_end) orelse continue;
        const candidate_lock = selfFieldBeforeMethod(context, lock_index) orelse continue;
        if (!std.mem.eql(u8, candidate_lock, lock_field)) continue;
        var index = lock_index + 1;
        while (index + 4 < function.body_end) : (index += 1) {
            if (context.tokenIs(index, "self") and context.tokens[index + 1].tag == .period and
                context.tokenIs(index + 2, state_field) and context.tokens[index + 3].tag == .period and
                context.tokenIs(index + 4, "store")) return true;
        }
    }
    return false;
}

test "opposite nested lock orders form a cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = struct { primary: Mutex, secondary: Mutex, " ++
        "fn add(self: *State) void { self.primary.lock(); defer self.primary.unlock(); self.secondary.lock(); defer self.secondary.unlock(); } " ++
        "fn cancel(self: *State) void { self.secondary.lock(); defer self.secondary.unlock(); self.primary.lock(); defer self.primary.unlock(); } };";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.lock_order_cycle, findings[0].rule);
}

test "waiting for state while its signaling lock is held reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = struct { mutex: Mutex, ready: Atomic(bool), " ++
        "fn wait(self: *State) void { self.mutex.lock(); defer self.mutex.unlock(); while (!self.ready.load(.acquire)) {} } " ++
        "fn signal(self: *State) void { self.mutex.lock(); defer self.mutex.unlock(); self.ready.store(true, .release); } };";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.wait_while_holding_lock, findings[0].rule);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = allocator, .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
