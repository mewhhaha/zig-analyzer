//! Comments carrying a configured task marker.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{.todo_comment};

pub fn run(context: RuleRun) !void {
    const level = context.level(.todo_comment);
    if (level == .off) return;
    var line_start: usize = 0;
    while (line_start < context.source.len) {
        const relative_end = std.mem.findScalar(u8, context.source[line_start..], '\n') orelse context.source.len - line_start;
        const line_end = line_start + relative_end;
        const line = context.source[line_start..line_end];
        if (commentStart(line)) |comment_start| {
            const comment = line[comment_start + 2 ..];
            for (context.configuration.todo_markers) |marker| {
                const marker_offset = markerOffset(comment, marker) orelse continue;
                const absolute = line_start + comment_start + 2 + marker_offset;
                const message = if (attribution(comment[marker_offset + marker.len ..])) |owner|
                    try context.allocator.print("comment contains task marker '{s}' attributed to '{s}'; resolve it or move it to the issue tracker", .{ marker, owner })
                else
                    try context.allocator.print("comment contains task marker '{s}'; track or resolve the promise before it becomes invisible debt", .{marker});
                try context.emit(.{
                    .rule = .todo_comment,
                    .level = level,
                    .span = .{ .start = absolute, .end = absolute + marker.len },
                    .message = message,
                });
                break;
            }
        }
        if (line_end == context.source.len) break;
        line_start = line_end + 1;
    }
}

/// Offset of the first use of `marker` in `comment` as a word of its own:
/// not part of a longer name (`REG_XXX`, `XXXX`, `TODOs`) and not quoted, as
/// a comment that mentions a marker (`grep for 'TODO(release)'`) quotes it.
fn markerOffset(comment: []const u8, marker: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.findPos(u8, comment, from, marker)) |offset| : (from = offset + 1) {
        const before: u8 = if (offset == 0) ' ' else comment[offset - 1];
        const after: u8 = if (offset + marker.len == comment.len) ' ' else comment[offset + marker.len];
        if (wordByte(marker[0]) and wordByte(before)) continue;
        if (wordByte(marker[marker.len - 1]) and wordByte(after)) continue;
        if (before == '"' or before == '\'' or before == '`') continue;
        return offset;
    }
    return null;
}

fn wordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// The owner or topic a marker names right after it, as `TODO(batiati):`
/// and `TODO(zig)` do.
fn attribution(after_marker: []const u8) ?[]const u8 {
    if (after_marker.len < 3 or after_marker[0] != '(') return null;
    const close = std.mem.findAny(u8, after_marker[1..], "()") orelse return null;
    if (close == 0 or after_marker[1 + close] != ')') return null;
    const owner = std.mem.trim(u8, after_marker[1 .. 1 + close], " ");
    return if (owner.len == 0) null else owner;
}

fn commentStart(line: []const u8) ?usize {
    var quote: ?u8 = null;
    var escaped = false;
    var index: usize = 0;
    while (index + 1 < line.len) : (index += 1) {
        const byte = line[index];
        if (quote) |delimiter| {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == delimiter) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '/' and line[index + 1] == '/') return index;
    }
    return null;
}

test "task markers in comments report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "// TODO replace this marker\nconst value = 1;\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.todo_comment}, .information));
    try support.expectRules(found, &.{.todo_comment});
}

test "markers count only as whole unquoted words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\// worst case: "-XXXXXXXXXXXXXyXXwXXdXXhXXmXX.XXXs".len = 34
        \\/// verify that the REG_XXX type of the stored registry value matches.
        \\/// The expected format is: `XXXX,layout_string` where XXXX is the checksum.
        \\// NB: grep for 'TODO(client_release)' after changing! See the TODOs below.
        \\const value = "// TODO inside a string";
        \\// See XXXX above. XXX: the real marker.
        \\
    ;
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.todo_comment}, .information));
    try support.expectRules(found, &.{.todo_comment});
    try std.testing.expectEqualStrings("XXX", source[found[0].span.start..found[0].span.end]);
    try std.testing.expect(std.mem.startsWith(u8, source[found[0].span.start..], "XXX: the real"));
}

test "attributed markers name their owner instead of calling the debt invisible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "// TODO(batiati): remove after the release.\n// TODO: unowned\n// TODO() empty\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.todo_comment}, .information));
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expect(std.mem.find(u8, found[0].message, "attributed to 'batiati'") != null);
    try std.testing.expect(std.mem.find(u8, found[1].message, "invisible debt") != null);
    try std.testing.expect(std.mem.find(u8, found[2].message, "invisible debt") != null);
}
