const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.unchecked_slice_reinterpretation);
    if (level == .off) return;

    for (context.tokens, 0..) |token, cast_index| {
        if (token.tag != .builtin) continue;
        const operand_index = nestedPointerCastOperand(context, cast_index) orelse continue;
        const slice_name = reinterpretationSlice(context, operand_index, cast_index) orelse continue;
        if (!bindingIsPlainSlice(context, slice_name, cast_index)) continue;
        try context.emit(.{
            .rule = .unchecked_slice_reinterpretation,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "reinterpreting plain slice '{s}' as an aligned pointer can panic for alignment and read beyond short input; validate length and copy into aligned storage",
                .{slice_name},
            ),
        });
    }
}

fn nestedPointerCastOperand(context: RuleRun, cast_index: usize) ?usize {
    if (cast_index + 4 >= context.tokens.len or context.tokens[cast_index + 1].tag != .l_paren or
        context.tokens[cast_index + 2].tag != .builtin or context.tokens[cast_index + 3].tag != .l_paren or
        context.tokens[cast_index + 4].tag != .identifier) return null;
    const align_then_pointer = context.tokenIs(cast_index, "@alignCast") and context.tokenIs(cast_index + 2, "@ptrCast");
    const pointer_then_align = context.tokenIs(cast_index, "@ptrCast") and context.tokenIs(cast_index + 2, "@alignCast");
    return if (align_then_pointer or pointer_then_align) cast_index + 4 else null;
}

fn reinterpretationSlice(context: RuleRun, operand_index: usize, before: usize) ?[]const u8 {
    if (operand_index + 2 < context.tokens.len and context.tokens[operand_index + 1].tag == .period and
        context.tokenIs(operand_index + 2, "ptr")) return context.tokenText(operand_index);
    const alias = context.tokenText(operand_index);
    var index = before;
    while (index > 2) {
        index -= 1;
        if (!context.tokenIs(index, alias) or index + 1 >= before or context.tokens[index + 1].tag != .equal) continue;
        const declaration_index = index - 1;
        if (context.tokens[declaration_index].tag != .keyword_const and context.tokens[declaration_index].tag != .keyword_var) continue;
        const statement_end = context.statementEnd(declaration_index) orelse continue;
        var source_index = index + 2;
        while (source_index + 2 < statement_end) : (source_index += 1) {
            if (context.tokens[source_index].tag == .identifier and context.tokens[source_index + 1].tag == .period and
                context.tokenIs(source_index + 2, "ptr")) return context.tokenText(source_index);
        }
    }
    return null;
}

fn bindingIsPlainSlice(context: RuleRun, name: []const u8, before: usize) bool {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, name) or index + 2 >= before or context.tokens[index + 1].tag != .colon) continue;
        var type_index = index + 2;
        var saw_slice = false;
        var explicit_alignment = false;
        while (type_index < before) : (type_index += 1) {
            switch (context.tokens[type_index].tag) {
                .l_bracket => if (type_index + 1 < before and context.tokens[type_index + 1].tag == .r_bracket) {
                    saw_slice = true;
                },
                .keyword_align => explicit_alignment = true,
                .comma, .r_paren, .equal, .semicolon, .l_brace => break,
                else => {},
            }
        }
        return saw_slice and !explicit_alignment;
    }
    return false;
}

test "plain slice pointer reinterpretation reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(raw: []const u8) Header {\n" ++
        "    const aligned: *align(@alignOf(Header)) const u8 = @alignCast(@ptrCast(raw.ptr));\n" ++
        "    return @as(*const Header, @ptrCast(aligned)).*;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "aligned slices and copied values stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(raw: []align(4) const u8, bytes: []const u8) Header {\n" ++
        "    const aligned: *align(4) const u8 = @alignCast(@ptrCast(raw.ptr));\n" ++
        "    _ = aligned;\n" ++
        "    return std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "byte-offset pointer aliases retain the original slice contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(raw: []const u8, offset: usize) Header {\n" ++
        "    const shifted = raw.ptr + offset;\n" ++
        "    const aligned: *align(@alignOf(Header)) const u8 = @alignCast(@ptrCast(shifted));\n" ++
        "    return @as(*const Header, @ptrCast(aligned)).*;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "ptrCast outside alignCast retains the same slice contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(raw: []const u8, offset: usize) *const u32 {\n" ++
        "    const shifted = raw.ptr + offset;\n" ++
        "    return @ptrCast(@alignCast(shifted));\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
