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

fn bodyCanExit(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| {
        switch (token.tag) {
            .keyword_break,
            .keyword_return,
            .keyword_try,
            .keyword_catch,
            .keyword_unreachable,
            .builtin,
            .l_paren,
            => return true,
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
