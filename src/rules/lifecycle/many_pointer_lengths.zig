//! Allocation lengths lost at a many-item or nullable pointer boundary: frees of slices rebuilt from a bare pointer, and nullable pointers copied by a separate length.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{ .pointer_only_free, .nullable_pointer_length };

pub fn run(context: RuleRun) !void {
    try findPointerOnlyFrees(context);
    try findNullablePointerLengths(context);
}

fn findPointerOnlyFrees(context: RuleRun) !void {
    const level = context.level(.pointer_only_free);
    if (level == .off) return;
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = context.functionRange(function_index) orelse continue;
        const pointer_name = manyPointerParameter(context, function.parameters_start, function.parameters_end) orelse continue;
        const slice = sliceFromPointer(context, pointer_name, function.body_start + 1, function.body_end) orelse continue;
        if (hasLengthParameter(context, function.parameters_start, function.parameters_end) and
            sliceHasNamedBound(context, slice.bracket_start + 1, slice.bracket_end)) continue;
        const free_index = freeOfBinding(context, slice.binding, function.body_start + 1, function.body_end) orelse continue;
        try context.emit(.{
            .rule = .pointer_only_free,
            .level = level,
            .span = context.tokens[free_index].loc,
            .message = try context.allocator.print(
                "freeing slice '{s}' reconstructed from pointer '{s}' without its allocation length can pass the allocator the wrong layout",
                .{ slice.binding, pointer_name },
            ),
        });
    }
}

fn findNullablePointerLengths(context: RuleRun) !void {
    const level = context.level(.nullable_pointer_length);
    if (level == .off) return;
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = context.functionRange(function_index) orelse continue;
        const pointer_name = nullableManyPointerParameter(context, function.parameters_start, function.parameters_end) orelse continue;
        const length_name = integerParameter(context, function.parameters_start, function.parameters_end) orelse continue;
        const allocation = allocationWithLength(context, length_name, function.body_start + 1, function.body_end) orelse continue;
        const branch = optionalPointerBranch(context, pointer_name, allocation.declaration_end + 1, function.body_end) orelse continue;
        if (!rangeCopiesName(context, branch.capture, branch.body_start + 1, branch.end)) continue;
        if (!rangeReturns(context, allocation.binding, branch.end + 1, function.body_end)) continue;
        try context.emit(.{
            .rule = .nullable_pointer_length,
            .level = level,
            .span = context.tokens[branch.start].loc,
            .message = try context.allocator.print(
                "nullable pointer '{s}' may be null while length '{s}' is positive, returning uninitialized allocation '{s}'",
                .{ pointer_name, length_name, allocation.binding },
            ),
        });
    }
}

fn freeOfBinding(context: RuleRun, binding: []const u8, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, "free") or
            method_index + 1 >= end or context.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        for (context.tokens[method_index + 2 .. @min(call_end, end)], method_index + 2..) |argument, index| {
            if (argument.tag == .identifier and context.tokenIs(index, binding)) return method_index;
        }
    }
    return null;
}

fn hasLengthParameter(context: RuleRun, start: usize, end: usize) bool {
    return integerParameter(context, start, end) != null;
}

fn manyPointerParameter(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start + 1 .. end], start + 1..) |token, name_index| {
        if (token.tag != .identifier or name_index + 3 >= end or context.tokens[name_index + 1].tag != .colon) continue;
        var index = name_index + 2;
        if (context.tokens[index].tag == .question_mark) index += 1;
        if (index + 1 < end and context.tokens[index].tag == .l_bracket and
            context.tokens[index + 1].tag == .asterisk) return context.tokenText(name_index);
    }
    return null;
}

fn sliceFromPointer(context: RuleRun, pointer_name: []const u8, start: usize, end: usize) ?ReconstructedSlice {
    for (context.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 6 >= end or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const statement_end = context.statementEnd(declaration_index) orelse continue;
        if (statement_end > end) continue;
        var index = declaration_index + 2;
        while (index + 1 < statement_end) : (index += 1) {
            if (context.tokenIs(index, pointer_name) and context.tokens[index + 1].tag == .l_bracket) {
                const bracket_end = context.matchingToken(index + 1, .l_bracket, .r_bracket) orelse continue;
                return .{
                    .binding = context.tokenText(declaration_index + 1),
                    .bracket_start = index + 1,
                    .bracket_end = bracket_end,
                };
            }
        }
    }
    return null;
}

fn sliceHasNamedBound(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| if (token.tag == .identifier) return true;
    return false;
}

fn allocationWithLength(context: RuleRun, length_name: []const u8, start: usize, end: usize) ?Allocation {
    for (context.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= end or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!rangeCalls(context, "alloc", declaration_index + 2, declaration_end) or
            !context.rangeContainsName(length_name, declaration_index + 2, declaration_end)) continue;
        return .{ .binding = context.tokenText(declaration_index + 1), .declaration_end = declaration_end };
    }
    return null;
}

fn integerParameter(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start + 1 .. end], start + 1..) |token, name_index| {
        if (token.tag != .identifier or name_index + 2 >= end or context.tokens[name_index + 1].tag != .colon or
            context.tokens[name_index + 2].tag != .identifier) continue;
        const type_name = context.tokenText(name_index + 2);
        if (std.mem.eql(u8, type_name, "usize") or std.mem.eql(u8, type_name, "u32") or
            std.mem.eql(u8, type_name, "u64")) return context.tokenText(name_index);
    }
    return null;
}

fn nullableManyPointerParameter(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start + 1 .. end], start + 1..) |token, name_index| {
        if (token.tag == .identifier and name_index + 4 < end and context.tokens[name_index + 1].tag == .colon and
            context.tokens[name_index + 2].tag == .question_mark and context.tokens[name_index + 3].tag == .l_bracket and
            context.tokens[name_index + 4].tag == .asterisk) return context.tokenText(name_index);
    }
    return null;
}

fn optionalPointerBranch(context: RuleRun, pointer_name: []const u8, start: usize, end: usize) ?OptionalBranch {
    for (context.tokens[start..end], start..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 1 >= end or context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end + 4 >= end or !context.rangeContainsName(pointer_name, if_index + 2, condition_end) or
            context.tokens[condition_end + 1].tag != .pipe or context.tokens[condition_end + 2].tag != .identifier or
            context.tokens[condition_end + 3].tag != .pipe or context.tokens[condition_end + 4].tag != .l_brace) continue;
        const body_start = condition_end + 4;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        return .{
            .start = if_index,
            .body_start = body_start,
            .end = body_end,
            .capture = context.tokenText(condition_end + 2),
        };
    }
    return null;
}

fn rangeCopiesName(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, copy_index| {
        if ((token.tag != .builtin or !context.tokenIs(copy_index, "@memcpy")) and
            (token.tag != .identifier or !context.tokenIs(copy_index, "copyForwards"))) continue;
        const statement_end = context.statementEnd(copy_index) orelse continue;
        if (statement_end <= end and context.rangeContainsName(name, copy_index + 1, statement_end)) return true;
    }
    return false;
}

fn rangeReturns(context: RuleRun, binding: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_return and index + 1 < end and context.tokenIs(index + 1, binding)) return true;
    }
    return false;
}

const ReconstructedSlice = struct {
    binding: []const u8,
    bracket_start: usize,
    bracket_end: usize,
};

const Allocation = struct { binding: []const u8, declaration_end: usize };

fn rangeCalls(context: RuleRun, method: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, method) and index + 1 < end and
            context.tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

const OptionalBranch = struct {
    start: usize,
    body_start: usize,
    end: usize,
    capture: []const u8,
};

test "pointer-only frees and nullable pointer lengths preserve allocation contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn release(a: anytype, ptr: [*]u8) void { const bytes = ptr[0..16]; a.free(bytes); } " ++
        "fn copy(a: anytype, ptr: ?[*]const u8, len: usize) ![]u8 { const out = try a.alloc(u8, len); if (ptr) |p| { @memcpy(out, p[0..len]); } return out; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "unrelated integer parameters do not supply allocation lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn release(a: anytype, ptr: [*]u8, flags: u32) void { " ++
        "const bytes = ptr[0..16]; a.free(bytes); _ = flags; } " ++
        "fn releaseKnown(a: anytype, ptr: [*]u8, len: usize) void { " ++
        "const bytes = ptr[0..len]; a.free(bytes); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.pointer_only_free, findings[0].rule);
}

test "nullable pointer fallback copies initialize their allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn copy(a: anytype, ptr: ?[*]const u8, fallback: []const u8, len: usize) ![]u8 { " ++
        "const out = try a.alloc(u8, len); if (ptr == null) { @memcpy(out, fallback[0..len]); } return out; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
