const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .unconditional_busy_loop,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.unconditional_busy_loop);
    if (level == .off) return;

    for (context.tokens, 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 4 >= context.tokens.len or
            context.tokens[while_index + 1].tag != .l_paren or
            context.tokens[while_index + 2].tag != .identifier or
            !context.tokenIs(while_index + 2, "true") or
            context.tokens[while_index + 3].tag != .r_paren) continue;
        const after_condition = while_index + 4;
        if (context.tokens[after_condition].tag == .colon) continue;

        var body_start = after_condition;
        var body_end: usize = undefined;
        if (context.tokens[after_condition].tag == .l_brace) {
            body_start = after_condition + 1;
            body_end = context.matchingToken(after_condition, .l_brace, .r_brace) orelse continue;
        } else {
            body_end = context.statementEnd(body_start) orelse continue;
        }
        if (insideNoreturnFunction(context, while_index)) continue;
        if (bodyCanExit(context, body_start, body_end)) continue;
        try context.emit(.{
            .rule = .unconditional_busy_loop,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(
                u8,
                "'while (true)' body contains no break, return, or call, so the loop can never exit",
            ),
        });
    }
}

fn insideNoreturnFunction(context: RuleRun, loop_index: usize) bool {
    var cursor = loop_index;
    while (cursor > 0) {
        cursor -= 1;
        if (context.tokens[cursor].tag != .keyword_fn) continue;
        var parameters_start = cursor + 1;
        while (parameters_start < loop_index and context.tokens[parameters_start].tag != .l_paren) : (parameters_start += 1) {}
        if (parameters_start >= loop_index) continue;
        const parameters_end = context.matchingToken(parameters_start, .l_paren, .r_paren) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < loop_index and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= loop_index) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (body_end < loop_index) continue;
        for (context.tokens[parameters_end + 1 .. body_start], parameters_end + 1..) |return_token, return_index| {
            if (return_token.tag == .identifier and context.tokenIs(return_index, "noreturn")) return true;
        }
        return false;
    }
    return false;
}

fn bodyCanExit(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .keyword_break => if (breakExitsOuterLoop(context, start, index)) return true,
            .keyword_return,
            .keyword_try,
            .keyword_catch,
            .keyword_unreachable,
            .builtin,
            => return true,
            .l_paren => if (isFunctionCall(context, start, index)) return true,
            // 'continue :label' targets an enclosing loop, leaving this one.
            .keyword_continue => if (index + 1 < end and context.tokens[index + 1].tag == .colon) return true,
            else => {},
        }
    }
    return false;
}

fn breakExitsOuterLoop(context: RuleRun, start: usize, break_index: usize) bool {
    if (break_index + 1 < context.tokens.len and context.tokens[break_index + 1].tag == .colon) return true;
    var brace_depth: usize = 0;
    var cursor = break_index;
    while (cursor > start) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .r_brace => brace_depth += 1,
            .l_brace => {
                if (brace_depth > 0) {
                    brace_depth -= 1;
                } else {
                    if (isLoopBodyOpening(context, start, cursor)) return false;
                }
            },
            .semicolon => if (brace_depth == 0) {
                if (isLoopHeader(context, cursor + 1, break_index)) return false;
            },
            else => {},
        }
    }
    return true;
}

fn isLoopBodyOpening(context: RuleRun, start: usize, l_brace_index: usize) bool {
    var cursor = l_brace_index;
    while (cursor > start) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .keyword_while, .keyword_for => return true,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn isLoopHeader(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| {
        if (token.tag == .keyword_while or token.tag == .keyword_for) return true;
    }
    return false;
}

fn isFunctionCall(context: RuleRun, start: usize, paren_index: usize) bool {
    if (paren_index == 0 or paren_index <= start) return false;
    const prev = context.tokens[paren_index - 1];
    if (prev.tag == .identifier) {
        if (paren_index >= 2 and context.tokens[paren_index - 2].tag == .keyword_fn) return false;
        return true;
    }
    if (prev.tag == .r_paren or prev.tag == .r_bracket) return true;
    return false;
}

test "while true without any exit or call reports the guaranteed hang" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn spin() void { while (true) {} }\n" ++
        "fn count(start: u32) void { var value = start; while (true) value +%= 1; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "never exit") != null);
}

test "loops with calls breaks returns or fallible bodies stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn serve() void { while (true) { poll(); } }\n" ++
        "fn wait(flag: *bool) void { while (true) { if (flag.*) break; } }\n" ++
        "fn pump() !void { while (true) { try step(); } }\n" ++
        "fn once() void { while (true) return; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a labeled continue to an enclosing loop counts as an exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn drain(items: *Queue) void {\n" ++
        "    outer: while (items.refill()) {\n" ++
        "        while (true) {\n" ++
        "            continue :outer;\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n" ++
        "fn stuck() void { while (true) { continue; } }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "terminal loops satisfy noreturn functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn helper() void { }\n" ++
        "fn trampoline() noreturn { switchContext(); while (true) {} }\n" ++
        "fn stuck() void { while (true) {} }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "arithmetic parens and inner loop breaks do not exit outer while true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn spin_arith(v: u32) void { var x = v; while (true) { x = (v + 1) * 2; } }\n" ++
        "fn spin_inner() void { while (true) { while (true) { break; } } }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, types.Configuration.defaults());
}
