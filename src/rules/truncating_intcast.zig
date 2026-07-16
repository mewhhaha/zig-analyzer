const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.truncating_intcast);
    if (level == .off) return;

    for (context.tokens, 0..) |token, cast_index| {
        if (token.tag != .builtin or !context.tokenIs(cast_index, "@intCast") or
            cast_index + 3 >= context.tokens.len or
            context.tokens[cast_index + 1].tag != .l_paren or
            context.tokens[cast_index + 2].tag != .identifier or
            context.tokens[cast_index + 3].tag != .r_paren) continue;
        const target_type = castTargetType(context, cast_index) orelse continue;
        const target_width = intTypeWidth(target_type) orelse continue;
        const value_name = context.tokenText(cast_index + 2);
        const function = enclosingFunction(context, cast_index) orelse continue;
        const declaration = soleDeclaration(context, function, value_name, cast_index) orelse continue;
        const source_width = intTypeWidth(declaration.type_text) orelse continue;
        if (target_width >= source_width) continue;
        if (capturedName(context, function.body_start + 1, cast_index, value_name)) continue;
        if (guardMentions(context, declaration.guard_scan_start, cast_index, value_name)) continue;
        try context.emit(.{
            .rule = .truncating_intcast,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "@intCast narrows '{s}' from {s} to {s} without a range guard; an out-of-range value is safety-checked illegal behavior",
                .{ value_name, declaration.type_text, target_type },
            ),
        });
    }
}

/// Matches only 'const x: <type> = @intCast(v);' and '@as(<type>, @intCast(v))';
/// any other cast context leaves the target type unknown.
fn castTargetType(context: RuleRun, cast_index: usize) ?[]const u8 {
    const tokens = context.tokens;
    if (cast_index >= 5 and cast_index + 4 < tokens.len and
        (tokens[cast_index - 5].tag == .keyword_const or tokens[cast_index - 5].tag == .keyword_var) and
        tokens[cast_index - 4].tag == .identifier and tokens[cast_index - 3].tag == .colon and
        tokens[cast_index - 2].tag == .identifier and tokens[cast_index - 1].tag == .equal and
        tokens[cast_index + 4].tag == .semicolon) return context.tokenText(cast_index - 2);
    if (cast_index >= 4 and cast_index + 4 < tokens.len and
        tokens[cast_index - 4].tag == .builtin and context.tokenIs(cast_index - 4, "@as") and
        tokens[cast_index - 3].tag == .l_paren and tokens[cast_index - 2].tag == .identifier and
        tokens[cast_index - 1].tag == .comma and
        tokens[cast_index + 4].tag == .r_paren) return context.tokenText(cast_index - 2);
    return null;
}

/// usize and isize count as 64 bits, so usize <-> u64 is never a narrowing.
fn intTypeWidth(text: []const u8) ?u32 {
    if (std.mem.eql(u8, text, "usize") or std.mem.eql(u8, text, "isize")) return 64;
    if (text.len < 2 or (text[0] != 'u' and text[0] != 'i')) return null;
    for (text[1..]) |character| if (!std.ascii.isDigit(character)) return null;
    return std.fmt.parseInt(u32, text[1..], 10) catch null;
}

const Function = struct {
    parameters_open: usize,
    parameters_end: usize,
    body_start: usize,
    body_end: usize,
};

fn enclosingFunction(context: RuleRun, token_index: usize) ?Function {
    var innermost: ?Function = null;
    for (context.tokens[0..token_index], 0..) |token, fn_index| {
        if (token.tag != .keyword_fn) continue;
        var opening = fn_index + 1;
        while (opening < token_index and context.tokens[opening].tag != .l_paren) opening += 1;
        if (opening >= token_index) continue;
        const parameters_end = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < token_index and context.tokens[body_start].tag != .l_brace) body_start += 1;
        if (body_start >= token_index) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (body_end <= token_index) continue;
        innermost = .{
            .parameters_open = opening,
            .parameters_end = parameters_end,
            .body_start = body_start,
            .body_end = body_end,
        };
    }
    return innermost;
}

const Declaration = struct {
    type_text: []const u8,
    guard_scan_start: usize,
};

/// The value's type is trusted only when the function declares it exactly once
/// (parameter or local) with a single-token type ascription.
fn soleDeclaration(context: RuleRun, function: Function, name: []const u8, before: usize) ?Declaration {
    var found: ?Declaration = null;
    var count: usize = 0;

    var index = function.parameters_open + 1;
    while (index < function.parameters_end) : (index += 1) {
        if (context.tokens[index].tag != .identifier or !context.tokenIs(index, name)) continue;
        const previous = context.tokens[index - 1].tag;
        if (previous != .l_paren and previous != .comma) continue;
        if (index + 1 >= function.parameters_end or context.tokens[index + 1].tag != .colon) continue;
        count += 1;
        if (index + 2 < function.parameters_end and context.tokens[index + 2].tag == .identifier and
            (index + 3 == function.parameters_end or context.tokens[index + 3].tag == .comma))
        {
            found = .{ .type_text = context.tokenText(index + 2), .guard_scan_start = function.body_start + 1 };
        }
    }

    index = function.body_start + 1;
    while (index < before) : (index += 1) {
        const tag = context.tokens[index].tag;
        if (tag != .keyword_const and tag != .keyword_var) continue;
        if (!startsStatement(context, index)) continue;
        if (index + 1 >= before or context.tokens[index + 1].tag != .identifier or
            !context.tokenIs(index + 1, name)) continue;
        count += 1;
        if (index + 4 < before and context.tokens[index + 2].tag == .colon and
            context.tokens[index + 3].tag == .identifier and context.tokens[index + 4].tag == .equal)
        {
            const declaration_end = context.statementEnd(index) orelse return null;
            found = .{ .type_text = context.tokenText(index + 3), .guard_scan_start = declaration_end + 1 };
        }
    }

    if (count != 1) return null;
    return found;
}

// `const` also appears inside pointer and slice types ("[]const u8"), where the
// following identifier is the pointee type, not a binding.
fn startsStatement(context: RuleRun, index: usize) bool {
    if (index == 0) return true;
    return switch (context.tokens[index - 1].tag) {
        .semicolon, .l_brace, .r_brace, .keyword_pub, .keyword_comptime, .keyword_export => true,
        else => false,
    };
}

/// A capture rebinding ('|name|') makes the declared type unreliable.
fn capturedName(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > 0 and context.tokens[index - 1].tag == .pipe) return true;
        if (index + 1 < context.tokens.len and context.tokens[index + 1].tag == .pipe) return true;
    }
    return false;
}

/// Any assert/if/while/switch condition, std.math.cast-style call, @min/@max
/// clamp, or remainder that mentions the value counts as a range guard.
fn guardMentions(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    var index = start;
    while (index < end) : (index += 1) {
        switch (context.tokens[index].tag) {
            .keyword_if, .keyword_while, .keyword_switch => {
                if (guardedParenMentions(context, index + 1, end, name)) return true;
            },
            .identifier => {
                if (!context.tokenIs(index, "assert") and !context.tokenIs(index, "cast")) continue;
                if (guardedParenMentions(context, index + 1, end, name)) return true;
            },
            .builtin => {
                if (!context.tokenIs(index, "@min") and !context.tokenIs(index, "@max") and
                    !context.tokenIs(index, "@mod") and !context.tokenIs(index, "@rem")) continue;
                if (guardedParenMentions(context, index + 1, end, name)) return true;
            },
            .percent, .percent_equal => {
                if (index > start and context.refersToBinding(index - 1, name)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn guardedParenMentions(context: RuleRun, opening: usize, end: usize, name: []const u8) bool {
    if (opening >= end or context.tokens[opening].tag != .l_paren) return false;
    const closing = context.matchingToken(opening, .l_paren, .r_paren) orelse return true;
    for (context.tokens[opening + 1 .. @min(closing, end)], opening + 1..) |token, index| {
        if (token.tag == .identifier and context.refersToBinding(index, name)) return true;
    }
    return false;
}

test "narrowing intCast of a wider declared value is flagged in both cast shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn direct(count: u64) void {\n" ++
        "    const small: u32 = @intCast(count);\n" ++
        "    _ = small;\n" ++
        "}\n" ++
        "fn wrapped() void {\n" ++
        "    const total: u64 = compute();\n" ++
        "    use(@as(u16, @intCast(total)));\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'count'") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "'total'") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "u16") != null);
}

test "a guard mentioning the value before the cast keeps it clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn asserted(count: u64) void {\n" ++
        "    assert(count <= std.math.maxInt(u32));\n" ++
        "    const small: u32 = @intCast(count);\n" ++
        "    _ = small;\n" ++
        "}\n" ++
        "fn branched(count: u64) void {\n" ++
        "    if (count > 100) return;\n" ++
        "    const small: u32 = @intCast(count);\n" ++
        "    _ = small;\n" ++
        "}\n" ++
        "fn checked(count: u64) void {\n" ++
        "    const verified = std.math.cast(u32, count) orelse return;\n" ++
        "    _ = verified;\n" ++
        "    const small: u32 = @intCast(count);\n" ++
        "    _ = small;\n" ++
        "}\n" ++
        "fn clamped(count: u64) void {\n" ++
        "    const bounded = @min(count, 10);\n" ++
        "    _ = bounded;\n" ++
        "    const small: u32 = @intCast(count);\n" ++
        "    _ = small;\n" ++
        "}\n" ++
        "fn wrappedaround(count: u64) void {\n" ++
        "    const slot = count % 16;\n" ++
        "    _ = slot;\n" ++
        "    const small: u32 = @intCast(count);\n" ++
        "    _ = small;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "widening equal-width and usize-u64 casts stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn widen(count: u32) void {\n" ++
        "    const wide: u64 = @intCast(count);\n" ++
        "    _ = wide;\n" ++
        "}\n" ++
        "fn resize(count: usize) void {\n" ++
        "    const same: u64 = @intCast(count);\n" ++
        "    _ = same;\n" ++
        "}\n" ++
        "fn tosize(count: u64) void {\n" ++
        "    const same: usize = @intCast(count);\n" ++
        "    _ = same;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "unknown ambiguous or shadowed value types stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn inferred() void {\n" ++
        "    const total = compute();\n" ++
        "    const small: u32 = @intCast(total);\n" ++
        "    _ = small;\n" ++
        "}\n" ++
        "fn foreign() void {\n" ++
        "    const small: u32 = @intCast(global_total);\n" ++
        "    _ = small;\n" ++
        "}\n" ++
        "fn shadowed(count: u64) void {\n" ++
        "    {\n" ++
        "        const count: u8 = 1;\n" ++
        "        _ = count;\n" ++
        "    }\n" ++
        "    const small: u32 = @intCast(count);\n" ++
        "    _ = small;\n" ++
        "}\n" ++
        "fn aliased(items: []const u64) void {\n" ++
        "    for (items) |count| {\n" ++
        "        _ = count;\n" ++
        "    }\n" ++
        "    const count: u64 = 1;\n" ++
        "    const small: u32 = @intCast(count);\n" ++
        "    _ = small;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "truncating intcast diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn direct(count: u64) void {\n" ++
        "    // zig-analyzer: disable-next-line truncating-intcast\n" ++
        "    const small: u32 = @intCast(count);\n" ++
        "    _ = small;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.truncating_intcast)] = .hint;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
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
