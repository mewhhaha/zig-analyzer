const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");
const extractElements = @import("prefer_vector_splat.zig").extractElements;

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_vector_load);
    if (level == .off) return;

    for (context.tokens, 0..) |token, index| {
        var dot_brace_start: ?usize = null;

        // Pattern A: @as(@Vector(...), .{ ... })
        if (token.tag == .builtin and context.tokenIs(index, "@as") and index + 4 < context.tokens.len and
            context.tokens[index + 1].tag == .l_paren)
        {
            if (context.tokens[index + 2].tag == .builtin and context.tokenIs(index + 2, "@Vector")) {
                const paren_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
                var depth: usize = 0;
                var comma_idx: ?usize = null;
                for (context.tokens[index + 1 .. paren_end], index + 1..) |t, i| switch (t.tag) {
                    .l_paren, .l_bracket, .l_brace => depth += 1,
                    .r_paren, .r_bracket, .r_brace => depth -|= 1,
                    .comma => if (depth == 1 and comma_idx == null) {
                        comma_idx = i;
                    },
                    else => {},
                };
                if (comma_idx) |c| {
                    if (c + 2 < paren_end and context.tokens[c + 1].tag == .period and context.tokens[c + 2].tag == .l_brace) {
                        dot_brace_start = c + 1;
                    }
                }
            }
        }

        // Pattern B: const/var name: @Vector(...) = .{ ... };
        if (dot_brace_start == null and (token.tag == .keyword_const or token.tag == .keyword_var) and
            index + 8 < context.tokens.len and context.tokens[index + 1].tag == .identifier and
            context.tokens[index + 2].tag == .colon and context.tokens[index + 3].tag == .builtin and
            context.tokenIs(index + 3, "@Vector"))
        {
            const vec_paren_end = context.matchingToken(index + 4, .l_paren, .r_paren) orelse continue;
            if (vec_paren_end + 3 < context.tokens.len and context.tokens[vec_paren_end + 1].tag == .equal and
                context.tokens[vec_paren_end + 2].tag == .period and context.tokens[vec_paren_end + 3].tag == .l_brace)
            {
                dot_brace_start = vec_paren_end + 2;
            }
        }

        const dot_start = dot_brace_start orelse continue;
        const brace_start = dot_start + 1;
        const brace_end = context.matchingToken(brace_start, .l_brace, .r_brace) orelse continue;

        const elements = try extractElements(context, brace_start, brace_end);
        if (elements.len < 2) continue;

        var array_receiver: ?[]const u8 = null;
        var valid_load = true;

        for (elements, 0..) |elem, expected_idx| {
            // Must end with [ expected_idx ]
            if (elem.end < elem.start + 3) {
                valid_load = false;
                break;
            }
            if (context.tokens[elem.end - 1].tag != .r_bracket or
                context.tokens[elem.end - 2].tag != .number_literal or
                context.tokens[elem.end - 3].tag != .l_bracket)
            {
                valid_load = false;
                break;
            }

            const idx_str = context.tokenText(elem.end - 2);
            const actual_idx = std.fmt.parseInt(usize, idx_str, 10) catch {
                valid_load = false;
                break;
            };
            if (actual_idx != expected_idx) {
                valid_load = false;
                break;
            }

            const receiver = std.mem.trim(
                u8,
                context.source[context.tokens[elem.start].loc.start..context.tokens[elem.end - 3].loc.start],
                " \t\r\n",
            );
            if (receiver.len == 0) {
                valid_load = false;
                break;
            }

            if (array_receiver) |arr| {
                if (!std.mem.eql(u8, arr, receiver)) {
                    valid_load = false;
                    break;
                }
            } else {
                array_receiver = receiver;
            }
        }

        if (!valid_load or array_receiver == null) continue;

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{
                .start = context.tokens[dot_start].loc.start,
                .end = context.tokens[brace_end].loc.end,
            },
            .replacement = try context.allocator.dupe(u8, array_receiver.?),
        };

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Use direct vector load from array",
            .kind = .refactor_rewrite,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        try context.emit(.{
            .rule = .prefer_vector_load,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(context.allocator, "manually unpacking array '{s}' into vector; use direct vector coercion/cast", .{array_receiver.?}),
            .fixes = fixes,
        });
    }
}

test "prefer vector load detects consecutive array unpacking in @as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn toVec(arr: [4]f32) @Vector(4, f32) {\n" ++
        "    return @as(@Vector(4, f32), .{ arr[0], arr[1], arr[2], arr[3] });\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("arr", findings[0].fixes[0].edits[0].replacement);
}

test "prefer vector load detects consecutive array unpacking in variable declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn toVec(arr: [4]f32) @Vector(4, f32) {\n" ++
        "    const v: @Vector(4, f32) = .{ arr[0], arr[1], arr[2], arr[3] };\n" ++
        "    return v;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("arr", findings[0].fixes[0].edits[0].replacement);
}

test "non-consecutive unpacking is not flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn toVec(arr: [4]f32) @Vector(4, f32) {\n" ++
        "    return @as(@Vector(4, f32), .{ arr[3], arr[2], arr[1], arr[0] });\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer vector load honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn toVec(arr: [4]f32) @Vector(4, f32) {\n" ++
        "    // zig-analyzer: disable-next-line prefer-vector-load\n" ++
        "    return @as(@Vector(4, f32), .{ arr[0], arr[1], arr[2], arr[3] });\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.prefer_vector_load)] = .warning;
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
