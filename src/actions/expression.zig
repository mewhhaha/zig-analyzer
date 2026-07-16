const std = @import("std");
const action_context = @import("context.zig");

const ActionRun = action_context.ActionRun;

pub fn run(context: ActionRun) !void {
    try addErrorAndOptionalActions(context);
    try addPointerCastAction(context);
    try addSplitCompoundAssertion(context);
    try addOrelseUnreachableUnwrap(context);
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
                try std.fmt.allocPrint(context.allocator, "try {s}", .{source_expression}),
                false,
            );
        }
        // A discarded |err| capture is a compile error in Zig 0.16, so the catch stays captureless.
        try context.oneEdit(
            "Handle the error with catch",
            .refactor_rewrite,
            expression.span,
            try std.fmt.allocPrint(context.allocator, "{s} catch @panic(\"TODO\")", .{source_expression}),
            false,
        );
        if (return_kind.errors.len != 0 and !return_kind.merged_error_sets) {
            try context.oneEdit(
                "Handle every error with a switch",
                .refactor_rewrite,
                expression.span,
                try errorSwitchReplacement(context, source_expression, return_kind.errors, try errorCaptureName(context)),
                false,
            );
        }
    }

    if (return_kind.optional) {
        try context.oneEdit(
            "Unwrap the optional or stop",
            .refactor_rewrite,
            expression.span,
            try std.fmt.allocPrint(context.allocator, "{s}.?", .{source_expression}),
            false,
        );
        if (function != null and function.?.returnsVoid(context)) {
            try context.oneEdit(
                "Return when the optional is null",
                .refactor_rewrite,
                expression.span,
                try std.fmt.allocPrint(context.allocator, "({s} orelse return)", .{source_expression}),
                false,
            );
        }
        if (standaloneStatement(context, expression.span)) |statement_span| {
            const indentation = context.lineIndentation(statement_span.start);
            try context.oneEdit(
                "Capture the optional payload",
                .refactor_rewrite,
                statement_span,
                try std.fmt.allocPrint(
                    context.allocator,
                    "if ({s}) |value| {{\n{s}    _ = value;\n{s}}}",
                    .{ source_expression, indentation, indentation },
                ),
                false,
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
        const candidate = try std.fmt.allocPrint(context.allocator, "err{d}", .{suffix});
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
    try writer.writer.writeAll("}");
    return try writer.toOwnedSlice();
}

fn standaloneStatement(context: ActionRun, expression_span: std.zig.Token.Loc) ?std.zig.Token.Loc {
    var end = expression_span.end;
    while (end < context.source.len and (context.source[end] == ' ' or context.source[end] == '\t')) : (end += 1) {}
    if (end >= context.source.len or context.source[end] != ';') return null;
    const line_start = (std.mem.lastIndexOfScalar(u8, context.source[0..expression_span.start], '\n') orelse 0) +
        @intFromBool(std.mem.lastIndexOfScalar(u8, context.source[0..expression_span.start], '\n') != null);
    if (std.mem.trim(u8, context.source[line_start..expression_span.start], " \t").len != 0) return null;
    return .{ .start = expression_span.start, .end = end + 1 };
}

fn addPointerCastAction(context: ActionRun) !void {
    const expression = selectedExpression(context) orelse return;
    if (expression.call_name != null) return;
    const assignment = typedAssignmentBefore(context, expression.token_index) orelse return;
    const source_type = declaredType(context, context.tokenText(expression.token_index), expression.token_index) orelse return;
    if (std.mem.indexOfScalar(u8, source_type, '*') == null or std.mem.indexOfScalar(u8, assignment.target_type, '*') == null) return;
    const needs_alignment = std.mem.indexOf(u8, assignment.target_type, "align(") != null and
        std.mem.indexOf(u8, source_type, "align(") == null;
    const needs_const_removal = try constQualified(context, source_type) and
        !try constQualified(context, assignment.target_type);
    const needs_pointer_cast = !std.mem.eql(u8, pointeeName(source_type), pointeeName(assignment.target_type));
    if (!needs_alignment and !needs_const_removal and !needs_pointer_cast) return;

    var replacement = context.source[expression.span.start..expression.span.end];
    if (needs_alignment) replacement = try std.fmt.allocPrint(context.allocator, "@alignCast({s})", .{replacement});
    if (needs_pointer_cast) replacement = try std.fmt.allocPrint(context.allocator, "@ptrCast({s})", .{replacement});
    if (needs_const_removal) replacement = try std.fmt.allocPrint(context.allocator, "@constCast({s})", .{replacement});
    const title = if (needs_const_removal)
        "Insert pointer casts including @constCast (removes const — verify writes are safe)"
    else
        "Insert the required pointer casts";
    try context.oneEdit(title, .quickfix, expression.span, replacement, false);
}

fn constQualified(context: ActionRun, type_text: []const u8) !bool {
    const buffer = try context.allocator.dupeZ(u8, type_text);
    var tokenizer = std.zig.Tokenizer.init(buffer);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return false;
        if (token.tag == .keyword_const) return true;
    }
}

fn pointeeName(pointer_type: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, pointer_type, " \t\r\n");
    const separator = std.mem.lastIndexOfAny(u8, trimmed, " \t") orelse return trimmed;
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
        if (std.mem.indexOf(u8, argument_text, "//") != null) continue;
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
            false,
        );
    }
}

fn topLevelAndOperands(context: ActionRun, start: usize, end: usize) !?[]const []const u8 {
    if (start >= end) return null;
    var operands: std.ArrayList([]const u8) = .empty;
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
            try std.fmt.allocPrint(context.allocator, "{s}.?", .{
                context.source[span.start..context.tokens[orelse_index - 1].loc.end],
            }),
            false,
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
        if (std.mem.indexOf(u8, gap, "//") != null) return true;
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

test "fallible and optional expressions get Zig recovery actions" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() error{Missing, Invalid}!u8 { return 1; } fn maybe() ?u8 { return 1; } fn run() !void { _ = load(); maybe(); }";
    const load_start = std.mem.lastIndexOf(u8, source, "load()") orelse unreachable;
    const fallible = try registry.actions(arena.allocator(), source, .{ .start = load_start, .end = load_start + 4 }, &.{});
    try std.testing.expectEqual(@as(usize, 3), fallible.len);
    const maybe_start = std.mem.lastIndexOf(u8, source, "maybe()") orelse unreachable;
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
    const load_start = std.mem.lastIndexOf(u8, source, "load()") orelse unreachable;
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
    const get_start = std.mem.lastIndexOf(u8, source, "get()") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = get_start, .end = get_start + 3 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "error switch captures avoid shadowing an existing err binding" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() error{Missing}!u8 { return 1; } fn run() void { const err = 1; _ = err; _ = load(); }";
    const load_start = std.mem.lastIndexOf(u8, source, "load()") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = load_start, .end = load_start + 4 }, &.{});
    var found_switch = false;
    for (actions) |action| {
        const replacement = action.edits[0].replacement;
        if (std.mem.indexOf(u8, replacement, "switch") == null) continue;
        found_switch = true;
        try std.testing.expect(std.mem.indexOf(u8, replacement, "catch |err2| switch (err2)") != null);
    }
    try std.testing.expect(found_switch);
}

test "merged error sets get no exhaustive switch" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() (error{A} || error{B})!u8 { return 1; } fn run() !void { _ = load(); }";
    const load_start = std.mem.lastIndexOf(u8, source, "load()") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = load_start, .end = load_start + 4 }, &.{});
    try std.testing.expect(actions.len >= 1);
    for (actions) |action| {
        try std.testing.expect(std.mem.indexOf(u8, action.edits[0].replacement, "switch") == null);
    }
}

test "pointer casts are composed in Zig order" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run(source: *const u8) void { const target: *align(8) u16 = source; _ = target; }";
    const start = std.mem.indexOfPos(u8, source, 20, "source;") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].edits[0].replacement, "@constCast(@ptrCast(@alignCast(source)))") != null);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].title, "@constCast") != null);
}

test "type paths containing 'const' letters get no spurious @constCast" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run(source: *constants.Config) void { const target: *config.Config = source; _ = target; }";
    const start = std.mem.indexOfPos(u8, source, 30, "source;") orelse unreachable;
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
    const start = std.mem.indexOf(u8, source, "assert") orelse unreachable;
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
    const start = std.mem.indexOf(u8, source, "assert") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "assertions with a comment between and and an operand are not split" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: bool, b: bool) void {\n    assert(a and // invariant\n    b);\n}";
    const start = std.mem.indexOf(u8, source, "assert") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "assertions mixing or at the top level stay together" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run(a: bool, b: bool, c: bool) void {\n    assert(a and b or c);\n}";
    const start = std.mem.indexOf(u8, source, "assert") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "orelse unreachable becomes a .? unwrap" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const call_source: [:0]const u8 = "fn get(map: Map, key: u32) u8 { return map.get(key) orelse unreachable; }";
    const call_start = std.mem.indexOf(u8, call_source, "unreachable") orelse unreachable;
    const call = try registry.actions(arena.allocator(), call_source, .{ .start = call_start, .end = call_start + 11 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), call.len);
    try std.testing.expectEqualStrings("map.get(key).?", call[0].edits[0].replacement);
    try std.testing.expectEqual(std.mem.indexOf(u8, call_source, "map.get").?, call[0].edits[0].span.start);

    const binding_source: [:0]const u8 = "fn run(maybe: ?u8) u8 { const value = maybe orelse unreachable; return value; }";
    const binding_start = std.mem.indexOf(u8, binding_source, "unreachable") orelse unreachable;
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
    const comment_start = std.mem.indexOf(u8, comment_source, "unreachable") orelse unreachable;
    const commented = try registry.actions(arena.allocator(), comment_source, .{ .start = comment_start, .end = comment_start + 11 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), commented.len);

    const operand_source: [:0]const u8 =
        "fn run(flag: bool, maybe: ?bool) bool { return flag == maybe orelse unreachable; }";
    const operand_start = std.mem.indexOf(u8, operand_source, "unreachable") orelse unreachable;
    const operand = try registry.actions(arena.allocator(), operand_source, .{ .start = operand_start, .end = operand_start + 11 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), operand.len);
}
