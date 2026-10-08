//! Allocation sizes and capacities computed from runtime values with unchecked arithmetic.
const std = @import("std");
const types = @import("../types.zig");
const RuleRun = @import("../context.zig").RuleRun;
const resources = @import("../resources.zig");
const support = @import("../test_support.zig");
const ArgumentRange = @import("../../syntax/tokens.zig").Range;

pub const rules = [_]types.Rule{.allocation_size_overflow};

pub fn run(context: RuleRun) !void {
    const level = context.level(.allocation_size_overflow);
    if (level == .off) return;
    // Several call sites can share one declared length; the finding points at
    // that shared declaration, so report it once instead of once per caller.
    var emitted: std.ArrayList(EmittedSize) = .empty;
    defer emitted.deinit(context.allocator);
    for (context.tokens, 0..) |token, method_index| {
        if (token.tag != .identifier or method_index == 0 or method_index + 1 >= context.tokens.len or
            context.tokens[method_index - 1].tag != .period or context.tokens[method_index + 1].tag != .l_paren) continue;
        var allocation_method: ?resources.SizedAllocation = null;
        for (resources.sized_allocations) |method| {
            if (context.tokenIs(method_index, method.method)) allocation_method = method;
        }
        const method = allocation_method orelse continue;
        const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        const length_argument = argumentFromEnd(context.tokens, method_index + 2, closing, method.length_from_end) orelse continue;
        if (uncheckedCapacityGrowth(context, length_argument, method_index)) |growth_index| {
            const growth_span = context.tokens[growth_index].loc;
            const growth_method = context.tokenText(method_index);
            if (sizeAlreadyEmitted(emitted.items, growth_span, growth_method, "growth")) continue;
            try emitted.append(context.allocator, .{ .start = growth_span.start, .end = growth_span.end, .method = growth_method, .operation = "growth" });
            try context.emit(.{
                .rule = .allocation_size_overflow,
                .level = level,
                .span = context.tokens[growth_index].loc,
                .message = try context.allocator.print(
                    "allocation capacity passed to {s} is grown with unchecked multiplication; validate overflow before growing",
                    .{context.tokenText(method_index)},
                ),
            });
            continue;
        }
        const length = declaredAllocationLength(context, length_argument, method_index) orelse length_argument;
        var multiplication_index: ?usize = null;
        var addition_index: ?usize = null;
        var has_runtime_name = false;
        for (context.tokens[length.start..length.end], length.start..) |argument_token, argument_index| {
            if (argument_token.tag == .asterisk) multiplication_index = argument_index;
            if (argument_token.tag == .plus) addition_index = argument_index;
            if (argument_token.tag == .identifier and identifierIsRuntimeBound(context, argument_index, method_index)) {
                has_runtime_name = true;
            }
        }
        const operation = if (multiplication_index != null and has_runtime_name)
            "multiplication"
        else if (addition_index) |operator_index|
            if (rangeHasRuntimeName(context, length.start, operator_index, method_index) and
                rangeHasRuntimeName(context, operator_index + 1, length.end, method_index))
                "addition"
            else
                continue
        else
            continue;
        if (multiplication_index != null and multiplicationFitsMinimumUsize(context, length, method_index)) continue;
        const length_span = context.tokens[length.start].loc;
        const length_method = context.tokenText(method_index);
        if (sizeAlreadyEmitted(emitted.items, length_span, length_method, operation)) continue;
        try emitted.append(context.allocator, .{ .start = length_span.start, .end = length_span.end, .method = length_method, .operation = operation });
        try context.emit(.{
            .rule = .allocation_size_overflow,
            .level = level,
            .span = length_span,
            .message = try context.allocator.print(
                "allocation length passed to {s} uses unchecked runtime {s}; validate overflow before allocating",
                .{ context.tokenText(method_index), operation },
            ),
        });
    }
}

const EmittedSize = struct { start: usize, end: usize, method: []const u8, operation: []const u8 };

fn argumentFromEnd(tokens: []const std.zig.Token, start: usize, end: usize, from_end: usize) ?ArgumentRange {
    var arguments: [8]ArgumentRange = undefined;
    var argument_count: usize = 0;
    var depth: usize = 0;
    var argument_start = start;
    for (tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (argument_count == arguments.len) return null;
                arguments[argument_count] = .{ .start = argument_start, .end = index };
                argument_count += 1;
                argument_start = index + 1;
            },
            else => {},
        }
    }
    if (argument_start < end) {
        if (argument_count == arguments.len) return null;
        arguments[argument_count] = .{ .start = argument_start, .end = end };
        argument_count += 1;
    }
    if (from_end == 0 or from_end > argument_count) return null;
    return arguments[argument_count - from_end];
}

fn declaredAllocationLength(context: RuleRun, argument: ArgumentRange, before: usize) ?ArgumentRange {
    if (argument.start + 1 != argument.end or context.tokens[argument.start].tag != .identifier) return null;
    const name = context.tokenText(argument.start);
    var index = before;
    while (index > 1) {
        index -= 1;
        if (!context.tokenIs(index, name) or context.tokens[index - 1].tag != .keyword_const or
            index + 1 >= before or context.tokens[index + 1].tag != .equal) continue;
        const declaration_scope_end = context.enclosingScopeEnd(index) orelse continue;
        if (declaration_scope_end < before) continue;
        const declaration_end = context.statementEnd(index - 1) orelse continue;
        if (declaration_end >= before or index + 2 >= declaration_end) continue;
        return .{ .start = index + 2, .end = declaration_end };
    }
    return null;
}

fn identifierIsRuntimeBound(context: RuleRun, identifier_index: usize, use_index: usize) bool {
    const body_start = containingRuntimeBodyStart(context, use_index) orelse return false;
    const name = context.tokenText(identifier_index);
    for (context.tokens[body_start + 1 .. use_index], body_start + 1..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > body_start + 1 and
            (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var))
        {
            if (context.tokens[index - 1].tag == .keyword_const and declarationValueIsComptime(context, index)) continue;
            return true;
        }
        if (index > body_start and context.tokens[index - 1].tag == .pipe) return true;
        if (index > body_start + 1 and context.tokens[index - 1].tag == .asterisk and context.tokens[index - 2].tag == .pipe) return true;
    }

    var cursor = body_start;
    while (cursor > 0 and context.tokens[cursor].tag != .keyword_fn) : (cursor -= 1) {}
    if (context.tokens[cursor].tag != .keyword_fn) return false;
    for (context.tokens[cursor..body_start], cursor..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index + 2 >= body_start or
            context.tokens[index + 1].tag != .colon) continue;
        // A comptime parameter (explicit keyword or a 'type' parameter) is
        // resolved before runtime and cannot overflow a size computation.
        if (index > 0 and context.tokens[index - 1].tag == .keyword_comptime) continue;
        if (context.tokenIs(index + 2, "type")) continue;
        return true;
    }
    return false;
}

fn multiplicationFitsMinimumUsize(context: RuleRun, expression: ArgumentRange, before: usize) bool {
    const text = context.source[context.tokens[expression.start].loc.start..context.tokens[expression.end - 1].loc.end];
    if (std.mem.find(u8, text, "@as(usize") == null and
        std.mem.find(u8, text, "@as( usize") == null) return false;

    var total_bits: usize = 0;
    var factor_count: usize = 0;
    for (context.tokens[expression.start..expression.end], expression.start..) |token, index| {
        if (token.tag != .identifier or !identifierIsRuntimeBound(context, index, before)) continue;
        const bits = unsignedBindingBits(context, context.tokenText(index), before) orelse return false;
        total_bits += bits;
        factor_count += 1;
    }
    return factor_count >= 2 and total_bits <= 32;
}

fn rangeHasRuntimeName(context: RuleRun, start: usize, end: usize, before: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and identifierIsRuntimeBound(context, index, before)) return true;
    }
    return false;
}

fn sizeAlreadyEmitted(emitted: []const EmittedSize, span: std.zig.Token.Loc, method: []const u8, operation: []const u8) bool {
    for (emitted) |prior| {
        if (prior.start == span.start and prior.end == span.end and
            std.mem.eql(u8, prior.method, method) and std.mem.eql(u8, prior.operation, operation)) return true;
    }
    return false;
}

fn uncheckedCapacityGrowth(context: RuleRun, argument: ArgumentRange, before: usize) ?usize {
    if (argument.start + 1 != argument.end or context.tokens[argument.start].tag != .identifier) return null;
    const body_start = containingRuntimeBodyStart(context, before) orelse return null;
    const capacity = context.tokenText(argument.start);
    var growth_index: ?usize = null;
    for (context.tokens[body_start + 1 .. before], body_start + 1..) |_, index| {
        if (context.tokenIs(index, "@mulWithOverflow") or context.tokenIs(index, "maxInt")) return null;
        if (index + 2 >= before or !context.tokenIs(index, capacity) or
            context.tokens[index + 1].tag != .asterisk_equal) continue;
        const factor = context.tokenText(index + 2);
        const value = std.fmt.parseInt(usize, factor, 0) catch continue;
        if (value > 1) growth_index = index;
    }
    return growth_index;
}

fn containingRuntimeBodyStart(context: RuleRun, use_index: usize) ?usize {
    var candidate: ?usize = null;
    for (context.tokens[0..use_index], 0..) |token, index| {
        if (token.tag != .keyword_fn and token.tag != .keyword_test) continue;
        for (context.tokens[index + 1 .. use_index], index + 1..) |following, body_start| {
            if (following.tag != .l_brace) continue;
            const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse break;
            if (body_end > use_index) candidate = body_start;
            break;
        }
    }
    return candidate;
}

fn declarationValueIsComptime(context: RuleRun, name_index: usize) bool {
    const end = context.statementEnd(name_index) orelse return false;
    var index = name_index + 1;
    while (index < end and context.tokens[index].tag != .equal) : (index += 1) {}
    if (index + 1 >= end) return false;

    const value_start = index + 1;
    if (value_start + 1 < end and context.tokens[value_start].tag == .identifier and
        context.tokens[value_start + 1].tag == .l_paren)
    {
        const call_end = context.matchingToken(value_start + 1, .l_paren, .r_paren) orelse return false;
        if (call_end + 1 != end) return false;

        var returns_type = false;
        for (context.tokens[0..name_index], 0..) |token, function_index| {
            if (token.tag != .keyword_fn or function_index + 2 >= name_index or
                context.tokens[function_index + 1].tag != .identifier or
                !context.tokenIs(function_index + 1, context.tokenText(value_start))) continue;
            const parameters_end = context.matchingToken(function_index + 2, .l_paren, .r_paren) orelse continue;
            if (parameters_end + 1 < name_index and context.tokenIs(parameters_end + 1, "type")) {
                returns_type = true;
                break;
            }
        }
        if (returns_type) {
            for (context.tokens[value_start + 2 .. call_end]) |token| switch (token.tag) {
                .number_literal,
                .char_literal,
                .string_literal,
                .plus,
                .minus,
                .asterisk,
                .slash,
                .percent,
                .comma,
                .l_paren,
                .r_paren,
                => {},
                else => return false,
            };
            return true;
        }
    }

    for (context.tokens[index + 1 .. end]) |token| {
        switch (token.tag) {
            .number_literal, .char_literal, .string_literal, .plus, .minus, .asterisk, .slash, .percent, .l_paren, .r_paren => {},
            else => return false,
        }
    }
    return true;
}

fn unsignedBindingBits(context: RuleRun, name: []const u8, before: usize) ?usize {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, name)) continue;
        if (index + 2 < before and context.tokens[index + 1].tag == .colon) {
            return unsignedTypeBits(context.tokenText(index + 2));
        }
        if (index == 0 or (context.tokens[index - 1].tag != .keyword_const and
            context.tokens[index - 1].tag != .keyword_var) or index + 1 >= before or
            context.tokens[index + 1].tag != .equal) continue;
        const declaration_end = context.statementEnd(index - 1) orelse continue;
        var value_index = index + 2;
        while (value_index + 2 < declaration_end) : (value_index += 1) {
            if (context.tokens[value_index].tag == .builtin and context.tokenIs(value_index, "@as") and
                context.tokens[value_index + 1].tag == .l_paren)
            {
                return unsignedTypeBits(context.tokenText(value_index + 2));
            }
        }
    }
    return null;
}

fn unsignedTypeBits(name: []const u8) ?usize {
    if (name.len < 2 or name[0] != 'u') return null;
    return std.fmt.parseInt(usize, name[1..], 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => null,
    };
}

test "constant allocation products are not runtime overflow risks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const KiB = 1024; fn run(a: anytype) !void { const bytes = try a.alloc(u8, 64 * KiB); defer a.free(bytes); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "allocSentinel checks the length rather than the sentinel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: anytype, count: usize) !void { const bytes = try a.allocSentinel(u8, count * 2, 0); defer a.free(bytes); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.allocation_size_overflow, findings[0].rule);
}

test "user methods named alloc are not allocator calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Slab = struct { pub fn alloc(self: *Slab) *u8 { return self.value; } value: *u8 };";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .allocation_size_overflow);
}

test "locally declared literal factors are not runtime overflow risks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: anytype) !void { const w = 640; const h = 480; const bytes = try a.alloc(u8, w * h); defer a.free(bytes); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "literal string lengths are not runtime overflow risks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "test \"input\" { const line = \"hello\"; const repeat = 4_000; const bytes = try std.testing.allocator.alloc(u8, line.len * repeat); defer std.testing.allocator.free(bytes); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "constants from locally instantiated types are not runtime overflow risks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn Block(comptime size: usize) type { return struct { pub const byte_size = size; }; } fn run(a: anytype) !void { const B = Block(64); const bytes = try a.alloc(u8, 3 * B.byte_size / 2); defer a.free(bytes); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "runtime const values and mutable literals still require checked allocation multiplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: anytype) !void { const width = loadWidth(); var height = 4; const first = try a.alloc(u8, width * 2); defer a.free(first); const second = try a.alloc(u8, height * 2); defer a.free(second); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var allocation_findings: usize = 0;
    for (findings) |finding| if (finding.rule == .allocation_size_overflow) {
        allocation_findings += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), allocation_findings);
}

test "realloc checks a locally declared runtime length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn grow(a: anytype, bytes: []u8) ![]u8 { const new_len = bytes.len * 2; return a.realloc(bytes, new_len); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var allocation_findings: usize = 0;
    for (findings) |finding| if (finding.rule == .allocation_size_overflow) {
        allocation_findings += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), allocation_findings);
}

test "allocation size findings report a shared declared length once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: anytype, first: []u8, second: []u8) !void { const total = first.len + second.len;" ++
        "const x = try a.alloc(u8, total); defer a.free(x); const y = try a.alloc(u8, total); defer a.free(y); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var allocation_findings: usize = 0;
    for (findings) |finding| if (finding.rule == .allocation_size_overflow) {
        allocation_findings += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), allocation_findings);
}

test "realloc does not chase mutable or constant declared lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn grow(a: anytype, first: []u8, second: []u8) !void {" ++
        "var runtime_len = first.len * 2; first = try a.realloc(first, runtime_len);" ++
        "const fixed_len = 16 * 2; second = try a.realloc(second, fixed_len); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .allocation_size_overflow);
}

test "allocation lengths ignore declarations from closed sibling scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn grow(a: anytype, bytes: []u8, new_len: usize, inspect: bool) ![]u8 {" ++
        "if (inspect) { const new_len = loadWidth() * 2; consume(new_len); }" ++
        "return a.realloc(bytes, new_len); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .allocation_size_overflow);
}

test "realloc capacity loops require checked growth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn ensure(a: anytype, bytes: []u8, needed: usize) ![]u8 {" ++
        "var capacity = if (bytes.len == 0) 8 else bytes.len * 2;" ++
        "while (capacity < needed) capacity *= 2; return a.realloc(bytes, capacity); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var allocation_findings: usize = 0;
    for (findings) |finding| if (finding.rule == .allocation_size_overflow) {
        allocation_findings += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), allocation_findings);
}

test "guarded realloc capacity growth stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn ensure(a: anytype, bytes: []u8, needed: usize) ![]u8 { var capacity = bytes.len;" ++
        "while (capacity < needed) { if (capacity > std.math.maxInt(usize) / 2) return error.Overflow; capacity *= 2; }" ++
        "return a.realloc(bytes, capacity); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .allocation_size_overflow);
}

test "adding independent runtime lengths before allocation reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn join(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !void {" ++
        "const combined = try allocator.alloc(u8, left.len + right.len); defer allocator.free(combined); }" ++
        "fn extend(allocator: std.mem.Allocator, bytes: []const u8) !void {" ++
        "const extended = try allocator.alloc(u8, bytes.len + 1); defer allocator.free(extended); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var allocation_findings: usize = 0;
    for (findings) |finding| if (finding.rule == .allocation_size_overflow) {
        allocation_findings += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), allocation_findings);
}

test "widened narrow factors that fit usize do not report overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: anytype, raw_width: usize, raw_height: usize) !void {" ++
        "const width = @as(u16, @intCast(raw_width)); const height = @as(u16, @intCast(raw_height));" ++
        "const bytes = try a.alloc(u8, @as(usize, @intCast(width)) * height); defer a.free(bytes); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .allocation_size_overflow);
}

test "comptime parameters do not make allocation sizes runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn decode(a: anytype, comptime Word: type) !void { const bytes = try a.alloc(Word, 4 * maxInt(Word)); defer a.free(bytes); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "unchecked multiplication of a runtime count reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: anytype, count: usize) !void { const bytes = try a.alloc(u8, count * 4); defer a.free(bytes); }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try support.expectRules(found, &.{.allocation_size_overflow});
}
