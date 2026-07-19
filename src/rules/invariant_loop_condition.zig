const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.invariant_loop_condition);
    if (level == .off) return;

    for (context.tokens, 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 5 >= context.tokens.len or
            context.tokens[while_index + 1].tag != .l_paren or
            context.tokens[while_index + 2].tag != .identifier or
            context.tokens[while_index + 4].tag != .number_literal or
            context.tokens[while_index + 5].tag != .r_paren) continue;
        const operator = context.tokens[while_index + 3].tag;
        if (operator != .angle_bracket_left and operator != .angle_bracket_left_equal and
            operator != .angle_bracket_right and operator != .angle_bracket_right_equal and
            operator != .equal_equal and operator != .bang_equal) continue;
        const name = context.tokenText(while_index + 2);
        const left = uniqueLiteralConst(context, name, while_index) orelse continue;
        const right = std.fmt.parseInt(u128, context.tokenText(while_index + 4), 0) catch continue;
        const result = switch (operator) {
            .angle_bracket_left => left < right,
            .angle_bracket_left_equal => left <= right,
            .angle_bracket_right => left > right,
            .angle_bracket_right_equal => left >= right,
            .equal_equal => left == right,
            .bang_equal => left != right,
            else => unreachable,
        };
        try context.emit(.{
            .rule = .invariant_loop_condition,
            .level = level,
            .span = context.tokens[while_index + 2].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "while condition is invariant and always {s} because '{s}' is a constant; express the actual exit condition directly",
                .{ if (result) "true" else "false", name },
            ),
        });
    }
}

fn uniqueLiteralConst(context: RuleRun, name: []const u8, use_index: usize) ?u128 {
    var value: ?u128 = null;
    for (context.tokens[0..use_index], 0..) |token, index| {
        if (token.tag != .keyword_const and token.tag != .keyword_var) continue;
        if (index + 3 >= context.tokens.len or !context.tokenIs(index + 1, name)) continue;
        if (!bindingVisibleAt(context, index + 1, use_index)) continue;
        if (token.tag == .keyword_var or value != null) return null;
        const statement_end = context.statementEnd(index) orelse return null;
        var equal_index = index + 2;
        while (equal_index < statement_end and context.tokens[equal_index].tag != .equal) : (equal_index += 1) {}
        if (equal_index + 2 != statement_end or context.tokens[equal_index + 1].tag != .number_literal) return null;
        value = std.fmt.parseInt(u128, context.tokenText(equal_index + 1), 0) catch return null;
    }
    if (parameterVisibleAt(context, name, use_index)) return null;
    for (context.tokens[0..use_index], 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        const is_const_name = index > 0 and context.tokens[index - 1].tag == .keyword_const;
        if ((index > 0 and context.tokens[index - 1].tag == .pipe) or
            (index + 1 < context.tokens.len and context.tokens[index + 1].tag == .pipe))
        {
            if (captureVisibleAt(context, index, use_index)) return null;
        }
        if (!is_const_name and index + 1 < context.tokens.len and context.tokens[index + 1].tag == .colon) continue;
    }
    return value;
}

fn bindingVisibleAt(context: RuleRun, binding_index: usize, use_index: usize) bool {
    const opening = context.enclosingOpeningBrace(binding_index) orelse return true;
    const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse return false;
    return binding_index < use_index and use_index < closing;
}

fn parameterVisibleAt(context: RuleRun, name: []const u8, use_index: usize) bool {
    for (context.tokens[0..use_index], 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        var parameters_start = function_index + 1;
        while (parameters_start < use_index and context.tokens[parameters_start].tag != .l_paren) : (parameters_start += 1) {}
        if (parameters_start >= use_index) continue;
        const parameters_end = context.matchingToken(parameters_start, .l_paren, .r_paren) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < use_index and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= use_index) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (use_index >= body_end) continue;
        for (context.tokens[parameters_start + 1 .. parameters_end], parameters_start + 1..) |parameter, index| {
            if (parameter.tag == .identifier and context.tokenIs(index, name) and index + 1 < parameters_end and
                context.tokens[index + 1].tag == .colon) return true;
        }
    }
    return false;
}

fn captureVisibleAt(context: RuleRun, capture_index: usize, use_index: usize) bool {
    var body_start = capture_index + 1;
    while (body_start < use_index and body_start - capture_index < 6 and
        context.tokens[body_start].tag != .l_brace) : (body_start += 1)
    {}
    if (body_start >= use_index or context.tokens[body_start].tag != .l_brace) return false;
    const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse return false;
    return use_index < body_end;
}

test "a loop condition over a literal constant reports its invariant result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const bytes_per_line = 16;\n" ++
        "fn dump() void { while (bytes_per_line > 0) { if (done()) break; } }\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "always true") != null);
}

test "variables and constants used in runtime conditions stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn consume(remaining: usize) void { while (remaining > 0) {} }\n" ++
        "fn count() void { var remaining: usize = 16; while (remaining > 0) : (remaining -= 1) {} }\n" ++
        "const limit = 16; fn shadowed(limit: usize) void { while (limit > 0) {} }\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "unrelated parameters do not hide global invariant loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const limit = 16; fn shadowed(limit: usize) void { while (limit > 0) {} } " ++
        "fn global() void { while (limit > 0) { if (done()) break; } }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.invariant_loop_condition)] = .information;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
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
