//! Per-token annotations an editor draws over source text: the class and
//! modifiers of a token for semantic highlighting, and inlay hints for obvious
//! types, implicit enum values and comptime parameter names. Offsets are bytes;
//! the transport converts them to positions.
const std = @import("std");
const document_module = @import("document.zig");
const tokens_util = @import("tokens.zig");

const Document = document_module.Document;
const matchingToken = tokens_util.matchingToken;

/// The order is the legend the server advertises.
pub const TokenClass = enum(u32) {
    variable,
    function,
    keyword,
    comment,
    string,
    number,
    macro,
};

/// Bit positions are the legend order of the modifiers the server advertises.
pub const Modifier = struct {
    pub const declaration: u32 = 1 << 0;
    pub const readonly: u32 = 1 << 1;
    pub const static: u32 = 1 << 2;
};

pub const Hint = struct {
    /// Where the hint is drawn.
    offset: usize,
    label: []const u8,
    kind: Kind,

    pub const Kind = enum { type, parameter };
};

pub fn tokenClass(document: *const Document, token: std.zig.Token) ?TokenClass {
    if (token.tag == .identifier) {
        if (document.declarationNamed(document.source[token.loc.start..token.loc.end])) |declaration| {
            return if (declaration.kind == .function) .function else .variable;
        }
        return .variable;
    }
    if (token.tag == .builtin) return .macro;
    if (token.tag == .doc_comment or token.tag == .container_doc_comment) return .comment;
    if (token.tag == .string_literal or token.tag == .multiline_string_literal_line or token.tag == .char_literal) return .string;
    if (token.tag == .number_literal) return .number;
    if (std.mem.startsWith(u8, @tagName(token.tag), "keyword_")) return .keyword;
    return null;
}

pub fn tokenModifiers(document: *const Document, token: std.zig.Token) u32 {
    var modifiers: u32 = if (isDeclarationSpan(document, token.loc)) Modifier.declaration else 0;
    if (token.tag != .identifier) return modifiers;
    const declaration = document.declarationNamed(document.source[token.loc.start..token.loc.end]) orelse return modifiers;
    if (!std.meta.eql(declaration.span, token.loc) or declaration.kind != .constant) return modifiers;
    modifiers |= Modifier.readonly;
    const line_end = std.mem.findScalarPos(u8, document.source, token.loc.end, '\n') orelse document.source.len;
    const declaration_tail = std.mem.trim(u8, document.source[token.loc.end..line_end], " \t\r");
    const equal = std.mem.findScalar(u8, declaration_tail, '=') orelse return modifiers;
    const initializer = std.mem.trim(u8, declaration_tail[equal + 1 ..], " \t\r");
    if (initializer.len != 0 and (std.ascii.isDigit(initializer[0]) or initializer[0] == '\'' or initializer[0] == '"' or
        std.mem.startsWith(u8, initializer, "true") or std.mem.startsWith(u8, initializer, "false")))
    {
        modifiers |= Modifier.static;
    }
    return modifiers;
}

fn isDeclarationSpan(document: *const Document, span: std.zig.Token.Loc) bool {
    for (document.declarations) |declaration| {
        if (std.meta.eql(declaration.span, span)) return true;
    }
    return false;
}

/// Every hint for `document`, in source-kind order: literal types, implicit
/// enum values, then comptime parameter names at call sites.
pub fn hints(allocator: std.mem.Allocator, document: *const Document) ![]const Hint {
    var found: std.ArrayList(Hint) = .empty;
    errdefer found.deinit(allocator);
    try literalTypeHints(allocator, document, &found);
    try enumValueHints(allocator, document, &found);
    try comptimeParameterHints(allocator, document, &found);
    return try found.toOwnedSlice(allocator);
}

fn literalTypeHints(allocator: std.mem.Allocator, document: *const Document, found: *std.ArrayList(Hint)) !void {
    var tokenizer = std.zig.Tokenizer.init(document.source);
    while (true) {
        const declaration_token = tokenizer.next();
        if (declaration_token.tag == .eof) break;
        if (declaration_token.tag != .keyword_const and declaration_token.tag != .keyword_var) continue;
        const name_token = tokenizer.next();
        if (name_token.tag != .identifier) continue;
        if (tokenizer.next().tag != .equal) continue;
        const value_token = tokenizer.next();
        const label = inferredTypeLabel(document.source[value_token.loc.start..value_token.loc.end], value_token.tag) orelse continue;
        try found.append(allocator, .{ .offset = name_token.loc.end, .label = label, .kind = .type });
    }
}

fn enumValueHints(allocator: std.mem.Allocator, document: *const Document, found: *std.ArrayList(Hint)) !void {
    const tokens = document.tokens;
    for (tokens, 0..) |token, enum_index| {
        if (token.tag != .keyword_enum) continue;
        var opening = enum_index + 1;
        if (opening < tokens.len and tokens[opening].tag == .l_paren) {
            opening = (matchingToken(tokens, opening, .l_paren, .r_paren) orelse continue) + 1;
        }
        if (opening >= tokens.len or tokens[opening].tag != .l_brace) continue;
        const closing = matchingToken(tokens, opening, .l_brace, .r_brace) orelse continue;
        var next_value: i128 = 0;
        var value_known = true;
        var cursor = opening + 1;
        while (cursor < closing) : (cursor += 1) {
            if (tokens[cursor].tag != .identifier or cursor > opening + 1 and switch (tokens[cursor - 1].tag) {
                .comma, .doc_comment, .container_doc_comment => false,
                else => true,
            }) continue;
            if (std.mem.eql(u8, document.source[tokens[cursor].loc.start..tokens[cursor].loc.end], "_")) continue;
            if (cursor + 1 < closing and tokens[cursor + 1].tag == .equal) {
                if (cursor + 2 < closing and tokens[cursor + 2].tag == .number_literal) {
                    next_value = std.fmt.parseInt(i128, document.source[tokens[cursor + 2].loc.start..tokens[cursor + 2].loc.end], 0) catch {
                        value_known = false;
                        continue;
                    };
                    next_value += 1;
                    value_known = true;
                } else value_known = false;
                continue;
            }
            if (!value_known) continue;
            try found.append(allocator, .{
                .offset = tokens[cursor].loc.end,
                .label = try allocator.print(" = {d}", .{next_value}),
                .kind = .type,
            });
            next_value += 1;
        }
    }
}

fn comptimeParameterHints(allocator: std.mem.Allocator, document: *const Document, found: *std.ArrayList(Hint)) !void {
    const tokens = document.tokens;
    for (tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 2 >= tokens.len or tokens[fn_index + 1].tag != .identifier or
            tokens[fn_index + 2].tag != .l_paren) continue;
        const function_name = document.source[tokens[fn_index + 1].loc.start..tokens[fn_index + 1].loc.end];
        const parameters_end = matchingToken(tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
        var ordinal: usize = 0;
        var parameter_cursor = fn_index + 3;
        var nested_depth: usize = 0;
        while (parameter_cursor < parameters_end) : (parameter_cursor += 1) {
            switch (tokens[parameter_cursor].tag) {
                .l_paren, .l_brace, .l_bracket => nested_depth += 1,
                .r_paren, .r_brace, .r_bracket => nested_depth -|= 1,
                .comma => if (nested_depth == 0) {
                    ordinal += 1;
                },
                .keyword_comptime => {
                    if (nested_depth != 0 or parameter_cursor + 1 >= parameters_end or
                        tokens[parameter_cursor + 1].tag != .identifier) continue;
                    const parameter_name = document.source[tokens[parameter_cursor + 1].loc.start..tokens[parameter_cursor + 1].loc.end];
                    for (tokens, 0..) |call_token, call_index| {
                        if (call_token.tag != .identifier or !std.mem.eql(u8, document.source[call_token.loc.start..call_token.loc.end], function_name) or
                            call_index + 1 >= tokens.len or tokens[call_index + 1].tag != .l_paren or
                            call_index > 0 and tokens[call_index - 1].tag == .keyword_fn) continue;
                        const argument_index = callArgumentToken(tokens, call_index + 1, ordinal) orelse continue;
                        try found.append(allocator, .{
                            .offset = tokens[argument_index].loc.start,
                            .label = try allocator.print("{s}:", .{parameter_name}),
                            .kind = .parameter,
                        });
                    }
                },
                else => {},
            }
        }
    }
}

fn callArgumentToken(tokens: []const std.zig.Token, opening: usize, requested_ordinal: usize) ?usize {
    const closing = matchingToken(tokens, opening, .l_paren, .r_paren) orelse return null;
    var ordinal: usize = 0;
    var nested_depth: usize = 0;
    var cursor = opening + 1;
    while (cursor < closing) : (cursor += 1) {
        if (ordinal == requested_ordinal and nested_depth == 0 and tokens[cursor].tag != .comma) return cursor;
        switch (tokens[cursor].tag) {
            .l_paren, .l_brace, .l_bracket => nested_depth += 1,
            .r_paren, .r_brace, .r_bracket => nested_depth -|= 1,
            .comma => if (nested_depth == 0) {
                ordinal += 1;
            },
            else => {},
        }
    }
    return null;
}

fn inferredTypeLabel(source: []const u8, tag: std.zig.Token.Tag) ?[]const u8 {
    return switch (tag) {
        .number_literal => ": comptime_int",
        .string_literal, .multiline_string_literal_line => ": []const u8",
        .char_literal => ": u8",
        .identifier => if (std.mem.eql(u8, source, "true") or std.mem.eql(u8, source, "false")) ": bool" else null,
        else => null,
    };
}

test "semantic classes cover keywords declarations and numbers" {
    var document = try Document.open(std.testing.allocator, "file:///fixture.zig", 1, "const answer = 42;\n");
    defer document.deinit();
    var tokenizer = std.zig.Tokenizer.init(document.source);
    const keyword = tokenizer.next();
    try std.testing.expectEqual(TokenClass.keyword, tokenClass(&document, keyword).?);
    const name = tokenizer.next();
    try std.testing.expectEqual(TokenClass.variable, tokenClass(&document, name).?);
    try std.testing.expectEqual(Modifier.declaration | Modifier.readonly | Modifier.static, tokenModifiers(&document, name));
    _ = tokenizer.next();
    try std.testing.expectEqual(TokenClass.number, tokenClass(&document, tokenizer.next()).?);
}

test "hints report obvious literal types" {
    var document = try Document.open(std.testing.allocator, "file:///fixture.zig", 1, "const answer = 42;\nconst enabled = true;\n");
    defer document.deinit();
    const found = try hints(std.testing.allocator, &document);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings(": comptime_int", found[0].label);
    try std.testing.expectEqualStrings(": bool", found[1].label);
}

test "enum hints expose implicit integer values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document = try Document.open(arena.allocator(), "file:///fixture.zig", 1, "const Mode = enum { idle, busy = 4, done };\n");
    defer document.deinit();
    const found = try hints(arena.allocator(), &document);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings(" = 0", found[0].label);
    try std.testing.expectEqualStrings(" = 5", found[1].label);
}

test "comptime calls show parameter-name hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document = try Document.open(
        arena.allocator(),
        "file:///fixture.zig",
        1,
        "fn Matrix(comptime Element: type, comptime size: usize) type { return [size]Element; }\nconst M = Matrix(u32, 3);\n",
    );
    defer document.deinit();
    const found = try hints(arena.allocator(), &document);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("Element:", found[0].label);
    try std.testing.expectEqualStrings("size:", found[1].label);
    try std.testing.expectEqual(Hint.Kind.parameter, found[0].kind);
}
