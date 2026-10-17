//! Source lines wider than the configured display-column limit.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{.line_length};

pub fn run(context: RuleRun) !void {
    const level = context.level(.line_length);
    if (level == .off) return;
    var start: usize = 0;
    while (start < context.source.len) {
        const relative_end = std.mem.findScalar(u8, context.source[start..], '\n') orelse context.source.len - start;
        const end = start + relative_end;
        // A CRLF line ending is not part of the line's width.
        const line = std.mem.trimEnd(u8, context.source[start..end], "\r");
        const columns = displayColumns(line);
        if (columns > context.configuration.line_length_limit and
            (!context.configuration.line_length_allow_unsplittable or !unsplittable(line)))
        {
            try context.emit(.{
                .rule = .line_length,
                .level = level,
                .span = .{ .start = start, .end = start + line.len },
                .message = try context.allocator.print("line is {d} display columns, exceeding the configured limit of {d}", .{ columns, context.configuration.line_length_limit }),
            });
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

/// Whether the line cannot be wrapped: it names a URL, it is one token
/// without whitespace, or its only token is a string literal (optionally
/// followed by `,`, `;`, closing delimiters or `++`). A `\\` multiline string
/// line is part of the string's value, so it can never be split.
fn unsplittable(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (std.mem.find(u8, trimmed, "http://") != null or std.mem.find(u8, trimmed, "https://") != null) return true;
    if (std.mem.findAny(u8, trimmed, " \t") == null) return true;
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return true;
    return loneStringLiteral(trimmed);
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
    const source = try arena.allocator().printSentinel("const long = \"{s}\";\nconst short = 1;\n", .{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, 0);
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.line_length}, .information));
    try support.expectRules(found, &.{.line_length});
}

test "multiline string lines and lone string literals cannot be split" {
    const words = "with several words that keep going well past the configured limit of one hundred display columns";
    try expectLineFindings("const text =\n    \\\\a multiline string line " ++ words ++ "\n;\n", 0);
    try expectLineFindings("const list = .{\n    \"a lone string literal " ++ words ++ "\",\n    \"x\" ++\n};\n", 0);
    try expectLineFindings("const parts = .{\n    \"a lone string literal " ++ words ++ "\" ++\n        \"tail\",\n};\n", 0);
    try expectLineFindings("const joined = \"a string after a declaration " ++ words ++ "\" ++\n    \"tail\";\n", 1);
    try expectLineFindings("fn f() void {\n    call(\"a string argument " ++ words ++ "\", 1);\n}\n", 1);
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
