//! Source lines wider than the configured display-column limit.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{.line_length};

pub fn run(context: RuleRun) !void {
    const level = context.level(.line_length);
    if (level == .off) return;
    const limit = context.configuration.line_length_limit;
    var start: usize = 0;
    // The first token at or after the current line; tokens are in source
    // order, so one cursor serves every line of the file.
    var first_token: usize = 0;
    while (start < context.source.len) {
        const relative_end = std.mem.findScalar(u8, context.source[start..], '\n') orelse context.source.len - start;
        const end = start + relative_end;
        // A CRLF line ending is not part of the line's width.
        const line = std.mem.trimEnd(u8, context.source[start..end], "\r");
        const columns = displayColumns(line);
        if (columns > limit) {
            while (first_token < context.tokens.len and context.tokens[first_token].loc.start < start) first_token += 1;
            if (!context.configuration.line_length_allow_unsplittable or
                !unsplittable(context, .{ .text = line, .start = start, .columns = columns, .first_token = first_token }))
            {
                try context.emit(.{
                    .rule = .line_length,
                    .level = level,
                    .span = .{ .start = start, .end = start + line.len },
                    .message = try context.allocator.print("line is {d} display columns, exceeding the configured limit of {d}", .{ columns, limit }),
                });
            }
        }
        if (end == context.source.len) break;
        start = end + 1;
    }
}

/// Terminal columns of `line`: tabs advance to the next multiple of eight,
/// East Asian wide characters and emoji take two columns, combining marks
/// none, and a byte that is not valid UTF-8 one.
fn displayColumns(line: []const u8) usize {
    var columns: usize = 0;
    var index: usize = 0;
    while (index < line.len) {
        if (decodeAt(line, index)) |decoded| {
            columns += if (decoded.codepoint == '\t') 8 - (columns % 8) else codepointWidth(decoded.codepoint);
            index += decoded.length;
        } else {
            columns += 1;
            index += 1;
        }
    }
    return columns;
}

const Decoded = struct { codepoint: u21, length: usize };

/// The code point encoded at `index`, or null when the bytes there are not
/// valid UTF-8.
fn decodeAt(line: []const u8, index: usize) ?Decoded {
    const length = std.unicode.utf8ByteSequenceLength(line[index]) catch return null;
    if (index + length > line.len) return null;
    const bytes = line[index..][0..length];
    const codepoint: u21 = switch (length) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch return null,
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch return null,
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch return null,
        else => return null,
    };
    return .{ .codepoint = codepoint, .length = length };
}

fn codepointWidth(codepoint: u21) usize {
    if (codepoint < 0x300) return 1;
    if (inRanges(codepoint, &zero_width)) return 0;
    if (inRanges(codepoint, &double_width)) return 2;
    return 1;
}

const Range = struct { u21, u21 };

/// Whether `codepoint` lies in one of the sorted, disjoint `ranges`.
fn inRanges(codepoint: u21, ranges: []const Range) bool {
    for (ranges) |range| {
        if (codepoint < range[0]) return false;
        if (codepoint <= range[1]) return true;
    }
    return false;
}

/// Combining marks, zero-width spaces and joiners, and variation selectors.
const zero_width = [_]Range{
    .{ 0x0300, 0x036f },   .{ 0x0483, 0x0489 }, .{ 0x0591, 0x05bd }, .{ 0x0610, 0x061a },
    .{ 0x064b, 0x065f },   .{ 0x0e31, 0x0e31 }, .{ 0x0e34, 0x0e3a }, .{ 0x0e47, 0x0e4e },
    .{ 0x1ab0, 0x1aff },   .{ 0x1dc0, 0x1dff }, .{ 0x200b, 0x200f }, .{ 0x2060, 0x2064 },
    .{ 0x20d0, 0x20ff },   .{ 0xfe00, 0xfe0f }, .{ 0xfe20, 0xfe2f }, .{ 0xfeff, 0xfeff },
    .{ 0xe0100, 0xe01ef },
};

/// East Asian Wide and Fullwidth characters and emoji presentation symbols.
const double_width = [_]Range{
    .{ 0x1100, 0x115f },   .{ 0x231a, 0x231b },   .{ 0x2329, 0x232a },   .{ 0x23e9, 0x23ec },
    .{ 0x23f0, 0x23f0 },   .{ 0x23f3, 0x23f3 },   .{ 0x25fd, 0x25fe },   .{ 0x2614, 0x2615 },
    .{ 0x2648, 0x2653 },   .{ 0x267f, 0x267f },   .{ 0x2693, 0x2693 },   .{ 0x26a1, 0x26a1 },
    .{ 0x26aa, 0x26ab },   .{ 0x26bd, 0x26be },   .{ 0x26c4, 0x26c5 },   .{ 0x26ce, 0x26ce },
    .{ 0x26d4, 0x26d4 },   .{ 0x26ea, 0x26ea },   .{ 0x26f2, 0x26f3 },   .{ 0x26f5, 0x26f5 },
    .{ 0x26fa, 0x26fa },   .{ 0x26fd, 0x26fd },   .{ 0x2705, 0x2705 },   .{ 0x270a, 0x270b },
    .{ 0x2728, 0x2728 },   .{ 0x274c, 0x274c },   .{ 0x274e, 0x274e },   .{ 0x2753, 0x2755 },
    .{ 0x2757, 0x2757 },   .{ 0x2795, 0x2797 },   .{ 0x27b0, 0x27b0 },   .{ 0x27bf, 0x27bf },
    .{ 0x2b1b, 0x2b1c },   .{ 0x2b50, 0x2b50 },   .{ 0x2b55, 0x2b55 },   .{ 0x2e80, 0x303e },
    .{ 0x3041, 0x33ff },   .{ 0x3400, 0x4dbf },   .{ 0x4e00, 0x9fff },   .{ 0xa000, 0xa4cf },
    .{ 0xa960, 0xa97f },   .{ 0xac00, 0xd7a3 },   .{ 0xf900, 0xfaff },   .{ 0xfe10, 0xfe19 },
    .{ 0xfe30, 0xfe6f },   .{ 0xff00, 0xff60 },   .{ 0xffe0, 0xffe6 },   .{ 0x16fe0, 0x16fe4 },
    .{ 0x17000, 0x18cff }, .{ 0x1b000, 0x1b2ff }, .{ 0x1f004, 0x1f004 }, .{ 0x1f0cf, 0x1f0cf },
    .{ 0x1f18e, 0x1f18e }, .{ 0x1f191, 0x1f19a }, .{ 0x1f200, 0x1f202 }, .{ 0x1f210, 0x1f23b },
    .{ 0x1f240, 0x1f248 }, .{ 0x1f250, 0x1f251 }, .{ 0x1f260, 0x1f265 }, .{ 0x1f300, 0x1f320 },
    .{ 0x1f32d, 0x1f335 }, .{ 0x1f337, 0x1f37c }, .{ 0x1f37e, 0x1f393 }, .{ 0x1f3a0, 0x1f3ca },
    .{ 0x1f3cf, 0x1f3d3 }, .{ 0x1f3e0, 0x1f3f0 }, .{ 0x1f3f4, 0x1f3f4 }, .{ 0x1f3f8, 0x1f43e },
    .{ 0x1f440, 0x1f440 }, .{ 0x1f442, 0x1f4fc }, .{ 0x1f4ff, 0x1f53d }, .{ 0x1f54b, 0x1f54e },
    .{ 0x1f550, 0x1f567 }, .{ 0x1f57a, 0x1f57a }, .{ 0x1f595, 0x1f596 }, .{ 0x1f5a4, 0x1f5a4 },
    .{ 0x1f5fb, 0x1f64f }, .{ 0x1f680, 0x1f6c5 }, .{ 0x1f6cc, 0x1f6cc }, .{ 0x1f6d0, 0x1f6d2 },
    .{ 0x1f6d5, 0x1f6d7 }, .{ 0x1f6dc, 0x1f6df }, .{ 0x1f6eb, 0x1f6ec }, .{ 0x1f6f4, 0x1f6fc },
    .{ 0x1f7e0, 0x1f7eb }, .{ 0x1f7f0, 0x1f7f0 }, .{ 0x1f90c, 0x1f93a }, .{ 0x1f93c, 0x1f945 },
    .{ 0x1f947, 0x1f9ff }, .{ 0x1fa70, 0x1faff }, .{ 0x20000, 0x2fffd }, .{ 0x30000, 0x3fffd },
};

/// A line beyond the limit.
const Line = struct {
    text: []const u8,
    /// Byte offset of `text` in the source.
    start: usize,
    columns: usize,
    /// The first token starting at or after `start`.
    first_token: usize,
};

/// Whether the line cannot be wrapped: it names a URL, it is one token
/// without whitespace, its only token is a string literal (optionally
/// followed by `,`, `;`, closing delimiters or `++`), it is a row of a data
/// table, or one string literal overflows by itself. A `\\` multiline string
/// line is part of the string's value, so it can never be split.
fn unsplittable(context: RuleRun, line: Line) bool {
    const trimmed = std.mem.trim(u8, line.text, " \t");
    if (std.mem.find(u8, trimmed, "http://") != null or std.mem.find(u8, trimmed, "https://") != null) return true;
    if (std.mem.findAny(u8, trimmed, " \t") == null) return true;
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return true;
    if (loneStringLiteral(trimmed)) return true;
    // Tokens from `first_token` on start at or after the line's start.
    var end_token = line.first_token;
    while (end_token < context.tokens.len and context.tokens[end_token].tag != .eof and
        context.tokens[end_token].loc.start - line.start < line.text.len) end_token += 1;
    if (end_token == line.first_token) return false;
    return tableRow(context, line, end_token) or stringOverflows(context, line, end_token);
}

/// Whether the tokens of the line, which end before `end_token`, are whole
/// elements of an initializer list built only from literals, names, enum and
/// decl literals, and nested initializers, as the rows of a data table are
/// (`.{ .seed = 0, .hash = 0x1766974bf7527d81, .b64 = "ICAg" },`). `zig fmt`
/// keeps such a row on one line, and wrapping it by hand breaks the table's
/// columns. A row whose code fits is reported, since its trailing comment can
/// move above it.
fn tableRow(context: RuleRun, line: Line, end_token: usize) bool {
    const tokens = context.tokens;
    const first = line.first_token;
    if (first == 0 or tokens[end_token - 1].tag != .comma) return false;
    switch (tokens[first - 1].tag) {
        .l_brace, .comma => {},
        else => return false,
    }
    var depth: usize = 0;
    for (tokens[first .. end_token - 1], first..) |token, index| {
        const previous = tokens[index - 1].tag;
        const element_start = switch (previous) {
            .l_brace, .l_paren, .comma, .equal => true,
            else => false,
        };
        switch (token.tag) {
            .number_literal, .string_literal, .char_literal, .identifier, .comma => {},
            .minus, .ampersand => if (!element_start) return false,
            .period => if (tokens[index + 1].tag != .identifier and tokens[index + 1].tag != .l_brace) return false,
            // `.field = value`
            .equal => if (index < first + 2 or previous != .identifier or tokens[index - 2].tag != .period or
                (index - 2 != first and tokens[index - 3].tag != .l_brace and tokens[index - 3].tag != .comma)) return false,
            .l_brace => {
                if (previous != .period and previous != .identifier) return false;
                depth += 1;
            },
            // A decl literal call, `.memia(.src0b, .tmp0, .add_size)`.
            .l_paren => {
                if (index < first + 2 or previous != .identifier or tokens[index - 2].tag != .period) return false;
                if (index - 2 != first) switch (tokens[index - 3].tag) {
                    .l_brace, .l_paren, .comma, .equal => {},
                    else => return false,
                };
                depth += 1;
            },
            .r_brace, .r_paren => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => return false,
        }
    }
    if (depth != 0) return false;
    const code_end = tokens[end_token - 1].loc.end - line.start;
    return displayColumns(line.text[0..code_end]) > context.configuration.line_length_limit;
}

/// Whether one string literal is what overflows: the rest of the line fits,
/// and the literal is too wide even for a continuation line of its own, so
/// only splitting the string itself would help. A `test` name cannot move at
/// all, so the rest fitting is enough.
fn stringOverflows(context: RuleRun, line: Line, end_token: usize) bool {
    var widest: ?usize = null;
    var widest_columns: usize = 0;
    for (context.tokens[line.first_token..end_token], line.first_token..) |token, index| {
        if (token.tag != .string_literal) continue;
        const columns = displayColumns(context.tokenText(index));
        if (columns > widest_columns) {
            widest = index;
            widest_columns = columns;
        }
    }
    const string = widest orelse return false;
    const limit = context.configuration.line_length_limit;
    if (line.columns - widest_columns > limit) return false;
    if (context.tokens[line.first_token].tag == .keyword_test and string == line.first_token + 1) return true;
    const indentation = displayColumns(line.text[0 .. line.text.len - std.mem.trimStart(u8, line.text, " \t").len]);
    // `zig fmt` indents a continuation line by four columns, and the literal
    // keeps the `,` or `;` that follows it.
    const own_line_indentation = if (string == line.first_token) indentation else indentation + 4;
    return own_line_indentation + widest_columns + 1 > limit;
}

fn loneStringLiteral(trimmed: []const u8) bool {
    if (trimmed.len < 2 or trimmed[0] != '"') return false;
    var index: usize = 1;
    while (index < trimmed.len and trimmed[index] != '"') : (index += 1) {
        if (trimmed[index] == '\\') index += 1;
    }
    if (index >= trimmed.len) return false;
    var rest = std.mem.trimStart(u8, trimmed[index + 1 ..], " ");
    if (std.mem.startsWith(u8, rest, "++")) rest = rest[2..];
    for (rest) |character| switch (character) {
        ',', ';', ')', ']', '}', ' ' => {},
        else => return false,
    };
    return true;
}

fn expectLineFindings(source: [:0]const u8, expected: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.line_length}, .information));
    try std.testing.expectEqual(expected, found.len);
}

test "lines beyond the configured width report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const long = first_operand + second_operand + third_operand + fourth_operand + fifth_operand + sixth;\n" ++
        "const short = 1;\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.line_length}, .information));
    try support.expectRules(found, &.{.line_length});
}

test "multiline string lines and lone string literals cannot be split" {
    const words = "with several words that keep going well past the configured limit of one hundred display columns";
    try expectLineFindings("const text =\n    \\\\a multiline string line " ++ words ++ "\n;\n", 0);
    try expectLineFindings("const list = .{\n    \"a lone string literal " ++ words ++ "\",\n    \"x\" ++\n};\n", 0);
    try expectLineFindings("const parts = .{\n    \"a lone string literal " ++ words ++ "\" ++\n        \"tail\",\n};\n", 0);
}

test "a string literal too wide for a line of its own does not make its line splittable" {
    const words = "with several words that keep going well past the configured limit of one hundred display columns";
    try expectLineFindings("const joined = \"a string after a declaration " ++ words ++ "\" ++\n    \"tail\";\n", 0);
    try expectLineFindings("fn f() void {\n    call(\"a string argument " ++ words ++ "\", 1);\n}\n", 0);
    try expectLineFindings("const config = .{\n    .field = \"a field value " ++ words ++ "\",\n};\n", 0);
    try expectLineFindings("test \"a test name that keeps describing what the test checks until it passes the limit\" {}\n", 0);
    // The literal fits on a continuation line of its own once it moves there.
    try expectLineFindings("fn f() void {\n    log.info(\"a string argument that fits on its own continuation line\", .{ first, second, third, fourth });\n}\n", 1);
    // The rest of the line overflows without the literal.
    try expectLineFindings("fn f() void {\n    call(\"a string argument " ++ words ++ "\", first_operand + second_operand + third_operand + fourth_operand + fifth_operand + sixth_operand);\n}\n", 1);
}

test "rows of data tables are unsplittable" {
    try expectLineFindings(
        \\const cases = [_]Case{
        \\    .{ .seed = 0xec42b7ab404b8acb, .hash = 0xe5a40d39ab796423, .b64 = "YWFhYQ==", .expected = "AQIDBA==" },
        \\    .{ ._, .p_w, .insr, .tmp2x, .memia(.src1w, .tmp0, .add_unaligned_size), .ui(0), .sia(-16, .src0), ._ },
        \\    .{ .src_constraints = .{ .{ .unsigned_int = .byte }, .{ .unsigned_int = .byte }, .any, .any, .any } },
        \\    0x0123456789abcdef, 0x0123456789abcdef, 0x0123456789abcdef, 0x0123456789abcdef, 0x0123456789abcdef,
        \\    .{ .name = "first", .items = &.{ .alpha, .beta, .gamma, .delta, .epsilon, .zeta, .eta, .theta, .iota } },
        \\};
        \\
    , 0);
    // Code, a computed value, a method call, or an overflowing trailing comment is not table data.
    try expectLineFindings(
        \\const cases = [_]Case{
        \\    .{ .seed = first_seed + second_seed + third_seed, .hash = 0xe5a40d39ab796423, .b64 = "YWFhYQ==" },
        \\    .{ .seed = 0xec42b7ab404b8acb, .hash = hasher.hash(0xe5a40d39ab796423), .b64 = "YWFhYQ==", .x = 1 },
        \\    .{ .seed = 0xec42b7ab404b8acb, .hash = 0xe5a40d39ab796423 }, // a comment that pushes the row past the limit
        \\};
        \\fn f() void {
        \\    try cg.asmRegisterRegisterMemory(.{ ._, .mov }, .rax, .rbx, .memia(.src0b, .tmp0, .add_unaligned_size));
        \\}
        \\
    , 4);
}

test "display columns ignore CRLF and count wide and combining characters" {
    // 100 ASCII columns followed by a CRLF ending stay within the limit.
    const hundred = "// " ++ "x " ++ "x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x " ++ "y";
    try std.testing.expectEqual(@as(usize, 100), displayColumns(hundred));
    try expectLineFindings(hundred ++ "\r\nconst a = 1;\r\n", 0);
    // Each CJK character and emoji takes two columns.
    try std.testing.expectEqual(@as(usize, 6), displayColumns("雪🙂ab"));
    try expectLineFindings("// 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 雪 \n", 1);
    // Combining marks take none, so a decomposed accent counts once.
    try std.testing.expectEqual(@as(usize, 1), displayColumns("e\u{301}"));
    // Invalid UTF-8 bytes count one column each without hiding the rest.
    try std.testing.expectEqual(@as(usize, 5), displayColumns("a\xffb雪"));
    try std.testing.expectEqual(@as(usize, 12), displayColumns("\taabc"));
}
