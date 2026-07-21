const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.unsigned_reverse_loop);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const explicit_unsigned = context.tokens[declaration_index + 2].tag == .colon and
            context.tokens[declaration_index + 3].tag == .identifier and
            isUnsignedType(context.tokenText(declaration_index + 3)) and
            context.tokens[declaration_index + 4].tag == .equal;
        const inferred_unsigned = context.tokens[declaration_index + 2].tag == .equal and
            initializerIsLength(context, declaration_index + 3, declaration_end);
        if (!explicit_unsigned and !inferred_unsigned) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const index_name = context.tokenText(declaration_index + 1);

        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |candidate, while_index| {
            if (candidate.tag != .keyword_while or context.enclosingOpeningBrace(while_index) != scope_opening or
                while_index + 5 >= scope_end or context.tokens[while_index + 1].tag != .l_paren) continue;
            const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
            if (condition_end != while_index + 5 or !context.tokenIs(while_index + 2, index_name) or
                context.tokens[while_index + 3].tag != .angle_bracket_right_equal or
                context.tokens[while_index + 4].tag != .number_literal or
                !context.tokenIs(while_index + 4, "0") or
                bindingShadowed(context, index_name, declaration_end + 1, while_index)) continue;
            const update_opening = condition_end + 2;
            if (update_opening >= scope_end or context.tokens[condition_end + 1].tag != .colon or
                context.tokens[update_opening].tag != .l_paren) continue;
            const update_end = context.matchingToken(update_opening, .l_paren, .r_paren) orelse continue;
            if (!decrementsByOne(context, index_name, update_opening + 1, update_end)) continue;
            const fixes = try reverseLoopFix(context, index_name, declaration_end, while_index, update_end);
            const message = try std.fmt.allocPrint(
                context.allocator,
                "unsigned loop index '{s}' is always greater than or equal to zero; decrementing it in the loop update underflows after zero",
                .{index_name},
            );
            errdefer context.allocator.free(message);
            try context.emit(.{
                .rule = .unsigned_reverse_loop,
                .level = level,
                .span = context.tokens[while_index + 3].loc,
                .message = message,
                .fixes = fixes,
            });
        }
    }
}

fn initializerIsLength(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "len") or index == start or
            context.tokens[index - 1].tag != .period) continue;
        for (context.tokens[index + 1 .. end]) |trailing| {
            if (trailing.tag != .minus and trailing.tag != .number_literal) return false;
        }
        return true;
    }
    return false;
}

// The rewrite moves the decrement to the top of the body, so the initializer
// must gain back the 1 the update no longer subtracts before the first visit.
// Both conditions are required to keep the visited indices identical.
fn reverseLoopFix(
    context: RuleRun,
    index_name: []const u8,
    declaration_end: usize,
    while_index: usize,
    update_end: usize,
) ![]const types.Fix {
    if (update_end + 1 >= context.tokens.len or context.tokens[update_end + 1].tag != .l_brace) return &.{};
    if (declaration_end < 3 or context.tokens[declaration_end - 2].tag != .minus or
        context.tokens[declaration_end - 1].tag != .number_literal or
        !context.tokenIs(declaration_end - 1, "1")) return &.{};
    const edits = try context.allocator.alloc(types.Edit, 3);
    edits[0] = .{
        .span = .{ .start = context.tokens[declaration_end - 3].loc.end, .end = context.tokens[declaration_end - 1].loc.end },
        .replacement = "",
    };
    edits[1] = .{
        .span = .{ .start = context.tokens[while_index + 3].loc.start, .end = context.tokens[update_end].loc.end },
        .replacement = "> 0)",
    };
    const body_opening = context.tokens[update_end + 1];
    edits[2] = .{
        .span = .{ .start = body_opening.loc.end, .end = body_opening.loc.end },
        .replacement = try std.fmt.allocPrint(context.allocator, " {s} -= 1;", .{index_name}),
    };
    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{
        .title = "Decrement at the top of the loop body",
        .kind = .quickfix,
        .edits = edits,
        .preferred = true,
    };
    return fixes;
}

fn isUnsignedType(name: []const u8) bool {
    if (std.mem.eql(u8, name, "usize")) return true;
    if (name.len < 2 or name[0] != 'u') return false;
    for (name[1..]) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}

fn decrementsByOne(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 2 < end) : (index += 1) {
        if (context.tokenIs(index, name) and context.tokens[index + 1].tag == .minus_equal and
            context.tokens[index + 2].tag == .number_literal and context.tokenIs(index + 2, "1")) return true;
    }
    return false;
}

fn bindingShadowed(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if ((token.tag == .keyword_const or token.tag == .keyword_var) and index + 1 < end and
            context.tokenIs(index + 1, name)) return true;
    }
    return false;
}

test "unsigned reverse loops report their non-terminating bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn reverse(values: []u8) void { var index: usize = values.len - 1; while (index >= 0) : (index -= 1) consume(values[index]); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, findings.items[0].message, "underflows") != null);
}

test "a braced reverse loop offers a body decrement rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn reverse(values: []u8) void { var index: usize = values.len - 1; while (index >= 0) : (index -= 1) { consume(values[index]); } }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(@as(usize, 1), findings.items[0].fixes.len);
    const edits = findings.items[0].fixes[0].edits;
    try std.testing.expectEqual(@as(usize, 3), edits.len);
    try std.testing.expectEqualStrings(" - 1", source[edits[0].span.start..edits[0].span.end]);
    try std.testing.expectEqualStrings("", edits[0].replacement);
    try std.testing.expectEqualStrings(">= 0) : (index -= 1)", source[edits[1].span.start..edits[1].span.end]);
    try std.testing.expectEqualStrings("> 0)", edits[1].replacement);
    try std.testing.expectEqual(edits[2].span.start, edits[2].span.end);
    try std.testing.expectEqualStrings(" index -= 1;", edits[2].replacement);
}

test "an inferred length index is still an unsigned reverse loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn reverse(values: []u8) void { var index = values.len; while (index >= 0) : (index -= 1) { consume(values[index]); } }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(@as(usize, 0), findings.items[0].fixes.len);
}

test "signed and zero-exclusive reverse loops remain valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn signed() void { var index: isize = 4; while (index >= 0) : (index -= 1) {} }\n" ++
        "fn unsigned() void { var index: usize = 4; while (index > 0) : (index -= 1) {} }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "unsigned reverse loop diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn reverse() void { var index: u32 = 4;\n" ++
        "// zig-analyzer: disable-next-line unsigned-reverse-loop\n" ++
        "while (index >= 0) : (index -= 1) {} }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
