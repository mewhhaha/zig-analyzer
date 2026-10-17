//! Unbuffered file writes issued from a loop.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const findTag = @import("../../syntax/tokens.zig").findTag;
const syntax_scope = @import("../../syntax/scope.zig");

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
            if (!bindingComesFromDirectWriter(context, loop_index, index - 2)) continue;
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

/// Whether the writer named at `use_index` is declared before the loop at
/// `before` from `stdout()`, or from `.writer()` on an opened, created or
/// accepted file.
fn bindingComesFromDirectWriter(context: RuleRun, before: usize, use_index: usize) bool {
    const declaration = localDeclaration(context, context.scopes.findBinding(use_index)) orelse return false;
    if (declaration.keyword >= before) return false;
    if (std.mem.find(u8, declaration.text, "stdout()") != null) return true;
    const writer_call = std.mem.find(u8, declaration.text, ".writer(") orelse return false;
    const receiver_start = std.mem.findLastAny(u8, declaration.text[0..writer_call], " =") orelse return false;
    const receiver = std.mem.trim(u8, declaration.text[receiver_start + 1 .. writer_call], " \t\r\n");
    const file = localDeclaration(context, context.scopes.findBindingNamed(receiver, declaration.keyword)) orelse return false;
    return std.mem.find(u8, file.text, ".openFile(") != null or
        std.mem.find(u8, file.text, ".createFile(") != null or
        std.mem.find(u8, file.text, ".accept(") != null;
}

const LocalDeclaration = struct { keyword: usize, text: []const u8 };

/// The source of the `const` or `var` statement that declares `binding`.
fn localDeclaration(context: RuleRun, binding: ?syntax_scope.Binding) ?LocalDeclaration {
    const name_index = (binding orelse return null).token_index;
    if (name_index == 0 or (context.tokens[name_index - 1].tag != .keyword_const and
        context.tokens[name_index - 1].tag != .keyword_var)) return null;
    const end = context.statementEnd(name_index - 1) orelse return null;
    return .{
        .keyword = name_index - 1,
        .text = context.source[context.tokens[name_index - 1].loc.start..context.tokens[end].loc.end],
    };
}

test "writers declared in another function or from a buffered source stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn open() !void { const writer = std.fs.File.stdout().writer(); _ = writer; }\n" ++
        "fn f(values: anytype, writer: anytype) !void { for (values) |value| { try writer.print(\"{}\", .{value}); } }\n" ++
        "fn g(values: anytype, buffered: anytype) !void { const writer = buffered.writer(); for (values) |value| { try writer.write(value); } }";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_buffered_writer}, .information));
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "unbuffered writes in a loop report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f(values: anytype) !void { const output = try std.fs.cwd().createFile(\"out\", .{}); const writer = output.writer(); for (values) |value| { try writer.write(value); } }";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_buffered_writer}, .information));
    try support.expectRules(found, &.{.prefer_buffered_writer});
}
