//! Functions longer than the configured line limit.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;
const lineSpan = @import("../../syntax/tokens.zig").lineSpan;

pub const rules = [_]types.Rule{.function_length};

pub fn run(context: RuleRun) !void {
    const level = context.level(.function_length);
    if (level == .off) return;
    for (context.tokens, 0..) |token, fn_index| {
        if (!context.isNamedFunction(fn_index) or insideKeywordBlock(context, fn_index, .keyword_test) or
            insideKeywordBlock(context, fn_index, .keyword_comptime)) continue;
        const body_open = nextTagBefore(context.tokens, fn_index + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        const lines = lineSpan(context.source, token.loc.start, context.tokens[body_end].loc.end);
        if (lines <= context.configuration.function_length_limit) continue;
        const name = if (fn_index + 1 < context.tokens.len and context.tokens[fn_index + 1].tag == .identifier) context.tokenText(fn_index + 1) else "function";
        try context.emit(.{
            .rule = .function_length,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("function '{s}' spans {d} lines, exceeding the configured limit of {d}", .{ name, lines, context.configuration.function_length_limit }),
        });
    }
}

/// Whether a block enclosing `index` opens within a few tokens after `keyword`.
fn insideKeywordBlock(context: RuleRun, index: usize, keyword: std.zig.Token.Tag) bool {
    var brace = context.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        var cursor = opening;
        while (cursor > 0 and opening - cursor < 16) {
            cursor -= 1;
            const tag = context.tokens[cursor].tag;
            if (tag == keyword) return true;
            if (tag == .semicolon or tag == .r_brace) break;
        }
    }
    return false;
}

test "functions beyond the configured length report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_writer: std.Io.Writer.Allocating = .init(arena.allocator());
    try source_writer.writer.writeAll("fn longFunction() void {\n");
    for (0..70) |_| try source_writer.writer.writeAll("_ = 1;\n");
    try source_writer.writer.writeAll("}\nfn short() void {}\n");
    const source = try arena.allocator().dupeSentinel(u8, source_writer.written(), 0);
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.function_length}, .information));
    try support.expectRules(found, &.{.function_length});
}
