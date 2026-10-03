const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_vector_reduce);
    if (level == .off) return;

    var i: usize = 0;
    while (i + 8 < context.tokens.len) : (i += 1) {
        // Look for v[0]
        if (context.tokens[i].tag != .identifier or
            context.tokens[i + 1].tag != .l_bracket or
            !context.tokenIs(i + 2, "0") or
            context.tokens[i + 3].tag != .r_bracket) continue;

        const v_name = context.tokenText(i);
        const op_tok = context.tokens[i + 4];
        const reduce_op: []const u8 = switch (op_tok.tag) {
            .plus => ".Add",
            .asterisk => ".Mul",
            .ampersand => ".And",
            .pipe => ".Or",
            .caret => ".Xor",
            else => continue,
        };

        var expected_idx: usize = 1;
        var cursor = i + 5;
        var last_end = i + 3;

        while (cursor + 3 < context.tokens.len) {
            if (context.tokens[cursor].tag != .identifier or
                !context.tokenIs(cursor, v_name) or
                context.tokens[cursor + 1].tag != .l_bracket or
                context.tokens[cursor + 2].tag != .number_literal or
                context.tokens[cursor + 3].tag != .r_bracket) break;

            const idx_str = context.tokenText(cursor + 2);
            const actual_idx = std.fmt.parseInt(usize, idx_str, 10) catch break;
            if (actual_idx != expected_idx) break;

            expected_idx += 1;
            last_end = cursor + 3;
            cursor += 4;

            if (cursor < context.tokens.len and context.tokens[cursor].tag == op_tok.tag) {
                cursor += 1;
            } else {
                break;
            }
        }

        // At least 3 elements: v[0] OP v[1] OP v[2]
        if (expected_idx < 3) continue;

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{
                .start = context.tokens[i].loc.start,
                .end = context.tokens[last_end].loc.end,
            },
            .replacement = try std.fmt.allocPrint(context.allocator, "@reduce({s}, {s})", .{ reduce_op, v_name }),
        };

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Use @reduce",
            .kind = .refactor_rewrite,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        try context.emit(.{
            .rule = .prefer_vector_reduce,
            .level = level,
            .span = context.tokens[i].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "serial lane accumulation over '{s}'; use @reduce for parallel tree reduction",
                .{v_name},
            ),
            .fixes = fixes,
        });

        i = last_end;
    }
}

test "prefer vector reduce detects 4-element addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn sum(v: @Vector(4, f32)) f32 {\n" ++
        "    return v[0] + v[1] + v[2] + v[3];\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("@reduce(.Add, v)", findings[0].fixes[0].edits[0].replacement);
}

test "prefer vector reduce detects bitwise and multiplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn calc(v: @Vector(4, u32)) u32 {\n" ++
        "    const prod = v[0] * v[1] * v[2] * v[3];\n" ++
        "    const bits = v[0] & v[1] & v[2];\n" ++
        "    return prod + bits;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("@reduce(.Mul, v)", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("@reduce(.And, v)", findings[1].fixes[0].edits[0].replacement);
}

test "non-consecutive indices are not flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn sum(v: @Vector(4, f32)) f32 {\n" ++
        "    return v[0] + v[2] + v[1] + v[3];\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer vector reduce honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn sum(v: @Vector(4, f32)) f32 {\n" ++
        "    // zig-analyzer: disable-next-line prefer-vector-reduce\n" ++
        "    return v[0] + v[1] + v[2] + v[3];\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.prefer_vector_reduce)] = .warning;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
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
