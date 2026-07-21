const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.truncating_intcast);
    if (level == .off) return;

    for (context.tokens, 0..) |token, cast_index| {
        if (token.tag != .builtin or !context.tokenIs(cast_index, "@intCast") or
            cast_index + 3 >= context.tokens.len or context.tokens[cast_index + 1].tag != .l_paren) continue;
        const value = castValue(context, cast_index) orelse continue;
        const target_type = castTargetType(context, cast_index) orelse continue;
        const target = intType(target_type) orelse continue;
        const value_name = context.tokenText(value.binding_index);
        const function = enclosingFunction(context, cast_index) orelse continue;
        const declaration = soleDeclaration(context, function, value_name, cast_index);
        const source_type = if (value.is_length)
            "usize"
        else if (value.field_index) |field_index|
            if (declaration) |known|
                structFieldType(context, known.type_text, context.tokenText(field_index)) orelse continue
            else
                continue
        else if (declaration) |known| known.type_text else continue;
        const source = intType(source_type) orelse continue;
        if (target.width >= source.width and (target.signed or !source.signed)) continue;
        if (!value.is_length and capturedName(context, function.body_start + 1, cast_index, value_name)) continue;
        const guard_scan_start = if (declaration) |known| known.guard_scan_start else function.body_start + 1;
        if (guardMentions(context, guard_scan_start, cast_index, value_name)) continue;
        try context.emit(.{
            .rule = .truncating_intcast,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "@intCast converts '{s}' from {s} to {s} without a range guard; an out-of-range value is safety-checked illegal behavior",
                .{
                    context.source[context.tokens[value.binding_index].loc.start..context.tokens[value.value_end_index].loc.end],
                    source_type,
                    target_type,
                },
            ),
        });
    }
}

const CastValue = struct {
    binding_index: usize,
    field_index: ?usize = null,
    value_end_index: usize,
    is_length: bool = false,
};

fn castValue(context: RuleRun, cast_index: usize) ?CastValue {
    if (context.tokens[cast_index + 2].tag != .identifier) return null;
    if (context.tokens[cast_index + 3].tag == .r_paren) return .{
        .binding_index = cast_index + 2,
        .value_end_index = cast_index + 2,
    };
    if (cast_index + 7 < context.tokens.len and context.tokens[cast_index + 3].tag == .period and
        context.tokens[cast_index + 4].tag == .identifier and context.tokens[cast_index + 5].tag == .period and
        context.tokenIs(cast_index + 6, "len") and context.tokens[cast_index + 7].tag == .r_paren) return .{
        .binding_index = cast_index + 2,
        .field_index = cast_index + 4,
        .value_end_index = cast_index + 6,
        .is_length = true,
    };
    if (cast_index + 5 >= context.tokens.len or context.tokens[cast_index + 3].tag != .period or
        context.tokens[cast_index + 4].tag != .identifier or context.tokens[cast_index + 5].tag != .r_paren) return null;
    return .{
        .binding_index = cast_index + 2,
        .field_index = cast_index + 4,
        .value_end_index = cast_index + 4,
    };
}

fn castTargetType(context: RuleRun, cast_index: usize) ?[]const u8 {
    const tokens = context.tokens;
    const cast_close = context.matchingToken(cast_index + 1, .l_paren, .r_paren) orelse return null;
    if (cast_index >= 5 and cast_close + 1 < tokens.len and
        (tokens[cast_index - 5].tag == .keyword_const or tokens[cast_index - 5].tag == .keyword_var) and
        tokens[cast_index - 4].tag == .identifier and tokens[cast_index - 3].tag == .colon and
        tokens[cast_index - 2].tag == .identifier and tokens[cast_index - 1].tag == .equal and
        tokens[cast_close + 1].tag == .semicolon) return context.tokenText(cast_index - 2);
    if (cast_index >= 4 and cast_close + 1 < tokens.len and
        tokens[cast_index - 4].tag == .builtin and context.tokenIs(cast_index - 4, "@as") and
        tokens[cast_index - 3].tag == .l_paren and tokens[cast_index - 2].tag == .identifier and
        tokens[cast_index - 1].tag == .comma and
        tokens[cast_close + 1].tag == .r_paren) return context.tokenText(cast_index - 2);
    return writeIntTargetType(context, cast_index, cast_close);
}

fn writeIntTargetType(context: RuleRun, cast_index: usize, cast_close: usize) ?[]const u8 {
    var write_index = cast_index;
    while (write_index > cast_index -| 48) {
        write_index -= 1;
        if (!context.tokenIs(write_index, "writeInt") or write_index < 4 or
            context.tokens[write_index - 1].tag != .period or !context.tokenIs(write_index - 2, "mem") or
            context.tokens[write_index - 3].tag != .period or !context.tokenIs(write_index - 4, "std") or
            write_index + 2 >= cast_index or context.tokens[write_index + 1].tag != .l_paren or
            context.tokens[write_index + 2].tag != .identifier) continue;
        const call_close = context.matchingToken(write_index + 1, .l_paren, .r_paren) orelse continue;
        if (cast_close >= call_close or callArgumentIndex(context, write_index + 2, cast_index) != 2) continue;
        return context.tokenText(write_index + 2);
    }
    return null;
}

fn callArgumentIndex(context: RuleRun, start: usize, target: usize) usize {
    var argument: usize = 0;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (context.tokens[start..target]) |token| switch (token.tag) {
        .l_paren => parenthesis_depth += 1,
        .r_paren => parenthesis_depth -|= 1,
        .l_bracket => bracket_depth += 1,
        .r_bracket => bracket_depth -|= 1,
        .l_brace => brace_depth += 1,
        .r_brace => brace_depth -|= 1,
        .comma => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            argument += 1;
        },
        else => {},
    };
    return argument;
}

/// usize and isize count as 64 bits, so usize <-> u64 is never a narrowing.
const IntType = struct { width: u32, signed: bool };

fn intType(text: []const u8) ?IntType {
    if (std.mem.eql(u8, text, "usize")) return .{ .width = 64, .signed = false };
    if (std.mem.eql(u8, text, "isize")) return .{ .width = 64, .signed = true };
    if (std.mem.eql(u8, text, "c_short")) return .{ .width = 16, .signed = true };
    if (std.mem.eql(u8, text, "c_int")) return .{ .width = 32, .signed = true };
    if (std.mem.eql(u8, text, "c_longlong")) return .{ .width = 64, .signed = true };
    if (std.mem.eql(u8, text, "c_ushort")) return .{ .width = 16, .signed = false };
    if (std.mem.eql(u8, text, "c_uint")) return .{ .width = 32, .signed = false };
    if (std.mem.eql(u8, text, "c_ulonglong")) return .{ .width = 64, .signed = false };
    if (text.len < 2 or (text[0] != 'u' and text[0] != 'i')) return null;
    for (text[1..]) |character| if (!std.ascii.isDigit(character)) return null;
    return .{
        .width = std.fmt.parseInt(u32, text[1..], 10) catch return null,
        .signed = text[0] == 'i',
    };
}

fn structFieldType(context: RuleRun, type_name: []const u8, field_name: []const u8) ?[]const u8 {
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .identifier or !context.tokenIs(declaration_index, type_name) or declaration_index == 0 or
            context.tokens[declaration_index - 1].tag != .keyword_const) continue;
        var struct_index = declaration_index + 1;
        while (struct_index < context.tokens.len and struct_index < declaration_index + 5 and
            context.tokens[struct_index].tag != .keyword_struct) : (struct_index += 1)
        {}
        if (struct_index >= context.tokens.len or context.tokens[struct_index].tag != .keyword_struct or
            struct_index + 1 >= context.tokens.len or context.tokens[struct_index + 1].tag != .l_brace) continue;
        const container_end = context.matchingToken(struct_index + 1, .l_brace, .r_brace) orelse continue;
        var depth: usize = 0;
        for (context.tokens[struct_index + 2 .. container_end], struct_index + 2..) |field, field_index| {
            switch (field.tag) {
                .l_brace => depth += 1,
                .r_brace => depth -|= 1,
                .identifier => if (depth == 0 and context.tokenIs(field_index, field_name) and
                    field_index + 2 < container_end and context.tokens[field_index + 1].tag == .colon and
                    context.tokens[field_index + 2].tag == .identifier) return context.tokenText(field_index + 2),
                else => {},
            }
        }
    }
    return null;
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

test "writeInt result context exposes unchecked slice length narrowing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Message = struct { payload: []const u8 };" ++
        "fn encode(message: Message, frame: []u8) void {" ++
        "std.mem.writeInt(u16, frame[0..2], @intCast(message.payload.len), .big); }" ++
        "fn checked(message: Message, frame: []u8) void {" ++
        "if (message.payload.len > std.math.maxInt(u16)) return;" ++
        "std.mem.writeInt(u16, frame[0..2], @intCast(message.payload.len), .big); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "message.payload.len") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "usize") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "u16") != null);
}

test "captured slice lengths retain usize narrowing evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn encode(records: []const Record) void { for (records) |record| {" ++
        "const length: u16 = @intCast(record.payload.len); _ = length; } }" ++
        "fn checked(records: []const Record) void { for (records) |record| {" ++
        "if (record.payload.len > std.math.maxInt(u16)) continue;" ++
        "const length: u16 = @intCast(record.payload.len); _ = length; } }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "record.payload.len") != null);
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

test "signed C length fields require a nonnegative guard before unsigned casts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Buffer = extern struct { length: c_int };\n" ++
        "fn unchecked(source: Buffer) void {\n" ++
        "    const length: usize = @intCast(source.length);\n" ++
        "    _ = length;\n" ++
        "}\n" ++
        "fn checked(source: Buffer) void {\n" ++
        "    if (source.length < 0) return;\n" ++
        "    const length: usize = @intCast(source.length);\n" ++
        "    _ = length;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "c_int") != null);
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
