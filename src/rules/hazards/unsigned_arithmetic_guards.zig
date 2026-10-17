//! Unsigned arithmetic evaluated before the guard that makes it safe: a clamp applied after the overflow, or a range end added before it is compared.
const std = @import("std");
const statementStart = @import("../../syntax/tokens.zig").statementStart;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const TokenRange = @import("../../syntax/tokens.zig").Range;
const findTag = @import("../../syntax/tokens.zig").findTag;
const lengthPath = @import("../../syntax/tokens.zig").lengthPath;
const lengthSum = @import("../../syntax/tokens.zig").lengthSum;
const isAssignment = @import("../../syntax/tokens.zig").isAssignment;
const isComparison = @import("../../syntax/tokens.zig").isComparison;

pub const rules = [_]types.Rule{ .overflow_before_clamp, .unchecked_range_end };

pub fn run(context: RuleRun) !void {
    var fields = try FieldTypes.init(context);
    defer fields.deinit(context.allocator);
    try findOverflowBeforeClamp(context, &fields);
    try findUncheckedRangeEnds(context, &fields);
    try findUncheckedDeclaredRangeEnds(context, &fields);
}

/// What the `name: Type` declarations of each name in the file declare, so
/// the field types of a path are looked up once instead of rescanning the file.
const FieldTypes = struct {
    facts: std.StringHashMapUnmanaged(Fact) = .empty,

    const Fact = struct {
        /// Every declaration has an unsigned integer type.
        unsigned: bool,
        /// The widest `uN` declared, or null when one declaration is not a `uN` name.
        bits: ?usize,
    };

    fn init(context: RuleRun) !FieldTypes {
        var fields: FieldTypes = .{};
        errdefer fields.deinit(context.allocator);
        for (context.tokens, 0..) |token, name_index| {
            if (token.tag != .identifier or name_index + 2 >= context.tokens.len or
                context.tokens[name_index + 1].tag != .colon) continue;
            const unsigned = typeRangeIsUnsigned(context, name_index + 2, context.tokens.len);
            const bits = if (context.tokens[name_index + 2].tag == .identifier)
                unsignedTypeBits(context.tokenText(name_index + 2))
            else
                null;
            const entry = try fields.facts.getOrPut(context.allocator, context.tokenText(name_index));
            if (!entry.found_existing) {
                entry.value_ptr.* = .{ .unsigned = unsigned, .bits = bits };
                continue;
            }
            entry.value_ptr.unsigned = entry.value_ptr.unsigned and unsigned;
            entry.value_ptr.bits = if (entry.value_ptr.bits) |widest| if (bits) |known| @max(widest, known) else null else null;
        }
        return fields;
    }

    fn deinit(fields: *FieldTypes, allocator: std.mem.Allocator) void {
        fields.facts.deinit(allocator);
    }

    /// Whether every declaration named `field_name` has an unsigned integer type.
    fn hasUnsignedType(fields: *const FieldTypes, field_name: []const u8) bool {
        const fact = fields.facts.get(field_name) orelse return false;
        return fact.unsigned;
    }

    /// The widest unsigned integer type a field named `field_name` is declared
    /// with, or null when one of its declarations is not an unsigned integer.
    fn unsignedBits(fields: *const FieldTypes, field_name: []const u8) ?usize {
        const fact = fields.facts.get(field_name) orelse return null;
        return fact.bits;
    }
};

fn findOverflowBeforeClamp(context: RuleRun, fields: *const FieldTypes) !void {
    const level = context.level(.overflow_before_clamp);
    if (level == .off) return;

    for (context.tokens, 0..) |token, clamp_index| {
        if (token.tag != .builtin or (!context.tokenIs(clamp_index, "@min") and
            !context.tokenIs(clamp_index, "@max")) or clamp_index + 1 >= context.tokens.len or
            context.tokens[clamp_index + 1].tag != .l_paren) continue;
        const closing = context.matchingToken(clamp_index + 1, .l_paren, .r_paren) orelse continue;
        const comma = context.topLevelComma(clamp_index + 2, closing) orelse continue;
        const arguments = [_]TokenRange{
            .{ .start = clamp_index + 2, .end = comma },
            .{ .start = comma + 1, .end = closing },
        };
        for (arguments) |argument| {
            const operator_tag: std.zig.Token.Tag = if (context.tokenIs(clamp_index, "@min")) .plus else .minus;
            const operator_index = arithmeticInRange(context, operator_tag, argument.start, argument.end) orelse continue;
            if (!integerExpression(context, argument.start, operator_index) or
                !integerExpression(context, operator_index + 1, argument.end) or
                !runtimeExpression(context, argument.start, operator_index) or
                !runtimeExpression(context, operator_index + 1, argument.end)) continue;
            if (bitSizeMinusLeadingZeros(context, argument.start, argument.end, operator_index)) continue;
            if (boundedUnsignedDifferenceInSignedType(context, argument.start, argument.end, operator_index)) continue;
            if (wideSignedOperation(context, argument.start, argument.end, operator_index)) continue;
            if (operator_tag == .plus and
                (additionCannotWrap(context, fields, argument.start, operator_index, argument.end) or
                    comptimeKnownName(context, argument.start, operator_index, 0) or
                    comptimeKnownName(context, operator_index + 1, argument.end, 0) or
                    loopConditionBoundsSum(context, argument.start, operator_index, argument.end))) continue;
            if (arithmeticHasVisibleGuard(context, operator_index, argument.start, argument.end, clamp_index)) continue;

            const operation = if (context.tokens[operator_index].tag == .plus) "addition" else "subtraction";
            const failure = if (context.tokens[operator_index].tag == .plus) "overflow" else "underflow";
            try context.emit(.{
                .rule = .overflow_before_clamp,
                .level = level,
                .span = context.tokens[operator_index].loc,
                .message = try context.allocator.print(
                    "integer {s} is evaluated before {s} and can {s}; guard it or use checked or saturating arithmetic",
                    .{ operation, context.tokenText(clamp_index), failure },
                ),
            });
            break;
        }
    }
}

fn findUncheckedRangeEnds(context: RuleRun, fields: *const FieldTypes) !void {
    const level = context.level(.unchecked_range_end);
    if (level == .off) return;
    for (context.tokens, 0..) |token, operator_index| {
        if (token.tag != .plus or additionIsInsideClamp(context, operator_index)) continue;
        const statement_start = statementStart(context.tokens, operator_index);
        const statement_end = context.statementEnd(operator_index) orelse continue;
        const left_start = additionOperandStart(context.tokens, operator_index, statement_start);
        const right_end = additionOperandEnd(context.tokens, operator_index + 1, statement_end);
        if (right_end >= statement_end) continue;
        const comparison = isComparison(context.tokens[right_end].tag);
        const slice_end = additionIsSliceEnd(context, left_start, right_end);
        if (!comparison and !slice_end) continue;
        if (left_start == operator_index or operator_index + 1 == right_end or
            !runtimeExpression(context, left_start, operator_index) or
            !unsignedIntegerExpression(context, fields, left_start, operator_index) or
            !unsignedIntegerExpression(context, fields, operator_index + 1, right_end)) continue;
        const runtime_length = runtimeExpression(context, operator_index + 1, right_end) and
            (rangeNamesLength(context, left_start, right_end) or
                extentComparedWithSameDimension(context, operator_index + 1, right_end, statement_end));
        const constant_lookahead = riskyConstantLookahead(context, left_start, operator_index, right_end) and
            (slice_end or rangeNamesLength(context, right_end + 1, statement_end));
        if (!runtime_length and !constant_lookahead) continue;
        if (rangeContainsCall(context.tokens, left_start, operator_index) or
            leftOperandEndsWithCall(context.tokens, operator_index) or
            leftOperandComesFromSearchMatch(context, left_start, operator_index, operator_index + 1, right_end) or
            narrowedOperandsCannotOverflowUsize(context, left_start, operator_index, right_end) or
            additionCannotWrap(context, fields, left_start, operator_index, right_end) or
            additionInsideAssertion(context, statement_start, operator_index) or
            loopConditionBoundsSum(context, left_start, operator_index, right_end)) continue;
        if (comparison and (guardOnlyPanics(context, statement_start, operator_index) or
            (cursorFromZero(context, left_start, operator_index) and
                literalOrLength(context, operator_index + 1, right_end)))) continue;
        if (runtime_length and rightOperandBoundedByRemaining(
            context,
            left_start,
            operator_index,
            right_end,
        )) continue;
        if (runtime_length and arithmeticHasVisibleGuard(
            context,
            operator_index,
            left_start,
            right_end,
            statement_start,
        )) continue;
        if (constant_lookahead and constantLookaheadHasVisibleGuard(
            context,
            left_start,
            operator_index,
            statement_start,
        )) continue;
        try context.emit(.{
            .rule = .unchecked_range_end,
            .level = level,
            .span = context.tokens[operator_index].loc,
            .message = try context.allocator.dupe(
                u8,
                "range end uses unchecked runtime addition before bounds validation; validate with subtraction or checked arithmetic",
            ),
        });
    }
}

fn findUncheckedDeclaredRangeEnds(context: RuleRun, fields: *const FieldTypes) !void {
    const level = context.level(.unchecked_range_end);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 3 >= context.tokens.len or context.tokens[declaration_index + 1].tag != .identifier) continue;
        const statement_end = context.statementEnd(declaration_index) orelse continue;
        const equal_index = findTag(context.tokens, declaration_index + 2, statement_end, .equal) orelse continue;
        if (rangeContainsComparison(context.tokens, equal_index + 1, statement_end)) continue;
        const operator_index = singleArithmeticInRange(context, .plus, equal_index + 1, statement_end) orelse continue;
        const left_start = additionOperandStart(context.tokens, operator_index, equal_index + 1);
        const right_end = additionOperandEnd(context.tokens, operator_index + 1, statement_end);
        if (right_end != statement_end or !runtimeExpression(context, left_start, operator_index) or
            !runtimeExpression(context, operator_index + 1, right_end) or
            !unsignedIntegerExpression(context, fields, left_start, operator_index) or
            !unsignedIntegerExpression(context, fields, operator_index + 1, right_end) or
            !rangeRepresentsLength(context, operator_index + 1, right_end, operator_index)) continue;
        if (additionCannotWrap(context, fields, left_start, operator_index, right_end) or
            rightOperandBoundedByRemaining(context, left_start, operator_index, right_end) or
            leftOperandComesFromSearchMatch(context, left_start, operator_index, operator_index + 1, right_end) or
            arithmeticHasVisibleGuard(context, operator_index, left_start, right_end, declaration_index)) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        const function_body = context.scopes.functionBodyContaining(declaration_index) orelse continue;
        if (!bindingFeedsBoundedRange(context, binding, function_body, statement_end + 1, scope_end, 0)) continue;
        try context.emit(.{
            .rule = .unchecked_range_end,
            .level = level,
            .span = context.tokens[operator_index].loc,
            .message = try context.allocator.dupe(
                u8,
                "range end uses unchecked runtime addition before bounds validation; validate with subtraction or checked arithmetic",
            ),
        });
    }
}

fn arithmeticHasVisibleGuard(
    context: RuleRun,
    operator_index: usize,
    left_start: usize,
    right_end: usize,
    use_index: usize,
) bool {
    const left_name = runtimeName(context, left_start, operator_index) orelse return false;
    const right_name = runtimeName(context, operator_index + 1, right_end) orelse return false;
    const body_start = context.scopes.functionBodyContaining(use_index) orelse return false;
    const scope = context.enclosingOpeningBrace(use_index) orelse return false;
    const companion: std.zig.Token.Tag = if (context.tokens[operator_index].tag == .plus) .minus else .plus;

    if (inlineConditionalGuardsArithmetic(
        context,
        left_name,
        right_name,
        companion,
        left_start,
        operator_index,
    )) return true;

    for (context.tokens[body_start + 1 .. use_index], body_start + 1..) |token, guard_index| {
        if (context.enclosingOpeningBrace(guard_index) != scope) continue;
        if (token.tag == .keyword_if and guard_index + 1 < use_index and
            context.tokens[guard_index + 1].tag == .l_paren)
        {
            const condition_end = context.matchingToken(guard_index + 1, .l_paren, .r_paren) orelse continue;
            if (condition_end >= use_index or !guardConditionMatches(
                context,
                left_name,
                right_name,
                companion,
                guard_index + 2,
                condition_end,
            )) continue;
            const guard_end = @min(context.statementEnd(guard_index) orelse use_index, use_index);
            if (rangeTerminates(context, condition_end + 1, guard_end)) return true;
        }
        if (token.tag == .identifier and context.tokenIs(guard_index, "assert") and
            guard_index + 1 < use_index and context.tokens[guard_index + 1].tag == .l_paren)
        {
            const condition_end = context.matchingToken(guard_index + 1, .l_paren, .r_paren) orelse continue;
            if (condition_end >= use_index) continue;
            if (guardConditionMatches(context, left_name, right_name, companion, guard_index + 2, condition_end)) return true;
            // An assertion that evaluates the same sum has already trapped on its overflow.
            if (guardConditionMatches(
                context,
                left_name,
                right_name,
                context.tokens[operator_index].tag,
                guard_index + 2,
                condition_end,
            )) return true;
        }
    }
    return false;
}

fn arithmeticInRange(context: RuleRun, tag: std.zig.Token.Tag, start: usize, end: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var result: ?usize = null;
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            else => if (token.tag == tag and parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                result = index;
            },
        }
    }
    return result;
}

fn bitSizeMinusLeadingZeros(context: RuleRun, start: usize, end: usize, operator_index: usize) bool {
    if (context.tokens[operator_index].tag != .minus) return false;
    var clz_name: ?[]const u8 = null;
    var index = operator_index + 1;
    while (index + 2 < end) : (index += 1) {
        if (context.tokens[index].tag != .builtin or !context.tokenIs(index, "@clz") or
            context.tokens[index + 1].tag != .l_paren or context.tokens[index + 2].tag != .identifier) continue;
        clz_name = context.tokenText(index + 2);
        break;
    }
    const name = clz_name orelse return false;
    index = start;
    while (index + 4 < operator_index) : (index += 1) {
        if (context.tokens[index].tag != .builtin or !context.tokenIs(index, "@bitSizeOf") or
            context.tokens[index + 1].tag != .l_paren or context.tokens[index + 2].tag != .builtin or
            !context.tokenIs(index + 2, "@TypeOf") or context.tokens[index + 3].tag != .l_paren or
            !context.tokenIs(index + 4, name)) continue;
        return true;
    }
    return false;
}

fn boundedUnsignedDifferenceInSignedType(context: RuleRun, start: usize, end: usize, operator_index: usize) bool {
    if (context.tokens[operator_index].tag != .minus) return false;
    const left_name = runtimeName(context, start, operator_index) orelse return false;
    const right_name = runtimeName(context, operator_index + 1, end) orelse return false;
    const left_bits = unsignedOriginBits(context, left_name, operator_index, 0) orelse return false;
    const right_bits = unsignedOriginBits(context, right_name, operator_index, 0) orelse return false;
    const signed_bits = signedOperationBits(context, left_name, start, end, operator_index) orelse return false;
    return @max(left_bits, right_bits) < signed_bits;
}

fn integerExpression(context: RuleRun, start: usize, end: usize) bool {
    if (start >= end) return false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .number_literal) return true;
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, "len") and index > start and context.tokens[index - 1].tag == .period) return true;
        if (index >= start + 2 and context.tokens[index - 1].tag == .period) {
            if (context.tokenIs(index - 2, "self") and selfFieldHasIntegerType(context, context.tokenText(index), index)) return true;
            continue;
        }
        if (integerTypedBinding(context, context.tokenText(index), index)) return true;
    }
    return false;
}

fn runtimeExpression(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, "self") or context.tokenIs(index, "std") or context.tokenIs(index, "math")) continue;
        if (index >= start + 2 and context.tokens[index - 1].tag == .period) switch (context.tokens[index - 2].tag) {
            .string_literal, .char_literal, .number_literal => continue,
            else => {},
        };
        return true;
    }
    return false;
}

fn additionIsInsideClamp(context: RuleRun, operator_index: usize) bool {
    var cursor = operator_index;
    while (cursor > 1) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) return false;
        if (context.tokens[cursor].tag != .l_paren or context.tokens[cursor - 1].tag != .builtin or
            (!context.tokenIs(cursor - 1, "@min") and !context.tokenIs(cursor - 1, "@max"))) continue;
        const closing = context.matchingToken(cursor, .l_paren, .r_paren) orelse return false;
        return operator_index < closing;
    }
    return false;
}

fn additionIsSliceEnd(context: RuleRun, left_start: usize, right_end: usize) bool {
    if (context.tokens[right_end].tag != .r_bracket or left_start == 0) return false;
    return context.tokens[left_start - 1].tag == .ellipsis2;
}

/// Sums that cannot wrap `usize`: lengths of objects in memory plus literals
/// (`a.len + 1 + b.len`), a narrower unsigned value widened to a
/// length's `usize` (`buf_len + bytes.len` with `buf_len: u8`), and many-pointer
/// arithmetic, which is not integer overflow.
fn additionCannotWrap(context: RuleRun, fields: *const FieldTypes, operand_start: usize, operator_index: usize, right_end: usize) bool {
    // The left operand of a returned sum starts at its `return`.
    const left_start = if (context.tokens[operand_start].tag == .keyword_return) operand_start + 1 else operand_start;
    if (left_start >= operator_index) return false;
    if (lengthSum(context.source, context.tokens, left_start, right_end)) return true;
    if (operator_index >= left_start + 2 and context.tokens[operator_index - 2].tag == .period and
        context.tokenIs(operator_index - 1, "ptr")) return true;
    return (lengthPath(context.source, context.tokens, operator_index + 1, right_end) and narrowUnsignedPath(context, fields, left_start, operator_index)) or
        (lengthPath(context.source, context.tokens, left_start, operator_index) and narrowUnsignedPath(context, fields, operator_index + 1, right_end));
}

/// Whether the operation is evaluated in a signed type of at least 64 bits.
/// Values that reach its range come only from sentinels; coordinates and
/// deltas widened to `i64` for signed arithmetic cannot overflow, and
/// `@max(0, a - b)` is the correct clamp for signed values.
fn wideSignedOperation(context: RuleRun, start: usize, end: usize, operator_index: usize) bool {
    const left_name = runtimeName(context, start, operator_index) orelse return false;
    const bits = signedOperationBits(context, left_name, start, end, operator_index) orelse return false;
    return bits >= 64;
}

/// Whether `[start, end)` is one identifier naming a value known at compile
/// time: a `comptime` or `type` parameter, or a `const` whose initializer uses
/// only literals, operators, primitive types and other such names. Adding one
/// is a fixed lookahead, like adding a literal.
fn comptimeKnownName(context: RuleRun, start: usize, end: usize, depth: usize) bool {
    if (depth == 3 or start + 1 != end or context.tokens[start].tag != .identifier) return false;
    const declaration = (context.scopes.findBinding(start) orelse return false).token_index;
    if (declaration == 0 or declaration + 2 >= context.tokens.len) return false;
    if (context.tokens[declaration - 1].tag == .keyword_comptime or
        (context.tokens[declaration + 1].tag == .colon and context.tokenIs(declaration + 2, "type"))) return true;
    if (context.tokens[declaration - 1].tag != .keyword_const) return false;
    const declaration_end = context.statementEnd(declaration - 1) orelse return false;
    const equal_index = findTag(context.tokens, declaration + 1, declaration_end, .equal) orelse return false;
    if (equal_index + 1 >= declaration_end) return false;
    for (context.tokens[equal_index + 1 .. declaration_end], equal_index + 1..) |token, index| switch (token.tag) {
        .number_literal,
        .char_literal,
        .keyword_if,
        .keyword_else,
        .keyword_and,
        .keyword_or,
        .l_paren,
        .r_paren,
        .plus,
        .minus,
        .asterisk,
        .slash,
        .percent,
        .angle_bracket_angle_bracket_left,
        .angle_bracket_angle_bracket_right,
        .equal_equal,
        .bang_equal,
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        => {},
        .identifier => if (!integerTypeName(context.tokenText(index)) and !context.tokenIs(index, "bool") and
            !comptimeKnownName(context, index, index + 1, depth + 1)) return false,
        else => return false,
    };
    return true;
}

/// Whether the sum's left operand is bounded by a length in the condition of
/// an enclosing `while` loop (`while (i < bytes.len)`, `while (i <= haystack.len
/// - needle.len)`, or `while (i <= end)` with `end` such a constant) and the
/// right operand is a length or a literal: the sum then stays within two
/// in-memory lengths and cannot wrap.
fn loopConditionBoundsSum(context: RuleRun, left_start: usize, operator_index: usize, right_end: usize) bool {
    if (left_start + 1 != operator_index or context.tokens[left_start].tag != .identifier or
        !literalOrLength(context, operator_index + 1, right_end)) return false;
    const cursor = context.tokenText(left_start);
    var brace = context.enclosingOpeningBrace(operator_index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (whileCondition(context, opening)) |condition| {
            if (conditionBoundsByLength(context, cursor, condition.start, condition.end)) return true;
        }
        if (context.scopes.functionKeyword(opening) != null) return false;
    }
    return false;
}

fn literalOrLength(context: RuleRun, start: usize, end: usize) bool {
    return (start + 1 == end and context.tokens[start].tag == .number_literal) or
        lengthPath(context.source, context.tokens, start, end);
}

/// The condition of the `while` loop whose body opens at `opening`.
fn whileCondition(context: RuleRun, opening: usize) ?TokenRange {
    if (opening < 3 or context.tokens[opening - 1].tag != .r_paren) return null;
    var condition_end = opening - 1;
    var condition_start = context.scopes.matchingToken(condition_end) orelse return null;
    // `while (condition) : (i += 1) {`
    if (condition_start >= 2 and context.tokens[condition_start - 1].tag == .colon and
        context.tokens[condition_start - 2].tag == .r_paren)
    {
        condition_end = condition_start - 2;
        condition_start = context.scopes.matchingToken(condition_end) orelse return null;
    }
    if (condition_start == 0 or context.tokens[condition_start - 1].tag != .keyword_while) return null;
    return .{ .start = condition_start + 1, .end = condition_end };
}

/// Whether the loop condition `[start, end)` compares `cursor <` or `cursor <=`
/// against an expression naming a length, with no `or` that could let the
/// loop run past it.
fn conditionBoundsByLength(context: RuleRun, cursor: []const u8, start: usize, end: usize) bool {
    if (rangeContainsTag(context.tokens, .keyword_or, start, end)) return false;
    var index = start;
    while (index + 2 < end) : (index += 1) {
        if (context.tokens[index].tag != .identifier or !context.tokenIs(index, cursor) or
            (context.tokens[index + 1].tag != .angle_bracket_left and
                context.tokens[index + 1].tag != .angle_bracket_left_equal)) continue;
        const bound_end = findTag(context.tokens, index + 2, end, .keyword_and) orelse end;
        if (rangeHasLengthField(context, index + 2, bound_end)) return true;
        if (bound_end != index + 3 or context.tokens[index + 2].tag != .identifier) continue;
        const declaration = (context.scopes.findBinding(index + 2) orelse continue).token_index;
        if (declaration == 0 or context.tokens[declaration - 1].tag != .keyword_const) continue;
        const declaration_end = context.statementEnd(declaration - 1) orelse continue;
        if (rangeHasLengthField(context, declaration + 1, declaration_end)) return true;
    }
    return false;
}

fn rangeHasLengthField(context: RuleRun, start: usize, end: usize) bool {
    var index = start;
    while (index + 1 < end) : (index += 1) {
        if (context.tokens[index].tag == .period and context.tokenIs(index + 1, "len")) return true;
    }
    return false;
}

/// Whether the comparison is the condition of an `if` whose branch only
/// panics: the guard is an assertion, and an overflow trap fails it the same way.
fn guardOnlyPanics(context: RuleRun, statement_start: usize, operator_index: usize) bool {
    if (context.tokens[statement_start].tag != .keyword_if or statement_start + 1 >= operator_index or
        context.tokens[statement_start + 1].tag != .l_paren) return false;
    const condition_end = context.scopes.matchingToken(statement_start + 1) orelse return false;
    if (condition_end < operator_index or condition_end + 2 >= context.tokens.len) return false;
    var branch = condition_end + 1;
    if (context.tokens[branch].tag == .l_brace) branch += 1;
    return context.tokens[branch].tag == .keyword_unreachable or
        (context.tokens[branch].tag == .builtin and context.tokenIs(branch, "@panic"));
}

/// Whether the left operand is a local `var` that starts at 0 and is only
/// advanced with `+=`: a cursor walking a buffer from its start, which a
/// comparison against that buffer's length bounds.
fn cursorFromZero(context: RuleRun, left_start: usize, operator_index: usize) bool {
    if (left_start + 1 != operator_index or context.tokens[left_start].tag != .identifier) return false;
    const declaration = (context.scopes.findBinding(left_start) orelse return false).token_index;
    if (declaration == 0 or context.tokens[declaration - 1].tag != .keyword_var) return false;
    const declaration_end = context.statementEnd(declaration - 1) orelse return false;
    if (declaration_end < declaration + 3 or context.tokens[declaration_end - 2].tag != .equal or
        !context.tokenIs(declaration_end - 1, "0")) return false;
    const scope_end = context.enclosingScopeEnd(declaration) orelse return false;
    const name = context.tokenText(left_start);
    for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or context.tokens[index - 1].tag == .period) continue;
        if (context.tokens[index - 1].tag == .ampersand) return false;
        const next = context.tokens[index + 1].tag;
        if (isAssignment(next) and next != .plus_equal) return false;
    }
    return true;
}

/// Whether `[start, end)` is a binding or field path declared with an
/// unsigned integer type narrower than `usize`.
fn narrowUnsignedPath(context: RuleRun, fields: *const FieldTypes, start: usize, end: usize) bool {
    if (end <= start or (end - start) % 2 == 0) return false;
    for (context.tokens[start..end], 0..) |token, offset| {
        if (token.tag != if (offset % 2 == 0) std.zig.Token.Tag.identifier else .period) return false;
    }
    const bits = if (end - start == 1)
        declaredUnsignedBits(context, start)
    else
        fields.unsignedBits(context.tokenText(end - 1));
    return if (bits) |known| known < @bitSizeOf(usize) else false;
}

/// The bit width of the unsigned integer type the binding visible at
/// `name_index` is declared with.
fn declaredUnsignedBits(context: RuleRun, name_index: usize) ?usize {
    const declaration = (context.scopes.findBinding(name_index) orelse return null).token_index;
    if (declaration + 3 >= context.tokens.len or context.tokens[declaration + 1].tag != .colon or
        context.tokens[declaration + 2].tag != .identifier or context.tokens[declaration + 3].tag == .period) return null;
    return unsignedTypeBits(context.tokenText(declaration + 2));
}

/// Whether the addition is an argument of `assert(...)`: an assertion states
/// the invariant rather than computing a range end.
fn additionInsideAssertion(context: RuleRun, statement_start: usize, operator_index: usize) bool {
    var cursor = operator_index;
    while (cursor > statement_start + 1) {
        cursor -= 1;
        if (context.tokens[cursor].tag != .l_paren or !context.tokenIs(cursor - 1, "assert")) continue;
        const closing = context.matchingToken(cursor, .l_paren, .r_paren) orelse return false;
        return operator_index < closing;
    }
    return false;
}

fn additionOperandEnd(tokens: []const std.zig.Token, start: usize, maximum: usize) usize {
    var end = start;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    while (end < maximum) : (end += 1) {
        switch (tokens[end].tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => if (parenthesis_depth != 0) {
                parenthesis_depth -= 1;
                continue;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => if (bracket_depth != 0) {
                bracket_depth -= 1;
                continue;
            },
            .l_brace => brace_depth += 1,
            .r_brace => if (brace_depth != 0) {
                brace_depth -= 1;
                continue;
            },
            else => {},
        }
        if (parenthesis_depth != 0 or bracket_depth != 0 or brace_depth != 0) continue;
        switch (tokens[end].tag) {
            .r_paren,
            .comma,
            .semicolon,
            .angle_bracket_left,
            .angle_bracket_left_equal,
            .angle_bracket_right,
            .angle_bracket_right_equal,
            .equal_equal,
            .bang_equal,
            .keyword_and,
            .keyword_or,
            .r_bracket,
            => return end,
            else => {},
        }
    }
    return end;
}

fn additionOperandStart(tokens: []const std.zig.Token, operator_index: usize, minimum: usize) usize {
    var start = operator_index;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    while (start > minimum) {
        const previous = tokens[start - 1].tag;
        switch (previous) {
            .r_paren => parenthesis_depth += 1,
            .l_paren => if (parenthesis_depth != 0) {
                parenthesis_depth -= 1;
                start -= 1;
                continue;
            },
            .r_bracket => bracket_depth += 1,
            .l_bracket => if (bracket_depth != 0) {
                bracket_depth -= 1;
                start -= 1;
                continue;
            },
            .r_brace => brace_depth += 1,
            .l_brace => if (brace_depth != 0) {
                brace_depth -= 1;
                start -= 1;
                continue;
            },
            else => {},
        }
        if (parenthesis_depth != 0 or bracket_depth != 0 or brace_depth != 0) {
            start -= 1;
            continue;
        }
        const boundary = switch (previous) {
            .l_paren,
            .comma,
            .semicolon,
            .equal,
            .plus_equal,
            .minus_equal,
            .asterisk_equal,
            .slash_equal,
            .percent_equal,
            .angle_bracket_left,
            .angle_bracket_left_equal,
            .angle_bracket_right,
            .angle_bracket_right_equal,
            .equal_equal,
            .bang_equal,
            .keyword_and,
            .keyword_or,
            .l_bracket,
            .ellipsis2,
            => true,
            else => false,
        };
        if (boundary) break;
        start -= 1;
    }
    return start;
}

fn constantLookaheadHasVisibleGuard(
    context: RuleRun,
    left_start: usize,
    operator_index: usize,
    use_index: usize,
) bool {
    const cursor_name = runtimeName(context, left_start, operator_index) orelse return false;
    const literal = context.tokenText(operator_index + 1);
    const body_start = context.scopes.functionBodyContaining(use_index) orelse return false;
    const scope = context.enclosingOpeningBrace(use_index) orelse return false;
    for (context.tokens[body_start + 1 .. use_index], body_start + 1..) |token, guard_index| {
        if (token.tag != .keyword_if or context.enclosingOpeningBrace(guard_index) != scope or
            guard_index + 1 >= use_index or context.tokens[guard_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(guard_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end >= use_index or !context.rangeContainsName(cursor_name, guard_index + 2, condition_end) or
            !rangeContainsLiteral(context, literal, guard_index + 2, condition_end) or
            !rangeNamesLength(context, guard_index + 2, condition_end) or
            !rangeContainsTag(context.tokens, .minus, guard_index + 2, condition_end)) continue;
        const guard_end = @min(context.statementEnd(guard_index) orelse use_index, use_index);
        if (rangeTerminates(context, condition_end + 1, guard_end)) return true;
    }
    return false;
}

fn extentComparedWithSameDimension(
    context: RuleRun,
    start: usize,
    comparison_index: usize,
    statement_end: usize,
) bool {
    const extent = runtimeName(context, start, comparison_index) orelse return false;
    if (!std.mem.eql(u8, extent, "width") and !std.mem.eql(u8, extent, "height")) return false;
    return context.rangeContainsName(extent, comparison_index + 1, statement_end);
}

fn leftOperandComesFromSearchMatch(
    context: RuleRun,
    left_start: usize,
    operator_index: usize,
    right_start: usize,
    right_end: usize,
) bool {
    const offset_name = runtimeName(context, left_start, operator_index) orelse return false;
    const needle_name = lengthReceiverName(context, right_start, right_end) orelse return false;
    const body_start = context.scopes.functionBodyContaining(operator_index) orelse return false;
    for (context.tokens[body_start + 1 .. operator_index], body_start + 1..) |token, call_index| {
        if (token.tag != .identifier or
            (!context.tokenIs(call_index, "indexOf") and !context.tokenIs(call_index, "indexOfPos")) or
            call_index + 1 >= operator_index or context.tokens[call_index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;
        if (!context.rangeContainsName(needle_name, call_index + 2, call_end)) continue;
        const capture_end = @min(call_end + 8, operator_index);
        for (context.tokens[call_end + 1 .. capture_end], call_end + 1..) |candidate, capture_index| {
            if (candidate.tag == .pipe and capture_index + 1 < capture_end and
                context.tokenIs(capture_index + 1, offset_name)) return true;
        }
    }
    return false;
}

fn leftOperandEndsWithCall(tokens: []const std.zig.Token, operator_index: usize) bool {
    if (operator_index == 0 or tokens[operator_index - 1].tag != .r_paren) return false;
    var depth: usize = 0;
    var index = operator_index - 1;
    while (index > 0) {
        switch (tokens[index].tag) {
            .r_paren => depth += 1,
            .l_paren => {
                depth -|= 1;
                if (depth == 0) return index > 0 and
                    (tokens[index - 1].tag == .identifier or tokens[index - 1].tag == .builtin);
            },
            else => {},
        }
        index -= 1;
    }
    return false;
}

fn narrowedOperandsCannotOverflowUsize(
    context: RuleRun,
    left_start: usize,
    operator_index: usize,
    right_end: usize,
) bool {
    const left_name = runtimeName(context, left_start, operator_index) orelse return false;
    const receiver = lengthReceiverName(context, operator_index + 1, right_end) orelse return false;
    const left_bits = unsignedOriginBits(context, left_name, operator_index, 0) orelse return false;
    const body_start = context.scopes.functionBodyContaining(operator_index) orelse return false;
    for (context.tokens[body_start + 1 .. operator_index], body_start + 1..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 4 >= operator_index or
            context.tokens[declaration_index + 1].tag != .identifier or
            context.tokens[declaration_index + 2].tag != .colon or
            context.tokens[declaration_index + 3].tag != .identifier) continue;
        const right_bits = unsignedTypeBits(context.tokenText(declaration_index + 3)) orelse continue;
        if (@max(left_bits, right_bits) + 1 > @bitSizeOf(usize)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= operator_index) continue;
        var saw_cast = false;
        var saw_receiver = false;
        var saw_length = false;
        for (context.tokens[declaration_index + 4 .. declaration_end], declaration_index + 4..) |candidate, index| {
            if (candidate.tag == .builtin and context.tokenIs(index, "@intCast")) saw_cast = true;
            if (candidate.tag == .identifier and context.tokenIs(index, receiver)) saw_receiver = true;
            if (candidate.tag == .identifier and context.tokenIs(index, "len")) saw_length = true;
        }
        if (saw_cast and saw_receiver and saw_length) return true;
    }
    return false;
}

fn rangeContainsCall(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    var index = start;
    while (index + 1 < end) : (index += 1) {
        if ((tokens[index].tag == .identifier or tokens[index].tag == .builtin) and
            tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

fn rangeNamesLength(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{ "len", "length", "count", "size" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        for (names) |name| if (context.tokenIs(index, name)) return true;
    }
    return false;
}

fn rightOperandBoundedByRemaining(
    context: RuleRun,
    left_start: usize,
    operator_index: usize,
    right_end: usize,
) bool {
    const left_name = runtimeName(context, left_start, operator_index) orelse return false;
    const right_name = runtimeName(context, operator_index + 1, right_end) orelse return false;
    const body_start = context.scopes.functionBodyContaining(operator_index) orelse return false;
    for (context.tokens[body_start + 1 .. operator_index], body_start + 1..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 2 >= operator_index or
            !context.tokenIs(declaration_index + 1, right_name)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= operator_index or
            !rangeContainsTag(context.tokens, .minus, declaration_index + 2, declaration_end) or
            !context.rangeContainsName(left_name, declaration_index + 2, declaration_end) or
            !rangeNamesLength(context, declaration_index + 2, declaration_end)) continue;
        return true;
    }
    return false;
}

fn riskyConstantLookahead(
    context: RuleRun,
    left_start: usize,
    operator_index: usize,
    right_end: usize,
) bool {
    if (!rangeHasCursorName(context, left_start, operator_index) or operator_index + 2 != right_end or
        context.tokens[operator_index + 1].tag != .number_literal) return false;
    const literal = context.tokenText(operator_index + 1);
    const lookahead = std.fmt.parseInt(usize, literal, 0) catch return false;
    return lookahead >= 4;
}

fn unsignedIntegerExpression(context: RuleRun, fields: *const FieldTypes, start: usize, end: usize) bool {
    if (start >= end) return false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .number_literal) return true;
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, "len") and index > start and context.tokens[index - 1].tag == .period) return true;
        if (index >= start + 2 and context.tokens[index - 1].tag == .period) {
            if (fields.hasUnsignedType(context.tokenText(index))) return true;
            continue;
        }
        if (unsignedTypedBinding(context, fields, context.tokenText(index), index)) return true;
    }
    return false;
}

fn bindingFeedsBoundedRange(
    context: RuleRun,
    binding: []const u8,
    function_body: usize,
    start: usize,
    end: usize,
    depth: usize,
) bool {
    if (depth == 3) return false;
    var statement_start = start;
    while (statement_start < end) {
        const statement_end = context.statementEnd(statement_start) orelse return false;
        const bounded_end = @min(statement_end, end);
        if (rangeContainsNameInFunction(context, binding, function_body, statement_start, bounded_end)) {
            if ((rangeContainsComparison(context.tokens, statement_start, bounded_end) and
                rangeNamesLength(context, statement_start, bounded_end)) or
                rangeUsesBindingAsSliceEnd(context, binding, function_body, statement_start, bounded_end)) return true;
            if (context.tokens[statement_start].tag == .keyword_const or context.tokens[statement_start].tag == .keyword_var) {
                const equal_index = findTag(context.tokens, statement_start + 2, bounded_end, .equal) orelse {
                    statement_start = statement_end + 1;
                    continue;
                };
                if (arithmeticInRange(context, .plus, equal_index + 1, bounded_end) != null and
                    rangeRepresentsLength(context, equal_index + 1, bounded_end, statement_start))
                {
                    const next_binding = context.tokenText(statement_start + 1);
                    if (bindingFeedsBoundedRange(context, next_binding, function_body, statement_end + 1, end, depth + 1)) return true;
                }
            }
        }
        statement_start = statement_end + 1;
    }
    return false;
}

fn rangeContainsComparison(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| if (isComparison(token.tag)) return true;
    return false;
}

fn rangeRepresentsLength(context: RuleRun, start: usize, end: usize, before: usize) bool {
    if (rangeNamesLength(context, start, end)) return true;
    const name = runtimeName(context, start, end) orelse return false;
    const body_start = context.scopes.functionBodyContaining(before) orelse return false;
    for (context.tokens[body_start + 1 .. before], body_start + 1..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 2 >= before or
            !context.tokenIs(declaration_index + 1, name)) continue;
        if (context.scopes.functionBodyContaining(declaration_index) != body_start) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= before) continue;
        for (context.tokens[declaration_index + 2 .. declaration_end], declaration_index + 2..) |candidate, index| {
            if (candidate.tag == .identifier and context.tokenIs(index, "readInt")) return true;
        }
    }
    return false;
}

fn singleArithmeticInRange(
    context: RuleRun,
    tag: std.zig.Token.Tag,
    start: usize,
    end: usize,
) ?usize {
    var selected: ?usize = null;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            else => if (token.tag == tag and parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                if (selected != null) return null;
                selected = index;
            },
        }
    }
    return selected;
}

fn guardConditionMatches(
    context: RuleRun,
    left_name: []const u8,
    right_name: []const u8,
    companion: std.zig.Token.Tag,
    start: usize,
    end: usize,
) bool {
    var saw_left = false;
    var saw_right = false;
    var saw_companion = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == companion) saw_companion = true;
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, left_name)) saw_left = true;
        if (context.tokenIs(index, right_name)) saw_right = true;
    }
    return saw_left and saw_right and saw_companion;
}

fn inlineConditionalGuardsArithmetic(
    context: RuleRun,
    left_name: []const u8,
    right_name: []const u8,
    companion: std.zig.Token.Tag,
    start: usize,
    operator_index: usize,
) bool {
    for (context.tokens[start..operator_index], start..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 1 >= operator_index or
            context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end >= operator_index or !guardConditionMatches(
            context,
            left_name,
            right_name,
            companion,
            if_index + 2,
            condition_end,
        )) continue;
        for (context.tokens[condition_end + 1 .. operator_index]) |branch_token| {
            if (branch_token.tag == .keyword_else) return true;
        }
    }
    return false;
}

fn rangeTerminates(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| switch (token.tag) {
        .keyword_return, .keyword_break, .keyword_continue, .keyword_unreachable => return true,
        else => {},
    };
    return false;
}

fn runtimeName(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    var name: ?[]const u8 = null;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or context.tokenIs(index, "self") or context.tokenIs(index, "std") or
            context.tokenIs(index, "math")) continue;
        name = context.tokenText(index);
    }
    return name;
}

fn signedOperationBits(context: RuleRun, left_name: []const u8, start: usize, end: usize, before: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier) if (signedTypeBits(context.tokenText(index))) |bits| return bits;
    }
    const function_start = enclosingFunctionDeclaration(context, before) orelse 0;
    var index = before;
    while (index > function_start) {
        index -= 1;
        if (!context.tokenIs(index, left_name) or index + 2 >= before or context.tokens[index + 1].tag != .colon) continue;
        return signedTypeBits(context.tokenText(index + 2));
    }
    return null;
}

fn unsignedOriginBits(context: RuleRun, name: []const u8, before: usize, depth: usize) ?usize {
    if (depth == 3) return null;
    const function_start = enclosingFunctionDeclaration(context, before) orelse 0;
    var index = before;
    while (index > function_start) {
        index -= 1;
        if (!context.tokenIs(index, name)) continue;
        if (index + 2 < before and context.tokens[index + 1].tag == .colon) {
            if (unsignedTypeBits(context.tokenText(index + 2))) |bits| return bits;
            if (signedTypeBits(context.tokenText(index + 2)) == null) continue;
            const declaration_end = context.statementEnd(statementStart(context.tokens, index)) orelse continue;
            var source_name: ?[]const u8 = null;
            for (context.tokens[index + 3 .. declaration_end], index + 3..) |token, value_index| {
                if (token.tag != .identifier or context.tokenIs(value_index, "intCast") or
                    context.tokenIs(value_index, "intFromFloat")) continue;
                if (context.tokens[value_index - 1].tag == .period) continue;
                source_name = context.tokenText(value_index);
            }
            if (source_name) |source| return unsignedOriginBits(context, source, index, depth + 1);
        }
        if (index > 0 and (context.tokens[index - 1].tag == .keyword_const or
            context.tokens[index - 1].tag == .keyword_var))
        {
            const declaration_end = context.statementEnd(index - 1) orelse continue;
            for (context.tokens[index + 1 .. declaration_end], index + 1..) |token, value_index| {
                if (token.tag == .identifier) if (unsignedTypeBits(context.tokenText(value_index))) |bits| return bits;
            }
        }
    }
    return null;
}

fn integerTypedBinding(context: RuleRun, name: []const u8, before: usize) bool {
    const function_body = context.scopes.functionBodyContaining(before) orelse return false;
    const function_start = context.scopes.functionKeyword(function_body) orelse return false;
    var name_index = before;
    while (name_index > function_start) {
        name_index -= 1;
        if (!context.tokenIs(name_index, name)) continue;
        if ((name_index > function_start and context.tokens[name_index - 1].tag == .pipe) or
            (name_index + 1 < before and context.tokens[name_index + 1].tag == .pipe)) return false;
        if (name_index + 1 < before and context.tokens[name_index + 1].tag == .colon) {
            return typeRangeIsInteger(context, name_index + 2, before);
        }
        if (name_index > function_start and
            (context.tokens[name_index - 1].tag == .keyword_const or context.tokens[name_index - 1].tag == .keyword_var) and
            name_index + 1 < before and context.tokens[name_index + 1].tag == .equal) return false;
    }
    return false;
}

fn selfFieldHasIntegerType(context: RuleRun, field_name: []const u8, before: usize) bool {
    const function_body = context.scopes.functionBodyContaining(before) orelse return false;
    const type_body = context.enclosingOpeningBrace(function_body) orelse return false;
    for (context.tokens[type_body + 1 .. function_body], type_body + 1..) |token, field_index| {
        if (token.tag != .identifier or !context.tokenIs(field_index, field_name) or
            field_index + 2 >= function_body or context.tokens[field_index + 1].tag != .colon or
            context.enclosingOpeningBrace(field_index) != type_body) continue;
        return typeRangeIsInteger(context, field_index + 2, function_body);
    }
    return false;
}

fn rangeContainsLiteral(context: RuleRun, literal: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .number_literal and std.mem.eql(u8, context.tokenText(index), literal)) return true;
    }
    return false;
}

fn rangeContainsTag(tokens: []const std.zig.Token, tag: std.zig.Token.Tag, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| if (token.tag == tag) return true;
    return false;
}

fn lengthReceiverName(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    var index = start;
    while (index + 2 < end) : (index += 1) {
        if (context.tokens[index].tag == .identifier and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, "len")) return context.tokenText(index);
    }
    return null;
}

fn unsignedTypeBits(name: []const u8) ?usize {
    if (name.len < 2 or name[0] != 'u') return null;
    return std.fmt.parseInt(usize, name[1..], 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => null,
    };
}

fn rangeHasCursorName(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{ "cursor", "offset" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        const identifier = context.tokenText(index);
        for (names) |name| {
            if (std.mem.eql(u8, identifier, name) or
                (identifier.len > name.len and identifier[identifier.len - name.len - 1] == '_' and
                    std.mem.endsWith(u8, identifier, name))) return true;
        }
    }
    return false;
}

fn unsignedTypedBinding(context: RuleRun, fields: *const FieldTypes, name: []const u8, before: usize) bool {
    const function_body = context.scopes.functionBodyContaining(before) orelse return false;
    const function_start = context.scopes.functionKeyword(function_body) orelse return false;
    var name_index = before;
    while (name_index > function_start) {
        name_index -= 1;
        if (!context.tokenIs(name_index, name) or name_index + 1 >= before) continue;
        if (context.tokens[name_index + 1].tag == .colon) {
            return typeRangeIsUnsigned(context, name_index + 2, before);
        }
        if (context.tokens[name_index + 1].tag != .equal or name_index == 0 or
            (context.tokens[name_index - 1].tag != .keyword_const and
                context.tokens[name_index - 1].tag != .keyword_var)) continue;
        const declaration_end = context.statementEnd(name_index - 1) orelse continue;
        if (declaration_end >= before) continue;
        for (context.tokens[name_index + 2 .. declaration_end], name_index + 2..) |token, index| {
            if (token.tag == .identifier and context.tokenIs(index, "readInt")) return true;
        }
        if (arithmeticInRange(context, .plus, name_index + 2, declaration_end)) |operator_index| {
            return unsignedIntegerExpression(context, fields, name_index + 2, operator_index) and
                unsignedIntegerExpression(context, fields, operator_index + 1, declaration_end);
        }
    }
    return false;
}

fn rangeContainsNameInFunction(
    context: RuleRun,
    name: []const u8,
    function_body: usize,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and
            context.scopes.functionBodyContaining(index) == function_body) return true;
    }
    return false;
}

fn rangeUsesBindingAsSliceEnd(
    context: RuleRun,
    binding: []const u8,
    function_body: usize,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, range_index| {
        if (token.tag != .ellipsis2) continue;
        for (context.tokens[range_index + 1 .. end], range_index + 1..) |candidate, index| {
            if (candidate.tag == .r_bracket) break;
            if (candidate.tag == .identifier and context.tokenIs(index, binding) and
                context.scopes.functionBodyContaining(index) == function_body) return true;
        }
    }
    return false;
}

fn enclosingFunctionDeclaration(context: RuleRun, target: usize) ?usize {
    const body = context.scopes.functionBodyContaining(target) orelse return null;
    return context.scopes.functionKeyword(body);
}

fn signedTypeBits(name: []const u8) ?usize {
    if (name.len < 2 or name[0] != 'i') return null;
    return std.fmt.parseInt(usize, name[1..], 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => null,
    };
}

fn typeRangeIsInteger(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, type_index| {
        if (token.tag == .identifier and integerTypeName(context.tokenText(type_index))) return true;
        if (token.tag == .comma or token.tag == .equal or token.tag == .r_paren or token.tag == .semicolon) return false;
    }
    return false;
}

fn typeRangeIsUnsigned(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, type_index| {
        if (token.tag == .identifier) return unsignedIntegerTypeName(context.tokenText(type_index));
        if (token.tag == .comma or token.tag == .equal or token.tag == .r_paren or token.tag == .semicolon) return false;
    }
    return false;
}

fn integerTypeName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize") or
        std.mem.eql(u8, name, "c_int") or std.mem.eql(u8, name, "c_uint") or
        std.mem.eql(u8, name, "c_long") or std.mem.eql(u8, name, "c_ulong") or
        std.mem.eql(u8, name, "c_short") or std.mem.eql(u8, name, "c_ushort") or
        std.mem.eql(u8, name, "c_longlong") or std.mem.eql(u8, name, "c_ulonglong")) return true;
    if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return false;
    for (name[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn unsignedIntegerTypeName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "c_uint") or
        std.mem.eql(u8, name, "c_ulong") or std.mem.eql(u8, name, "c_ushort") or
        std.mem.eql(u8, name, "c_ulonglong")) return true;
    if (name.len < 2 or name[0] != 'u') return false;
    for (name[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

test "checked addition is not made safe by a later minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Writer = struct { offset: usize, output: []u8, " ++
        "fn end(self: *Writer, amount: usize) usize { return @min(self.output.len, self.offset + amount); } }; " ++
        "fn second(limit: usize, offset: usize, amount: usize) usize { " ++
        "return @min(limit + 1, offset + amount); }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(types.Rule.overflow_before_clamp, found[0].rule);
    try std.testing.expectEqual(types.Rule.overflow_before_clamp, found[1].rule);
}

test "safe clamp arithmetic remains clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn guarded(limit: usize, offset: usize, amount: usize) usize { " ++
        "if (amount > limit - offset) return limit; return @min(limit, offset + amount); } " ++
        "fn saturated(limit: usize, offset: usize, amount: usize) usize { return @min(limit, offset +| amount); } " ++
        "fn smallLookahead(limit: usize, offset: usize) usize { return @min(limit, offset + 8); } " ++
        "fn indexed(ranges: []Range, output_length: usize, range: Range) usize { " ++
        "return @max(ranges[output_length - 1].end, range.end); } " ++
        "const global_amount: usize = 1; fn inferred(limit: usize, offset: usize) usize { " ++
        "const global_amount = compute(); return @min(limit, offset + global_amount); } " ++
        "fn checked(limit: usize, offset: usize, amount: usize) !usize { " ++
        "const end = try std.math.add(usize, offset, amount); return @min(limit, end); }" ++
        "fn conditional(label: []const u8, maximum: usize) usize { " ++
        "return @max(0, if (maximum > label.len + 3) 0 else label.len + 3 - maximum); }" ++
        "fn bits(number: u64) usize { return @max(@bitSizeOf(@TypeOf(number)) - @clz(number), 3); }" ++
        "fn widened(height: u16, thickness: u16) i32 { const height_i: i32 = @intCast(height);" ++
        "return @max(0, height_i - @as(i32, thickness)); }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "unchecked range end addition before comparison reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Entry = struct { offset: usize, data: []const u8 };" ++
        "const Sprite = struct { width: usize };" ++
        "fn contains(total: usize, offset: usize, bytes: []const u8) bool {" ++
        "return offset + bytes.len <= total; }" ++
        "fn adjacent(entry: Entry, next: Entry) bool {" ++
        "return entry.offset + entry.data.len == next.offset; }" ++
        "fn decode(bytes: []const u8, cursor: usize, name_len: usize) bool {" ++
        "return cursor + 8 > bytes.len or cursor + name_len > bytes.len; }" ++
        "fn region(sprite: Sprite, x: usize, width: usize) bool {" ++
        "return x + width <= sprite.width; }" ++
        "fn take(bytes: []const u8, start: usize, length: usize) []const u8 {" ++
        "return bytes[start..start + length]; }" ++
        "fn assigned(bytes: []const u8, cursor: usize) bool {" ++
        "const name_len = std.mem.readInt(u32, bytes[0..4], .little);" ++
        "const content_len = std.mem.readInt(u32, bytes[4..8], .little);" ++
        "const name_end = cursor + name_len; const content_end = name_end + content_len;" ++
        "return content_end <= bytes.len; }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var range_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unchecked_range_end) range_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), range_count);
}

test "range checks inside functions with anonymous struct returns report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn contains(total: usize, offset: usize, bytes: []const u8) struct { ok: bool } {" ++
        "_ = total; const end = offset + bytes.len; return .{ .ok = end <= bytes.len }; }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var range_count: usize = 0;
    for (found) |finding| if (finding.rule == .unchecked_range_end) {
        range_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), range_count);
}

test "subtraction and checked range ends stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn contains(total: usize, offset: usize, bytes: []const u8) bool {" ++
        "if (offset > total) return false; return bytes.len <= total - offset; }" ++
        "fn checked(total: usize, offset: usize, length: usize) !bool {" ++
        "const end = try std.math.add(usize, offset, length); return end <= total; }" ++
        "fn header(bytes: []const u8, cursor: usize) bool {" ++
        "if (cursor > bytes.len - 8) return false; return cursor + 8 <= bytes.len; }" ++
        "fn signed(x: i32, width: i32, limit: i32) bool { return x + width <= limit; }" ++
        "fn floating(x: f64, width: f64, limit: f64) bool { return x + width <= limit; }" ++
        "fn narrowed(word: []const u8, col: u16, limit: usize) bool {" ++
        "const word_len: u16 = @intCast(word.len); _ = word_len; return col + word.len <= limit; }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unchecked_range_end);
}

test "sums of lengths, assertions, widened operands and pointer arithmetic stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Digest = struct { buf_len: u8, buf: [64]u8 };" ++
        "fn joined(buffer: []u8, a: []const u8, b: []const u8) []u8 { return buffer[0 .. a.len + 1 + b.len]; }" ++
        "fn fits(a: []const u8, b: []const u8, limit: usize) bool { return a.list.items.len + b.len > limit; }" ++
        "fn total(a: []const u8, b: []const u8) usize { const sum = a.len + b.len; return buffer[0..sum].len; }" ++
        "fn room(self: *List, offset: usize, n: usize) void { std.debug.assert(offset + n <= self.capacity); }" ++
        "fn update(d: *Digest, b: []const u8) bool { return d.buf_len + b.len >= 64; }" ++
        "fn small(count: u16, b: []const u8, limit: usize) bool { return count + b.len > limit; }" ++
        "fn last(buf: []u8, end: [*]u8) bool { return buf.ptr + buf.len == end; }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unchecked_range_end);
}

test "a wide operand added to a length still reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn wide(count: u64, b: []const u8, limit: usize) bool { return count + b.len > limit; }" ++
        "fn cursor(offset: usize, b: []const u8, limit: usize) bool { return offset + b.len > limit; }" ++
        "fn later(offset: usize, b: []const u8, limit: usize) bool { const ok = offset + b.len <= limit; assert(ok); return ok; }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var range_count: usize = 0;
    for (found) |finding| if (finding.rule == .unchecked_range_end) {
        range_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), range_count);
}

test "nested functions do not consume an outer declared range end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(cursor: usize, amount: usize) usize { const Decoder = struct { fn read(bytes: []const u8) u32 {" ++
        "const amount = std.mem.readInt(u32, bytes[0..4], .little); return amount; } }; _ = Decoder;" ++
        "const end = cursor + amount; const Local = struct {" ++
        "fn take(bytes: []const u8, end: usize) []const u8 { return bytes[0..end]; } }; _ = Local; return end; }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unchecked_range_end);
}

test "comparisons nested inside a later call are not range-end bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn measure(slice: []const u8, index: usize) u64 { var length: u64 = 0;" ++
        "length += slice.len - 2 + @intFromBool(index != 0); return length; }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unchecked_range_end);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, types.Configuration.defaults());
}
