//! What the editor shows for a declaration: its text, a type summary and the
//! doc comment above it. Reads syntax only; hover and completion details
//! render these summaries.
const std = @import("std");
const tokens_util = @import("tokens.zig");

const tokenize = tokens_util.tokenize;
const matchingToken = tokens_util.matchingToken;

pub const Summary = struct {
    declaration: []const u8,
    type_summary: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
};

pub fn describeBinding(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    binding_span: std.zig.Token.Loc,
) !?Summary {
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    const binding_index = for (tokens, 0..) |token, index| {
        if (token.tag == .identifier and std.meta.eql(token.loc, binding_span)) break index;
    } else return null;

    if (binding_index > 0 and tokens[binding_index - 1].tag == .keyword_fn) {
        return try describeFunctionBinding(allocator, source_bytes, tokens, binding_index);
    }
    if (binding_index > 0 and
        (tokens[binding_index - 1].tag == .keyword_const or tokens[binding_index - 1].tag == .keyword_var))
    {
        return try describeVariableBinding(allocator, source_bytes, tokens, binding_index);
    }
    if (binding_index + 1 < tokens.len and tokens[binding_index + 1].tag == .colon) {
        return try describeTypedBinding(allocator, source_bytes, tokens, binding_index);
    }
    if (binding_index > 0 and binding_index + 1 < tokens.len and
        tokens[binding_index - 1].tag == .pipe and tokens[binding_index + 1].tag == .pipe)
    {
        return try describeCaptureBinding(allocator, source_bytes, tokens, binding_index);
    }
    return null;
}

fn describeCaptureBinding(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_index: usize,
) !?Summary {
    var iterable_index = binding_index - 1;
    while (iterable_index > 0 and tokens[iterable_index].tag != .r_paren) : (iterable_index -= 1) {}
    if (tokens[iterable_index].tag != .r_paren or iterable_index == 0) return null;
    iterable_index -= 1;
    if (tokens[iterable_index].tag != .identifier) return null;
    const iterable_name = source[tokens[iterable_index].loc.start..tokens[iterable_index].loc.end];
    const iterable_type = typedBindingTypeNamed(source, tokens, iterable_name) orelse return null;
    const element_type = if (std.mem.startsWith(u8, iterable_type, "[]const "))
        iterable_type["[]const ".len..]
    else if (std.mem.startsWith(u8, iterable_type, "[]"))
        iterable_type[2..]
    else
        return null;
    const name = source[tokens[binding_index].loc.start..tokens[binding_index].loc.end];
    return .{
        .declaration = try allocator.print("{s}: {s}", .{ name, element_type }),
        .type_summary = element_type,
    };
}

pub fn describeTypedMemberNamed(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    name: []const u8,
) !?Summary {
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index + 1 >= tokens.len or tokens[index + 1].tag != .colon) continue;
        if (!std.mem.eql(u8, source_bytes[token.loc.start..token.loc.end], name)) continue;
        return try describeTypedBinding(allocator, source_bytes, tokens, index);
    }
    return null;
}

pub fn describeEnumTagNamed(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    name: []const u8,
) !?Summary {
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or !std.mem.eql(u8, source_bytes[token.loc.start..token.loc.end], name)) continue;
        const opening_brace = enclosingSyntaxToken(tokens, index, .l_brace, .r_brace) orelse continue;
        if (opening_brace == 0 or tokens[opening_brace - 1].tag != .keyword_enum) continue;
        if (opening_brace < 3 or tokens[opening_brace - 2].tag != .equal or tokens[opening_brace - 3].tag != .identifier) continue;
        const enum_name = source_bytes[tokens[opening_brace - 3].loc.start..tokens[opening_brace - 3].loc.end];
        return .{
            .declaration = try allocator.print(".{s}", .{name}),
            .type_summary = enum_name,
        };
    }
    return null;
}

fn enclosingSyntaxToken(
    tokens: []const std.zig.Token,
    index: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == closing_tag) {
            depth += 1;
        } else if (tokens[cursor].tag == opening_tag) {
            if (depth == 0) return cursor;
            depth -= 1;
        }
    }
    return null;
}

fn typedBindingTypeNamed(
    source: []const u8,
    tokens: []const std.zig.Token,
    name: []const u8,
) ?[]const u8 {
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index + 2 >= tokens.len or tokens[index + 1].tag != .colon) continue;
        if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) continue;
        var end_index = index + 2;
        var bracket_depth: usize = 0;
        while (end_index < tokens.len) : (end_index += 1) {
            switch (tokens[end_index].tag) {
                .l_bracket => bracket_depth += 1,
                .r_bracket => bracket_depth -|= 1,
                .comma, .r_paren, .equal => if (bracket_depth == 0) break,
                else => {},
            }
        }
        if (end_index == index + 2) return null;
        return std.mem.trim(
            u8,
            source[tokens[index + 1].loc.end..tokens[end_index - 1].loc.end],
            " \t\r\n",
        );
    }
    return null;
}

fn describeFunctionBinding(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_index: usize,
) !Summary {
    const function_index = binding_index - 1;
    var opening_parenthesis = binding_index + 1;
    while (opening_parenthesis < tokens.len and tokens[opening_parenthesis].tag != .l_paren) : (opening_parenthesis += 1) {}
    if (opening_parenthesis == tokens.len) return error.MalformedFunctionDeclaration;
    const closing_parenthesis = matchingToken(tokens, opening_parenthesis, .l_paren, .r_paren) orelse {
        return error.MalformedFunctionDeclaration;
    };
    var body_index = closing_parenthesis + 1;
    while (body_index < tokens.len and tokens[body_index].tag != .l_brace and tokens[body_index].tag != .semicolon) : (body_index += 1) {}
    if (body_index == tokens.len) return error.MalformedFunctionDeclaration;
    const declaration_end = tokens[body_index - 1].loc.end;
    const declaration = std.mem.trim(u8, source[tokens[function_index].loc.start..declaration_end], " \t\r\n");

    var summary: std.Io.Writer.Allocating = .init(allocator);
    defer summary.deinit();
    try summary.writer.writeAll("fn (");
    var segment_start = opening_parenthesis + 1;
    var nested_parentheses: usize = 0;
    var first_parameter = true;
    var index = segment_start;
    while (index <= closing_parenthesis) : (index += 1) {
        const at_end = index == closing_parenthesis;
        if (!at_end) {
            if (tokens[index].tag == .l_paren) nested_parentheses += 1;
            if (tokens[index].tag == .r_paren) nested_parentheses -|= 1;
        }
        if (!at_end and (tokens[index].tag != .comma or nested_parentheses != 0)) continue;
        if (segment_start < index) {
            const colon_index = for (tokens[segment_start..index], segment_start..) |token, parameter_index| {
                if (token.tag == .colon) break parameter_index;
            } else null;
            if (colon_index) |colon| {
                if (!first_parameter) try summary.writer.writeAll(", ");
                if (tokens[segment_start].tag == .keyword_comptime) try summary.writer.writeAll("comptime ");
                const parameter_type = std.mem.trim(
                    u8,
                    source[tokens[colon].loc.end..tokens[index - 1].loc.end],
                    " \t\r\n",
                );
                try summary.writer.writeAll(parameter_type);
                first_parameter = false;
            }
        }
        segment_start = index + 1;
    }
    try summary.writer.writeAll(") ");
    const return_type = std.mem.trim(
        u8,
        source[tokens[closing_parenthesis].loc.end..tokens[body_index].loc.start],
        " \t\r\n",
    );
    try summary.writer.writeAll(if (return_type.len == 0) "void" else return_type);
    return .{
        .declaration = declaration,
        .type_summary = try summary.toOwnedSlice(),
        .documentation = try documentationBefore(allocator, source, tokens[function_index].loc.start),
    };
}

fn describeVariableBinding(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_index: usize,
) !Summary {
    const declaration_index = binding_index - 1;
    var end_index = binding_index + 1;
    while (end_index < tokens.len and tokens[end_index].tag != .semicolon) : (end_index += 1) {}
    if (end_index == tokens.len) return error.MalformedVariableDeclaration;
    const declaration = std.mem.trim(
        u8,
        source[tokens[declaration_index].loc.start..tokens[end_index - 1].loc.end],
        " \t\r\n",
    );
    var colon_index: ?usize = null;
    var equal_index: ?usize = null;
    for (tokens[binding_index + 1 .. end_index], binding_index + 1..) |token, index| {
        if (token.tag == .colon and colon_index == null) colon_index = index;
        if (token.tag == .equal) {
            equal_index = index;
            break;
        }
    }
    const explicit_type = if (colon_index) |colon|
        std.mem.trim(
            u8,
            source[tokens[colon].loc.end..tokens[(equal_index orelse end_index) - 1].loc.end],
            " \t\r\n",
        )
    else
        null;
    const value_token = if (equal_index) |equal|
        if (equal + 2 == end_index) tokens[equal + 1] else null
    else
        null;
    const inferred_type = if (explicit_type) |type_name|
        type_name
    else if (value_token) |token|
        inferredLiteralType(source[token.loc.start..token.loc.end], token.tag)
    else
        null;
    const type_summary = if (inferred_type) |type_name| summary: {
        if (value_token) |token| {
            const value = source[token.loc.start..token.loc.end];
            if (value.len <= 64) break :summary try allocator.print("{s} = {s}", .{ type_name, value });
        }
        break :summary type_name;
    } else null;
    return .{
        .declaration = declaration,
        .type_summary = type_summary,
        .documentation = try documentationBefore(allocator, source, tokens[declaration_index].loc.start),
    };
}

fn describeTypedBinding(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_index: usize,
) !Summary {
    const colon_index = binding_index + 1;
    var end_index = colon_index + 1;
    var bracket_depth: usize = 0;
    var parenthesis_depth: usize = 0;
    while (end_index < tokens.len) : (end_index += 1) {
        switch (tokens[end_index].tag) {
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => {
                if (bracket_depth == 0 and parenthesis_depth == 0) break;
                parenthesis_depth -|= 1;
            },
            .comma, .equal, .semicolon, .r_brace => if (bracket_depth == 0 and parenthesis_depth == 0) break,
            else => {},
        }
    }
    if (end_index == colon_index + 1) return error.MalformedTypedBinding;
    const type_name = std.mem.trim(
        u8,
        source[tokens[colon_index].loc.end..tokens[end_index - 1].loc.end],
        " \t\r\n",
    );
    return .{
        .declaration = source[tokens[binding_index].loc.start..tokens[end_index - 1].loc.end],
        .type_summary = type_name,
        .documentation = try documentationBefore(allocator, source, tokens[binding_index].loc.start),
    };
}

pub fn inferredLiteralType(source: []const u8, tag: std.zig.Token.Tag) ?[]const u8 {
    return switch (tag) {
        .number_literal => if (std.mem.findScalar(u8, source, '.') == null) "comptime_int" else "comptime_float",
        .string_literal => "string",
        .char_literal => "comptime_int",
        .identifier => if (std.mem.eql(u8, source, "true") or std.mem.eql(u8, source, "false")) "bool" else null,
        else => null,
    };
}

pub fn isTypeDeclaration(source: []const u8, span: std.zig.Token.Loc) bool {
    var cursor = span.end;
    while (cursor < source.len and (source[cursor] == ' ' or source[cursor] == '\t' or source[cursor] == '\r' or source[cursor] == '\n')) : (cursor += 1) {}
    if (cursor < source.len and source[cursor] == '=') {
        cursor += 1;
        while (cursor < source.len and (source[cursor] == ' ' or source[cursor] == '\t' or source[cursor] == '\r' or source[cursor] == '\n')) : (cursor += 1) {}
        const rest = source[cursor..];
        return std.mem.startsWith(u8, rest, "struct") or
            std.mem.startsWith(u8, rest, "enum") or
            std.mem.startsWith(u8, rest, "union") or
            std.mem.startsWith(u8, rest, "opaque") or
            std.mem.startsWith(u8, rest, "@Type");
    }
    return false;
}

pub fn extractTypeNameFromSummary(summary: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, summary, " \t\r\n");
    if (std.mem.findScalar(u8, trimmed, '=')) |equal| {
        trimmed = std.mem.trim(u8, trimmed[0..equal], " \t\r\n");
    }
    while (trimmed.len > 0 and (trimmed[0] == '?' or trimmed[0] == '*')) {
        trimmed = trimmed[1..];
    }
    if (std.mem.startsWith(u8, trimmed, "[]const ")) {
        trimmed = trimmed["[]const ".len..];
    } else if (std.mem.startsWith(u8, trimmed, "[]")) {
        trimmed = trimmed[2..];
    }
    return std.mem.trim(u8, trimmed, " \t\r\n");
}

fn documentationBefore(
    allocator: std.mem.Allocator,
    source: []const u8,
    declaration_start: usize,
) !?[]const u8 {
    const declaration_line_start = std.mem.findScalarLast(u8, source[0..declaration_start], '\n') orelse 0;
    var block_start = if (declaration_line_start == 0) 0 else declaration_line_start;
    var cursor = block_start;
    var found = false;
    while (cursor > 0) {
        const previous_end = cursor - 1;
        const previous_start = if (std.mem.findScalarLast(u8, source[0..previous_end], '\n')) |nl| nl + 1 else 0;
        const line = std.mem.trim(u8, source[previous_start..previous_end], " \t\r");
        if (!std.mem.startsWith(u8, line, "///")) break;
        found = true;
        block_start = previous_start;
        cursor = previous_start;
    }
    if (!found) return null;

    var documentation: std.Io.Writer.Allocating = .init(allocator);
    defer documentation.deinit();
    var lines = std.mem.splitScalar(u8, source[block_start..declaration_line_start], '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "///")) continue;
        if (!first) try documentation.writer.writeByte('\n');
        try documentation.writer.writeAll(std.mem.trimStart(u8, line[3..], " "));
        first = false;
    }
    return try documentation.toOwnedSlice();
}

test "hover descriptions cover fields and loop captures" {
    const source = "const Entry = struct { value: u32 }; fn run(values: []const u32) void { for (values) |value| { _ = value; } }";
    const field = (try describeTypedMemberNamed(std.testing.allocator, source, "value")).?;
    try std.testing.expectEqualStrings("value: u32", field.declaration);
    try std.testing.expectEqualStrings("u32", field.type_summary.?);

    const source_z = try std.testing.allocator.dupeSentinel(u8, source, 0);
    defer std.testing.allocator.free(source_z);
    const tokens = try tokenize(std.testing.allocator, source_z);
    defer std.testing.allocator.free(tokens);
    const capture_index = for (tokens, 0..) |token, index| {
        if (token.tag == .identifier and token.loc.start > 80 and
            std.mem.eql(u8, source[token.loc.start..token.loc.end], "value")) break index;
    } else unreachable;
    const capture = (try describeCaptureBinding(std.testing.allocator, source, tokens, capture_index)).?;
    defer std.testing.allocator.free(capture.declaration);
    try std.testing.expectEqualStrings("value: u32", capture.declaration);
    try std.testing.expectEqualStrings("u32", capture.type_summary.?);

    const enum_tag = (try describeEnumTagNamed(
        std.testing.allocator,
        "const Stage = enum { buffered, traced };",
        "buffered",
    )).?;
    defer std.testing.allocator.free(enum_tag.declaration);
    try std.testing.expectEqualStrings(".buffered", enum_tag.declaration);
    try std.testing.expectEqualStrings("Stage", enum_tag.type_summary.?);
}
