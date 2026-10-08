//! Questions about the source text around a byte offset or a function name:
//! which string literal the cursor is in, which call it is inside, where a
//! function body begins and ends.
const std = @import("std");
const document_module = @import("document.zig");
const tokens_util = @import("tokens.zig");
const syntax_types = @import("types.zig");

const tokenize = tokens_util.tokenize;
const matchingToken = tokens_util.matchingToken;
const Declaration = document_module.Declaration;

pub fn formatStringAt(source: [:0]const u8, byte_offset: usize) bool {
    var previous: [2]std.zig.Token = undefined;
    var previous_count: usize = 0;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return false;
        if (token.tag == .string_literal and byte_offset > token.loc.start and byte_offset < token.loc.end) {
            if (previous_count < 2 or previous[1].tag != .l_paren or previous[0].tag != .identifier) return false;
            const callee = source[previous[0].loc.start..previous[0].loc.end];
            return std.mem.eql(u8, callee, "print") or std.mem.eql(u8, callee, "format") or
                std.mem.eql(u8, callee, "allocPrint") or std.mem.eql(u8, callee, "bufPrint");
        }
        if (previous_count < previous.len) {
            previous[previous_count] = token;
            previous_count += 1;
        } else {
            previous[0] = previous[1];
            previous[1] = token;
        }
    }
}

pub fn importStringPrefix(source: [:0]const u8, byte_offset: usize) ?[]const u8 {
    var previous: [3]std.zig.Token = undefined;
    var previous_count: usize = 0;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return null;
        if (token.tag == .string_literal and byte_offset > token.loc.start and byte_offset <= token.loc.end) {
            if (previous_count < 2 or previous[previous_count - 1].tag != .l_paren or
                previous[previous_count - 2].tag != .builtin or
                !std.mem.eql(u8, source[previous[previous_count - 2].loc.start..previous[previous_count - 2].loc.end], "@import")) return null;
            return source[token.loc.start + 1 .. @min(byte_offset, token.loc.end - 1)];
        }
        if (previous_count < previous.len) {
            previous[previous_count] = token;
            previous_count += 1;
        } else {
            previous[0] = previous[1];
            previous[1] = previous[2];
            previous[2] = token;
        }
    }
}

pub fn importPathAt(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    byte_offset: usize,
) !?[]const u8 {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or index + 3 >= tokens.len or
            !std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import") or
            tokens[index + 1].tag != .l_paren or
            tokens[index + 2].tag != .string_literal or
            tokens[index + 3].tag != .r_paren)
        {
            continue;
        }
        if (byte_offset < token.loc.start or byte_offset > tokens[index + 3].loc.end) continue;
        const literal = source[tokens[index + 2].loc.start..tokens[index + 2].loc.end];
        if (literal.len < 2) return null;
        return literal[1 .. literal.len - 1];
    }
    return null;
}

pub const CallContext = struct {
    name: []const u8,
    active_parameter: u32,
};

pub fn callAt(source: []const u8, byte_offset: usize) ?CallContext {
    if (byte_offset > source.len) return null;
    var nesting: u32 = 0;
    var cursor = byte_offset;
    while (cursor > 0) {
        cursor -= 1;
        switch (source[cursor]) {
            ')' => nesting += 1,
            '(' => {
                if (nesting != 0) {
                    nesting -= 1;
                    continue;
                }
                var name_end = cursor;
                while (name_end > 0 and std.ascii.isWhitespace(source[name_end - 1])) name_end -= 1;
                var name_start = name_end;
                while (name_start > 0 and syntax_types.isIdentifierByte(source[name_start - 1])) name_start -= 1;
                if (name_start == name_end) return null;
                var active_parameter: u32 = 0;
                var argument_nesting: u32 = 0;
                for (source[cursor + 1 .. byte_offset]) |byte| switch (byte) {
                    '(', '[', '{' => argument_nesting += 1,
                    ')', ']', '}' => argument_nesting -|= 1,
                    ',' => if (argument_nesting == 0) {
                        active_parameter += 1;
                    },
                    else => {},
                };
                return .{ .name = source[name_start..name_end], .active_parameter = active_parameter };
            },
            else => {},
        }
    }
    return null;
}

pub fn functionSignature(source: [:0]const u8, name: []const u8) ?[]const u8 {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const function_token = tokenizer.next();
        if (function_token.tag == .eof) return null;
        if (function_token.tag != .keyword_fn) continue;
        const name_token = tokenizer.next();
        if (name_token.tag != .identifier) continue;
        if (!std.mem.eql(u8, source[name_token.loc.start..name_token.loc.end], name)) continue;
        var nesting: u32 = 0;
        var found_parameters = false;
        while (true) {
            const token = tokenizer.next();
            switch (token.tag) {
                .l_paren => {
                    nesting += 1;
                    found_parameters = true;
                },
                .r_paren => {
                    nesting -|= 1;
                    if (found_parameters and nesting == 0) {
                        return source[function_token.loc.start..token.loc.end];
                    }
                },
                .eof => return null,
                else => {},
            }
        }
    }
}

pub const FunctionBodyTokenBounds = struct {
    opening: usize,
    closing: usize,
};

pub fn functionBodyTokenBounds(tokens: []const std.zig.Token, declaration: Declaration) ?FunctionBodyTokenBounds {
    const name_index = for (tokens, 0..) |token, index| {
        if (std.meta.eql(token.loc, declaration.span)) break index;
    } else return null;
    if (name_index == 0 or tokens[name_index - 1].tag != .keyword_fn or name_index + 1 >= tokens.len or
        tokens[name_index + 1].tag != .l_paren) return null;
    const parameters_end = matchingToken(tokens, name_index + 1, .l_paren, .r_paren) orelse return null;
    var opening = parameters_end + 1;
    while (opening < tokens.len and tokens[opening].tag != .l_brace and tokens[opening].tag != .semicolon) : (opening += 1) {}
    if (opening >= tokens.len or tokens[opening].tag != .l_brace) return null;
    return .{
        .opening = opening,
        .closing = matchingToken(tokens, opening, .l_brace, .r_brace) orelse return null,
    };
}

pub fn functionContainingToken(
    declarations: []const Declaration,
    tokens: []const std.zig.Token,
    token_index: usize,
) ?Declaration {
    for (declarations) |declaration| {
        if (declaration.kind != .function) continue;
        const body = functionBodyTokenBounds(tokens, declaration) orelse continue;
        if (token_index > body.opening and token_index < body.closing) return declaration;
    }
    return null;
}

test "calls and signatures report the active argument" {
    const source: [:0]const u8 = "fn add(left: u32, right: u32) u32 { return left + right; }\nconst sum = add(1, 2);\n";
    const second_argument = std.mem.find(u8, source, "2);").? + 1;
    const call = callAt(source, second_argument).?;
    try std.testing.expectEqualStrings("add", call.name);
    try std.testing.expectEqual(@as(u32, 1), call.active_parameter);
    try std.testing.expectEqualStrings("fn add(left: u32, right: u32)", functionSignature(source, call.name).?);
}

test "format and import string contexts are recognized precisely" {
    const format_source: [:0]const u8 = "std.debug.print(\"value {}\", .{42});\n";
    const format_offset = std.mem.find(u8, format_source, "{}") orelse unreachable;
    try std.testing.expect(formatStringAt(format_source, format_offset + 1));
    try std.testing.expect(!formatStringAt(format_source, format_source.len));

    const import_source: [:0]const u8 = "const module = @import(\"dir/mod\");\n";
    const import_offset = std.mem.find(u8, import_source, "dir/mod") orelse unreachable;
    try std.testing.expectEqualStrings("dir/mo", importStringPrefix(import_source, import_offset + "dir/mo".len).?);
}
