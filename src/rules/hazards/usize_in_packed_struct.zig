const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .usize_in_packed_struct,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.usize_in_packed_struct);
    if (level == .off) return;

    // Only bit-packed layouts are covered: in an 'extern' container a
    // pointer-sized field mirrors the C ABI's size_t/intptr_t on purpose.
    for (context.tokens, 0..) |token, layout_index| {
        const layout: []const u8 = switch (token.tag) {
            .keyword_packed => "packed",
            else => continue,
        };
        if (layout_index + 2 >= context.tokens.len) continue;
        const container: []const u8 = switch (context.tokens[layout_index + 1].tag) {
            .keyword_struct => "struct",
            .keyword_union => "union",
            else => continue,
        };
        var opening = layout_index + 2;
        if (context.tokens[opening].tag == .l_paren) {
            // 'packed union(usize)' is deliberately pointer-sized; its fields
            // track the backing integer by construction.
            if (context.tokenIs(opening + 1, "usize") or context.tokenIs(opening + 1, "isize")) continue;
            opening = (context.matchingToken(opening, .l_paren, .r_paren) orelse continue) + 1;
        }
        if (opening >= context.tokens.len or context.tokens[opening].tag != .l_brace) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;

        var brace_depth: usize = 0;
        var parenthesis_depth: usize = 0;
        var bracket_depth: usize = 0;
        var index = opening + 1;
        while (index < closing) : (index += 1) {
            switch (context.tokens[index].tag) {
                .l_brace => brace_depth += 1,
                .r_brace => brace_depth -|= 1,
                .l_paren => parenthesis_depth += 1,
                .r_paren => parenthesis_depth -|= 1,
                .l_bracket => bracket_depth += 1,
                .r_bracket => bracket_depth -|= 1,
                .colon => {
                    if (brace_depth != 0 or parenthesis_depth != 0 or bracket_depth != 0) continue;
                    const type_index = pointerSizedFieldType(context, index, closing) orelse continue;
                    try context.emit(.{
                        .rule = .usize_in_packed_struct,
                        .level = level,
                        .span = context.tokens[type_index].loc,
                        .message = try context.allocator.print(
                            "field '{s}' of this {s} {s} uses pointer-sized '{s}'; its width and the layout vary by target",
                            .{ context.tokenText(index - 1), layout, container, context.tokenText(type_index) },
                        ),
                    });
                },
                else => {},
            }
        }
    }
}

fn pointerSizedFieldType(context: RuleRun, colon_index: usize, closing: usize) ?usize {
    if (colon_index < 2 or context.tokens[colon_index - 1].tag != .identifier) return null;
    var prev_index = colon_index - 2;
    if (context.tokens[prev_index].tag == .keyword_pub) {
        if (prev_index == 0) return null;
        prev_index -= 1;
    }
    switch (context.tokens[prev_index].tag) {
        // '}' and ';' precede fields that follow a method or nested declaration.
        .l_brace, .comma, .doc_comment, .r_brace, .semicolon => {},
        else => return null,
    }
    var index = colon_index + 1;
    while (index < closing and context.tokens[index].tag == .question_mark) index += 1;
    while (index + 2 < closing and context.tokens[index].tag == .l_bracket) {
        const length_tag = context.tokens[index + 1].tag;
        if ((length_tag != .number_literal and length_tag != .identifier) or
            context.tokens[index + 2].tag != .r_bracket) return null;
        index += 3;
    }
    if (index + 1 > closing or context.tokens[index].tag != .identifier) return null;
    const name = context.tokenText(index);
    if (!std.mem.eql(u8, name, "usize") and !std.mem.eql(u8, name, "isize")) return null;
    return switch (context.tokens[index + 1].tag) {
        .comma, .r_brace, .equal, .keyword_align => index,
        else => null,
    };
}

test "pointer-sized fields in packed containers report the layout hazard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Header = packed struct(u64) { flags: u32, count: usize, base: isize };\n" ++
        "const Word = packed union { address: usize, halves: u64 };";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "'count'") != null);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "packed") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "'base'") != null);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "'isize'") != null);
    try std.testing.expect(std.mem.find(u8, findings[2].message, "'address'") != null);
    try std.testing.expect(std.mem.find(u8, findings[2].message, "packed union") != null);
}

test "pointer-sized fields after methods and declarations report the hazard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Frame = packed struct {\n" ++
        "    fn width() u8 {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "    const alignment = 8;\n" ++
        "    base: usize,\n" ++
        "};";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "'base'") != null);
}

test "public pointer-sized fields report the hazard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Header = packed struct {\n" ++
        "    pub count: usize,\n" ++
        "};";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "'count'") != null);
}

test "plain and extern containers stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Plain = struct { count: usize };\n" ++
        "const Sizes = packed struct { small: u8, wide: u64 };\n" ++
        "const Sysinfo = extern struct { totalram: usize, loads: [3]usize };\n" ++
        "const Flags = packed union(usize) { raw: usize, shifted: u64 };\n" ++
        "const Callbacks = extern struct { hash: *const fn (usize) u64, width: u32 };";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, types.Configuration.defaults());
}
