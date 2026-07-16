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
        const destination = parseArgument(context, builtin_index + 2, comma) orelse continue;
        const source_argument = parseArgument(context, comma + 1, closing) orelse continue;
        if (!std.mem.eql(u8, destination.base, source_argument.base)) continue;
        if (provablyDisjoint(destination.bounds, source_argument.bounds)) continue;
        try context.emit(.{
            .rule = .aliased_memcpy,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "@memcpy destination and source both derive from '{s}'; overlapping copies are undefined behavior, use std.mem.copyForwards or std.mem.copyBackwards",
                .{destination.base},
            ),
        });
    }
}

const Argument = struct {
    base: []const u8,
    bounds: SliceBounds,
};

/// A null lower bound means the start of the base value; a null upper bound
/// means its end. A whole-value argument is .{ .lower = null, .upper = null }.
const SliceBounds = struct {
    lower: ?[]const u8,
    upper: ?[]const u8,
};

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

fn parseArgument(context: RuleRun, start: usize, end: usize) ?Argument {
    if (start >= end or context.tokens[start].tag != .identifier) return null;
    var index = start;
    var trailing_slice: ?SliceBounds = null;
    var slice_open = start;
    while (index + 1 < end) {
        switch (context.tokens[index + 1].tag) {
            .period => {
                if (index + 2 >= end or context.tokens[index + 2].tag != .identifier) return null;
                index += 2;
                trailing_slice = null;
            },
            .period_asterisk => {
                index += 1;
                trailing_slice = null;
            },
            .l_bracket => {
                const bracket_close = context.matchingToken(index + 1, .l_bracket, .r_bracket) orelse return null;
                if (bracket_close >= end) return null;
                trailing_slice = bracketSliceBounds(context, index + 1, bracket_close);
                slice_open = index + 1;
                index = bracket_close;
            },
            else => return null,
        }
    }
    if (trailing_slice) |bounds| return .{
        .base = std.mem.trimEnd(u8, context.source[context.tokens[start].loc.start..context.tokens[slice_open].loc.start], " \t\r\n"),
        .bounds = bounds,
    };
    return .{
        .base = context.source[context.tokens[start].loc.start..context.tokens[index].loc.end],
        .bounds = .{ .lower = null, .upper = null },
    };
}

fn bracketSliceBounds(context: RuleRun, opening: usize, closing: usize) ?SliceBounds {
    var depth: usize = 0;
    var ellipsis: ?usize = null;
    var upper_end = closing;
    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, index| {
        switch (token.tag) {
            .l_bracket, .l_paren, .l_brace => depth += 1,
            .r_bracket, .r_paren, .r_brace => depth -|= 1,
            .ellipsis2 => if (depth == 0) {
                if (ellipsis != null) return null;
                ellipsis = index;
            },
            .colon => if (depth == 0 and ellipsis != null and upper_end == closing) {
                upper_end = index;
            },
            else => {},
        }
    }
    const dots = ellipsis orelse return null;
    if (dots == opening + 1) return null;
    const lower = context.source[context.tokens[opening + 1].loc.start..context.tokens[dots].loc.start];
    const upper: ?[]const u8 = if (dots + 1 == upper_end)
        null
    else
        context.source[context.tokens[dots + 1].loc.start..context.tokens[upper_end].loc.start];
    return .{ .lower = std.mem.trim(u8, lower, " \t\r\n"), .upper = if (upper) |text| std.mem.trim(u8, text, " \t\r\n") else null };
}

fn provablyDisjoint(first: SliceBounds, second: SliceBounds) bool {
    if (boundsOrdered(first.upper, second.lower)) return true;
    return boundsOrdered(second.upper, first.lower);
}

/// True when the first range provably ends where the second begins or earlier:
/// either the bound texts are identical pure expressions, or both are integer
/// literals in order. A null upper bound extends to the end of the value and
/// can never come before another bound.
fn boundsOrdered(upper: ?[]const u8, lower: ?[]const u8) bool {
    const upper_text = upper orelse return false;
    const lower_text = lower orelse "0";
    if (std.mem.eql(u8, upper_text, lower_text) and upper_text.len != 0 and
        std.mem.indexOfScalar(u8, upper_text, '(') == null) return true;
    const upper_value = std.fmt.parseInt(u128, upper_text, 0) catch return false;
    const lower_value = std.fmt.parseInt(u128, lower_text, 0) catch return false;
    return upper_value <= lower_value;
}

test "memcpy between possibly overlapping slices of one base value reports the hazard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn shift(buffer: []u8, half: usize) void { @memcpy(buffer[0..half], buffer[1..]); }\n" ++
        "fn dup(state: *State) void { @memcpy(state.bytes[0..4], state.bytes[2..6]); }\n" ++
        "fn whole(buffer: []u8) void { @memcpy(buffer, buffer); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'buffer'") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "copyForwards") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "'state.bytes'") != null);
}

test "memcpy through a pointer dereference reports the shared base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn compact(node: *Node) void { @memcpy(node.*.bytes[0..4], node.*.bytes[2..6]); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'node.*.bytes'") != null);
}

test "memcpy between distinct bases or from a call result stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn copy(destination: []u8, source_bytes: []u8) void { @memcpy(destination, source_bytes); }\n" ++
        "fn fill(buffer: []u8) void { @memcpy(buffer[0..4], produce()); }\n" ++
        "fn fields(state: *State) void { @memcpy(state.front[0..4], state.back[0..4]); }\n" ++
        "fn across(a: *Node, b: *Node) void { @memcpy(a.*.bytes[0..4], b.*.bytes[0..4]); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "memcpy between provably disjoint ranges of one base stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn move(buffer: []u8, half: usize) void { @memcpy(buffer[0..half], buffer[half..]); }\n" ++
        "fn pack(state: *State) void { @memcpy(state.bytes[0..4], state.bytes[4..8]); }\n" ++
        "fn tail(buffer: []u8, half: usize) void { @memcpy(buffer[half..], buffer[0..half]); }\n" ++
        "fn sentinel(buffer: []u8, half: usize) void { @memcpy(buffer[0..half :0], buffer[half..]); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "aliased memcpy diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn shift(buffer: []u8, half: usize) void {\n" ++
        "// zig-analyzer: disable-next-line aliased-memcpy\n" ++
        "@memcpy(buffer[0..half], buffer[1..]); }";
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
