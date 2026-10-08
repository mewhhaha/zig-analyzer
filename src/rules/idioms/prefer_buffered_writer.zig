//! Unbuffered file writes issued from a loop.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const findTag = @import("../../syntax/tokens.zig").findTag;

pub const rules = [_]types.Rule{.prefer_buffered_writer};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_buffered_writer);
    if (level == .off) return;
    for (context.tokens, 0..) |token, loop_index| {
        if (token.tag != .keyword_for and token.tag != .keyword_while) continue;
        const opening = findTag(context.tokens, loop_index + 1, @min(loop_index + 24, context.tokens.len), .l_brace) orelse continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        for (context.tokens[opening + 1 .. closing], opening + 1..) |body_token, index| {
            if (body_token.tag != .identifier or (!context.tokenIs(index, "write") and !context.tokenIs(index, "writeAll") and !context.tokenIs(index, "print")) or
                index < 2 or context.tokens[index - 1].tag != .period or context.tokens[index - 2].tag != .identifier) continue;
            const writer = context.tokenText(index - 2);
            if (!bindingComesFromDirectWriter(context, loop_index, writer)) continue;
            try context.emit(.{
                .rule = .prefer_buffered_writer,
                .level = level,
                .span = body_token.loc,
                .message = try context.allocator.print("writer '{s}' performs small unbuffered writes inside a loop; buffer it and flush once", .{writer}),
            });
            break;
        }
    }
}

fn bindingComesFromDirectWriter(context: RuleRun, before: usize, name: []const u8) bool {
    var index: usize = 0;
    while (index + 5 < before) : (index += 1) {
        if ((context.tokens[index].tag != .keyword_const and context.tokens[index].tag != .keyword_var) or
            !context.tokenIs(index + 1, name)) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[context.tokens[index].loc.start..context.tokens[end].loc.end];
        if (std.mem.find(u8, declaration, "stdout()") != null) return true;
        const writer_call = std.mem.find(u8, declaration, ".writer(") orelse continue;
        const receiver_start = std.mem.findLastAny(u8, declaration[0..writer_call], " =") orelse continue;
        const receiver = std.mem.trim(u8, declaration[receiver_start + 1 .. writer_call], " \t\r\n");
        if (bindingComesFromFileOpen(context, index, receiver)) return true;
    }
    return false;
}

fn bindingComesFromFileOpen(context: RuleRun, before: usize, name: []const u8) bool {
    var index: usize = 0;
    while (index + 4 < before) : (index += 1) {
        if ((context.tokens[index].tag != .keyword_const and context.tokens[index].tag != .keyword_var) or
            !context.tokenIs(index + 1, name)) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[context.tokens[index].loc.start..context.tokens[end].loc.end];
        return std.mem.find(u8, declaration, ".openFile(") != null or
            std.mem.find(u8, declaration, ".createFile(") != null or
            std.mem.find(u8, declaration, ".accept(") != null;
    }
    return false;
}

test "unbuffered writes in a loop report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f(values: anytype) !void { const output = try std.fs.cwd().createFile(\"out\", .{}); const writer = output.writer(); for (values) |value| { try writer.write(value); } }";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_buffered_writer}, .information));
    try support.expectRules(found, &.{.prefer_buffered_writer});
}
