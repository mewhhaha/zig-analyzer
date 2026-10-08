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
        const line = context.source[start..end];
        const columns = displayColumns(line);
        if (columns > context.configuration.line_length_limit and
            (!context.configuration.line_length_allow_unsplittable or !singleUnsplittableToken(line)))
        {
            try context.emit(.{
                .rule = .line_length,
                .level = level,
                .span = .{ .start = start, .end = end },
                .message = try context.allocator.print("line is {d} display columns, exceeding the configured limit of {d}", .{ columns, context.configuration.line_length_limit }),
            });
        }
        if (end == context.source.len) break;
        start = end + 1;
    }
}

fn displayColumns(line: []const u8) usize {
    var columns: usize = 0;
    var view = std.unicode.Utf8View.init(line) catch return line.len;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == '\t') {
            columns += 8 - (columns % 8);
        } else {
            columns += 1;
        }
    }
    return columns;
}

fn singleUnsplittableToken(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.find(u8, trimmed, "http://") != null or std.mem.find(u8, trimmed, "https://") != null) return true;
    return std.mem.findAny(u8, trimmed, " \t") == null;
}

test "lines beyond the configured width report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try arena.allocator().printSentinel("const long = \"{s}\";\nconst short = 1;\n", .{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, 0);
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.line_length}, .information));
    try support.expectRules(found, &.{.line_length});
}
