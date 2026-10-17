const std = @import("std");

const analysis = @import("../analysis.zig");
const tokens_util = @import("../syntax/tokens.zig");
const syntax_types = @import("../syntax/types.zig");
const action_context = @import("context.zig");

const ActionRun = action_context.ActionRun;
const Ast = std.zig.Ast;

pub fn run(context: ActionRun) !void {
    try addErrorAndOptionalActions(context);
    try addPointerCastAction(context);
    try addSplitCompoundAssertion(context);
    try addOrelseUnreachableUnwrap(context);
    try addArithmeticVariants(context);
}

const ReturnKind = struct {
    fallible: bool = false,
    optional: bool = false,
    errors: []const []const u8 = &.{},
    merged_error_sets: bool = false,
};

const Expression = struct {
    span: std.zig.Token.Loc,
    call_name: ?[]const u8 = null,
    token_index: usize,
};

fn addErrorAndOptionalActions(context: ActionRun) !void {
    const expression = selectedExpression(context) orelse return;
    const return_kind = if (expression.call_name) |name|
        try declaredReturnKind(context, name)
    else
        declaredBindingKind(context, context.tokenText(expression.token_index), expression.token_index);
    if (!return_kind.fallible and !return_kind.optional) return;
    const source_expression = context.source[expression.span.start..expression.span.end];
    const function = action_context.containingFunction(context, expression.token_index);

    if (return_kind.fallible and statementContext(context, expression)) {
        if (function != null and function.?.returnsError(context)) {
            try context.oneEdit(
                "Propagate the error with try",
                .refactor_rewrite,
                expression.span,
                try context.allocator.print("try {s}", .{source_expression}),
                .{},
            );
        }
        // A discarded |err| capture is a compile error, so the catch stays captureless.
        try context.oneEdit(
            "Handle the error with catch",
            .refactor_rewrite,
            expression.span,
            try context.allocator.print("{s} catch @panic(\"TODO\")", .{source_expression}),
            .{},
        );
        if (return_kind.errors.len != 0 and !return_kind.merged_error_sets) {
            try context.oneEdit(
                "Handle every error with a switch",
                .refactor_rewrite,
                expression.span,
                try errorSwitchReplacement(context, source_expression, return_kind.errors, try errorCaptureName(context)),
                .{},
            );
        }
    }

    if (return_kind.optional) {
        try context.oneEdit(
            "Unwrap the optional or stop",
            .refactor_rewrite,
            expression.span,
            try context.allocator.print("{s}.?", .{source_expression}),
            .{},
        );
        if (function != null and function.?.returnsVoid(context)) {
            try context.oneEdit(
                "Return when the optional is null",
                .refactor_rewrite,
                expression.span,
                try context.allocator.print("({s} orelse return)", .{source_expression}),
                .{},
            );
        }
        if (standaloneStatement(context, expression.span)) |statement_span| {
            const indentation = context.lineIndentation(statement_span.start);
            try context.oneEdit(
                "Capture the optional payload",
                .refactor_rewrite,
                statement_span,
                try context.allocator.print(
                    "if ({s}) |value| {{\n{s}    _ = value;\n{s}}}",
                    .{ source_expression, indentation, indentation },
                ),
                .{},
            );
        }
    }
}

fn selectedExpression(context: ActionRun) ?Expression {
    const selected_index = action_context.selectedTokenIndex(context) orelse return null;
    const token = context.tokens[selected_index];
    if (token.tag != .identifier) return null;
    if (selected_index > 0 and switch (context.tokens[selected_index - 1].tag) {
        .keyword_fn, .keyword_const, .keyword_var, .keyword_try, .period => true,
        else => false,
    }) return null;
    if (selected_index + 1 < context.tokens.len and context.tokens[selected_index + 1].tag == .l_paren) {
        const closing = context.matchingToken(selected_index + 1, .l_paren, .r_paren) orelse return null;
        if (closing + 1 < context.tokens.len and context.tokens[closing + 1].tag == .keyword_catch) return null;
        const span = std.zig.Token.Loc{ .start = token.loc.start, .end = context.tokens[closing].loc.end };
        if (!context.selected(span)) return null;
        return .{ .span = span, .call_name = context.tokenText(selected_index), .token_index = selected_index };
    }
    if (selected_index + 1 < context.tokens.len and context.tokens[selected_index + 1].tag == .period) return null;
    return .{ .span = token.loc, .token_index = selected_index };
}

fn declaredReturnKind(context: ActionRun, name: []const u8) !ReturnKind {
    var declared: ?ReturnKind = null;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .keyword_fn or index + 2 >= context.tokens.len or
            context.tokens[index + 1].tag != .identifier or !context.tokenIs(index + 1, name) or
            context.tokens[index + 2].tag != .l_paren) continue;
        if (declared != null) return .{};
        const parameters_end = context.matchingToken(index + 2, .l_paren, .r_paren) orelse continue;
        var return_end = parameters_end + 1;
        while (return_end < context.tokens.len and context.tokens[return_end].tag != .semicolon) {
            if (context.tokens[return_end].tag == .keyword_error and return_end + 1 < context.tokens.len and
                context.tokens[return_end + 1].tag == .l_brace)
            {
                return_end = (context.matchingToken(return_end + 1, .l_brace, .r_brace) orelse break) + 1;
                continue;
            }
            if (context.tokens[return_end].tag == .l_brace) break;
            return_end += 1;
        }
        declared = returnKind(context, parameters_end + 1, return_end);
    }
    return declared orelse .{};
}

fn declaredBindingKind(context: ActionRun, name: []const u8, before: usize) ReturnKind {
    const function = action_context.containingFunction(context, before);
    const lower = if (function) |enclosing| enclosing.fn_index else 0;
    var index = before;
    while (index > lower) {
        index -= 1;
        if (!context.tokenIs(index, name) or index + 2 >= context.tokens.len or context.tokens[index + 1].tag != .colon) continue;
        var type_end = index + 2;
        while (type_end < before and context.tokens[type_end].tag != .comma and
            context.tokens[type_end].tag != .equal and context.tokens[type_end].tag != .r_paren) : (type_end += 1)
        {}
        return returnKind(context, index + 2, type_end);
    }
    return .{};
}

fn returnKind(context: ActionRun, start: usize, end: usize) ReturnKind {
    var kind: ReturnKind = .{};
    for (context.tokens[start..end]) |token| switch (token.tag) {
        .bang => kind.fallible = true,
        .question_mark => kind.optional = true,
        .pipe_pipe => kind.merged_error_sets = true,
        else => {},
    };
    kind.errors = explicitErrors(context, start, end);
    return kind;
}

fn statementContext(context: ActionRun, expression: Expression) bool {
    if (standaloneStatement(context, expression.span) != null) return true;
    if (expression.token_index == 0) return false;
    const previous = context.tokens[expression.token_index - 1].tag;
    if (previous != .equal and previous != .keyword_return) return false;
    var end = expression.span.end;
    while (end < context.source.len and (context.source[end] == ' ' or context.source[end] == '\t')) : (end += 1) {}
    return end < context.source.len and context.source[end] == ';';
}

fn errorCaptureName(context: ActionRun) ![]const u8 {
    if (!identifierExists(context, "err")) return "err";
    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const candidate = try context.allocator.print("err{d}", .{suffix});
        if (!identifierExists(context, candidate)) return candidate;
    }
}

fn identifierExists(context: ActionRun, name: []const u8) bool {
    for (context.tokens, 0..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

fn explicitErrors(context: ActionRun, start: usize, end: usize) []const []const u8 {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_error or index + 1 >= end or context.tokens[index + 1].tag != .l_brace) continue;
        const closing = context.matchingToken(index + 1, .l_brace, .r_brace) orelse return &.{};
        var count: usize = 0;
        for (context.tokens[index + 2 .. @min(closing, end)]) |field| if (field.tag == .identifier) {
            count += 1;
        };
        const names = context.allocator.alloc([]const u8, count) catch return &.{};
        var write_index: usize = 0;
        for (context.tokens[index + 2 .. @min(closing, end)], index + 2..) |field, field_index| {
            if (field.tag != .identifier) continue;
            names[write_index] = context.tokenText(field_index);
            write_index += 1;
        }
        return names;
    }
    return &.{};
}

fn errorSwitchReplacement(
    context: ActionRun,
    expression: []const u8,
    errors: []const []const u8,
    capture: []const u8,
) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(context.allocator);
    defer writer.deinit();
    try writer.writer.print("{s} catch |{s}| switch ({s}) {{\n", .{ expression, capture, capture });
    for (errors) |name| try writer.writer.print("    error.{s} => @panic(\"TODO\"),\n", .{name});
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn standaloneStatement(context: ActionRun, expression_span: std.zig.Token.Loc) ?std.zig.Token.Loc {
    var end = expression_span.end;
    while (end < context.source.len and (context.source[end] == ' ' or context.source[end] == '\t')) : (end += 1) {}
    if (end >= context.source.len or context.source[end] != ';') return null;
    const line_start = if (std.mem.findScalarLast(u8, context.source[0..expression_span.start], '\n')) |nl| nl + 1 else 0;
    if (std.mem.trim(u8, context.source[line_start..expression_span.start], " \t").len != 0) return null;
    return .{ .start = expression_span.start, .end = end + 1 };
}

fn addPointerCastAction(context: ActionRun) !void {
    const expression = selectedExpression(context) orelse return;
    if (expression.call_name != null) return;
    const assignment = typedAssignmentBefore(context, expression.token_index) orelse return;
    const source_type = declaredType(context, context.tokenText(expression.token_index), expression.token_index) orelse return;
    if (std.mem.findScalar(u8, source_type, '*') == null or std.mem.findScalar(u8, assignment.target_type, '*') == null) return;
    const needs_alignment = std.mem.find(u8, assignment.target_type, "align(") != null and
        std.mem.find(u8, source_type, "align(") == null;
    const needs_const_removal = try constQualified(context, source_type) and
        !try constQualified(context, assignment.target_type);
    const needs_pointer_cast = !std.mem.eql(u8, pointeeName(source_type), pointeeName(assignment.target_type));
    if (!needs_alignment and !needs_const_removal and !needs_pointer_cast) return;

    var replacement = context.source[expression.span.start..expression.span.end];
    if (needs_alignment) replacement = try context.allocator.print("@alignCast({s})", .{replacement});
    if (needs_pointer_cast) replacement = try context.allocator.print("@ptrCast({s})", .{replacement});
    if (needs_const_removal) replacement = try context.allocator.print("@constCast({s})", .{replacement});
    const title = if (needs_const_removal)
        "Insert pointer casts including @constCast (removes const — verify writes are safe)"
    else
        "Insert the required pointer casts";
    try context.oneEdit(title, .quickfix, expression.span, replacement, .{});
}

fn constQualified(context: ActionRun, type_text: []const u8) !bool {
    const buffer = try context.allocator.dupeSentinel(u8, type_text, 0);
    defer context.allocator.free(buffer);
    var tokenizer = std.zig.Tokenizer.init(buffer);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return false;
        if (token.tag == .keyword_const) return true;
    }
}

fn pointeeName(pointer_type: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, pointer_type, " \t\r\n");
    const separator = std.mem.findLastAny(u8, trimmed, " \t") orelse return trimmed;
    return std.mem.trim(u8, trimmed[separator + 1 ..], " \t\r\n");
}

const TypedAssignment = struct { target_type: []const u8 };

fn typedAssignmentBefore(context: ActionRun, expression_index: usize) ?TypedAssignment {
    if (expression_index < 4 or context.tokens[expression_index - 1].tag != .equal) return null;
    var colon = expression_index - 1;
    while (colon > 0 and context.tokens[colon].tag != .colon and context.tokens[colon].tag != .semicolon and
        context.tokens[colon].tag != .l_brace) : (colon -= 1)
    {}
    if (context.tokens[colon].tag != .colon) return null;
    const start = context.tokens[colon + 1].loc.start;
    const end = context.tokens[expression_index - 1].loc.start;
    return .{ .target_type = std.mem.trim(u8, context.source[start..end], " \t\r\n") };
}

fn addSplitCompoundAssertion(context: ActionRun) !void {
    for (context.tokens, 0..) |token, name_index| {
        if (token.tag != .identifier or !context.tokenIs(name_index, "assert") or
            name_index + 1 >= context.tokens.len or context.tokens[name_index + 1].tag != .l_paren) continue;
        var callee_start = name_index;
        while (callee_start >= 2 and context.tokens[callee_start - 1].tag == .period and
            context.tokens[callee_start - 2].tag == .identifier) callee_start -= 2;
        const closing = context.matchingToken(name_index + 1, .l_paren, .r_paren) orelse continue;
        const call_span = std.zig.Token.Loc{
            .start = context.tokens[callee_start].loc.start,
            .end = context.tokens[closing].loc.end,
        };
        const statement_span = standaloneStatement(context, call_span) orelse continue;
        if (!context.selected(statement_span)) continue;
        const conditions = try topLevelAndOperands(context, name_index + 2, closing) orelse continue;
        if (conditions.len < 2) continue;
        // A line comment inside an operand would comment out the inserted ');',
        // and one next to an 'and' or a parenthesis would be dropped silently.
        const argument_text = context.source[context.tokens[name_index + 1].loc.end..context.tokens[closing].loc.start];
        if (std.mem.find(u8, argument_text, "//") != null) continue;
        const callee = context.source[context.tokens[callee_start].loc.start..context.tokens[name_index].loc.end];
        const indentation = context.lineIndentation(statement_span.start);
        var writer: std.Io.Writer.Allocating = .init(context.allocator);
        defer writer.deinit();
        for (conditions, 0..) |condition, index| {
            if (index != 0) try writer.writer.print("\n{s}", .{indentation});
            try writer.writer.print("{s}({s});", .{ callee, std.mem.trim(u8, condition, " \t\r\n") });
        }
        try context.oneEdit(
            "Split compound assertion",
            .refactor_rewrite,
            statement_span,
            try writer.toOwnedSlice(),
            .{},
        );
    }
}

fn topLevelAndOperands(context: ActionRun, start: usize, end: usize) !?[]const []const u8 {
    if (start >= end) return null;
    var operands: std.ArrayList([]const u8) = .empty;
    errdefer operands.deinit(context.allocator);
    var operand_start = start;
    var depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .keyword_or, .comma => if (depth == 0) return null,
        .keyword_and => if (depth == 0) {
            if (operand_start == index) return null;
            try operands.append(context.allocator, context.source[context.tokens[operand_start].loc.start..token.loc.start]);
            operand_start = index + 1;
        },
        else => {},
    };
    if (operand_start >= end) return null;
    try operands.append(
        context.allocator,
        context.source[context.tokens[operand_start].loc.start..context.tokens[end - 1].loc.end],
    );
    return try operands.toOwnedSlice(context.allocator);
}

/// 'value.?' is Zig's spelling of 'value orelse unreachable', so the rewrite
/// preserves behavior exactly. The match is limited to a postfix chain that
/// starts its own expression so no lower-precedence operand is captured.
fn addOrelseUnreachableUnwrap(context: ActionRun) !void {
    for (context.tokens, 0..) |token, orelse_index| {
        if (token.tag != .keyword_orelse or orelse_index == 0 or orelse_index + 1 >= context.tokens.len or
            context.tokens[orelse_index + 1].tag != .keyword_unreachable) continue;
        if (orelse_index + 2 < context.tokens.len and switch (context.tokens[orelse_index + 2].tag) {
            .semicolon, .comma, .r_paren, .r_bracket, .r_brace => false,
            else => true,
        }) continue;
        const start_index = unwrappedChainStart(context, orelse_index - 1) orelse continue;
        if (start_index > 0 and !startsOwnExpression(context.tokens[start_index - 1].tag)) continue;
        const span = std.zig.Token.Loc{
            .start = context.tokens[start_index].loc.start,
            .end = context.tokens[orelse_index + 1].loc.end,
        };
        if (!context.selected(span)) continue;
        if (commentBetweenTokens(context, start_index, orelse_index + 1)) continue;
        try context.oneEdit(
            "Unwrap with '.?' instead of orelse unreachable",
            .refactor_rewrite,
            span,
            try context.allocator.print("{s}.?", .{
                context.source[span.start..context.tokens[orelse_index - 1].loc.end],
            }),
            .{},
        );
    }
}

fn unwrappedChainStart(context: ActionRun, last: usize) ?usize {
    var index = last;
    while (true) {
        switch (context.tokens[index].tag) {
            .identifier => {
                if (index >= 2 and context.tokens[index - 1].tag == .period) {
                    switch (context.tokens[index - 2].tag) {
                        .identifier, .r_paren, .r_bracket, .question_mark => {
                            index -= 2;
                            continue;
                        },
                        else => return null,
                    }
                }
                // '.name' with nothing to chain from is an enum or error literal.
                if (index >= 1 and context.tokens[index - 1].tag == .period) return null;
                return index;
            },
            .question_mark => {
                if (index >= 2 and context.tokens[index - 1].tag == .period) {
                    index -= 2;
                    continue;
                }
                return null;
            },
            .period_asterisk => {
                if (index == 0) return null;
                index -= 1;
            },
            .r_paren => {
                const opening = reverseMatchingToken(context, index, .r_paren, .l_paren) orelse return null;
                if (opening == 0) return opening;
                switch (context.tokens[opening - 1].tag) {
                    .identifier, .r_paren, .r_bracket, .question_mark => index = opening - 1,
                    .builtin => return opening - 1,
                    // Not a call: the parenthesized group is its own primary.
                    else => return opening,
                }
            },
            .r_bracket => {
                const opening = reverseMatchingToken(context, index, .r_bracket, .l_bracket) orelse return null;
                if (opening == 0) return null;
                switch (context.tokens[opening - 1].tag) {
                    .identifier, .r_paren, .r_bracket => index = opening - 1,
                    else => return null,
                }
            },
            else => return null,
        }
    }
}

fn startsOwnExpression(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal,
        .l_paren,
        .l_brace,
        .l_bracket,
        .comma,
        .semicolon,
        .keyword_return,
        .equal_angle_bracket_right,
        => true,
        else => false,
    };
}

fn reverseMatchingToken(
    context: ActionRun,
    closing: usize,
    closing_tag: std.zig.Token.Tag,
    opening_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    var index = closing + 1;
    while (index > 0) {
        index -= 1;
        const tag = context.tokens[index].tag;
        if (tag == closing_tag) depth += 1;
        if (tag != opening_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

fn commentBetweenTokens(context: ActionRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        const gap = context.source[token.loc.end..context.tokens[index + 1].loc.start];
        if (std.mem.find(u8, gap, "//") != null) return true;
    }
    return false;
}

fn declaredType(context: ActionRun, name: []const u8, before: usize) ?[]const u8 {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, name) or index + 2 >= context.tokens.len or context.tokens[index + 1].tag != .colon) continue;
        var end = index + 2;
        while (end < before and context.tokens[end].tag != .comma and context.tokens[end].tag != .equal and
            context.tokens[end].tag != .r_paren) : (end += 1)
        {}
        return std.mem.trim(u8, context.source[context.tokens[index + 2].loc.start..context.tokens[end].loc.start], " \t\r\n");
    }
    return null;
}

/// The overflow-aware spellings of one arithmetic operator.
const ArithmeticOperator = struct {
    wrapping: ?[]const u8 = null,
    saturating: []const u8,
    checked: ?CheckedBuiltin = null,
    compound: bool = false,
};

const CheckedBuiltin = struct {
    builtin: []const u8,
    /// The base name of the tuple the checked rewrite binds.
    result: []const u8,
};

fn arithmeticOperator(tag: Ast.Node.Tag) ?ArithmeticOperator {
    const add: CheckedBuiltin = .{ .builtin = "@addWithOverflow", .result = "sum" };
    const sub: CheckedBuiltin = .{ .builtin = "@subWithOverflow", .result = "difference" };
    const mul: CheckedBuiltin = .{ .builtin = "@mulWithOverflow", .result = "product" };
    return switch (tag) {
        .add => .{ .wrapping = "+%", .saturating = "+|", .checked = add },
        .sub => .{ .wrapping = "-%", .saturating = "-|", .checked = sub },
        .mul => .{ .wrapping = "*%", .saturating = "*|", .checked = mul },
        .shl => .{ .saturating = "<<|" },
        .assign_add => .{ .wrapping = "+%=", .saturating = "+|=", .checked = add, .compound = true },
        .assign_sub => .{ .wrapping = "-%=", .saturating = "-|=", .checked = sub, .compound = true },
        .assign_mul => .{ .wrapping = "*%=", .saturating = "*|=", .checked = mul, .compound = true },
        .assign_shl => .{ .saturating = "<<|=", .compound = true },
        else => null,
    };
}

/// Spells a selected `+`, `-` or `*` (or its compound assignment) with
/// wrapping, saturating or overflow-checked arithmetic, and `<<` with a
/// saturating shift. The left operand must be proven a fixed-width integer:
/// `+%` and `+|` reject floats and pointer arithmetic, and `@addWithOverflow`
/// rejects `comptime_int`, so an unproven operand could stop compiling.
fn addArithmeticVariants(context: ActionRun) !void {
    const operator_index = selectedArithmeticOperator(context) orelse return;
    var tree = try Ast.parse(context.allocator, context.source, .{ .mode = .zig });
    defer tree.deinit(context.allocator);
    const node = arithmeticNodeAt(&tree, operator_index) orelse return;
    const operator = arithmeticOperator(tree.nodeTag(node)).?;
    const body = enclosingBody(context, &tree, operator_index) orelse return;
    const scope: TypeScope = .{ .context = context, .tree = &tree, .body = body };
    const left, const right = tree.nodeData(node).node_and_node;
    const left_proven = scope.integer(left);
    // `1 << n` only compiles with a comptime shift, so the literal form is for the other operators.
    const literal_left = tree.nodeTag(node) != .shl and integerLiteral(&tree, left) and scope.integer(right);
    if (!left_proven and !literal_left) return;
    const operator_span = context.tokens[operator_index].loc;
    if (operator.wrapping) |wrapping| try context.oneEdit(
        try context.allocator.print("Use wrapping arithmetic '{s}'", .{wrapping}),
        .refactor_rewrite,
        operator_span,
        wrapping,
        .{},
    );
    try context.oneEdit(
        try context.allocator.print("Use saturating arithmetic '{s}'", .{operator.saturating}),
        .refactor_rewrite,
        operator_span,
        operator.saturating,
        .{},
    );
    const checked = operator.checked orelse return;
    if (!body.accepts_overflow) return;
    const edits = try checkedArithmeticEdits(scope, node, operator.compound, checked) orelse return;
    try context.add(
        try context.allocator.print("Use checked arithmetic '{s}'", .{checked.builtin}),
        .refactor_rewrite,
        edits,
        .{},
    );
}

fn selectedArithmeticOperator(context: ActionRun) ?usize {
    for (context.tokens, 0..) |token, index| {
        if (token.loc.start > context.selection.end) return null;
        switch (token.tag) {
            .plus,
            .minus,
            .asterisk,
            .angle_bracket_angle_bracket_left,
            .plus_equal,
            .minus_equal,
            .asterisk_equal,
            .angle_bracket_angle_bracket_left_equal,
            => if (context.selected(token.loc)) return index,
            else => {},
        }
    }
    return null;
}

fn arithmeticNodeAt(tree: *const Ast, operator_index: usize) ?Ast.Node.Index {
    for (1..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeMainToken(node) == operator_index and arithmeticOperator(tree.nodeTag(node)) != null) return node;
    }
    return null;
}

/// The innermost function or test body around a token: the parameter list's
/// parentheses (none for a test), the body's braces, and whether the body may
/// `return error.Overflow`.
const Body = struct {
    parameters: ?[2]usize,
    start: usize,
    end: usize,
    accepts_overflow: bool,
};

fn enclosingBody(context: ActionRun, tree: *const Ast, index: usize) ?Body {
    var innermost: ?Body = null;
    for (1..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const body_node = switch (tree.nodeTag(node)) {
            .fn_decl => tree.nodeData(node).node_and_node[1],
            .test_decl => tree.nodeData(node).opt_token_and_node[1],
            else => continue,
        };
        const start = tree.firstToken(body_node);
        const end = tree.lastToken(body_node);
        if (index <= start or index >= end) continue;
        if (innermost) |current| if (current.start > start) continue;
        if (tree.nodeTag(node) == .test_decl) {
            // A test returns `anyerror!void`.
            innermost = .{ .parameters = null, .start = start, .end = end, .accepts_overflow = true };
            continue;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const prototype = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]) orelse continue;
        const parameters_end = context.matchingToken(prototype.lparen, .l_paren, .r_paren) orelse continue;
        innermost = .{
            .parameters = .{ prototype.lparen, parameters_end },
            .start = start,
            .end = end,
            .accepts_overflow = returnsOverflow(tree, prototype),
        };
    }
    return innermost;
}

/// Whether the function's error set admits `error.Overflow`: an inferred set
/// (`!T`), `anyerror`, or an explicit `error{...}` naming `Overflow`.
fn returnsOverflow(tree: *const Ast, prototype: Ast.full.FnProto) bool {
    const return_type = prototype.ast.return_type.unwrap() orelse return false;
    if (tree.tokenTag(tree.firstToken(return_type) - 1) == .bang) return true;
    if (tree.nodeTag(return_type) != .error_union) return false;
    const error_set = tree.nodeData(return_type).node_and_node[0];
    switch (tree.nodeTag(error_set)) {
        .identifier => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(error_set)), "anyerror"),
        .error_set_decl => {
            const opening, const closing = tree.nodeData(error_set).token_and_token;
            for (opening + 1..closing) |token| {
                if (tree.tokenTag(@intCast(token)) == .identifier and
                    std.mem.eql(u8, tree.tokenSlice(@intCast(token)), "Overflow")) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn integerLiteral(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .char_literal => true,
        .number_literal => switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
            .int, .big_int => true,
            .float, .failure => false,
        },
        else => false,
    };
}

/// What the one declaration of a name says about its type.
const Declaration = union(enum) {
    /// The annotation's tokens, `[start, end)`.
    annotated: [2]usize,
    /// A `for` capture of a range input, which is a `usize`.
    range_index,
    /// A binding initialized with a string literal.
    string_literal,
    unknown,
};

/// Syntax-only type facts for the operands of one expression inside `body`.
const TypeScope = struct {
    context: ActionRun,
    tree: *const Ast,
    body: Body,

    /// Whether `node` is proven to have a fixed-width integer type: a name
    /// annotated with one, a range index, `.len` of a sequence, `@as(T, x)`, or
    /// arithmetic whose left operand (or right, beside a literal) is one.
    fn integer(scope: TypeScope, node: Ast.Node.Index) bool {
        const tree = scope.tree;
        switch (tree.nodeTag(node)) {
            .identifier => return switch (scope.declaration(tree.nodeMainToken(node)) orelse return false) {
                .annotated => |range| range[1] == range[0] + 1 and
                    syntax_types.isIntegerTypeName(scope.context.tokenText(range[0])),
                .range_index => true,
                .string_literal, .unknown => false,
            },
            .field_access => {
                const object, const field = tree.nodeData(node).node_and_token;
                if (tree.nodeTag(object) != .identifier) return false;
                const object_declaration = scope.declaration(tree.nodeMainToken(object)) orelse return false;
                if (std.mem.eql(u8, tree.tokenSlice(field), "len")) switch (object_declaration) {
                    .annotated => |range| if (scope.sequenceType(range)) return true,
                    .string_literal => return true,
                    .range_index, .unknown => {},
                };
                return switch (object_declaration) {
                    .annotated => |range| scope.integerField(range, tree.tokenSlice(field)),
                    .range_index, .string_literal, .unknown => false,
                };
            },
            .grouped_expression => return scope.integer(tree.nodeData(node).node_and_token[0]),
            .builtin_call_two, .builtin_call_two_comma => {
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as")) return false;
                const type_node = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return false;
                return tree.nodeTag(type_node) == .identifier and
                    syntax_types.isIntegerTypeName(tree.tokenSlice(tree.nodeMainToken(type_node)));
            },
            .add, .sub, .mul, .div, .mod, .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat, .bit_and, .bit_or, .bit_xor => {
                const left, const right = tree.nodeData(node).node_and_node;
                return scope.integer(left) or (integerLiteral(tree, left) and scope.integer(right));
            },
            .shl, .shl_sat, .shr => return scope.integer(tree.nodeData(node).node_and_node[0]),
            else => return false,
        }
    }

    /// Whether a receiver annotated `range` (`*Self`, `T`, `*const @This()`) is
    /// the struct around the body and its field `name` is annotated with a
    /// fixed-width integer type.
    fn integerField(scope: TypeScope, range: [2]usize, name: []const u8) bool {
        const context = scope.context;
        const tree = scope.tree;
        var type_start = range[0];
        while (type_start < range[1] and
            (context.tokens[type_start].tag == .asterisk or context.tokens[type_start].tag == .keyword_const)) type_start += 1;
        const container = action_context.enclosingStruct(tree, scope.body.start) orelse return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const members = tree.fullContainerDecl(&buffer, container).?.ast.members;
        const this_type = type_start + 3 == range[1] and context.tokenIs(type_start, "@This") and
            context.tokens[type_start + 1].tag == .l_paren and context.tokens[type_start + 2].tag == .r_paren;
        if (!this_type) {
            if (type_start + 1 != range[1] or context.tokens[type_start].tag != .identifier) return false;
            if (!action_context.namesStruct(context, tree, container, context.tokenText(type_start))) return false;
        }
        for (members) |member| {
            const field = tree.fullContainerField(member) orelse continue;
            if (!std.mem.eql(u8, tree.tokenSlice(field.ast.main_token), name)) continue;
            const type_node = field.ast.type_expr.unwrap() orelse return false;
            return tree.nodeTag(type_node) == .identifier and
                syntax_types.isIntegerTypeName(tree.tokenSlice(tree.nodeMainToken(type_node)));
        }
        return false;
    }

    /// A slice, an array, or a pointer to an array: types whose `.len` is a `usize`.
    fn sequenceType(scope: TypeScope, range: [2]usize) bool {
        const tokens = scope.context.tokens;
        var index = range[0];
        if (tokens[index].tag == .asterisk) {
            index += 1;
            if (index < range[1] and tokens[index].tag == .keyword_const) index += 1;
            // `*[]T` has no `.len` of its own, so only `*[N]T` counts.
            if (index + 1 >= range[1] or tokens[index].tag != .l_bracket or tokens[index + 1].tag == .r_bracket) return false;
        }
        return index + 1 < range[1] and tokens[index].tag == .l_bracket and tokens[index + 1].tag != .asterisk;
    }

    /// The only declaration of the name at `use` visible from the body: a
    /// parameter, a local, or a capture of the function; else an annotated
    /// top-level declaration. Two declarations of the name in the function
    /// (in sibling scopes) are ambiguous and prove nothing.
    fn declaration(scope: TypeScope, use: Ast.TokenIndex) ?Declaration {
        const context = scope.context;
        const name = scope.tree.tokenSlice(use);
        var found: ?Declaration = null;
        var count: usize = 0;
        if (scope.body.parameters) |parameters| {
            var depth: usize = 0;
            for (context.tokens[parameters[0] + 1 .. parameters[1]], parameters[0] + 1..) |token, index| switch (token.tag) {
                .l_paren, .l_bracket, .l_brace => depth += 1,
                .r_paren, .r_bracket, .r_brace => depth -|= 1,
                .identifier => if (depth == 0 and context.tokens[index + 1].tag == .colon and context.tokenIs(index, name)) {
                    count += 1;
                    found = .{ .annotated = .{ index + 2, topLevelEnd(context, index + 2, parameters[1], &.{.comma}) } };
                },
                else => {},
            };
        }
        for (context.tokens[scope.body.start + 1 .. scope.body.end], scope.body.start + 1..) |token, index| {
            if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
            switch (context.tokens[index - 1].tag) {
                .keyword_const, .keyword_var => {
                    count += 1;
                    found = localDeclaration(context, index, scope.body.end);
                },
                .pipe, .comma, .asterisk => if (captureDeclaration(context, index)) |capture| {
                    count += 1;
                    found = capture;
                },
                else => {},
            }
        }
        if (count == 1) return found;
        if (count != 0) return null;
        for (scope.tree.rootDecls()) |root| {
            const variable = scope.tree.fullVarDecl(root) orelse continue;
            if (!context.tokenIs(variable.ast.mut_token + 1, name)) continue;
            const type_node = variable.ast.type_node.unwrap() orelse return .unknown;
            return .{ .annotated = .{ scope.tree.firstToken(type_node), scope.tree.lastToken(type_node) + 1 } };
        }
        return null;
    }
};

/// The first token in `[start, end)` at bracket depth zero whose tag is one of
/// `stops`, or `end`.
fn topLevelEnd(context: ActionRun, start: usize, end: usize, stops: []const std.zig.Token.Tag) usize {
    var depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        else => if (depth == 0 and std.mem.findScalar(std.zig.Token.Tag, stops, token.tag) != null) return index,
    };
    return end;
}

fn localDeclaration(context: ActionRun, name_index: usize, end: usize) Declaration {
    if (context.tokens[name_index + 1].tag == .colon) {
        return .{ .annotated = .{ name_index + 2, topLevelEnd(context, name_index + 2, end, &.{ .equal, .semicolon }) } };
    }
    if (context.tokens[name_index + 1].tag == .equal and context.tokens[name_index + 2].tag == .string_literal and
        context.tokens[name_index + 3].tag == .semicolon) return .string_literal;
    return .unknown;
}

/// The declaration a name inside `|...|` makes: a range index when it captures
/// a `for` input that is a range, else an untyped capture. Null when the pipes
/// are not a capture list.
fn captureDeclaration(context: ActionRun, name_index: usize) ?Declaration {
    var position: usize = 0;
    var cursor = name_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .pipe => break,
            .comma => position += 1,
            .identifier, .asterisk => {},
            else => return null,
        }
    }
    if (cursor == 0 or context.tokens[cursor].tag != .pipe) return null;
    switch (context.tokens[cursor - 1].tag) {
        .r_paren => {},
        .keyword_else, .keyword_catch, .equal_angle_bracket_right => return .unknown,
        else => return null,
    }
    const opening = tokens_util.matchingOpeningToken(context.tokens, cursor - 1, .l_paren, .r_paren) orelse return .unknown;
    if (opening == 0 or context.tokens[opening - 1].tag != .keyword_for) return .unknown;
    var input_start = opening + 1;
    for (0..position) |_| {
        input_start = topLevelEnd(context, input_start, cursor - 1, &.{.comma}) + 1;
        if (input_start >= cursor - 1) return .unknown;
    }
    const input_end = topLevelEnd(context, input_start, cursor - 1, &.{.comma});
    for (context.tokens[input_start..input_end]) |token| if (token.tag == .ellipsis2) return .range_index;
    return .unknown;
}

/// The edits that bind `@addWithOverflow(a, b)` before the statement holding
/// `a + b` and return `error.Overflow` when it overflowed. Only a whole
/// statement value is hoisted (`const x = a + b;`, `return a + b;`, `x = a + b;`,
/// `x += b;`), so nothing else in the statement changes evaluation order, and
/// only directly inside a block outside `defer` and `comptime`, where a
/// statement can be inserted and `return` is allowed.
fn checkedArithmeticEdits(
    scope: TypeScope,
    node: Ast.Node.Index,
    compound: bool,
    checked: CheckedBuiltin,
) !?[]const analysis.Edit {
    const context = scope.context;
    const tree = scope.tree;
    const statement = if (compound) node else valueStatement(tree, node) orelse return null;
    if (!directBlockStatement(tree, statement)) return null;
    const left, const right = tree.nodeData(node).node_and_node;
    if (compound or tree.nodeTag(statement) == .assign) {
        if (!pureLocation(context, tree, tree.nodeData(statement).node_and_node[0])) return null;
    }
    const first = tree.firstToken(statement);
    const statement_start = context.tokens[first].loc.start;
    if (std.mem.trim(u8, context.source[tokens_util.lineStart(context.source, statement_start)..statement_start], " \t").len != 0) return null;
    const left_text = nodeSource(context, tree, left);
    const right_text = nodeSource(context, tree, right);
    for ([_][]const u8{ left_text, right_text }) |operand| {
        if (std.mem.findScalar(u8, operand, '\n') != null or tokens_util.containsComment(operand)) return null;
    }
    var name: []const u8 = checked.result;
    var suffix: usize = 2;
    while (identifierExists(context, name)) : (suffix += 1) {
        name = try context.allocator.print("{s}{d}", .{ checked.result, suffix });
    }
    const indentation = context.lineIndentation(statement_start);
    const check_format = "const {s} = {s}({s}, {s});\n{s}if ({s}[1] != 0) return error.Overflow;\n{s}";
    const check_arguments = .{ name, checked.builtin, left_text, right_text, indentation, name, indentation };
    if (compound) {
        const edits = try context.allocator.alloc(analysis.Edit, 1);
        errdefer context.allocator.free(edits);
        edits[0] = .{
            .span = .{ .start = statement_start, .end = nodeSpan(context, tree, statement).end },
            .replacement = try context.allocator.print(check_format ++ "{s} = {s}[0]", check_arguments ++ .{ left_text, name }),
        };
        return edits;
    }
    const edits = try context.allocator.alloc(analysis.Edit, 2);
    errdefer context.allocator.free(edits);
    edits[0] = .{
        .span = .{ .start = statement_start, .end = statement_start },
        .replacement = try context.allocator.print(check_format, check_arguments),
    };
    edits[1] = .{ .span = nodeSpan(context, tree, node), .replacement = try context.allocator.print("{s}[0]", .{name}) };
    return edits;
}

/// The statement whose whole value is `node`: a local's initializer, a
/// returned operand, or the right side of a plain assignment.
fn valueStatement(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    for (1..tree.nodes.len) |raw_node| {
        const candidate: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        switch (tree.nodeTag(candidate)) {
            .simple_var_decl, .local_var_decl, .aligned_var_decl => {
                if (tree.fullVarDecl(candidate).?.ast.init_node.unwrap() == node) return candidate;
            },
            .@"return" => if (tree.nodeData(candidate).opt_node.unwrap() == node) return candidate,
            .assign => if (tree.nodeData(candidate).node_and_node[1] == node) return candidate,
            else => {},
        }
    }
    return null;
}

fn directBlockStatement(tree: *const Ast, statement: Ast.Node.Index) bool {
    const first = tree.firstToken(statement);
    var in_block = false;
    for (1..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        switch (tree.nodeTag(node)) {
            .block_two, .block_two_semicolon, .block, .block_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                const statements = tree.blockStatements(&buffer, node) orelse continue;
                if (std.mem.findScalar(Ast.Node.Index, statements, statement) != null) in_block = true;
            },
            // `return` is not allowed in a deferred expression or a comptime block.
            .@"defer", .@"errdefer", .@"comptime" => {
                if (tree.firstToken(node) < first and first <= tree.lastToken(node)) return false;
            },
            else => {},
        }
    }
    return in_block;
}

/// Whether evaluating the assignment target twice is harmless: a path of
/// names, fields, dereferences and literal or name indexes, with no call.
fn pureLocation(context: ActionRun, tree: *const Ast, node: Ast.Node.Index) bool {
    for (context.tokens[tree.firstToken(node) .. tree.lastToken(node) + 1]) |token| switch (token.tag) {
        .identifier, .period, .period_asterisk, .question_mark, .l_bracket, .r_bracket, .number_literal => {},
        else => return false,
    };
    return true;
}

fn nodeSpan(context: ActionRun, tree: *const Ast, node: Ast.Node.Index) std.zig.Token.Loc {
    return .{
        .start = context.tokens[tree.firstToken(node)].loc.start,
        .end = context.tokens[tree.lastToken(node)].loc.end,
    };
}

fn nodeSource(context: ActionRun, tree: *const Ast, node: Ast.Node.Index) []const u8 {
    const span = nodeSpan(context, tree, node);
    return context.source[span.start..span.end];
}

test "fallible and optional expressions get Zig recovery actions" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() error{Missing, Invalid}!u8 { return 1; } fn maybe() ?u8 { return 1; } fn run() !void { _ = load(); maybe(); }";
    const load_start = std.mem.findLast(u8, source, "load()") orelse unreachable;
    const fallible = try registry.actions(arena.allocator(), source, .{ .start = load_start, .end = load_start + 4 }, &.{});
    try std.testing.expectEqual(@as(usize, 3), fallible.len);
    const maybe_start = std.mem.findLast(u8, source, "maybe()") orelse unreachable;
    const optional = try registry.actions(arena.allocator(), source, .{ .start = maybe_start, .end = maybe_start + 5 }, &.{});
    try std.testing.expect(optional.len >= 2);
    try std.testing.expectEqualStrings("maybe().?", optional[0].edits[0].replacement);
}

test "fallible calls embedded in larger expressions get no rewrite" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() error{Missing}!u8 { return 1; } fn run() !void { const x = load() + 1; _ = x; }";
    const load_start = std.mem.findLast(u8, source, "load()") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = load_start, .end = load_start + 4 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "ambiguous same-named functions get no error rewrite" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const A = struct { fn get() !u8 { return 1; } }; " ++
        "const B = struct { fn get() u8 { return 2; } fn run() void { _ = get(); } };";
    const get_start = std.mem.findLast(u8, source, "get()") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = get_start, .end = get_start + 3 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "error switch captures avoid shadowing an existing err binding" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() error{Missing}!u8 { return 1; } fn run() void { const err = 1; _ = err; _ = load(); }";
    const load_start = std.mem.findLast(u8, source, "load()") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = load_start, .end = load_start + 4 }, &.{});
    var found_switch = false;
    for (actions) |action| {
        const replacement = action.edits[0].replacement;
        if (std.mem.find(u8, replacement, "switch") == null) continue;
        found_switch = true;
        try std.testing.expect(std.mem.find(u8, replacement, "catch |err2| switch (err2)") != null);
    }
    try std.testing.expect(found_switch);
}

test "merged error sets get no exhaustive switch" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() (error{A} || error{B})!u8 { return 1; } fn run() !void { _ = load(); }";
    const load_start = std.mem.findLast(u8, source, "load()") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = load_start, .end = load_start + 4 }, &.{});
    try std.testing.expect(actions.len >= 1);
    for (actions) |action| {
        try std.testing.expect(std.mem.find(u8, action.edits[0].replacement, "switch") == null);
    }
}

test "pointer casts are composed in Zig order" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run(source: *const u8) void { const target: *align(8) u16 = source; _ = target; }";
    const start = std.mem.findPos(u8, source, 20, "source;") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expect(std.mem.find(u8, actions[0].edits[0].replacement, "@constCast(@ptrCast(@alignCast(source)))") != null);
    try std.testing.expect(std.mem.find(u8, actions[0].title, "@constCast") != null);
}

test "type paths containing 'const' letters get no spurious @constCast" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run(source: *constants.Config) void { const target: *config.Config = source; _ = target; }";
    const start = std.mem.findPos(u8, source, 30, "source;") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("@ptrCast(source)", actions[0].edits[0].replacement);
    try std.testing.expectEqualStrings("Insert the required pointer casts", actions[0].title);
}

test "compound assertions split into one assert per condition" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: bool, b: bool, c: bool) void {\n    std.debug.assert(a and b and c);\n}";
    const start = std.mem.find(u8, source, "assert") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings(
        "std.debug.assert(a);\n    std.debug.assert(b);\n    std.debug.assert(c);",
        actions[0].edits[0].replacement,
    );
}

test "assertions with a comment inside an operand are not split" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: bool, b: bool) void {\n    assert(a // invariant\n    and b);\n}";
    const start = std.mem.find(u8, source, "assert") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "assertions with a comment between and and an operand are not split" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: bool, b: bool) void {\n    assert(a and // invariant\n    b);\n}";
    const start = std.mem.find(u8, source, "assert") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "assertions mixing or at the top level stay together" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run(a: bool, b: bool, c: bool) void {\n    assert(a and b or c);\n}";
    const start = std.mem.find(u8, source, "assert") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "orelse unreachable becomes a .? unwrap" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const call_source: [:0]const u8 = "fn get(map: Map, key: u32) u8 { return map.get(key) orelse unreachable; }";
    const call_start = std.mem.find(u8, call_source, "unreachable") orelse unreachable;
    const call = try registry.actions(arena.allocator(), call_source, .{ .start = call_start, .end = call_start + 11 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), call.len);
    try std.testing.expectEqualStrings("map.get(key).?", call[0].edits[0].replacement);
    try std.testing.expectEqual(std.mem.find(u8, call_source, "map.get").?, call[0].edits[0].span.start);

    const binding_source: [:0]const u8 = "fn run(maybe: ?u8) u8 { const value = maybe orelse unreachable; return value; }";
    const binding_start = std.mem.find(u8, binding_source, "unreachable") orelse unreachable;
    const binding = try registry.actions(arena.allocator(), binding_source, .{ .start = binding_start, .end = binding_start + 11 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), binding.len);
    try std.testing.expectEqualStrings("maybe.?", binding[0].edits[0].replacement);
}

test "orelse unreachable with a comment or a larger operand is not rewritten" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const comment_source: [:0]const u8 =
        "fn run(maybe: ?u8) u8 { return maybe orelse // proven non-null\n    unreachable; }";
    const comment_start = std.mem.find(u8, comment_source, "unreachable") orelse unreachable;
    const commented = try registry.actions(arena.allocator(), comment_source, .{ .start = comment_start, .end = comment_start + 11 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), commented.len);

    const operand_source: [:0]const u8 =
        "fn run(flag: bool, maybe: ?bool) bool { return flag == maybe orelse unreachable; }";
    const operand_start = std.mem.find(u8, operand_source, "unreachable") orelse unreachable;
    const operand = try registry.actions(arena.allocator(), operand_source, .{ .start = operand_start, .end = operand_start + 11 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), operand.len);
}

/// The actions offered with the cursor on the first `operator` after `after`.
fn actionsAtOperator(allocator: std.mem.Allocator, source: [:0]const u8, after: []const u8, operator: []const u8) ![]const action_context.Candidate {
    const registry = @import("registry.zig");
    const start = std.mem.findPos(u8, source, std.mem.find(u8, source, after).?, operator).?;
    return registry.actions(allocator, source, .{ .start = start, .end = start }, &.{});
}

fn applied(allocator: std.mem.Allocator, source: [:0]const u8, edits: []const analysis.Edit) ![]const u8 {
    return @import("../syntax/text_edits.zig").apply(allocator, source, edits);
}

test "integer arithmetic offers wrapping, saturating and checked spellings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn total(a: u32, b: u32) !u32 {
        \\    return a + b;
        \\}
    ;
    const actions = try actionsAtOperator(arena.allocator(), source, "return", "+");
    try std.testing.expectEqual(@as(usize, 3), actions.len);
    try std.testing.expectEqualStrings("Use wrapping arithmetic '+%'", actions[0].title);
    try std.testing.expectEqualStrings("+%", actions[0].edits[0].replacement);
    try std.testing.expectEqualStrings("+|", actions[1].edits[0].replacement);
    try std.testing.expectEqualStrings("Use checked arithmetic '@addWithOverflow'", actions[2].title);
    try std.testing.expectEqualStrings(
        \\fn total(a: u32, b: u32) !u32 {
        \\    const sum = @addWithOverflow(a, b);
        \\    if (sum[1] != 0) return error.Overflow;
        \\    return sum[0];
        \\}
    , try applied(arena.allocator(), source, actions[2].edits));
}

test "compound assignments rewrite the target once more for the checked form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn scale(values: []const u16, factor: u16) !u16 {
        \\    var product: u16 = 1;
        \\    for (values) |value| {
        \\        product *= value * factor;
        \\    }
        \\    return product;
        \\}
    ;
    const actions = try actionsAtOperator(arena.allocator(), source, "product *=", "*=");
    try std.testing.expectEqual(@as(usize, 3), actions.len);
    try std.testing.expectEqualStrings("*%=", actions[0].edits[0].replacement);
    try std.testing.expectEqualStrings("*|=", actions[1].edits[0].replacement);
    try std.testing.expectEqualStrings(
        \\fn scale(values: []const u16, factor: u16) !u16 {
        \\    var product: u16 = 1;
        \\    for (values) |value| {
        \\        const product2 = @mulWithOverflow(product, value * factor);
        \\        if (product2[1] != 0) return error.Overflow;
        \\        product = product2[0];
        \\    }
        \\    return product;
        \\}
    , try applied(arena.allocator(), source, actions[2].edits));
}

test "shifts only offer the saturating shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn widen(bits: u32, shift: u5) !u32 { return bits << shift; }";
    const actions = try actionsAtOperator(arena.allocator(), source, "bits <<", "<<");
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("<<|", actions[0].edits[0].replacement);
}

test "checked arithmetic needs an error return and a whole-statement value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const infallible = try actionsAtOperator(allocator, "fn f(a: u8) u8 {\n    return a + 1;\n}", "a +", "+");
    try std.testing.expectEqual(@as(usize, 2), infallible.len);
    const closed_set = try actionsAtOperator(allocator, "fn f(a: u8) error{Empty}!u8 {\n    return a + 1;\n}", "a +", "+");
    try std.testing.expectEqual(@as(usize, 2), closed_set.len);
    const listed = try actionsAtOperator(allocator, "fn f(a: u8) error{Overflow}!u8 {\n    return a + 1;\n}", "a +", "+");
    try std.testing.expectEqual(@as(usize, 3), listed.len);
    const any = try actionsAtOperator(allocator, "fn f(a: u8) anyerror!u8 {\n    return a + 1;\n}", "a +", "+");
    try std.testing.expectEqual(@as(usize, 3), any.len);
    const embedded = try actionsAtOperator(allocator, "fn f(a: u8, b: u8) !bool {\n    return a + 1 > b;\n}", "a +", "+");
    try std.testing.expectEqual(@as(usize, 2), embedded.len);
    const deferred = try actionsAtOperator(allocator, "fn f(a: u8) !void {\n    defer {\n        const b = a + 1;\n        _ = b;\n    }\n}", "a +", "+");
    try std.testing.expectEqual(@as(usize, 2), deferred.len);
    const unbraced = try actionsAtOperator(allocator, "fn f(a: u8, c: bool) !u8 {\n    if (c) return a + 1;\n    return a;\n}", "a +", "+");
    try std.testing.expectEqual(@as(usize, 2), unbraced.len);
    const shared_line = try actionsAtOperator(allocator, "fn f(a: u8) !u8 { return a + 1; }", "a +", "+");
    try std.testing.expectEqual(@as(usize, 2), shared_line.len);
    const call_target = try actionsAtOperator(allocator, "fn f(a: []u8, i: usize) !void {\n    a[slot(i)] += 1;\n}", "+=", "+=");
    try std.testing.expectEqual(@as(usize, 0), call_target.len);
    const in_test = try actionsAtOperator(allocator, "test \"x\" {\n    const a: u8 = 1;\n    const b = a - 1;\n    _ = b;\n}", "a -", "-");
    try std.testing.expectEqual(@as(usize, 3), in_test.len);
    try std.testing.expectEqualStrings(
        "test \"x\" {\n    const a: u8 = 1;\n    const difference = @subWithOverflow(a, 1);\n" ++
            "    if (difference[1] != 0) return error.Overflow;\n    const b = difference[0];\n    _ = b;\n}",
        try applied(allocator, "test \"x\" {\n    const a: u8 = 1;\n    const b = a - 1;\n    _ = b;\n}", in_test[2].edits),
    );
}

test "arithmetic rewrites need a proven fixed-width integer operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { source: [:0]const u8, anchor: []const u8 }{
        .{ .source = "fn f(a: f32, b: f32) f32 { return a + b; }", .anchor = "a +" },
        .{ .source = "fn f(p: [*]u8, n: usize) [*]u8 { return p + n; }", .anchor = "p +" },
        .{ .source = "fn f(a: anytype) @TypeOf(a) { return a + 1; }", .anchor = "a +" },
        .{ .source = "fn f() u8 { return 1 + 2; }", .anchor = "1 +" },
        .{ .source = "fn f(x: u32) u32 { return 1 << x; }", .anchor = "1 <<" },
        .{ .source = "fn g(m: f32) f32 { const n: f32 = m; return n + 1; } fn f(n: usize) usize { return n; }", .anchor = "n +" },
        .{ .source = "fn f(x: u8) void { if (x > 0) { const y: u8 = 1; _ = y; } else { const y: f32 = 1; _ = y + 1; } }", .anchor = "y +" },
        .{ .source = "fn f(o: ?u8) u8 { if (o) |y| return y + 1; return 0; } const y: u8 = 0;", .anchor = "y +" },
        .{ .source = "fn f(xs: []const f32) f32 { for (xs) |x| return x * 2; return 0; }", .anchor = "x *" },
    };
    for (cases) |case| {
        const actions = try actionsAtOperator(allocator, case.source, case.anchor, case.anchor[case.anchor.len - 1 ..]);
        errdefer std.debug.print("offered for: {s}\n", .{case.source});
        try std.testing.expectEqual(@as(usize, 0), actions.len);
    }
}

test "lengths, range indexes, casts and integer fields are proven integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const last = try actionsAtOperator(allocator, "fn f(items: []const u8) usize { return items.len - 1; }", "len", "-");
    try std.testing.expectEqualStrings("-%", last[0].edits[0].replacement);
    const index = try actionsAtOperator(allocator, "fn f(items: []const u8) void { for (items, 0..) |_, i| { _ = i + 1; } }", "i +", "+");
    try std.testing.expectEqual(@as(usize, 2), index.len);
    const cast = try actionsAtOperator(allocator, "fn f(x: anytype) u16 { return @as(u16, x) * 3; }", "@as", "*");
    try std.testing.expectEqual(@as(usize, 2), cast.len);
    const literal = try actionsAtOperator(allocator, "fn f(x: i64) i64 { return 1 - x; }", "1 -", "-");
    try std.testing.expectEqual(@as(usize, 2), literal.len);
    const field = try actionsAtOperator(
        allocator,
        "const Counter = struct { count: u32, const Self = @This(); fn bump(self: *Self) void { self.count += 1; } };",
        "self.count",
        "+=",
    );
    try std.testing.expectEqual(@as(usize, 2), field.len);
    try std.testing.expectEqualStrings("+%=", field[0].edits[0].replacement);
    const foreign = try actionsAtOperator(
        allocator,
        "const Counter = struct { count: u32, fn bump(other: *Other) void { other.count += 1; } }; const Other = struct { count: f32 };",
        "other.count",
        "+=",
    );
    try std.testing.expectEqual(@as(usize, 0), foreign.len);
}
