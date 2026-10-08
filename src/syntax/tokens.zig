//! Token-stream helpers shared by documents, rules and actions. Everything here
//! is a free function over `(source, tokens)` so engines without a `RuleRun`
//! (project analysis, summaries, document scopes) use the same invariants.
const std = @import("std");

const Tag = std.zig.Token.Tag;

/// Half-open range of token indexes, e.g. one call argument.
pub const Range = struct { start: usize, end: usize };

/// Tokenizes `source`. The result ends with the `.eof` token, the shape every
/// production consumer (documents, rules, actions) receives.
pub fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    errdefer tokens.deinit(allocator);
    try tokens.ensureTotalCapacity(allocator, @max(16, source.len / 8));
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
    }
}

pub fn tokenText(source: []const u8, token: std.zig.Token) []const u8 {
    return source[token.loc.start..token.loc.end];
}

pub fn tokenIs(source: []const u8, token: std.zig.Token, expected: []const u8) bool {
    return std.mem.eql(u8, tokenText(source, token), expected);
}

/// Index of the `closing_tag` that balances the `opening_tag` at `opening_index`.
pub fn matchingToken(tokens: []const std.zig.Token, opening_index: usize, opening_tag: Tag, closing_tag: Tag) ?usize {
    var depth: usize = 0;
    for (tokens[opening_index..], opening_index..) |token, index| {
        if (token.tag == opening_tag) depth += 1;
        if (token.tag != closing_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

/// `matchingToken` for a `(`, `{` or `[` at `opening`.
pub fn matchingDelimiter(tokens: []const std.zig.Token, opening: usize) ?usize {
    const closing_tag: Tag = switch (tokens[opening].tag) {
        .l_paren => .r_paren,
        .l_brace => .r_brace,
        .l_bracket => .r_bracket,
        else => return null,
    };
    return matchingToken(tokens, opening, tokens[opening].tag, closing_tag);
}

/// Index of the `;` ending the statement that starts at `start`, or null when a
/// closing brace of the enclosing block comes first.
pub fn statementEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[start..], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => {
                if (brace_depth == 0) return null;
                brace_depth -= 1;
            },
            .semicolon => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index,
            else => {},
        }
    }
    return null;
}

pub fn enclosingOpeningBrace(tokens: []const std.zig.Token, index: usize) ?usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => depth += 1,
            .l_brace => {
                if (depth == 0) return cursor;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

/// Whether `try` or an explicit `return error...` between `start` and `end`
/// can leave the block opened at `scope_opening`, either directly or from one
/// nested block, before code later in that block runs.
pub fn fallibleOperationBetween(tokens: []const std.zig.Token, start: usize, end: usize, scope_opening: usize) bool {
    for (tokens[start..end], start..) |token, index| {
        const fallible = token.tag == .keyword_try or
            (token.tag == .keyword_return and index + 1 < end and tokens[index + 1].tag == .keyword_error);
        if (!fallible) continue;
        const enclosing = enclosingOpeningBrace(tokens, index) orelse continue;
        if (enclosing == scope_opening) return true;
        if (enclosingOpeningBrace(tokens, enclosing) == scope_opening) return true;
    }
    return false;
}

/// Closing brace of the innermost block containing token `index`.
pub fn enclosingScopeEnd(tokens: []const std.zig.Token, index: usize) ?usize {
    const opening = enclosingOpeningBrace(tokens, index) orelse return null;
    return matchingToken(tokens, opening, .l_brace, .r_brace);
}

/// First token of kind `tag` in `[start, end)`.
pub fn findTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: Tag) ?usize {
    for (tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

/// First comma in `[start, end)` that is not nested in brackets.
pub fn topLevelComma(tokens: []const std.zig.Token, start: usize, end: usize) ?usize {
    var depth: usize = 0;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) return index,
        else => {},
    };
    return null;
}

/// Exclusive end of the arguments between the parentheses at `opening` and
/// `closing`: `closing`, or the trailing comma `zig fmt` writes after a
/// multi-line list. Null when there are no arguments.
pub fn argumentsEnd(tokens: []const std.zig.Token, opening: usize, closing: usize) ?usize {
    const end = if (closing > opening + 1 and tokens[closing - 1].tag == .comma) closing - 1 else closing;
    return if (end > opening + 1) end else null;
}

/// The three top-level arguments between the call parentheses at `opening` and
/// `closing`, or null for any other argument count or an empty argument.
pub fn threeArguments(tokens: []const std.zig.Token, opening: usize, closing: usize) ?[3]Range {
    var commas: [2]usize = undefined;
    var comma_count: usize = 0;
    var depth: usize = 0;
    for (tokens[opening + 1 .. closing], opening + 1..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            if (comma_count == commas.len) return null;
            commas[comma_count] = index;
            comma_count += 1;
        },
        else => {},
    };
    if (comma_count != 2 or commas[0] == opening + 1 or commas[1] == commas[0] + 1 or commas[1] + 1 == closing) return null;
    return .{
        .{ .start = opening + 1, .end = commas[0] },
        .{ .start = commas[0] + 1, .end = commas[1] },
        .{ .start = commas[1] + 1, .end = closing },
    };
}

/// Source text of the tokens in `range`, trimmed of surrounding whitespace.
pub fn rangeSource(source: []const u8, tokens: []const std.zig.Token, range: Range) []const u8 {
    return std.mem.trim(u8, source[tokens[range.start].loc.start..tokens[range.end - 1].loc.end], " \t\r\n");
}

/// Dotted identifier path (`a.b.c`, optionally ending in `.*`) as a token range.
pub fn pathBefore(tokens: []const std.zig.Token, before: usize) ?Range {
    if (before == 0) return null;
    var cursor = before;
    if (tokens[cursor - 1].tag == .period_asterisk) cursor -= 1;
    if (cursor == 0 or tokens[cursor - 1].tag != .identifier) return null;
    cursor -= 1;
    while (cursor >= 2 and tokens[cursor - 1].tag == .period and tokens[cursor - 2].tag == .identifier) cursor -= 2;
    return .{ .start = cursor, .end = before };
}

/// Dotted identifier path starting at `start`, optionally ending in `.*`.
pub fn pathAfter(tokens: []const std.zig.Token, start: usize) ?Range {
    if (start >= tokens.len or tokens[start].tag != .identifier) return null;
    var cursor = start + 1;
    while (cursor + 1 < tokens.len and tokens[cursor].tag == .period and tokens[cursor + 1].tag == .identifier) cursor += 2;
    if (cursor < tokens.len and tokens[cursor].tag == .period_asterisk) cursor += 1;
    return .{ .start = start, .end = cursor };
}

/// Whether `text`, a stretch of Zig source that starts between tokens, holds a
/// `//` comment (doc comments included). Slashes inside string and character
/// literals and multiline string lines are not comments.
pub fn containsComment(text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            '"', '\'' => |quote| {
                index += 1;
                while (index < text.len and text[index] != quote and text[index] != '\n') : (index += 1) {
                    if (text[index] == '\\') index += 1;
                }
            },
            '\\' => if (index + 1 < text.len and text[index + 1] == '\\') {
                while (index < text.len and text[index] != '\n') : (index += 1) {}
            },
            '/' => if (index + 1 < text.len and text[index + 1] == '/') return true,
            else => {},
        }
    }
    return false;
}

/// Zig character literal (`'x'`, `'\n'`, `'\x41'`) equal to the one-byte string
/// literal `text`, or null when `text` is not a one-byte string literal.
pub fn parseSingleByteLiteral(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (text.len < 3 or text[0] != '"' or text[text.len - 1] != '"') return null;
    const inner = text[1 .. text.len - 1];
    if (inner.len == 1) {
        if (inner[0] == '\\') return null;
        if (inner[0] == '\'') return try allocator.dupe(u8, "'\\''");
        return try allocator.print("'{c}'", .{inner[0]});
    }
    if (inner.len == 2 and inner[0] == '\\') {
        switch (inner[1]) {
            'n', 'r', 't', '\\', '0' => return try allocator.print("'\\{c}'", .{inner[1]}),
            '\'' => return try allocator.dupe(u8, "'\\''"),
            '"' => return try allocator.dupe(u8, "'\"'"),
            else => return null,
        }
    }
    if (inner.len == 4 and inner[0] == '\\' and inner[1] == 'x') {
        return try allocator.print("'{s}'", .{inner});
    }
    return null;
}

pub fn lineStart(source: []const u8, offset: usize) usize {
    return (std.mem.findScalarLast(u8, source[0..@min(offset, source.len)], '\n') orelse return 0) + 1;
}

pub fn lineEnd(source: []const u8, offset: usize) usize {
    const relative = std.mem.findScalar(u8, source[@min(offset, source.len)..], '\n') orelse return source.len;
    return @min(offset, source.len) + relative + 1;
}

/// The whole lines holding `[start, end)`, widened so deleting them leaves
/// formatted source: blank lines that would end up doubled, leading a block, or
/// trailing before its closing brace go with them.
pub fn removedLinesSpan(source: []const u8, start: usize, end: usize) std.zig.Token.Loc {
    var span: std.zig.Token.Loc = .{ .start = lineStart(source, start), .end = lineEnd(source, end) };
    const previous_line = if (span.start == 0) "" else std.mem.trimEnd(u8, source[lineStart(source, span.start - 1)..span.start], " \t\r\n");
    const blank_before = previous_line.len == 0 or previous_line[previous_line.len - 1] == '{';
    if (blank_before) {
        while (span.end < source.len and lineIsBlank(source, span.end)) span.end = lineEnd(source, span.end);
    }
    const next_line = std.mem.trimStart(u8, source[span.end..lineEnd(source, span.end)], " \t");
    const closes_block = next_line.len > 0 and next_line[0] == '}';
    if (closes_block) {
        while (span.start > 0 and lineIsBlank(source, lineStart(source, span.start - 1))) span.start = lineStart(source, span.start - 1);
    }
    return span;
}

fn lineIsBlank(source: []const u8, offset: usize) bool {
    return std.mem.trim(u8, source[lineStart(source, offset)..lineEnd(source, offset)], " \t\r\n").len == 0;
}

/// `text` with each line after the first moved out by one indentation level.
pub fn dedentContinuationLines(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(if (!first and std.mem.startsWith(u8, line, "    ")) line[4..] else line);
        first = false;
    }
    return try writer.toOwnedSlice();
}

pub fn lineIndentation(source: []const u8, offset: usize) []const u8 {
    const start = lineStart(source, offset);
    var end = start;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) : (end += 1) {}
    return source[start..end];
}

pub fn attachedCommentStart(source: []const u8, declaration_start: usize) usize {
    var start = declaration_start;
    while (start > 0) {
        const previous_end = start - 1;
        const previous_start = lineStart(source, previous_end);
        const previous_line = std.mem.trim(u8, source[previous_start..previous_end], " \t\r");
        if (!std.mem.startsWith(u8, previous_line, "//")) break;
        if (std.mem.startsWith(u8, previous_line, "//!")) break;
        start = previous_start;
    }
    return start;
}

pub fn matchingOpeningToken(
    tokens: []const std.zig.Token,
    closing_index: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    var cursor = closing_index + 1;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == closing_tag) depth += 1;
        if (tokens[cursor].tag != opening_tag) continue;
        depth -= 1;
        if (depth == 0) return cursor;
    }
    return null;
}

pub fn callExpressionStart(tokens: []const std.zig.Token, opening: usize) ?usize {
    if (opening == 0 or tokens[opening - 1].tag != .identifier) return null;
    var start = opening - 1;
    while (start >= 2 and tokens[start - 1].tag == .period) {
        switch (tokens[start - 2].tag) {
            .identifier => start -= 2,
            .r_paren => {
                const group_open = matchingOpeningToken(tokens, start - 2, .l_paren, .r_paren) orelse return null;
                if (group_open == 0 or tokens[group_open - 1].tag != .identifier) return null;
                start = group_open - 1;
            },
            .r_bracket => {
                const group_open = matchingOpeningToken(tokens, start - 2, .l_bracket, .r_bracket) orelse return null;
                if (group_open == 0 or tokens[group_open - 1].tag != .identifier) return null;
                start = group_open - 1;
            },
            else => return null,
        }
    }
    return start;
}

pub fn isAssignment(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal,
        .plus_equal,
        .plus_percent_equal,
        .plus_pipe_equal,
        .minus_equal,
        .minus_percent_equal,
        .minus_pipe_equal,
        .asterisk_equal,
        .asterisk_percent_equal,
        .asterisk_pipe_equal,
        .slash_equal,
        .percent_equal,
        .ampersand_equal,
        .pipe_equal,
        .caret_equal,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left_pipe_equal,
        .angle_bracket_angle_bracket_right_equal,
        => true,
        else => false,
    };
}

/// Index of the first `wanted` token at or after `start`, or null once `stop` comes first.
pub fn nextTagBefore(tokens: []const std.zig.Token, start: usize, wanted: std.zig.Token.Tag, stop: std.zig.Token.Tag) ?usize {
    for (tokens[start..], start..) |token, index| {
        if (token.tag == stop) return null;
        if (token.tag == wanted) return index;
    }
    return null;
}

/// First token of the statement containing `index`.
pub fn statementStart(tokens: []const std.zig.Token, index: usize) usize {
    var start = index;
    while (start > 0) {
        switch (tokens[start - 1].tag) {
            .semicolon, .l_brace, .r_brace => return start,
            else => start -= 1,
        }
    }
    return start;
}

/// Number of lines the byte range covers.
pub fn lineSpan(source: []const u8, start: usize, end: usize) usize {
    return std.mem.countScalar(u8, source[@min(start, source.len)..@min(end, source.len)], '\n') + 1;
}

/// A call `name(...)`, with the receiver identifier of `receiver.name(...)`.
pub const Call = struct {
    opening: usize,
    closing: usize,
    name_index: usize,
    receiver_index: ?usize,
};

/// The first call whose parentheses close within `[start, end]`.
pub fn firstCall(tokens: []const std.zig.Token, start: usize, end: usize) ?Call {
    for (tokens[start..end], start..) |token, opening| {
        if (token.tag != .l_paren or opening == 0 or tokens[opening - 1].tag != .identifier) continue;
        const closing = matchingToken(tokens, opening, .l_paren, .r_paren) orelse continue;
        if (closing > end) continue;
        return .{
            .opening = opening,
            .closing = closing,
            .name_index = opening - 1,
            .receiver_index = if (opening >= 3 and tokens[opening - 2].tag == .period and
                tokens[opening - 3].tag == .identifier) opening - 3 else null,
        };
    }
    return null;
}

/// Whether the `fn` or `const` token at `index` declares an `extern` or
/// `export` symbol, whose spelling the Zig source does not choose.
pub fn foreignDeclaration(tokens: []const std.zig.Token, index: usize) bool {
    if (index > 0 and (tokens[index - 1].tag == .keyword_extern or tokens[index - 1].tag == .keyword_export)) return true;
    return index > 1 and tokens[index - 1].tag == .string_literal and tokens[index - 2].tag == .keyword_extern;
}

pub fn insideFunctionOrTestBody(tokens: []const std.zig.Token, declaration_index: usize) bool {
    var nested_closing_braces: usize = 0;
    var cursor = declaration_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => nested_closing_braces += 1,
            .l_brace => {
                if (nested_closing_braces != 0) {
                    nested_closing_braces -= 1;
                    continue;
                }
                var signature_cursor = cursor;
                while (signature_cursor > 0) {
                    signature_cursor -= 1;
                    switch (tokens[signature_cursor].tag) {
                        .keyword_fn, .keyword_test => return true,
                        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return false,
                        .semicolon, .l_brace, .r_brace => break,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

test "tokenize keeps the trailing eof token" {
    const tokens = try tokenize(std.testing.allocator, "const x = 1;");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 6), tokens.len);
    try std.testing.expectEqual(Tag.eof, tokens[tokens.len - 1].tag);
}

const sample: [:0]const u8 = "fn f(a: u8, b: [2]u8) u8 { const x = g(a, b[0], (1 + 2)); return x; }";

test "delimiters, statements and scopes" {
    const tokens = try tokenize(std.testing.allocator, sample);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(Tag.r_paren, tokens[matchingToken(tokens, 2, .l_paren, .r_paren).?].tag);
    try std.testing.expectEqual(Tag.r_paren, tokens[matchingDelimiter(tokens, 2).?].tag);
    try std.testing.expectEqual(@as(?usize, null), matchingDelimiter(tokens, 0));
    const declaration = findTag(tokens, 0, tokens.len, .keyword_const).?;
    try std.testing.expectEqual(Tag.semicolon, tokens[statementEnd(tokens, declaration).?].tag);
    try std.testing.expectEqual(@as(?usize, null), enclosingOpeningBrace(tokens, 0));
    try std.testing.expectEqual(Tag.l_brace, tokens[enclosingOpeningBrace(tokens, declaration).?].tag);
    try std.testing.expectEqual(Tag.r_brace, tokens[enclosingScopeEnd(tokens, declaration).?].tag);
    try std.testing.expectEqualStrings("fn", tokenText(sample, tokens[0]));
    try std.testing.expect(tokenIs(sample, tokens[1], "f"));
}

test "arguments split at top-level commas only" {
    const tokens = try tokenize(std.testing.allocator, sample);
    defer std.testing.allocator.free(tokens);
    const call = findTag(tokens, 0, tokens.len, .identifier).?;
    var open: usize = call;
    while (tokens[open].tag != .l_paren or tokens[open - 1].tag != .identifier or !tokenIs(sample, tokens[open - 1], "g")) open += 1;
    const close = matchingDelimiter(tokens, open).?;
    const arguments = threeArguments(tokens, open, close).?;
    try std.testing.expectEqualStrings("a", rangeSource(sample, tokens, arguments[0]));
    try std.testing.expectEqualStrings("b[0]", rangeSource(sample, tokens, arguments[1]));
    try std.testing.expectEqualStrings("(1 + 2)", rangeSource(sample, tokens, arguments[2]));
    try std.testing.expectEqual(@as(?[3]Range, null), threeArguments(tokens, 2, matchingDelimiter(tokens, 2).?));
    try std.testing.expectEqual(arguments[1].start - 1, topLevelComma(tokens, arguments[0].start, close).?);
}

test "paths extend over fields and dereference" {
    const source: [:0]const u8 = "a.b.c.* == d";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const after = pathAfter(tokens, 0).?;
    try std.testing.expectEqualStrings("a.b.c.*", source[tokens[after.start].loc.start..tokens[after.end - 1].loc.end]);
    const before = pathBefore(tokens, after.end).?;
    try std.testing.expectEqual(@as(usize, 0), before.start);
    try std.testing.expectEqual(@as(?Range, null), pathAfter(tokens, tokens.len - 1));
}

test "one-byte string literals become character literals" {
    const a = std.testing.allocator;
    const plain = (try parseSingleByteLiteral(a, "\"x\"")).?;
    defer a.free(plain);
    try std.testing.expectEqualStrings("'x'", plain);
    const newline = (try parseSingleByteLiteral(a, "\"\\n\"")).?;
    defer a.free(newline);
    try std.testing.expectEqualStrings("'\\n'", newline);
    try std.testing.expectEqual(@as(?[]const u8, null), try parseSingleByteLiteral(a, "\"xy\""));
    try std.testing.expectEqual(@as(?[]const u8, null), try parseSingleByteLiteral(a, "\"\\\""));
}

test "comments are recognized outside literals only" {
    try std.testing.expect(containsComment("x // note"));
    try std.testing.expect(containsComment("/// doc"));
    try std.testing.expect(!containsComment("const url = \"http://example\";"));
    try std.testing.expect(!containsComment("const c = '/'; const d = \"\\\"//\";"));
    try std.testing.expect(!containsComment("const s =\n    \\\\ // text\n;"));
    try std.testing.expect(containsComment("const s = \"a\"; // after"));
    try std.testing.expect(!containsComment("a /* not zig */ b"));
}
