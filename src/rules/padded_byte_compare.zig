const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.padded_byte_compare);
    if (level == .off) return;

    for (context.tokens, 0..) |token, eql_index| {
        if (token.tag != .identifier or !context.tokenIs(eql_index, "eql") or
            eql_index + 4 >= context.tokens.len or
            context.tokens[eql_index + 1].tag != .l_paren or
            !context.tokenIs(eql_index + 2, "u8") or
            context.tokens[eql_index + 3].tag != .comma) continue;
        const closing = context.matchingToken(eql_index + 1, .l_paren, .r_paren) orelse continue;
        const argument_comma = topLevelComma(context, eql_index + 4, closing) orelse continue;
        const first = bytesOperandValue(context, eql_index + 4, argument_comma);
        const second = bytesOperandValue(context, argument_comma + 1, closing);
        const padded = paddedOperandType(context, first, eql_index) orelse
            paddedOperandType(context, second, eql_index) orelse continue;

        var path_start = eql_index;
        while (path_start >= 2 and context.tokens[path_start - 1].tag == .period and
            context.tokens[path_start - 2].tag == .identifier) path_start -= 2;
        try context.emit(.{
            .rule = .padded_byte_compare,
            .level = level,
            .span = .{ .start = context.tokens[path_start].loc.start, .end = context.tokens[closing].loc.end },
            .message = try std.fmt.allocPrint(
                context.allocator,
                "byte comparison of '{s}' values includes padding bytes whose contents are undefined, so equal values can compare unequal; compare fields directly or use std.meta.eql",
                .{padded},
            ),
        });
    }
}

fn topLevelComma(context: RuleRun, start: usize, end: usize) ?usize {
    var depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) return index,
            else => {},
        }
    }
    return null;
}

/// Accepts exactly 'asBytes(&v)' and 'toBytes(v)' (optionally '&'-prefixed and
/// path-qualified) and returns the token index of 'v'.
fn bytesOperandValue(context: RuleRun, start: usize, end: usize) ?usize {
    var index = start;
    if (index < end and context.tokens[index].tag == .ampersand) index += 1;
    if (index >= end or context.tokens[index].tag != .identifier) return null;
    var callee = index;
    while (callee + 2 < end and context.tokens[callee + 1].tag == .period and
        context.tokens[callee + 2].tag == .identifier) callee += 2;
    const takes_pointer = context.tokenIs(callee, "asBytes");
    if (!takes_pointer and !context.tokenIs(callee, "toBytes")) return null;
    if (callee + 1 >= end or context.tokens[callee + 1].tag != .l_paren) return null;
    var value = callee + 2;
    if (takes_pointer) {
        if (value >= end or context.tokens[value].tag != .ampersand) return null;
        value += 1;
    }
    if (value + 2 != end or context.tokens[value].tag != .identifier or
        context.tokens[value + 1].tag != .r_paren) return null;
    return value;
}

fn paddedOperandType(context: RuleRun, value_index: ?usize, use_index: usize) ?[]const u8 {
    const value = value_index orelse return null;
    const type_name = declaredTypeName(context, context.tokenText(value), use_index) orelse return null;
    const layout = localPlainStructLayout(context, type_name) orelse return null;
    if (layout.max_alignment <= 1 or layout.size_sum % layout.max_alignment == 0) return null;
    return type_name;
}

/// The value's type is trusted only for a parameter or a local with a
/// single-token type ascription inside the function using it.
fn declaredTypeName(context: RuleRun, name: []const u8, before: usize) ?[]const u8 {
    const function = enclosingFunction(context, before) orelse return null;

    var index = function.parameters_open + 1;
    while (index < function.parameters_end) : (index += 1) {
        if (context.tokens[index].tag != .identifier or !context.tokenIs(index, name)) continue;
        const previous = context.tokens[index - 1].tag;
        if (previous != .l_paren and previous != .comma) continue;
        if (index + 2 >= function.parameters_end or context.tokens[index + 1].tag != .colon or
            context.tokens[index + 2].tag != .identifier) return null;
        if (index + 3 != function.parameters_end and context.tokens[index + 3].tag != .comma) return null;
        return context.tokenText(index + 2);
    }

    index = function.body_start + 1;
    while (index < before) : (index += 1) {
        const tag = context.tokens[index].tag;
        if (tag != .keyword_const and tag != .keyword_var) continue;
        if (index + 4 >= before or !context.tokenIs(index + 1, name) or
            context.tokens[index + 1].tag != .identifier) continue;
        if (context.tokens[index + 2].tag != .colon or context.tokens[index + 3].tag != .identifier or
            context.tokens[index + 4].tag != .equal) return null;
        return context.tokenText(index + 3);
    }
    return null;
}

const Function = struct {
    parameters_open: usize,
    parameters_end: usize,
    body_start: usize,
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
        };
    }
    return innermost;
}

const Layout = struct {
    size_sum: usize,
    max_alignment: usize,
};

/// Layout is computed only for a same-file 'const T = struct { ... }' (never
/// packed or extern) whose fields are all fixed-size primitives. Zig may
/// reorder fields, but when the field sizes cannot fill a multiple of the
/// largest alignment, every permutation contains padding.
fn localPlainStructLayout(context: RuleRun, type_name: []const u8) ?Layout {
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 4 >= context.tokens.len or
            !context.tokenIs(index + 1, type_name) or
            context.tokens[index + 2].tag != .equal or
            context.tokens[index + 3].tag != .keyword_struct or
            context.tokens[index + 4].tag != .l_brace) continue;
        const closing = context.matchingToken(index + 4, .l_brace, .r_brace) orelse return null;

        var layout: Layout = .{ .size_sum = 0, .max_alignment = 1 };
        var field_count: usize = 0;
        var cursor = index + 5;
        while (cursor < closing) {
            if (cursor + 2 >= closing or context.tokens[cursor].tag != .identifier or
                context.tokens[cursor + 1].tag != .colon or
                context.tokens[cursor + 2].tag != .identifier) return null;
            const primitive = primitiveLayout(context.tokenText(cursor + 2)) orelse return null;
            layout.size_sum += primitive.size_sum;
            layout.max_alignment = @max(layout.max_alignment, primitive.max_alignment);
            field_count += 1;
            if (cursor + 3 == closing) break;
            if (context.tokens[cursor + 3].tag != .comma) return null;
            cursor += 4;
        }
        if (field_count == 0) return null;
        return layout;
    }
    return null;
}

fn primitiveLayout(type_text: []const u8) ?Layout {
    const primitives = [_]struct { name: []const u8, bytes: usize }{
        .{ .name = "bool", .bytes = 1 },
        .{ .name = "u8", .bytes = 1 },
        .{ .name = "i8", .bytes = 1 },
        .{ .name = "u16", .bytes = 2 },
        .{ .name = "i16", .bytes = 2 },
        .{ .name = "u32", .bytes = 4 },
        .{ .name = "i32", .bytes = 4 },
        .{ .name = "u64", .bytes = 8 },
        .{ .name = "i64", .bytes = 8 },
        .{ .name = "u128", .bytes = 16 },
        .{ .name = "i128", .bytes = 16 },
        .{ .name = "f16", .bytes = 2 },
        .{ .name = "f32", .bytes = 4 },
        .{ .name = "f64", .bytes = 8 },
        .{ .name = "f128", .bytes = 16 },
    };
    for (primitives) |primitive| {
        if (std.mem.eql(u8, type_text, primitive.name)) {
            return .{ .size_sum = primitive.bytes, .max_alignment = primitive.bytes };
        }
    }
    return null;
}

test "byte comparison of a provably padded struct is reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Pair = struct { flag: u8, count: u32 };\n" ++
        "fn same(a: Pair, b: Pair) bool {\n" ++
        "    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));\n" ++
        "}\n" ++
        "fn copies(a: Pair, b: Pair) bool {\n" ++
        "    return mem.eql(u8, &mem.toBytes(a), &mem.toBytes(b));\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'Pair'") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "std.meta.eql") != null);
}

test "tightly packed structs compare their bytes cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Even = struct { low: u32, high: u32 };\n" ++
        "const Bytes = struct { first: u8, second: u8, third: bool };\n" ++
        "const Filled = struct { flag: u8, pad: u8, half: u16, count: u32 };\n" ++
        "fn even(a: Even, b: Even) bool {\n" ++
        "    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));\n" ++
        "}\n" ++
        "fn bytes(a: Bytes, b: Bytes) bool {\n" ++
        "    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));\n" ++
        "}\n" ++
        "fn filled(a: Filled, b: Filled) bool {\n" ++
        "    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "extern and packed structs with defined layout are left alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Raw = extern struct { flag: u8, count: u32 };\n" ++
        "const Bits = packed struct { flag: u8, count: u32 };\n" ++
        "fn raw(a: Raw, b: Raw) bool {\n" ++
        "    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));\n" ++
        "}\n" ++
        "fn bits(a: Bits, b: Bits) bool {\n" ++
        "    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));\n" ++
        "}\n";
    const findingsList = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findingsList.len);
}

test "unresolvable operand types stay silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Pair = struct { flag: u8, count: u32, name: []const u8 };\n" ++
        "fn imported(a: protocol.Header, b: protocol.Header) bool {\n" ++
        "    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));\n" ++
        "}\n" ++
        "fn nonprimitive(a: Pair, b: Pair) bool {\n" ++
        "    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));\n" ++
        "}\n" ++
        "fn slices(a: []const u8, b: []const u8) bool {\n" ++
        "    return std.mem.eql(u8, a, b);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "padded byte compare diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Pair = struct { flag: u8, count: u32 };\n" ++
        "fn same(a: Pair, b: Pair) bool {\n" ++
        "    // zig-analyzer: disable-next-line padded-byte-compare\n" ++
        "    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));\n" ++
        "}\n";
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
