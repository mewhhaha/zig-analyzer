//! The part of a formatter's output that falls in one span of the source, as
//! byte edits, for range formatting. `zig fmt` formats whole files; when its
//! output differs from the source only in whitespace, every difference is the
//! whitespace between two non-whitespace bytes both texts share, so applying
//! any subset of those edits keeps every token and comment. Any other
//! difference is offered only when it lies inside the span, and a subset that
//! would not parse is not offered at all.
const std = @import("std");
const lineStart = @import("tokens.zig").lineStart;
const lineContentEnd = @import("tokens.zig").lineContentEnd;

const Loc = std.zig.Token.Loc;

pub const Edit = struct {
    /// Bytes of the source to replace.
    span: Loc,
    /// Bytes of the formatted text that replace them.
    replacement: []const u8,
};

/// The edits from `source` to `formatted` that touch the lines of `span`, in
/// source order. Empty when nothing there changes, or when the changes there
/// cannot be separated from changes elsewhere without breaking the program.
/// The caller owns the slice; replacements point into `formatted`.
pub fn editsWithin(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    formatted: []const u8,
    span: Loc,
) ![]const Edit {
    const lines: Loc = .{
        .start = lineStart(source, span.start),
        .end = lineContentEnd(source, @max(span.start, span.end)),
    };
    const all = try whitespaceEdits(allocator, source, formatted) orelse
        return try wholeChangeWithin(allocator, source, formatted, lines);
    defer allocator.free(all);
    var selected: std.ArrayList(Edit) = .empty;
    errdefer selected.deinit(allocator);
    for (all) |edit| {
        // A run ending where the first line starts holds that line's
        // indentation; one starting at the last line's newline holds only
        // what follows it, unless the source ends there.
        const starts_after = edit.span.start > lines.end or
            (edit.span.start == lines.end and lines.end != source.len);
        if (edit.span.end < lines.start or starts_after) continue;
        try selected.append(allocator, edit);
    }
    if (selected.items.len == 0 or selected.items.len == all.len) return try selected.toOwnedSlice(allocator);
    // Whitespace still decides some parses, such as an operator spaced on one
    // side only; keep the subset only when its result parses.
    if (!try parsesAfter(allocator, source, selected.items)) {
        selected.deinit(allocator);
        return &.{};
    }
    return try selected.toOwnedSlice(allocator);
}

/// Every edit from `source` to `formatted`, each replacing one whitespace run
/// (possibly empty) between two bytes both texts share, or null when the
/// texts differ in anything but whitespace.
pub fn whitespaceEdits(allocator: std.mem.Allocator, source: []const u8, formatted: []const u8) !?[]Edit {
    var edits: std.ArrayList(Edit) = .empty;
    errdefer edits.deinit(allocator);
    var source_index: usize = 0;
    var formatted_index: usize = 0;
    while (true) {
        const source_end = whitespaceEnd(source, source_index);
        const formatted_end = whitespaceEnd(formatted, formatted_index);
        if (!std.mem.eql(u8, source[source_index..source_end], formatted[formatted_index..formatted_end])) {
            try edits.append(allocator, .{
                .span = .{ .start = source_index, .end = source_end },
                .replacement = formatted[formatted_index..formatted_end],
            });
        }
        source_index = source_end;
        formatted_index = formatted_end;
        if (source_index == source.len or formatted_index == formatted.len) break;
        // Shared bytes up to the next whitespace on either side; whitespace
        // only one side has is an empty run on the other.
        while (source_index < source.len and formatted_index < formatted.len and
            !isWhitespace(source[source_index]) and !isWhitespace(formatted[formatted_index]))
        {
            if (source[source_index] != formatted[formatted_index]) {
                edits.deinit(allocator);
                return null;
            }
            source_index += 1;
            formatted_index += 1;
        }
    }
    if (source_index != source.len or formatted_index != formatted.len) {
        edits.deinit(allocator);
        return null;
    }
    return try edits.toOwnedSlice(allocator);
}

/// The single edit replacing everything between the common prefix and suffix
/// of the two texts, when that lies inside `lines`; else no edit.
fn wholeChangeWithin(allocator: std.mem.Allocator, source: []const u8, formatted: []const u8, lines: Loc) ![]const Edit {
    var prefix: usize = 0;
    while (prefix < source.len and prefix < formatted.len and source[prefix] == formatted[prefix]) prefix += 1;
    var suffix: usize = 0;
    while (suffix < source.len - prefix and suffix < formatted.len - prefix and
        source[source.len - 1 - suffix] == formatted[formatted.len - 1 - suffix]) suffix += 1;
    const changed: Loc = .{ .start = prefix, .end = source.len - suffix };
    if (changed.start < lines.start or changed.end > lines.end) return &.{};
    const edits = try allocator.alloc(Edit, 1);
    edits[0] = .{ .span = changed, .replacement = formatted[prefix .. formatted.len - suffix] };
    return edits;
}

fn parsesAfter(allocator: std.mem.Allocator, source: []const u8, edits: []const Edit) !bool {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var copied: usize = 0;
    for (edits) |edit| {
        try result.appendSlice(allocator, source[copied..edit.span.start]);
        try result.appendSlice(allocator, edit.replacement);
        copied = edit.span.end;
    }
    try result.appendSlice(allocator, source[copied..]);
    const text = try result.toOwnedSliceSentinel(allocator, 0);
    defer allocator.free(text);
    var tree = try std.zig.Ast.parse(allocator, text, .{ .mode = .zig });
    defer tree.deinit(allocator);
    return tree.errors.len == 0;
}

fn whitespaceEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and isWhitespace(text[end])) end += 1;
    return end;
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn applied(source: []const u8, edits: []const Edit) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(std.testing.allocator);
    var copied: usize = 0;
    for (edits) |edit| {
        try result.appendSlice(std.testing.allocator, source[copied..edit.span.start]);
        try result.appendSlice(std.testing.allocator, edit.replacement);
        copied = edit.span.end;
    }
    try result.appendSlice(std.testing.allocator, source[copied..]);
    return try result.toOwnedSlice(std.testing.allocator);
}

test "whitespace edits reproduce the formatted text" {
    const source = "const a=1;\nfn  f() void {\n_ = a;\n}\n";
    const formatted = "const a = 1;\nfn f() void {\n    _ = a;\n}\n";
    const edits = (try whitespaceEdits(std.testing.allocator, source, formatted)).?;
    defer std.testing.allocator.free(edits);
    const result = try applied(source, edits);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(formatted, result);
}

test "a change beyond whitespace has no whitespace edits" {
    try std.testing.expect(try whitespaceEdits(std.testing.allocator, "const a = @\"b\";\n", "const a = b;\n") == null);
}

test "edits within a span format only its lines" {
    const source: [:0]const u8 = "const a=1;\nconst b=2;\nconst c=3;\n";
    const formatted = "const a = 1;\nconst b = 2;\nconst c = 3;\n";
    const line = std.mem.find(u8, source, "const b").?;
    const edits = try editsWithin(std.testing.allocator, source, formatted, .{ .start = line, .end = line + 3 });
    defer std.testing.allocator.free(edits);
    const result = try applied(source, edits);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("const a=1;\nconst b = 2;\nconst c=3;\n", result);
}

test "a non-whitespace change is offered only when it lies inside the span" {
    const source: [:0]const u8 = "const a = 1;\nconst b = @\"c\";\nconst d=2;\n";
    const formatted = "const a = 1;\nconst b = c;\nconst d = 2;\n";
    const second_line = std.mem.find(u8, source, "const b").?;
    const outside = try editsWithin(std.testing.allocator, source, formatted, .{ .start = 0, .end = 2 });
    defer std.testing.allocator.free(outside);
    try std.testing.expectEqual(@as(usize, 0), outside.len);
    const covering = try editsWithin(std.testing.allocator, source, formatted, .{ .start = second_line, .end = source.len });
    defer std.testing.allocator.free(covering);
    try std.testing.expectEqual(@as(usize, 1), covering.len);
    const result = try applied(source, covering);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(formatted, result);
}

test "a subset that would not parse is not offered" {
    // Not what `zig fmt` produces, but the shape the parse check guards:
    // taking only the first line's edit leaves `-` spaced on one side.
    const source: [:0]const u8 = "const a = 1 -\n    2;\nconst c = 3;\n";
    const formatted = "const a = 1-\n2;\nconst c = 3;\n";
    const edits = try editsWithin(std.testing.allocator, source, formatted, .{ .start = 0, .end = 1 });
    defer std.testing.allocator.free(edits);
    try std.testing.expectEqual(@as(usize, 0), edits.len);
}

test "an indentation change belongs to the line it indents" {
    const source: [:0]const u8 = "fn f() void {\n_ = 1;\n}\n";
    const formatted = "fn f() void {\n    _ = 1;\n}\n";
    const second_line = std.mem.find(u8, source, "_ = 1").?;
    const edits = try editsWithin(std.testing.allocator, source, formatted, .{ .start = second_line, .end = second_line });
    defer std.testing.allocator.free(edits);
    const result = try applied(source, edits);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(formatted, result);
    const first_line = try editsWithin(std.testing.allocator, source, formatted, .{ .start = 0, .end = 0 });
    defer std.testing.allocator.free(first_line);
    try std.testing.expectEqual(@as(usize, 0), first_line.len);
}
