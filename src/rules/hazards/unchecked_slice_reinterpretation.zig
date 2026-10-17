const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .unchecked_slice_reinterpretation,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.unchecked_slice_reinterpretation);
    if (level == .off) return;

    for (context.tokens, 0..) |token, cast_index| {
        if (token.tag != .builtin) continue;
        const operand_index = nestedPointerCastOperand(context, cast_index) orelse continue;
        const slice_index = reinterpretationSlice(context, operand_index) orelse continue;
        if (!bindingIsPlainSlice(context, slice_index) or functionTakesAlignment(context, cast_index)) continue;
        const slice_name = context.tokenText(slice_index);
        try context.emit(.{
            .rule = .unchecked_slice_reinterpretation,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
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

/// The slice whose `.ptr` the cast operand is, directly (`raw.ptr`) or through
/// the declaration of the operand (`const shifted = raw.ptr + offset;`).
fn reinterpretationSlice(context: RuleRun, operand_index: usize) ?usize {
    if (operand_index + 2 < context.tokens.len and context.tokens[operand_index + 1].tag == .period and
        context.tokenIs(operand_index + 2, "ptr")) return operand_index;
    const alias = (context.scopes.findBinding(operand_index) orelse return null).token_index;
    if (alias == 0 or alias + 1 >= context.tokens.len or context.tokens[alias + 1].tag != .equal or
        (context.tokens[alias - 1].tag != .keyword_const and context.tokens[alias - 1].tag != .keyword_var)) return null;
    const statement_end = context.statementEnd(alias - 1) orelse return null;
    var source_index = alias + 2;
    while (source_index + 2 < statement_end) : (source_index += 1) {
        if (context.tokens[source_index].tag == .identifier and context.tokens[source_index + 1].tag == .period and
            context.tokenIs(source_index + 2, "ptr")) return source_index;
    }
    return null;
}

/// Whether the binding the identifier at `use_index` names is declared with
/// a slice type and no explicit alignment.
fn bindingIsPlainSlice(context: RuleRun, use_index: usize) bool {
    const declaration = (context.scopes.findBinding(use_index) orelse return false).token_index;
    if (declaration + 2 >= context.tokens.len or context.tokens[declaration + 1].tag != .colon) return false;
    var saw_slice = false;
    var explicit_alignment = false;
    for (context.tokens[declaration + 2 ..], declaration + 2..) |token, type_index| {
        switch (token.tag) {
            .l_bracket => if (context.tokens[type_index + 1].tag == .r_bracket) {
                saw_slice = true;
            },
            .keyword_align => explicit_alignment = true,
            .comma, .r_paren, .equal, .semicolon, .l_brace, .eof => break,
            else => {},
        }
    }
    return saw_slice and !explicit_alignment;
}

/// Whether the function around the cast takes a `mem.Alignment` parameter,
/// as allocator implementations do: the caller's alignment travels beside the
/// plain slice, so the slice type does not describe it.
fn functionTakesAlignment(context: RuleRun, cast_index: usize) bool {
    const body = context.scopes.functionBodyContaining(cast_index) orelse return false;
    const opening = (context.scopes.functionKeyword(body) orelse return false) + 2;
    const closing = context.matchingToken(opening, .l_paren, .r_paren) orelse return false;
    for (context.tokens[opening..closing], opening..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "Alignment")) return true;
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

test "the operand's own declaration decides the slice and allocator internals stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn read(buf: []u8) usize { const rc = system.read(buf.ptr, buf.len); return rc; }\n" ++
        "fn mmap(ptr: ?[*]u8, length: usize) []align(4096) u8 {\n" ++
        "    const rc = system.mmap(ptr, length);\n" ++
        "    return @as([*]align(4096) u8, @ptrCast(@alignCast(rc)))[0..length];\n" ++
        "}\n" ++
        "fn free(context: *anyopaque, memory: []u8, alignment: mem.Alignment, ra: usize) void {\n" ++
        "    const node: *usize = @ptrCast(@alignCast(memory.ptr));\n" ++
        "    _ = .{ context, alignment, ra, node };\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
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
    return support.findings(allocator, run, source, types.Configuration.defaults());
}
