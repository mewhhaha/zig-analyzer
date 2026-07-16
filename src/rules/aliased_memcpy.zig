const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.aliased_memcpy);
    if (level == .off) return;

    for (context.tokens, 0..) |token, builtin_index| {
        if (token.tag != .builtin or !context.tokenIs(builtin_index, "@memcpy") or
            builtin_index + 1 >= context.tokens.len or
            context.tokens[builtin_index + 1].tag != .l_paren) continue;
        const closing = context.matchingToken(builtin_index + 1, .l_paren, .r_paren) orelse continue;
        const comma = singleTopLevelComma(context, builtin_index + 2, closing) orelse continue;
        const destination_base = basePath(context, builtin_index + 2, comma) orelse continue;
        const source_base = basePath(context, comma + 1, closing) orelse continue;
        if (!std.mem.eql(u8, destination_base, source_base)) continue;
        try context.emit(.{
            .rule = .aliased_memcpy,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "@memcpy destination and source both derive from '{s}'; overlapping copies are undefined behavior, use std.mem.copyForwards or std.mem.copyBackwards",
                .{destination_base},
            ),
        });
    }
}

fn singleTopLevelComma(context: RuleRun, start: usize, end: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var comma: ?usize = null;
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .comma => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                if (comma != null) return null;
                comma = index;
            },
            else => {},
        }
    }
    return comma;
}

fn basePath(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    if (start >= end or context.tokens[start].tag != .identifier) return null;
    var index = start;
    while (index + 2 < end and context.tokens[index + 1].tag == .period and
        context.tokens[index + 2].tag == .identifier) index += 2;
    if (index + 1 < end and context.tokens[index + 1].tag != .l_bracket) return null;
    return context.source[context.tokens[start].loc.start..context.tokens[index].loc.end];
}

test "memcpy between slices of one base value reports the overlap hazard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn shift(buffer: []u8, half: usize) void { @memcpy(buffer[0..half], buffer[half..]); }\n" ++
        "fn dup(state: *State) void { @memcpy(state.bytes[0..4], state.bytes[4..8]); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'buffer'") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "copyForwards") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "'state.bytes'") != null);
}

test "memcpy between distinct bases or from a call result stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn copy(destination: []u8, source_bytes: []u8) void { @memcpy(destination, source_bytes); }\n" ++
        "fn fill(buffer: []u8) void { @memcpy(buffer[0..4], produce()); }\n" ++
        "fn fields(state: *State) void { @memcpy(state.front[0..4], state.back[0..4]); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "aliased memcpy diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn shift(buffer: []u8, half: usize) void {\n" ++
        "// zig-analyzer: disable-next-line aliased-memcpy\n" ++
        "@memcpy(buffer[0..half], buffer[half..]); }";
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
