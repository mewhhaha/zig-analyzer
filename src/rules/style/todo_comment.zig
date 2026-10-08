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
                const marker_offset = std.mem.find(u8, comment, marker) orelse continue;
                const absolute = line_start + comment_start + 2 + marker_offset;
                try context.emit(.{
                    .rule = .todo_comment,
                    .level = level,
                    .span = .{ .start = absolute, .end = absolute + marker.len },
                    .message = try context.allocator.print("comment contains task marker '{s}'; track or resolve the promise before it becomes invisible debt", .{marker}),
                });
                break;
            }
        }
        if (line_end == context.source.len) break;
        line_start = line_end + 1;
    }
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
