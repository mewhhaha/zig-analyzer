const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

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
    for (context.tokens[0..loop_index], 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        var parameters_start = function_index + 1;
        while (parameters_start < loop_index and context.tokens[parameters_start].tag != .l_paren) : (parameters_start += 1) {}
        if (parameters_start == loop_index) continue;
        const parameters_end = context.matchingToken(parameters_start, .l_paren, .r_paren) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < loop_index) : (body_start += 1) {
            if (context.tokens[body_start].tag != .l_brace) continue;
            const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
            if (body_end < loop_index) {
                if (body_start > parameters_end + 1 and switch (context.tokens[body_start - 1].tag) {
                    .period, .keyword_error, .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => true,
                    else => false,
                }) continue;
                break;
            }
            for (context.tokens[parameters_end + 1 .. body_start], parameters_end + 1..) |return_token, return_index| {
                if (return_token.tag == .identifier and context.tokenIs(return_index, "noreturn")) return true;
            }
            return false;
        }
    }
    return false;
}

fn bodyCanExit(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .keyword_break,
            .keyword_return,
            .keyword_try,
            .keyword_catch,
            .keyword_unreachable,
            .builtin,
            .l_paren,
            => return true,
            // 'continue :label' targets an enclosing loop, leaving this one.
            .keyword_continue => if (index + 1 < end and context.tokens[index + 1].tag == .colon) return true,
            else => {},
        }
    }
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
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "never exit") != null);
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
        "fn trampoline() noreturn { switchContext(); while (true) {} }\n" ++
        "fn stuck() void { while (true) {} }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "busy loop diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn spin() void {\n" ++
        "// zig-analyzer: disable-next-line unconditional-busy-loop\n" ++
        "while (true) {} }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
