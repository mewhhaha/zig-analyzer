const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const statementStart = @import("../../syntax/tokens.zig").statementStart;

pub const rules = [_]types.Rule{
    .truncating_intcast,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.truncating_intcast);
    if (level == .off) return;

    for (context.tokens, 0..) |token, cast_index| {
        if (token.tag != .builtin or !context.tokenIs(cast_index, "@intCast") or
            cast_index + 3 >= context.tokens.len or context.tokens[cast_index + 1].tag != .l_paren) continue;
        const value = castValue(context, cast_index) orelse continue;
        const function = enclosingFunction(context, cast_index) orelse continue;
        const target_type = castTargetType(context, cast_index, function) orelse continue;
        const target = intType(target_type) orelse continue;
        const value_name = context.tokenText(value.binding_index);
        const declaration = soleDeclaration(context, function, value_name, cast_index);
        const slice_length = value.is_length or sliceLength(context, value);
        const source_type = if (slice_length)
            "usize"
        else if (value.field_index) |field_index|
            if (declaration) |known|
                structFieldType(context, known.type_text, context.tokenText(field_index), cast_index) orelse continue
            else
                continue
        else if (declaration) |known| known.type_text else continue;
        const source = intType(source_type) orelse continue;
        if (target.width >= source.width and (target.signed or !source.signed)) continue;
        if (!slice_length and capturedName(context, function.body_start + 1, cast_index, value_name)) continue;
        if (insideComptime(context, function, cast_index)) continue;
        if (value.field_index == null) if (declaration) |known| if (initializerBounds(context, known, target)) continue;
        const guard_scan_start = if (declaration) |known| known.guard_scan_start else function.body_start + 1;
        if (guardMentions(context, guard_scan_start, cast_index, value_name)) continue;
        try context.emit(.{
            .rule = .truncating_intcast,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
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

/// The integer type the cast's result location gives it: a typed declaration,
/// `@as`, a `std.mem.writeInt` value, the function's return type, a field of a
/// local struct being initialized or assigned, an assigned typed variable, or
/// a parameter of a function this file declares.
fn castTargetType(context: RuleRun, cast_index: usize, function: Function) ?[]const u8 {
    const tokens = context.tokens;
    const cast_close = context.matchingToken(cast_index + 1, .l_paren, .r_paren) orelse return null;
    if (cast_index < 1 or cast_close + 1 >= tokens.len) return null;
    const after = tokens[cast_close + 1].tag;
    if (cast_index >= 5 and
        (tokens[cast_index - 5].tag == .keyword_const or tokens[cast_index - 5].tag == .keyword_var) and
        tokens[cast_index - 4].tag == .identifier and tokens[cast_index - 3].tag == .colon and
        tokens[cast_index - 2].tag == .identifier and tokens[cast_index - 1].tag == .equal and
        after == .semicolon) return context.tokenText(cast_index - 2);
    if (cast_index >= 4 and tokens[cast_index - 4].tag == .builtin and context.tokenIs(cast_index - 4, "@as") and
        tokens[cast_index - 3].tag == .l_paren and tokens[cast_index - 2].tag == .identifier and
        tokens[cast_index - 1].tag == .comma and after == .r_paren)
    {
        // `@ptrFromInt(@as(usize, @intCast(address)))` restores an address an
        // earlier `@intFromPtr` widened, so it always fits.
        if (cast_index >= 6 and tokens[cast_index - 5].tag == .l_paren and
            context.tokenIs(cast_index - 6, "@ptrFromInt")) return null;
        return context.tokenText(cast_index - 2);
    }
    if (writeIntTargetType(context, cast_index, cast_close)) |target| return target;
    switch (tokens[cast_index - 1].tag) {
        .keyword_return => return if (after == .semicolon) returnTypeName(context, function) else null,
        .equal => switch (after) {
            .comma, .r_brace => return fieldInitializerType(context, cast_index),
            .semicolon => return assignmentTargetType(context, cast_index),
            else => return null,
        },
        .l_paren, .comma => return if (after == .comma or after == .r_paren) parameterType(context, cast_index) else null,
        else => return null,
    }
}

/// The return type of `function` when it is one type name, optionally after
/// an error set (`u8`, `!u8`, `Error!u8`, `error{Overflow}!u8`).
fn returnTypeName(context: RuleRun, function: Function) ?[]const u8 {
    const end = function.body_start;
    if (end < 1 or context.tokens[end - 1].tag != .identifier) return null;
    const start = end - 1;
    if (start == function.parameters_end + 1) return context.tokenText(start);
    return if (context.tokens[start - 1].tag == .bang) context.tokenText(start) else null;
}

/// The type of `.field` in `Type{ .field = @intCast(value) }`, or in an
/// anonymous `.{ ... }` declared `: Type` or returned from a function
/// returning `Type`, when `Type` is a struct this file declares.
fn fieldInitializerType(context: RuleRun, cast_index: usize) ?[]const u8 {
    if (cast_index < 4 or context.tokens[cast_index - 2].tag != .identifier or
        context.tokens[cast_index - 3].tag != .period) return null;
    const opening = context.enclosingOpeningBrace(cast_index) orelse return null;
    if (opening < 2) return null;
    const type_name = switch (context.tokens[opening - 1].tag) {
        .identifier => context.tokenText(opening - 1),
        .period => anonymousLiteralType(context, opening - 1) orelse return null,
        else => return null,
    };
    return structFieldType(context, type_name, context.tokenText(cast_index - 2), cast_index);
}

/// The result type of the anonymous literal whose `.` is at `period`.
fn anonymousLiteralType(context: RuleRun, period: usize) ?[]const u8 {
    if (period < 1) return null;
    const before = period - 1;
    if (context.tokens[before].tag == .keyword_return) {
        const function = enclosingFunction(context, period) orelse return null;
        return returnTypeName(context, function);
    }
    if (before < 4 or context.tokens[before].tag != .equal or context.tokens[before - 1].tag != .identifier or
        context.tokens[before - 2].tag != .colon or context.tokens[before - 3].tag != .identifier or
        (context.tokens[before - 4].tag != .keyword_const and context.tokens[before - 4].tag != .keyword_var)) return null;
    return context.tokenText(before - 1);
}

/// The declared type of the target of `target = @intCast(value);`: a local
/// declared with one type name, or a field of a local or parameter whose type
/// is (a pointer to) a struct this file declares.
fn assignmentTargetType(context: RuleRun, cast_index: usize) ?[]const u8 {
    const target_start = statementStart(context.tokens, cast_index);
    const target_end = cast_index - 1;
    if (target_start + 1 == target_end and context.tokens[target_start].tag == .identifier)
        return declaredTypeName(context, target_start, false);
    if (target_start + 3 != target_end or context.tokens[target_start].tag != .identifier or
        context.tokens[target_start + 1].tag != .period or context.tokens[target_start + 2].tag != .identifier) return null;
    const type_name = declaredTypeName(context, target_start, true) orelse return null;
    return structFieldType(context, type_name, context.tokenText(target_start + 2), cast_index);
}

/// The one type name the binding visible at `use_index` is declared with
/// (`name: T`), seen through `*T` and `*const T` when `through_pointer`.
fn declaredTypeName(context: RuleRun, use_index: usize, through_pointer: bool) ?[]const u8 {
    const declaration = (context.scopes.findBinding(use_index) orelse return null).token_index;
    if (declaration + 2 >= context.tokens.len or context.tokens[declaration + 1].tag != .colon) return null;
    var type_index = declaration + 2;
    if (through_pointer and context.tokens[type_index].tag == .asterisk) {
        type_index += 1;
        if (context.tokens[type_index].tag == .keyword_const) type_index += 1;
    }
    if (type_index + 1 >= context.tokens.len or context.tokens[type_index].tag != .identifier) return null;
    return switch (context.tokens[type_index + 1].tag) {
        .equal, .semicolon, .comma, .r_paren => context.tokenText(type_index),
        else => null,
    };
}

/// The type of the parameter that receives the cast in a direct call
/// `function(..., @intCast(value), ...)` of a function this file declares.
fn parameterType(context: RuleRun, cast_index: usize) ?[]const u8 {
    var opening = cast_index;
    var depth: usize = 0;
    while (opening > 0) {
        opening -= 1;
        switch (context.tokens[opening].tag) {
            .r_paren, .r_bracket, .r_brace => depth += 1,
            .l_paren, .l_bracket, .l_brace => {
                if (depth == 0) break;
                depth -= 1;
            },
            .semicolon => return null,
            else => {},
        }
    }
    if (opening < 2 or context.tokens[opening].tag != .l_paren or context.tokens[opening - 1].tag != .identifier or
        context.tokens[opening - 2].tag == .period or context.tokens[opening - 2].tag == .keyword_fn) return null;
    const argument = callArgumentIndex(context, opening + 1, cast_index);
    const function_name = (context.scopes.findBinding(opening - 1) orelse return null).token_index;
    if (function_name == 0 or context.tokens[function_name - 1].tag != .keyword_fn or
        context.tokens[function_name + 1].tag != .l_paren) return null;
    const parameters_end = context.matchingToken(function_name + 1, .l_paren, .r_paren) orelse return null;
    var parameter: usize = 0;
    var index = function_name + 2;
    while (index + 2 < parameters_end) : (index += 1) {
        if (context.tokens[index].tag != .identifier or context.tokens[index + 1].tag != .colon or
            (context.tokens[index - 1].tag != .l_paren and context.tokens[index - 1].tag != .comma)) continue;
        if (parameter == argument) {
            if (context.tokens[index + 2].tag != .identifier) return null;
            const type_end = index + 3;
            if (type_end != parameters_end and context.tokens[type_end].tag != .comma) return null;
            return context.tokenText(index + 2);
        }
        parameter += 1;
    }
    return null;
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

/// The one-name type of `field_name` in `const type_name = struct { ... }`,
/// the declaration of `type_name` visible at `use_index`.
fn structFieldType(context: RuleRun, type_name: []const u8, field_name: []const u8, use_index: usize) ?[]const u8 {
    const declaration_index = (context.scopes.findBindingNamed(type_name, use_index) orelse return null).token_index;
    if (declaration_index == 0 or context.tokens[declaration_index - 1].tag != .keyword_const) return null;
    var struct_index = declaration_index + 1;
    while (struct_index < context.tokens.len and struct_index < declaration_index + 5 and
        context.tokens[struct_index].tag != .keyword_struct) : (struct_index += 1)
    {}
    if (struct_index >= context.tokens.len or context.tokens[struct_index].tag != .keyword_struct or
        struct_index + 1 >= context.tokens.len or context.tokens[struct_index + 1].tag != .l_brace) return null;
    const container_end = context.matchingToken(struct_index + 1, .l_brace, .r_brace) orelse return null;
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
    return null;
}

/// Whether the value is `slice.len` of a binding declared as a slice; an
/// array's length is comptime-known, so its cast is checked at compile time.
fn sliceLength(context: RuleRun, value: CastValue) bool {
    const field_index = value.field_index orelse return false;
    if (!context.tokenIs(field_index, "len")) return false;
    const declaration = (context.scopes.findBinding(value.binding_index) orelse return false).token_index;
    if (declaration + 3 >= context.tokens.len or context.tokens[declaration + 1].tag != .colon or
        context.tokens[declaration + 2].tag != .l_bracket) return false;
    return context.tokens[declaration + 3].tag == .r_bracket or context.tokens[declaration + 3].tag == .colon;
}

/// Whether the cast is evaluated at compile time, inside a `comptime` block or
/// expression, where an out-of-range value is a compile error instead.
fn insideComptime(context: RuleRun, function: Function, cast_index: usize) bool {
    const statement_start = statementStart(context.tokens, cast_index);
    for (context.tokens[statement_start..cast_index]) |token| if (token.tag == .keyword_comptime) return true;
    var brace = context.enclosingOpeningBrace(cast_index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening <= function.body_start) return false;
        if (context.tokens[opening - 1].tag == .keyword_comptime) return true;
        if (opening >= 3 and context.tokens[opening - 1].tag == .colon and
            context.tokens[opening - 2].tag == .identifier and context.tokens[opening - 3].tag == .keyword_comptime) return true;
    }
    return false;
}

/// Whether the value's initializer already bounds it to the target: it ends in
/// a right shift that leaves at most `target.width` bits of a 64-bit value
/// (`@intCast(l >> 59)` cast to `u5`) or a mask that fits the target
/// (`x & 0xff` cast to `u8`). Both operators bind looser than arithmetic, so
/// the last one applies to the whole value.
fn initializerBounds(context: RuleRun, declaration: Declaration, target: IntType) bool {
    const initializer = declaration.initializer orelse return false;
    var start = initializer.start;
    var end = initializer.end;
    while (end > start + 2 and context.tokens[start].tag == .builtin and context.tokens[start + 1].tag == .l_paren and
        context.matchingToken(start + 1, .l_paren, .r_paren) == end - 1)
    {
        start += 2;
        end -= 1;
    }
    if (end < start + 3 or context.tokens[end - 1].tag != .number_literal) return false;
    const amount = std.fmt.parseInt(u64, context.tokenText(end - 1), 0) catch return false;
    const value_bits = target.width -| @intFromBool(target.signed);
    return switch (context.tokens[end - 2].tag) {
        .angle_bracket_angle_bracket_right => amount +| value_bits >= 64,
        .ampersand => value_bits < 64 and amount >> @intCast(value_bits) == 0,
        else => false,
    };
}

const Function = struct {
    parameters_open: usize,
    parameters_end: usize,
    body_start: usize,
    body_end: usize,
};

fn enclosingFunction(context: RuleRun, token_index: usize) ?Function {
    const body_start = context.scopes.functionBodyContaining(token_index) orelse return null;
    const opening = (context.scopes.functionKeyword(body_start) orelse return null) + 2;
    return .{
        .parameters_open = opening,
        .parameters_end = context.matchingToken(opening, .l_paren, .r_paren) orelse return null,
        .body_start = body_start,
        .body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse return null,
    };
}

const Declaration = struct {
    type_text: []const u8,
    guard_scan_start: usize,
    /// The value of a local declaration; parameters have none.
    initializer: ?Range = null,
};

const Range = @import("../../syntax/tokens.zig").Range;

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
            found = .{
                .type_text = context.tokenText(index + 3),
                .guard_scan_start = declaration_end + 1,
                .initializer = .{ .start = index + 5, .end = declaration_end },
            };
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
            .keyword_if, .keyword_while => {
                if (conditionHasBoundaryCheck(context, index + 1, end, name)) return true;
            },
            .keyword_switch => {
                if (guardedParenMentions(context, index + 1, end, name) or
                    switchOnDerivedValue(context, index + 1, end, name)) return true;
            },
            .identifier => {
                if (context.tokenIs(index, "assert")) {
                    if (conditionHasBoundaryCheck(context, index + 1, end, name)) return true;
                } else if (context.tokenIs(index, "cast") or context.tokenIs(index, "clamp")) {
                    if (guardedParenMentions(context, index + 1, end, name)) return true;
                }
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

/// `switch (length)` where `const length = f(name)`: the prongs select on a
/// value computed from `name`, such as its encoded length.
fn switchOnDerivedValue(context: RuleRun, opening: usize, end: usize, name: []const u8) bool {
    if (opening + 2 >= end or context.tokens[opening].tag != .l_paren or
        context.tokens[opening + 1].tag != .identifier or context.tokens[opening + 2].tag != .r_paren) return false;
    const declaration = (context.scopes.findBinding(opening + 1) orelse return false).token_index;
    if (declaration == 0 or (context.tokens[declaration - 1].tag != .keyword_const and
        context.tokens[declaration - 1].tag != .keyword_var)) return false;
    const declaration_end = context.statementEnd(declaration - 1) orelse return false;
    for (context.tokens[declaration + 1 .. declaration_end], declaration + 1..) |token, index| {
        if (token.tag == .identifier and context.refersToBinding(index, name)) return true;
    }
    return false;
}

fn conditionHasBoundaryCheck(context: RuleRun, opening: usize, end: usize, name: []const u8) bool {
    if (opening >= end or context.tokens[opening].tag != .l_paren) return false;
    const closing = context.matchingToken(opening, .l_paren, .r_paren) orelse return true;
    var mentions_name = false;
    var has_boundary = false;
    for (context.tokens[opening + 1 .. @min(closing, end)], opening + 1..) |token, index| {
        if (token.tag == .identifier and context.refersToBinding(index, name)) {
            mentions_name = true;
        }
        switch (token.tag) {
            .angle_bracket_left, .angle_bracket_left_equal, .angle_bracket_right, .angle_bracket_right_equal => has_boundary = true,
            else => {},
        }
    }
    return mentions_name and has_boundary;
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "'count'") != null);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "u64") != null);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "u32") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "'total'") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "u16") != null);
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "message.payload.len") != null);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "usize") != null);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "u16") != null);
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "record.payload.len") != null);
}

test "result types from returns, fields, assignments and parameters are checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const S = struct { a: u8, b: u16 };\n" ++
        "fn returned(n: usize) u8 { return @intCast(n); }\n" ++
        "fn failing(n: usize) error{Oops}!u8 { return @intCast(n); }\n" ++
        "fn typed(n: usize) S { return S{ .a = @intCast(n), .b = 0 }; }\n" ++
        "fn anonymous(n: usize) S { const s: S = .{ .a = @intCast(n), .b = 0 }; return s; }\n" ++
        "fn field(n: usize) S { var s: S = undefined; s.a = @intCast(n); return s; }\n" ++
        "fn local(n: usize) u8 { var out: u8 = 0; out = @intCast(n); return out; }\n" ++
        "fn sliceLength(s: []const u8) u16 { const len: u16 = @intCast(s.len); return len; }\n" ++
        "fn take(value: u8) void { _ = value; }\n" ++
        "fn passed(n: usize) void { take(@intCast(n)); }\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 8), findings.len);
}

test "pointer round trips, comptime values and bounded initializers stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn restore(user_data: u128) *Context { return @ptrFromInt(@as(usize, @intCast(user_data))); }\n" ++
        "fn folded() u32 { const r_mod_q = comptime blk: { var r: u64 = 1; break :blk @as(u32, @intCast(r)); }; return r_mod_q; }\n" ++
        "fn rotate(l: u64, xor_s: u32) u32 { const rot: u32 = @intCast(l >> 59); return xor_s >> @as(u5, @intCast(rot)); }\n" ++
        "fn low(x: u32) u8 { const masked: u32 = x & 0xff; return @as(u8, @intCast(masked)); }\n" ++
        "fn encode(c: u21, out: []u8) void { const length = sequenceLength(c); switch (length) { 1 => out[0] = @as(u8, @intCast(c)), else => {} } }\n" ++
        "fn array(bytes: [4]u8) u8 { const len: u8 = @intCast(bytes.len); return len; }\n" ++
        "fn method(n: usize, list: *List) void { list.take(@intCast(n)); }\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
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

test "equality check does not count as a range guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn nonZero(count: u64) void {\n" ++
        "    if (count != 0) {\n" ++
        "        const small: u8 = @intCast(count);\n" ++
        "        _ = small;\n" ++
        "    }\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
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
    try std.testing.expect(std.mem.find(u8, findings[0].message, "c_int") != null);
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

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.truncating_intcast}, .hint));
}
