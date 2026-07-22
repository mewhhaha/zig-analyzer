const std = @import("std");
const analysis = @import("../analysis.zig");
const action_context = @import("context.zig");

const ActionRun = action_context.ActionRun;

pub fn run(context: ActionRun) !void {
    try addMutableCapture(context);
    try addTaggedUnionSwitch(context);
    try addFormatRepair(context);
    try addFormatArgumentRepair(context);
    try addInlineElseRefactor(context);
    try addMaterializedType(context);
    try addReflectedDeclaration(context);
}

fn addFormatArgumentRepair(context: ActionRun) !void {
    for (context.tokens, 0..) |token, string_index| {
        if (token.tag != .string_literal or !context.selected(token.loc) or string_index < 2 or
            context.tokens[string_index - 1].tag != .l_paren or context.tokens[string_index - 2].tag != .identifier) continue;
        const callee = context.tokenText(string_index - 2);
        if (!std.mem.eql(u8, callee, "print") and !std.mem.eql(u8, callee, "format") and
            !std.mem.eql(u8, callee, "allocPrint") and !std.mem.eql(u8, callee, "bufPrint")) continue;
        if (string_index + 3 >= context.tokens.len or context.tokens[string_index + 1].tag != .comma or
            context.tokens[string_index + 2].tag != .period or context.tokens[string_index + 3].tag != .l_brace) continue;
        const tuple_end = context.matchingToken(string_index + 3, .l_brace, .r_brace) orelse continue;
        const arguments = (try simpleTupleArguments(context, string_index + 4, tuple_end)) orelse continue;
        const format = context.tokenText(string_index);
        const placeholder_count = formatPlaceholderCount(format);
        if (placeholder_count == arguments.len or placeholder_count > 16) continue;

        var writer: std.Io.Writer.Allocating = .init(context.allocator);
        defer writer.deinit();
        if (placeholder_count < arguments.len) {
            if (format.len < 2 or format[format.len - 1] != '"') continue;
            try writer.writer.writeAll(format[0 .. format.len - 1]);
            for (placeholder_count..arguments.len) |_| try writer.writer.writeAll(" {any}");
            try writer.writer.writeAll("\"");
            try context.oneEdit(
                "Add missing format placeholders",
                .refactor_rewrite,
                token.loc,
                try writer.toOwnedSlice(),
                .{},
            );
            continue;
        }
        try writer.writer.writeAll(".{");
        for (0..placeholder_count) |index| {
            if (index != 0) try writer.writer.writeAll(", ");
            if (index < arguments.len) {
                const argument = arguments[index];
                try writer.writer.writeAll(context.source[argument.start..argument.end]);
            } else {
                // @panic("TODO") is a compiling noreturn tuple filler; undefined is not formattable.
                try writer.writer.writeAll("@panic(\"TODO\")");
            }
        }
        try writer.writer.writeAll("}");
        try context.oneEdit(
            "Add missing format arguments",
            .refactor_rewrite,
            .{
                .start = context.tokens[string_index + 2].loc.start,
                .end = context.tokens[tuple_end].loc.end,
            },
            try writer.toOwnedSlice(),
            .{},
        );
    }
}

fn simpleTupleArguments(context: ActionRun, start: usize, end: usize) !?[]const std.zig.Token.Loc {
    var arguments: std.ArrayList(std.zig.Token.Loc) = .empty;
    errdefer arguments.deinit(context.allocator);
    if (start == end) return try arguments.toOwnedSlice(context.allocator);
    var argument_start = start;
    var depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            if (argument_start == index or index != argument_start + 1) return null;
            try arguments.append(context.allocator, .{
                .start = context.tokens[argument_start].loc.start,
                .end = context.tokens[index - 1].loc.end,
            });
            argument_start = index + 1;
        },
        else => {},
    };
    if (argument_start >= end or end != argument_start + 1) return null;
    try arguments.append(context.allocator, .{
        .start = context.tokens[argument_start].loc.start,
        .end = context.tokens[end - 1].loc.end,
    });
    return try arguments.toOwnedSlice(context.allocator);
}

fn formatPlaceholderCount(format: []const u8) usize {
    var count: usize = 0;
    var index: usize = 1;
    while (index + 1 < format.len) : (index += 1) {
        if (format[index] != '{') continue;
        if (index + 1 < format.len and format[index + 1] == '{') {
            index += 1;
            continue;
        }
        const closing = std.mem.indexOfScalarPos(u8, format, index + 1, '}') orelse return count;
        count += 1;
        index = closing;
    }
    return count;
}

fn loneEmptyPlaceholder(format: []const u8) ?usize {
    var empty_placeholder: ?usize = null;
    var placeholder_count: usize = 0;
    var index: usize = 1;
    while (index + 1 < format.len) : (index += 1) {
        if (format[index] != '{') continue;
        if (format[index + 1] == '{') {
            index += 1;
            continue;
        }
        const closing = std.mem.indexOfScalarPos(u8, format, index + 1, '}') orelse break;
        placeholder_count += 1;
        if (closing == index + 1) empty_placeholder = index;
        index = closing;
    }
    if (placeholder_count != 1) return null;
    return empty_placeholder;
}

fn addMutableCapture(context: ActionRun) !void {
    for (context.tokens, 0..) |token, capture_index| {
        if (token.tag != .identifier or capture_index == 0 or capture_index + 1 >= context.tokens.len or
            context.tokens[capture_index - 1].tag != .pipe or context.tokens[capture_index + 1].tag != .pipe) continue;
        const body_start = capture_index + 2;
        if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (!captureSourceMutable(context, capture_index)) continue;
        const mutations = (try captureMutations(context, context.tokenText(capture_index), body_start + 1, body_end)) orelse continue;
        if (mutations.len == 0) continue;
        var selected = context.selected(token.loc);
        for (mutations) |mutation| {
            if (context.selected(context.tokens[mutation].loc)) selected = true;
        }
        if (!selected) continue;
        const edits = try context.allocator.alloc(analysis.Edit, mutations.len + 1);
        edits[0] = .{ .span = .{ .start = token.loc.start, .end = token.loc.start }, .replacement = "*" };
        for (mutations, edits[1..]) |mutation, *edit| {
            const mutated = context.tokens[mutation];
            edit.* = .{ .span = .{ .start = mutated.loc.end, .end = mutated.loc.end }, .replacement = ".*" };
        }
        try context.add(
            try std.fmt.allocPrint(context.allocator, "Capture '{s}' by pointer", .{context.tokenText(capture_index)}),
            .quickfix,
            edits,
            .{},
        );
    }
}

fn captureSourceMutable(context: ActionRun, capture_index: usize) bool {
    var condition_end = capture_index;
    while (condition_end > 0 and context.tokens[condition_end].tag != .r_paren) : (condition_end -= 1) {}
    if (context.tokens[condition_end].tag != .r_paren) return false;
    var condition_start = condition_end;
    var depth: usize = 0;
    while (condition_start > 0) {
        condition_start -= 1;
        if (context.tokens[condition_start].tag == .r_paren) depth += 1;
        if (context.tokens[condition_start].tag != .l_paren) continue;
        if (depth != 0) {
            depth -= 1;
            continue;
        }
        break;
    }
    if (context.tokens[condition_start].tag != .l_paren or condition_start + 1 >= condition_end) return false;
    if (condition_start == 0) return false;
    const supports_pointer_capture = switch (context.tokens[condition_start - 1].tag) {
        .keyword_if, .keyword_while, .keyword_switch => true,
        else => false,
    };
    if (!supports_pointer_capture) return false;
    const name_index = condition_start + 1;
    if (context.tokens[name_index].tag != .identifier) return false;
    if (name_index + 3 == condition_end and context.tokens[name_index + 1].tag == .period and
        context.tokens[name_index + 2].tag == .asterisk)
    {
        return mutablePointerBinding(context, context.tokenText(name_index), condition_start);
    }
    if (name_index + 1 != condition_end) return false;
    return mutableLocalBinding(context, context.tokenText(name_index), condition_start);
}

fn mutableLocalBinding(context: ActionRun, name: []const u8, before: usize) bool {
    const function = action_context.containingFunction(context, before);
    const lower = if (function) |enclosing| enclosing.body_start else 0;
    var index = before;
    while (index > lower) {
        index -= 1;
        if (context.tokenIs(index, name) and index > 0 and context.tokens[index - 1].tag == .keyword_var) return true;
    }
    return false;
}

fn mutablePointerBinding(context: ActionRun, name: []const u8, before: usize) bool {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, name) or index + 2 >= before or context.tokens[index + 1].tag != .colon) continue;
        const type_start = context.tokens[index + 2].loc.start;
        var type_end_index = index + 2;
        while (type_end_index < before and context.tokens[type_end_index].tag != .comma and
            context.tokens[type_end_index].tag != .r_paren and context.tokens[type_end_index].tag != .equal) : (type_end_index += 1)
        {}
        const type_end = context.tokens[type_end_index].loc.start;
        const binding_type = std.mem.trim(u8, context.source[type_start..type_end], " \t\r\n");
        return std.mem.startsWith(u8, binding_type, "*") and !std.mem.startsWith(u8, binding_type, "*const");
    }
    return false;
}

fn captureMutations(context: ActionRun, name: []const u8, start: usize, end: usize) !?[]const usize {
    var mutations: std.ArrayList(usize) = .empty;
    errdefer mutations.deinit(context.allocator);
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index + 1 >= end) continue;
        if (isAssignment(context.tokens[index + 1].tag)) {
            try mutations.append(context.allocator, index);
            continue;
        }
        // Field access auto-dereferences through the pointer capture; any other
        // use of the name would change type once it becomes a pointer.
        if (context.tokens[index + 1].tag != .period) return null;
    }
    return try mutations.toOwnedSlice(context.allocator);
}

fn isAssignment(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal,
        .plus_equal,
        .minus_equal,
        .asterisk_equal,
        .asterisk_percent_equal,
        .asterisk_pipe_equal,
        .slash_equal,
        .percent_equal,
        .pipe_equal,
        .ampersand_equal,
        .caret_equal,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_right_equal,
        => true,
        else => false,
    };
}

fn addTaggedUnionSwitch(context: ActionRun) !void {
    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 7 >= context.tokens.len or context.tokens[if_index + 1].tag != .l_paren or
            context.tokens[if_index + 2].tag != .identifier or context.tokens[if_index + 3].tag != .equal_equal or
            context.tokens[if_index + 4].tag != .period or context.tokens[if_index + 5].tag != .identifier or
            context.tokens[if_index + 6].tag != .r_paren or context.tokens[if_index + 7].tag != .l_brace) continue;
        const if_span = token.loc;
        if (!context.selected(if_span) and !context.selected(context.tokens[if_index + 2].loc)) continue;
        const value_name = context.tokenText(if_index + 2);
        const tag_name = context.tokenText(if_index + 5);
        const type_name = bindingType(context, value_name, if_index) orelse continue;
        const shape = context.shapeNamed(type_name) orelse continue;
        if (shape.kind != .tagged_union or !shapeContains(shape, tag_name)) continue;
        const body_end = context.matchingToken(if_index + 7, .l_brace, .r_brace) orelse continue;
        if (body_end + 1 < context.tokens.len and context.tokens[body_end + 1].tag == .keyword_else) continue;
        const capture = try payloadCaptureName(context, if_index + 8, body_end);
        const rewritten_body = (try payloadRewrittenBody(context, value_name, tag_name, capture, if_index + 8, body_end)) orelse continue;
        const indentation = context.lineIndentation(token.loc.start);
        try context.oneEdit(
            "Use a tagged-union switch and payload capture",
            .refactor_rewrite,
            .{ .start = token.loc.start, .end = context.tokens[body_end].loc.end },
            try std.fmt.allocPrint(
                context.allocator,
                "switch ({s}) {{\n{s}    .{s} => |{s}| {{{s}}},\n{s}    else => {{}},\n{s}}}",
                .{ value_name, indentation, tag_name, capture, rewritten_body, indentation, indentation },
            ),
            .{},
        );
    }
}

fn payloadCaptureName(context: ActionRun, start: usize, end: usize) ![]const u8 {
    if (!identifierWithin(context, "payload", start, end)) return "payload";
    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(context.allocator, "payload{d}", .{suffix});
        if (!identifierWithin(context, candidate, start, end)) return candidate;
    }
}

fn identifierWithin(context: ActionRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

fn payloadRewrittenBody(
    context: ActionRun,
    value_name: []const u8,
    tag_name: []const u8,
    capture: []const u8,
    start: usize,
    end: usize,
) !?[]const u8 {
    var writer: std.Io.Writer.Allocating = .init(context.allocator);
    defer writer.deinit();
    var cursor = context.tokens[start - 1].loc.end;
    var replaced = false;
    var index = start;
    while (index < end) : (index += 1) {
        if (context.tokens[index].tag != .identifier or !context.tokenIs(index, value_name)) continue;
        if (context.tokens[index - 1].tag == .period) continue;
        if (index + 2 >= end or context.tokens[index + 1].tag != .period or
            context.tokens[index + 2].tag != .identifier or !context.tokenIs(index + 2, tag_name)) continue;
        // A by-value capture is immutable and a fresh copy: assigning into it does
        // not compile, and taking its address would divert writes from the union.
        if (assignsThroughPostfixChain(context, index + 3, end)) return null;
        if (addressedThroughParens(context, index)) return null;
        try writer.writer.writeAll(context.source[cursor..context.tokens[index].loc.start]);
        try writer.writer.writeAll(capture);
        cursor = context.tokens[index + 2].loc.end;
        index += 2;
        replaced = true;
    }
    if (!replaced) return null;
    try writer.writer.writeAll(context.source[cursor..context.tokens[end].loc.start]);
    return try writer.toOwnedSlice();
}

fn assignsThroughPostfixChain(context: ActionRun, start: usize, end: usize) bool {
    var index = start;
    while (index < end) {
        switch (context.tokens[index].tag) {
            .period => {
                if (index + 1 >= end) return false;
                switch (context.tokens[index + 1].tag) {
                    // '.field' and the '.?' unwrap both continue the assignable chain.
                    .identifier, .question_mark => index += 2,
                    else => return false,
                }
            },
            .period_asterisk => index += 1,
            .l_bracket => index = (context.matchingToken(index, .l_bracket, .r_bracket) orelse return false) + 1,
            else => return isAssignment(context.tokens[index].tag),
        }
    }
    return false;
}

fn addressedThroughParens(context: ActionRun, value_index: usize) bool {
    var index = value_index;
    while (index > 0 and context.tokens[index - 1].tag == .l_paren) index -= 1;
    return index > 0 and context.tokens[index - 1].tag == .ampersand;
}

fn bindingType(context: ActionRun, name: []const u8, before: usize) ?[]const u8 {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, name) or index + 2 >= before or context.tokens[index + 1].tag != .colon or
            context.tokens[index + 2].tag != .identifier) continue;
        return context.tokenText(index + 2);
    }
    return null;
}

fn shapeContains(shape: analysis.ResolvedShape, name: []const u8) bool {
    for (shape.fields) |field| if (std.mem.eql(u8, field, name)) return true;
    return false;
}

fn addFormatRepair(context: ActionRun) !void {
    for (context.tokens, 0..) |token, string_index| {
        if (token.tag != .string_literal or !context.selected(token.loc) or string_index < 2 or
            context.tokens[string_index - 1].tag != .l_paren or context.tokens[string_index - 2].tag != .identifier) continue;
        const callee = context.tokenText(string_index - 2);
        if (!std.mem.eql(u8, callee, "print") and !std.mem.eql(u8, callee, "format") and
            !std.mem.eql(u8, callee, "allocPrint") and !std.mem.eql(u8, callee, "bufPrint")) continue;
        const format = context.tokenText(string_index);
        const empty_placeholder = loneEmptyPlaceholder(format) orelse continue;
        if (string_index + 5 >= context.tokens.len or
            context.tokens[string_index + 1].tag != .comma or context.tokens[string_index + 2].tag != .period or
            context.tokens[string_index + 3].tag != .l_brace) continue;
        const argument_index = string_index + 4;
        if (context.tokens[argument_index + 1].tag != .r_brace) continue;
        const specifier = formatSpecifier(context, argument_index) orelse continue;
        const replacement = try std.fmt.allocPrint(
            context.allocator,
            "{s}{s}{s}",
            .{ format[0..empty_placeholder], specifier, format[empty_placeholder + 2 ..] },
        );
        try context.oneEdit(
            try std.fmt.allocPrint(context.allocator, "Use the '{s}' format specifier", .{specifier}),
            .quickfix,
            token.loc,
            replacement,
            .{ .preferred = true },
        );
    }
}

fn formatSpecifier(context: ActionRun, argument_index: usize) ?[]const u8 {
    const argument = context.tokens[argument_index];
    if (argument.tag == .string_literal) return "{s}";
    if (argument.tag != .identifier) return null;
    const name = context.tokenText(argument_index);
    var index = argument_index;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, name) or index + 2 >= argument_index or context.tokens[index + 1].tag != .colon) continue;
        return switch (context.tokens[index + 2].tag) {
            .question_mark => "{?}",
            .bang, .keyword_error => "{!}",
            else => null,
        };
    }
    return null;
}

fn addInlineElseRefactor(context: ActionRun) !void {
    for (context.tokens, 0..) |token, inline_index| {
        if (token.tag != .keyword_inline or inline_index + 2 >= context.tokens.len or
            context.tokens[inline_index + 1].tag != .keyword_for or !context.selected(token.loc)) continue;
        const opening = inline_index + 2;
        if (context.tokens[opening].tag != .l_paren) continue;
        const header_end = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        const type_name = reflectedTypeName(context, opening + 1, header_end) orelse continue;
        const shape = context.shapeNamed(type_name) orelse continue;
        if (shape.kind != .tagged_union) continue;
        if (uniformUnionPayloadType(context, type_name) == null) continue;
        var body_start = header_end + 1;
        while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= context.tokens.len) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        const value_name = reflectedDispatchValue(context, body_start + 1, body_end) orelse continue;
        const field_name = reflectedFieldCapture(context, header_end + 1, body_start) orelse continue;
        if (!loopBodyIsGuardedReturn(context, value_name, field_name, body_start, body_end)) continue;
        const trailing_unreachable = body_end + 2 < context.tokens.len and
            context.tokens[body_end + 1].tag == .keyword_unreachable and context.tokens[body_end + 2].tag == .semicolon;
        const at_function_end = body_end + 1 < context.tokens.len and context.tokens[body_end + 1].tag == .r_brace;
        if (!trailing_unreachable and !at_function_end) continue;
        var replacement_end = context.tokens[body_end].loc.end;
        if (trailing_unreachable) replacement_end = context.tokens[body_end + 2].loc.end;
        const indentation = context.lineIndentation(token.loc.start);
        try context.oneEdit(
            "Use an inline-else switch",
            .refactor_rewrite,
            .{ .start = token.loc.start, .end = replacement_end },
            try std.fmt.allocPrint(
                context.allocator,
                "return switch ({s}) {{\n{s}    inline else => |payload| payload,\n{s}}};",
                .{ value_name, indentation, indentation },
            ),
            .{},
        );
    }
}

fn uniformUnionPayloadType(context: ActionRun, type_name: []const u8) ?[]const u8 {
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 7 >= context.tokens.len or !context.tokenIs(index + 1, type_name) or
            context.tokens[index + 2].tag != .equal or context.tokens[index + 3].tag != .keyword_union or
            context.tokens[index + 4].tag != .l_paren) continue;
        const tag_end = context.matchingToken(index + 4, .l_paren, .r_paren) orelse continue;
        const opening = tag_end + 1;
        if (opening >= context.tokens.len or context.tokens[opening].tag != .l_brace) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        var payload_type: ?[]const u8 = null;
        var cursor = opening + 1;
        while (cursor + 2 < closing) {
            if (context.tokens[cursor].tag != .identifier or context.tokens[cursor + 1].tag != .colon) return null;
            var field_end = cursor + 2;
            while (field_end < closing and context.tokens[field_end].tag != .comma) : (field_end += 1) {}
            if (field_end != cursor + 3) return null;
            const field_type = std.mem.trim(
                u8,
                context.source[context.tokens[cursor + 2].loc.start..context.tokens[field_end - 1].loc.end],
                " \t\r\n",
            );
            if (payload_type) |expected| {
                if (!std.mem.eql(u8, expected, field_type)) return null;
            } else payload_type = field_type;
            cursor = field_end + @intFromBool(field_end < closing);
        }
        return payload_type;
    }
    return null;
}

fn reflectedTypeName(context: ActionRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .builtin and context.tokenIs(index, "@typeInfo") and index + 2 < end and
            context.tokens[index + 1].tag == .l_paren and context.tokens[index + 2].tag == .identifier) return context.tokenText(index + 2);
    }
    return null;
}

fn reflectedFieldCapture(context: ActionRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .pipe and index + 2 < end and context.tokens[index + 1].tag == .identifier and
            context.tokens[index + 2].tag == .pipe) return context.tokenText(index + 1);
    }
    return null;
}

fn reflectedDispatchValue(context: ActionRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .builtin and context.tokenIs(index, "@tagName") and index + 2 < end and
            context.tokens[index + 1].tag == .l_paren and context.tokens[index + 2].tag == .identifier) return context.tokenText(index + 2);
    }
    return null;
}

fn loopBodyIsGuardedReturn(context: ActionRun, value: []const u8, field: []const u8, body_start: usize, body_end: usize) bool {
    const tokens = context.tokens;
    var index = body_start + 1;
    if (index + 2 >= body_end or tokens[index].tag != .keyword_if or tokens[index + 1].tag != .l_paren) return false;
    index += 2;
    if (tokens[index].tag != .identifier) return false;
    var callee_end = index;
    index += 1;
    while (index + 1 < body_end and tokens[index].tag == .period and tokens[index + 1].tag == .identifier) {
        callee_end = index + 1;
        index += 2;
    }
    if (!context.tokenIs(callee_end, "eql")) return false;
    if (index + 2 >= body_end or tokens[index].tag != .l_paren) return false;
    index += 1;
    if (tokens[index].tag != .identifier or !context.tokenIs(index, "u8")) return false;
    index += 1;
    if (tokens[index].tag != .comma) return false;
    index += 1;
    var compares_field = false;
    var compares_tag = false;
    index = eqlOperandEnd(context, index, body_end, value, field, &compares_field, &compares_tag) orelse return false;
    if (index >= body_end or tokens[index].tag != .comma) return false;
    index += 1;
    index = eqlOperandEnd(context, index, body_end, value, field, &compares_field, &compares_tag) orelse return false;
    if (!compares_field or !compares_tag) return false;
    if (index + 1 >= body_end or tokens[index].tag != .r_paren or tokens[index + 1].tag != .r_paren) return false;
    index += 2;
    if (index + 10 != body_end) return false;
    return tokens[index].tag == .keyword_return and
        tokens[index + 1].tag == .builtin and context.tokenIs(index + 1, "@field") and
        tokens[index + 2].tag == .l_paren and context.tokenIs(index + 3, value) and
        tokens[index + 4].tag == .comma and context.tokenIs(index + 5, field) and
        tokens[index + 6].tag == .period and context.tokenIs(index + 7, "name") and
        tokens[index + 8].tag == .r_paren and tokens[index + 9].tag == .semicolon;
}

fn eqlOperandEnd(
    context: ActionRun,
    index: usize,
    end: usize,
    value: []const u8,
    field: []const u8,
    compares_field: *bool,
    compares_tag: *bool,
) ?usize {
    const tokens = context.tokens;
    if (index + 2 < end and tokens[index].tag == .identifier and context.tokenIs(index, field) and
        tokens[index + 1].tag == .period and tokens[index + 2].tag == .identifier and context.tokenIs(index + 2, "name"))
    {
        compares_field.* = true;
        return index + 3;
    }
    if (index + 3 < end and tokens[index].tag == .builtin and context.tokenIs(index, "@tagName") and
        tokens[index + 1].tag == .l_paren and tokens[index + 2].tag == .identifier and
        context.tokenIs(index + 2, value) and tokens[index + 3].tag == .r_paren)
    {
        compares_tag.* = true;
        return index + 4;
    }
    return null;
}

fn addMaterializedType(context: ActionRun) !void {
    for (context.tokens, 0..) |token, type_index| {
        if (token.tag != .identifier or !context.selected(token.loc)) continue;
        const shape = context.shapeNamed(context.tokenText(type_index)) orelse continue;
        if (type_index == 0 or context.tokens[type_index - 1].tag != .keyword_const) continue;
        const declaration_end = context.statementEnd(type_index - 1) orelse continue;
        const explicit_name = try collisionFreeTypeName(context, shape.type_name);
        defer context.allocator.free(explicit_name);
        const declaration = try materializedDeclaration(context, shape, explicit_name);
        try context.oneEdit(
            try std.fmt.allocPrint(context.allocator, "Materialize resolved type as '{s}'", .{explicit_name}),
            .refactor_extract,
            .{ .start = context.tokens[declaration_end].loc.end, .end = context.tokens[declaration_end].loc.end },
            declaration,
            .{},
        );
    }
}

fn collisionFreeTypeName(context: ActionRun, type_name: []const u8) ![]const u8 {
    var candidate = try std.fmt.allocPrint(context.allocator, "Resolved{s}", .{type_name});
    var suffix: usize = 2;
    while (std.mem.indexOf(u8, context.source, candidate) != null) : (suffix += 1) {
        const next_candidate = try std.fmt.allocPrint(context.allocator, "Resolved{s}{d}", .{ type_name, suffix });
        context.allocator.free(candidate);
        candidate = next_candidate;
    }
    return candidate;
}

fn materializedDeclaration(context: ActionRun, shape: analysis.ResolvedShape, explicit_name: []const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(context.allocator);
    defer writer.deinit();
    const kind = switch (shape.kind) {
        .enumeration => "enum",
        .tagged_union => "union(enum)",
        .structure => "struct",
    };
    try writer.writer.print("\nconst {s} = {s} {{\n", .{ explicit_name, kind });
    for (shape.fields) |field| switch (shape.kind) {
        .enumeration => try writer.writer.print("    {s},\n", .{field}),
        .tagged_union, .structure => try writer.writer.print(
            "    {s}: @TypeOf(@field(@as({s}, undefined), \"{s}\")),\n",
            .{ field, shape.type_name, field },
        ),
    };
    try writer.writer.writeAll("};");
    return try writer.toOwnedSlice();
}

fn addReflectedDeclaration(context: ActionRun) !void {
    for (context.tokens, 0..) |token, builtin_index| {
        if (token.tag != .builtin or (!context.tokenIs(builtin_index, "@hasField") and !context.tokenIs(builtin_index, "@hasDecl")) or
            builtin_index + 5 >= context.tokens.len or context.tokens[builtin_index + 1].tag != .l_paren or
            context.tokens[builtin_index + 2].tag != .identifier or context.tokens[builtin_index + 3].tag != .comma or
            context.tokens[builtin_index + 4].tag != .string_literal or !context.selected(context.tokens[builtin_index + 4].loc)) continue;
        const type_name = context.tokenText(builtin_index + 2);
        const member_name = stringValue(context.tokenText(builtin_index + 4)) orelse continue;
        if (context.shapeNamed(type_name)) |shape| {
            if (shape.kind != .structure) continue;
            if (shapeContains(shape, member_name)) continue;
        }
        const container_end = localPlainStructEnd(context, type_name) orelse continue;
        const indentation = context.lineIndentation(context.tokens[container_end].loc.start);
        const declaration = if (context.tokenIs(builtin_index, "@hasField"))
            try std.fmt.allocPrint(context.allocator, "{s}    @\"{s}\": void = {{}},\n", .{ indentation, member_name })
        else
            try std.fmt.allocPrint(context.allocator, "{s}    pub const @\"{s}\" = {{}};\n", .{ indentation, member_name });
        try context.oneEdit(
            try std.fmt.allocPrint(context.allocator, "Generate reflected member '{s}'", .{member_name}),
            .refactor_rewrite,
            .{ .start = context.tokens[container_end].loc.start, .end = context.tokens[container_end].loc.start },
            declaration,
            .{},
        );
    }
}

fn localPlainStructEnd(context: ActionRun, name: []const u8) ?usize {
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 4 >= context.tokens.len or !context.tokenIs(index + 1, name) or
            context.tokens[index + 2].tag != .equal) continue;
        if (context.tokens[index + 3].tag != .keyword_struct or context.tokens[index + 4].tag != .l_brace) continue;
        return context.matchingToken(index + 4, .l_brace, .r_brace);
    }
    return null;
}

fn stringValue(literal: []const u8) ?[]const u8 {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    const value = literal[1 .. literal.len - 1];
    if (std.mem.indexOfScalar(u8, value, '\\') != null) return null;
    return value;
}

test "mutable captures format strings and reflected declarations have actions" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const capture_source: [:0]const u8 = "fn run(value: ?u8) void { var current = value; if (current) |payload| { payload += 1; } }";
    const capture = std.mem.indexOf(u8, capture_source, "payload") orelse unreachable;
    const capture_actions = try registry.actions(arena.allocator(), capture_source, .{ .start = capture, .end = capture + 7 }, &.{});
    try std.testing.expectEqual(@as(usize, 2), capture_actions[0].edits.len);
    try std.testing.expectEqualStrings("*", capture_actions[0].edits[0].replacement);
    try std.testing.expectEqualStrings(".*", capture_actions[0].edits[1].replacement);
    const mutation = std.mem.lastIndexOf(u8, capture_source, "payload") orelse unreachable;
    try std.testing.expectEqual(mutation + 7, capture_actions[0].edits[1].span.start);

    const format_source: [:0]const u8 = "fn run() void { std.debug.print(\"name {}\", .{\"zig\"}); }";
    const format = std.mem.indexOf(u8, format_source, "\"name {}\"") orelse unreachable;
    const format_actions = try registry.actions(arena.allocator(), format_source, .{ .start = format, .end = format + 9 }, &.{});
    try std.testing.expectEqualStrings("\"name {s}\"", format_actions[0].edits[0].replacement);

    const reflection_source: [:0]const u8 = "const Config = struct {}; comptime { _ = @hasDecl(Config, \"load\"); }";
    const member = std.mem.indexOf(u8, reflection_source, "\"load\"") orelse unreachable;
    const reflection_actions = try registry.actions(arena.allocator(), reflection_source, .{ .start = member, .end = member + 6 }, &.{});
    try std.testing.expect(std.mem.indexOf(u8, reflection_actions[0].edits[0].replacement, "pub const") != null);
}

test "format argument arity gets explicit tuple repairs" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const missing_source: [:0]const u8 = "fn run(one: u8) void { std.debug.print(\"{} {}\", .{one}); }";
    const missing_format = std.mem.indexOf(u8, missing_source, "\"{} {}\"") orelse unreachable;
    const missing = try registry.actions(arena.allocator(), missing_source, .{ .start = missing_format, .end = missing_format + 7 }, &.{});
    try std.testing.expectEqualStrings(".{one, @panic(\"TODO\")}", missing[0].edits[0].replacement);

    const extra_source: [:0]const u8 = "fn run(one: u8, two: u8) void { std.debug.print(\"{}\", .{one, two}); }";
    const extra_format = std.mem.indexOf(u8, extra_source, "\"{}\"") orelse unreachable;
    const extra = try registry.actions(arena.allocator(), extra_source, .{ .start = extra_format, .end = extra_format + 4 }, &.{});
    try std.testing.expectEqualStrings("Add missing format placeholders", extra[0].title);
    try std.testing.expectEqualStrings("\"{} {any}\"", extra[0].edits[0].replacement);
    try std.testing.expectEqual(extra_format, extra[0].edits[0].span.start);
}

test "escaped format braces are counted and replaced escape-aware" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run() void { std.debug.print(\"{{}} {}\", .{\"zig\"}); }";
    const format = std.mem.indexOf(u8, source, "\"{{}} {}\"") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = format, .end = format + 9 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("\"{{}} {s}\"", actions[0].edits[0].replacement);
}

test "out-of-scope var bindings do not enable pointer captures" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn other() void { var current: ?u8 = 1; _ = current; } " ++
        "fn run(value: ?u8) void { const current = value; if (current) |payload| { payload += 1; } }";
    const capture = std.mem.lastIndexOf(u8, source, "payload") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = capture, .end = capture + 7 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "compiler shapes drive tagged union and materialization actions" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_][]const u8{ "number", "text" };
    const shapes = [_]analysis.ResolvedShape{.{ .type_name = "Value", .kind = .tagged_union, .fields = &fields }};
    const switch_source: [:0]const u8 = "fn run(value: Value) void { if (value == .number) { _ = value.number; } }";
    const if_start = std.mem.indexOf(u8, switch_source, "if") orelse unreachable;
    const switch_actions = try registry.actions(arena.allocator(), switch_source, .{ .start = if_start, .end = if_start + 2 }, &shapes);
    try std.testing.expect(std.mem.indexOf(u8, switch_actions[0].edits[0].replacement, "|payload|") != null);

    const materialize_source: [:0]const u8 = "const Value = makeValue();";
    const type_start = std.mem.indexOf(u8, materialize_source, "Value") orelse unreachable;
    const materialize_actions = try registry.actions(arena.allocator(), materialize_source, .{ .start = type_start, .end = type_start + 5 }, &shapes);
    try std.testing.expect(std.mem.indexOf(u8, materialize_actions[0].edits[0].replacement, "union(enum)") != null);
}

test "tagged union switches leave dangling else branches alone" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_][]const u8{ "number", "text" };
    const shapes = [_]analysis.ResolvedShape{.{ .type_name = "Value", .kind = .tagged_union, .fields = &fields }};
    const source: [:0]const u8 = "fn run(value: Value) void { if (value == .number) { _ = value.number; } else { _ = value; } }";
    const if_start = std.mem.indexOf(u8, source, "if") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = if_start, .end = if_start + 2 }, &shapes);
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "tagged union payload rewrites spare string literals and longer identifiers" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_][]const u8{ "number", "text" };
    const shapes = [_]analysis.ResolvedShape{.{ .type_name = "Value", .kind = .tagged_union, .fields = &fields }};
    const source: [:0]const u8 =
        "fn run(value: Value) void { if (value == .number) { " ++
        "std.debug.print(\"value.number={d}\", .{value.number}); _ = value.number_total; } }";
    const if_start = std.mem.indexOf(u8, source, "if") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = if_start, .end = if_start + 2 }, &shapes);
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    const replacement = actions[0].edits[0].replacement;
    try std.testing.expect(std.mem.indexOf(u8, replacement, "\"value.number={d}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, replacement, ".{payload}") != null);
    try std.testing.expect(std.mem.indexOf(u8, replacement, "value.number_total") != null);
}

test "tagged union bodies that mutate or address the payload keep the if" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_][]const u8{ "number", "text" };
    const shapes = [_]analysis.ResolvedShape{.{ .type_name = "Value", .kind = .tagged_union, .fields = &fields }};

    const assign_source: [:0]const u8 =
        "fn run() void { var value: Value = .{ .number = 1 }; if (value == .number) { value.number = 2; } }";
    const assign_start = std.mem.indexOf(u8, assign_source, "if") orelse unreachable;
    const assign = try registry.actions(arena.allocator(), assign_source, .{ .start = assign_start, .end = assign_start + 2 }, &shapes);
    try std.testing.expectEqual(@as(usize, 0), assign.len);

    const address_source: [:0]const u8 =
        "fn run() void { var value: Value = .{ .number = 1 }; if (value == .number) { mutate(&value.number); } }";
    const address_start = std.mem.indexOf(u8, address_source, "if") orelse unreachable;
    const address = try registry.actions(arena.allocator(), address_source, .{ .start = address_start, .end = address_start + 2 }, &shapes);
    try std.testing.expectEqual(@as(usize, 0), address.len);
}

test "tagged union bodies that assign through unwraps or take parenthesized addresses keep the if" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_][]const u8{ "number", "text" };
    const shapes = [_]analysis.ResolvedShape{.{ .type_name = "Value", .kind = .tagged_union, .fields = &fields }};

    const unwrap_source: [:0]const u8 =
        "fn run() void { var value: Value = .{ .number = 1 }; if (value == .number) { value.number.? = 2; } }";
    const unwrap_start = std.mem.indexOf(u8, unwrap_source, "if") orelse unreachable;
    const unwrap = try registry.actions(arena.allocator(), unwrap_source, .{ .start = unwrap_start, .end = unwrap_start + 2 }, &shapes);
    try std.testing.expectEqual(@as(usize, 0), unwrap.len);

    const parenthesized_source: [:0]const u8 =
        "fn run() void { var value: Value = .{ .number = 1 }; if (value == .number) { mutate(&(value.number)); } }";
    const parenthesized_start = std.mem.indexOf(u8, parenthesized_source, "if") orelse unreachable;
    const parenthesized = try registry.actions(arena.allocator(), parenthesized_source, .{ .start = parenthesized_start, .end = parenthesized_start + 2 }, &shapes);
    try std.testing.expectEqual(@as(usize, 0), parenthesized.len);
}

test "tagged union payload captures avoid names already used in the body" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_][]const u8{ "number", "text" };
    const shapes = [_]analysis.ResolvedShape{.{ .type_name = "Value", .kind = .tagged_union, .fields = &fields }};
    const source: [:0]const u8 =
        "fn run(value: Value) void { if (value == .number) { const payload = value.number; _ = payload; } }";
    const if_start = std.mem.indexOf(u8, source, "if") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = if_start, .end = if_start + 2 }, &shapes);
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].edits[0].replacement, "|payload2|") != null);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].edits[0].replacement, "const payload = payload2;") != null);
}

test "reflected fields only land in plain struct containers" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const union_source: [:0]const u8 =
        "const Value = union(enum) { number: u8 }; comptime { _ = @hasField(Value, \"text\"); }";
    const union_member = std.mem.indexOf(u8, union_source, "\"text\"") orelse unreachable;
    const union_actions = try registry.actions(arena.allocator(), union_source, .{ .start = union_member, .end = union_member + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), union_actions.len);

    const extern_source: [:0]const u8 =
        "const Raw = extern struct { a: u8 }; comptime { _ = @hasField(Raw, \"b\"); }";
    const extern_member = std.mem.indexOf(u8, extern_source, "\"b\"") orelse unreachable;
    const extern_actions = try registry.actions(arena.allocator(), extern_source, .{ .start = extern_member, .end = extern_member + 3 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), extern_actions.len);
}

test "reflection dispatch can become an inline-else switch" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_][]const u8{ "number", "code" };
    const shapes = [_]analysis.ResolvedShape{.{ .type_name = "Value", .kind = .tagged_union, .fields = &fields }};
    const source: [:0]const u8 =
        "const Value = union(enum) { number: u8, code: u8, }; " ++
        "fn get(value: Value) u8 { inline for (@typeInfo(Value).@\"union\".fields) |field| { " ++
        "if (std.mem.eql(u8, field.name, @tagName(value))) return @field(value, field.name); } unreachable; }";
    const start = std.mem.indexOf(u8, source, "inline") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 6 }, &shapes);
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expect(std.mem.indexOf(u8, actions[0].edits[0].replacement, "inline else") != null);

    const swapped_source: [:0]const u8 =
        "const Value = union(enum) { number: u8, code: u8, }; " ++
        "fn get(value: Value) u8 { inline for (@typeInfo(Value).@\"union\".fields) |field| { " ++
        "if (std.mem.eql(u8, @tagName(value), field.name)) return @field(value, field.name); } unreachable; }";
    const swapped_start = std.mem.indexOf(u8, swapped_source, "inline") orelse unreachable;
    const swapped = try registry.actions(arena.allocator(), swapped_source, .{ .start = swapped_start, .end = swapped_start + 6 }, &shapes);
    try std.testing.expectEqual(@as(usize, 1), swapped.len);

    const mixed_source: [:0]const u8 =
        "const Value = union(enum) { number: u8, code: u16, }; " ++
        "fn get(value: Value) u16 { inline for (@typeInfo(Value).@\"union\".fields) |field| { " ++
        "if (std.mem.eql(u8, field.name, @tagName(value))) return @field(value, field.name); } unreachable; }";
    const mixed_start = std.mem.indexOf(u8, mixed_source, "inline") orelse unreachable;
    const mixed_actions = try registry.actions(arena.allocator(), mixed_source, .{ .start = mixed_start, .end = mixed_start + 6 }, &shapes);
    try std.testing.expectEqual(@as(usize, 0), mixed_actions.len);
}

test "reflection dispatch loops that are not the exact guarded return stay put" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = [_][]const u8{ "number", "code" };
    const shapes = [_]analysis.ResolvedShape{.{ .type_name = "Value", .kind = .tagged_union, .fields = &fields }};

    const negated_source: [:0]const u8 =
        "const Value = union(enum) { number: u8, code: u8, }; " ++
        "fn get(value: Value) u8 { inline for (@typeInfo(Value).@\"union\".fields) |field| { " ++
        "if (!std.mem.eql(u8, field.name, @tagName(value))) return @field(value, field.name); } unreachable; }";
    const negated_start = std.mem.indexOf(u8, negated_source, "inline") orelse unreachable;
    const negated = try registry.actions(arena.allocator(), negated_source, .{ .start = negated_start, .end = negated_start + 6 }, &shapes);
    try std.testing.expectEqual(@as(usize, 0), negated.len);

    const effect_source: [:0]const u8 =
        "const Value = union(enum) { number: u8, code: u8, }; " ++
        "fn get(value: Value) u8 { inline for (@typeInfo(Value).@\"union\".fields) |field| { " ++
        "std.debug.print(\"x\", .{}); " ++
        "if (std.mem.eql(u8, field.name, @tagName(value))) return @field(value, field.name); } unreachable; }";
    const effect_start = std.mem.indexOf(u8, effect_source, "inline") orelse unreachable;
    const effect = try registry.actions(arena.allocator(), effect_source, .{ .start = effect_start, .end = effect_start + 6 }, &shapes);
    try std.testing.expectEqual(@as(usize, 0), effect.len);

    const trailing_source: [:0]const u8 =
        "const Value = union(enum) { number: u8, code: u8, }; " ++
        "fn get(value: Value) u8 { inline for (@typeInfo(Value).@\"union\".fields) |field| { " ++
        "if (std.mem.eql(u8, field.name, @tagName(value))) return @field(value, field.name); } return 0; }";
    const trailing_start = std.mem.indexOf(u8, trailing_source, "inline") orelse unreachable;
    const trailing = try registry.actions(arena.allocator(), trailing_source, .{ .start = trailing_start, .end = trailing_start + 6 }, &shapes);
    try std.testing.expectEqual(@as(usize, 0), trailing.len);
}
