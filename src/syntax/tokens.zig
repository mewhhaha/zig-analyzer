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

/// How deeply `(`, `{` and `[` may nest in a file the analyzer parses.
/// `std.zig.Ast.parse` recurses at every level, so a pasted minified or
/// generated blob nested far deeper would overflow the stack (a Debug build
/// fails near 2000 parentheses on an 8 MiB stack); such a file is skipped
/// instead. Real code stays near 20 levels; clang stops at the same 256.
pub const max_nesting_depth = 256;

/// How many `else if` links one chain may have. The parser also recurses per
/// link, though far less steeply (a Debug build on an 8 MiB stack still
/// parses 5000); real chains reach about 250.
pub const max_else_if_chain = 2000;

/// Index of the first token nesting past `max_nesting_depth` or
/// `max_else_if_chain`, or null when `tokens` are safe to parse.
pub fn excessiveNesting(tokens: []const std.zig.Token) ?usize {
    // The `else if` links of the chain running at each bracket level. A chain
    // ends at a `;` or `,` there, or at a `}` back at its level not followed
    // by `else`.
    var chains: [max_nesting_depth + 1]usize = @splat(0);
    var depth: usize = 0;
    for (tokens, 0..) |token, index| switch (token.tag) {
        .l_paren, .l_brace, .l_bracket => {
            depth += 1;
            if (depth > max_nesting_depth) return index;
            chains[depth] = 0;
        },
        .r_paren, .r_bracket => depth -|= 1,
        .r_brace => {
            depth -|= 1;
            if (index + 1 < tokens.len and tokens[index + 1].tag != .keyword_else) chains[depth] = 0;
        },
        .semicolon, .comma => chains[depth] = 0,
        .keyword_else => if (index + 1 < tokens.len and tokens[index + 1].tag == .keyword_if) {
            chains[depth] += 1;
            if (chains[depth] > max_else_if_chain) return index;
        },
        else => {},
    };
    return null;
}

pub fn tokenText(source: []const u8, token: std.zig.Token) []const u8 {
    return source[token.loc.start..token.loc.end];
}

pub fn tokenIs(source: []const u8, token: std.zig.Token, expected: []const u8) bool {
    return std.mem.eql(u8, tokenText(source, token), expected);
}

/// The name an identifier spelling denotes: `@"name"` and `name` are the same
/// identifier. Escape sequences inside the quotes are left as written.
pub fn identifierName(spelling: []const u8) []const u8 {
    if (spelling.len >= 3 and spelling[0] == '@' and spelling[1] == '"' and spelling[spelling.len - 1] == '"') {
        return spelling[2 .. spelling.len - 1];
    }
    return spelling;
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

/// End of the type that starts at `start` in a field or parameter: the first
/// `,`, `=`, `{`, `}` or `;` before `end` outside parentheses and brackets, or
/// `end`.
pub fn fieldTypeEnd(tokens: []const std.zig.Token, start: usize, end: usize) usize {
    var depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) switch (tokens[index].tag) {
        .l_paren, .l_bracket => depth += 1,
        .r_paren, .r_bracket => depth -|= 1,
        .comma, .equal, .l_brace, .r_brace, .semicolon => if (depth == 0) return index,
        else => {},
    };
    return end;
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

/// Whether `[start, end)` is exactly a dotted identifier path (`a`, `a.b.c`).
pub fn isDottedPath(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    if (start >= end) return false;
    for (tokens[start..end], 0..) |token, offset| {
        const expected: Tag = if (offset % 2 == 0) .identifier else .period;
        if (token.tag != expected) return false;
    }
    return (end - start) % 2 == 1;
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

/// The operands of the binary `node` when both are the same dotted identifier
/// path (`a.b.c`, optionally dereferenced). Reasoning over the node rather than
/// neighbouring tokens keeps operator precedence out of the rule.
pub fn identicalPathOperands(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?[2]std.zig.Ast.Node.Index {
    const left, const right = tree.nodeData(node).node_and_node;
    return if (identicalPaths(tree, left, right)) .{ left, right } else null;
}

/// Whether both nodes are the same dotted identifier path, optionally dereferenced.
pub fn identicalPaths(tree: *const std.zig.Ast, left: std.zig.Ast.Node.Index, right: std.zig.Ast.Node.Index) bool {
    if (!isPathNode(tree, left) or !isPathNode(tree, right)) return false;
    return std.mem.eql(u8, tree.getNodeSource(left), tree.getNodeSource(right));
}

fn isPathNode(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .identifier => true,
        .field_access => isPathNode(tree, tree.nodeData(node).node_and_token[0]),
        .deref => isPathNode(tree, tree.nodeData(node).node),
        else => false,
    };
}

/// Whether `text`, a stretch of Zig source that starts between tokens, holds a
/// `//` comment (doc comments included). Slashes inside string and character
/// literals and multiline string lines are not comments.
pub fn containsComment(text: []const u8) bool {
    return commentStart(text) != null;
}

/// Offset of the first `//` comment in `text`, read as `containsComment` does.
pub fn commentStart(text: []const u8) ?usize {
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
            '/' => if (index + 1 < text.len and text[index + 1] == '/') return index,
            else => {},
        }
    }
    return null;
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

/// End of the text of the line holding `offset`: the offset of its `\n`, or
/// `source.len` on the last line. Unlike `lineEnd`, it excludes the newline.
pub fn lineContentEnd(source: []const u8, offset: usize) usize {
    return std.mem.findScalarPos(u8, source, @min(offset, source.len), '\n') orelse source.len;
}

/// The offset every line of `source` starts at: 0, then one past each `\n`.
pub fn lineStarts(allocator: std.mem.Allocator, source: []const u8) ![]usize {
    const starts = try allocator.alloc(usize, std.mem.countScalar(u8, source, '\n') + 1);
    starts[0] = 0;
    var line: usize = 1;
    var offset: usize = 0;
    while (std.mem.findScalarPos(u8, source, offset, '\n')) |newline| : (line += 1) {
        offset = newline + 1;
        starts[line] = offset;
    }
    return starts;
}

/// The 0-based line holding `offset`, given the `lineStarts` of its source.
pub fn lineOf(line_starts: []const usize, offset: usize) usize {
    return std.sort.partitionPoint(usize, line_starts, offset, struct {
        fn startsAtOrBefore(target: usize, start: usize) bool {
            return start <= target;
        }
    }.startsAtOrBefore) - 1;
}

/// The whole lines holding `[start, end)`, widened so deleting them leaves
/// formatted source: blank lines that would end up doubled, leading a block or
/// the file, or trailing before its closing brace or the end of the file go
/// with them.
pub fn removedLinesSpan(source: []const u8, start: usize, end: usize) std.zig.Token.Loc {
    var span: std.zig.Token.Loc = .{ .start = lineStart(source, start), .end = lineEnd(source, end) };
    const previous_line = if (span.start == 0) "" else std.mem.trimEnd(u8, source[lineStart(source, span.start - 1)..span.start], " \t\r\n");
    const blank_before = previous_line.len == 0 or previous_line[previous_line.len - 1] == '{';
    if (blank_before) {
        while (span.end < source.len and lineIsBlank(source, span.end)) span.end = lineEnd(source, span.end);
    }
    const next_line = std.mem.trimStart(u8, source[span.end..lineEnd(source, span.end)], " \t");
    const closes_block = span.end >= source.len or next_line.len > 0 and next_line[0] == '}';
    if (closes_block) {
        while (span.start > 0 and lineIsBlank(source, lineStart(source, span.start - 1))) span.start = lineStart(source, span.start - 1);
    }
    // A block left with nothing in it is written `{}`.
    if (closes_block and span.end < source.len and span.start > 0) {
        const opening_line = source[lineStart(source, span.start - 1) .. span.start - 1];
        const opening = std.mem.trim(u8, opening_line, " \t\r");
        if (opening.len != 0 and opening[opening.len - 1] == '{' and
            !std.mem.startsWith(u8, opening, "//") and !std.mem.startsWith(u8, opening, "\\\\"))
        {
            const brace_end = lineStart(source, span.start - 1) + std.mem.trimEnd(u8, opening_line, " \t\r").len;
            const closing = span.end + (lineEnd(source, span.end) - span.end - next_line.len);
            return .{ .start = brace_end, .end = closing };
        }
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

/// First token of the dotted identifier path (`a.b.c`) right before the call
/// parentheses at `opening`, or null when no identifier precedes them. Unlike
/// `callExpressionStart`, a call or index in the chain ends the path, so
/// `a().b(` starts at `b`.
pub fn dottedCalleeStart(tokens: []const std.zig.Token, opening: usize) ?usize {
    if (opening == 0 or tokens[opening - 1].tag != .identifier) return null;
    var start = opening - 1;
    while (start >= 2 and tokens[start - 1].tag == .period and tokens[start - 2].tag == .identifier) start -= 2;
    return start;
}

/// Whether `tag` is one of the six comparison operators.
pub fn isComparison(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .equal_equal,
        .bang_equal,
        => true,
        else => false,
    };
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

/// Closing brace of the block of the `test`, `test "name"` or `test name` declaration at `test_index`.
pub fn testBlockEnd(tokens: []const std.zig.Token, test_index: usize) ?usize {
    if (tokens[test_index].tag != .keyword_test) return null;
    var opening = test_index + 1;
    if (opening < tokens.len and (tokens[opening].tag == .string_literal or tokens[opening].tag == .identifier)) opening += 1;
    if (opening >= tokens.len or tokens[opening].tag != .l_brace) return null;
    return matchingToken(tokens, opening, .l_brace, .r_brace);
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

/// Whether `[start, end)` is a `+`-separated sum of `.len` paths and number
/// literals with at least one length (`a.len + 1 + b.len`). Lengths of objects
/// in memory cannot add up past `usize`, so such a sum cannot wrap.
pub fn lengthSum(source: []const u8, tokens: []const std.zig.Token, start: usize, end: usize) bool {
    var cursor = start;
    var lengths: usize = 0;
    while (cursor < end) {
        if (tokens[cursor].tag == .number_literal) {
            cursor += 1;
        } else {
            var term_end = cursor;
            while (term_end < end and tokens[term_end].tag != .plus) : (term_end += 1) {}
            if (!lengthPath(source, tokens, cursor, term_end)) return false;
            lengths += 1;
            cursor = term_end;
        }
        if (cursor == end) break;
        if (tokens[cursor].tag != .plus) return false;
        cursor += 1;
    }
    return lengths != 0 and cursor == end;
}

/// Whether `[start, end)` is a dotted path ending in `.len`.
pub fn lengthPath(source: []const u8, tokens: []const std.zig.Token, start: usize, end: usize) bool {
    if (end < start + 3 or !tokenIs(source, tokens[end - 1], "len") or (end - start) % 2 == 0) return false;
    for (tokens[start..end], 0..) |token, offset| {
        if (token.tag != if (offset % 2 == 0) Tag.identifier else .period) return false;
    }
    return true;
}

/// What a primitive number type name spells.
pub const NumberKind = enum { unsigned, signed, float };

/// The kind of the primitive number type `name` (`u8`, `usize`, `i64`,
/// `c_int`, `f32`, `comptime_float`), or null for any other name.
pub fn primitiveNumberKind(name: []const u8) ?NumberKind {
    const unsigned_c = [_][]const u8{ "usize", "c_uint", "c_ushort", "c_ulong", "c_ulonglong" };
    const signed_c = [_][]const u8{ "isize", "c_int", "c_short", "c_long", "c_longlong", "comptime_int" };
    const floats = [_][]const u8{ "f16", "f32", "f64", "f80", "f128", "c_longdouble", "comptime_float" };
    for (unsigned_c) |known| if (std.mem.eql(u8, name, known)) return .unsigned;
    for (signed_c) |known| if (std.mem.eql(u8, name, known)) return .signed;
    for (floats) |known| if (std.mem.eql(u8, name, known)) return .float;
    if (name.len < 2) return null;
    const kind: NumberKind = switch (name[0]) {
        'u' => .unsigned,
        'i' => .signed,
        else => return null,
    };
    for (name[1..]) |byte| if (!std.ascii.isDigit(byte)) return null;
    return kind;
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

test "nesting past the limit is found at its first excess bracket" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "const x = ");
    try text.appendNTimes(allocator, '(', max_nesting_depth - 1);
    try text.appendSlice(allocator, "[1]");
    try text.appendNTimes(allocator, ')', max_nesting_depth - 1);
    try text.appendSlice(allocator, "; fn f() void {}\x00");
    const balanced = try tokenize(allocator, text.items[0 .. text.items.len - 1 :0]);
    defer allocator.free(balanced);
    try std.testing.expectEqual(@as(?usize, null), excessiveNesting(balanced));

    text.clearRetainingCapacity();
    try text.appendSlice(allocator, "const x = ");
    try text.appendNTimes(allocator, '{', max_nesting_depth);
    try text.appendSlice(allocator, "(\x00");
    const deep = try tokenize(allocator, text.items[0 .. text.items.len - 1 :0]);
    defer allocator.free(deep);
    try std.testing.expectEqual(Tag.l_paren, deep[excessiveNesting(deep).?].tag);
}

test "else-if chains count their links, and separate statements do not chain" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "fn f(a: u32) u32 { if (a == 0) { return 0; }");
    for (0..max_else_if_chain) |_| try text.appendSlice(allocator, " else if (a == 1) { return 1; }");
    // Statements one after another, and an expression chain ended by `;`.
    for (0..max_else_if_chain) |_| try text.appendSlice(allocator, " if (a == 2) { return 2; } else if (a == 3) {}");
    for (0..2) |_| {
        try text.appendSlice(allocator, " _ = if (a == 4) 4");
        for (0..max_else_if_chain / 2 + 1) |_| try text.appendSlice(allocator, " else if (a == 5) 5");
        try text.appendSlice(allocator, " else 6;");
    }
    try text.appendSlice(allocator, " return 7; }\x00");
    const longest = try tokenize(allocator, text.items[0 .. text.items.len - 1 :0]);
    defer allocator.free(longest);
    try std.testing.expectEqual(@as(?usize, null), excessiveNesting(longest));

    text.items.len -= " return 7; }\x00".len;
    try text.appendSlice(allocator, " if (a == 8) {} else if (a == 9) {}");
    for (0..max_else_if_chain) |_| try text.appendSlice(allocator, " else if (a == 9) {}");
    try text.appendSlice(allocator, " }\x00");
    const too_long = try tokenize(allocator, text.items[0 .. text.items.len - 1 :0]);
    defer allocator.free(too_long);
    const excess = excessiveNesting(too_long).?;
    try std.testing.expectEqual(Tag.keyword_else, too_long[excess].tag);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text.items[too_long[excess].loc.start..], "else"));
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
    try std.testing.expect(isDottedPath(tokens, 0, 5));
    try std.testing.expect(!isDottedPath(tokens, 0, 4));
    try std.testing.expect(!isDottedPath(tokens, 0, 6));
    try std.testing.expect(!isDottedPath(tokens, 0, 0));
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

test "sums of lengths and literals are recognized" {
    const source: [:0]const u8 = "_ = .{ a.len + 1 + b.c.len, a.len, 1 + 2, a.len + b, a.len + b.len * 2 };";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const Case = struct { start: usize, end: usize, expected: bool };
    const cases = [_]Case{
        .{ .start = 4, .end = 15, .expected = true },
        .{ .start = 16, .end = 19, .expected = true },
        .{ .start = 20, .end = 23, .expected = false },
        .{ .start = 24, .end = 29, .expected = false },
        .{ .start = 30, .end = 39, .expected = false },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, lengthSum(source, tokens, case.start, case.end));
    try std.testing.expect(lengthPath(source, tokens, 10, 15));
    try std.testing.expect(!lengthPath(source, tokens, 9, 15));
}

test "line starts locate the line of every offset" {
    const source = "ab\n\ncd\n";
    const starts = try lineStarts(std.testing.allocator, source);
    defer std.testing.allocator.free(starts);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 4, 7 }, starts);
    for ([_]usize{ 0, 0, 0, 1, 2, 2, 2, 3 }, 0..) |line, offset| try std.testing.expectEqual(line, lineOf(starts, offset));
    try std.testing.expectEqual(@as(usize, 3), lineOf(starts, 100));
}

test "comments are recognized outside literals only" {
    try std.testing.expect(containsComment("x // note"));
    try std.testing.expect(containsComment("/// doc"));
    try std.testing.expect(!containsComment("const url = \"http://example\";"));
    try std.testing.expect(!containsComment("const c = '/'; const d = \"\\\"//\";"));
    try std.testing.expect(!containsComment("const s =\n    \\\\ // text\n;"));
    try std.testing.expect(containsComment("const s = \"a\"; // after"));
    try std.testing.expect(!containsComment("a /* not zig */ b"));
    try std.testing.expectEqual(@as(?usize, 16), commentStart("const s = \"//\"; // after"));
}

test "removing a block's only statement leaves an empty block" {
    const cases = [_]struct { source: []const u8, line: []const u8, expected: []const u8 }{
        .{ .source = "fn f(x: u32) void {\n    if (x > 3) {\n        _ = x;\n    }\n}\n", .line = "_ = x;", .expected = "fn f(x: u32) void {\n    if (x > 3) {}\n}\n" },
        .{ .source = "const S = struct {\n    // keep {\n    const a = 1;\n};\n", .line = "const a = 1;", .expected = "const S = struct {\n    // keep {\n};\n" },
        .{ .source = "fn f() void {\n    one();\n    two();\n}\n", .line = "two();", .expected = "fn f() void {\n    one();\n}\n" },
    };
    for (cases) |case| {
        const start = std.mem.find(u8, case.source, case.line).?;
        const span = removedLinesSpan(case.source, start, start + case.line.len);
        const result = try std.mem.concat(std.testing.allocator, u8, &.{ case.source[0..span.start], case.source[span.end..] });
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case.expected, result);
    }
}
