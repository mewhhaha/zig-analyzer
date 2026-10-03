const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");
const extractElements = @import("prefer_vector_splat.zig").extractElements;

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_vector_op);
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

        var left_receiver: ?[]const u8 = null;
        var right_receiver: ?[]const u8 = null;
        var common_op: ?std.zig.Token.Tag = null;
        var valid_op = true;

        for (elements, 0..) |elem, expected_idx| {
            // Must have: left[expected_idx] OP right[expected_idx]
            // Look for OP at depth 0 inside element
            var op_idx: ?usize = null;
            var depth: usize = 0;
            for (context.tokens[elem.start..elem.end], elem.start..) |t, i| switch (t.tag) {
                .l_paren, .l_bracket, .l_brace => depth += 1,
                .r_paren, .r_bracket, .r_brace => depth -|= 1,
                .plus, .minus, .asterisk, .slash => if (depth == 0 and op_idx == null) {
                    op_idx = i;
                },
                else => {},
            };

            const op_pos = op_idx orelse {
                valid_op = false;
                break;
            };

            const op_tag = context.tokens[op_pos].tag;
            if (common_op) |co| {
                if (co != op_tag) {
                    valid_op = false;
                    break;
                }
            } else {
                common_op = op_tag;
            }

            // Left part: elem.start .. op_pos
            // Must end with [ expected_idx ]
            if (op_pos < elem.start + 3) {
                valid_op = false;
                break;
            }
            if (context.tokens[op_pos - 1].tag != .r_bracket or
                context.tokens[op_pos - 2].tag != .number_literal or
                context.tokens[op_pos - 3].tag != .l_bracket)
            {
                valid_op = false;
                break;
            }
            const left_idx = std.fmt.parseInt(usize, context.tokenText(op_pos - 2), 10) catch {
                valid_op = false;
                break;
            };
            if (left_idx != expected_idx) {
                valid_op = false;
                break;
            }
            const left_name = std.mem.trim(u8, context.source[context.tokens[elem.start].loc.start..context.tokens[op_pos - 3].loc.start], " \t\r\n");

            // Right part: op_pos + 1 .. elem.end
            // Must end with [ expected_idx ]
            if (elem.end < op_pos + 4) {
                valid_op = false;
                break;
            }
            if (context.tokens[elem.end - 1].tag != .r_bracket or
                context.tokens[elem.end - 2].tag != .number_literal or
                context.tokens[elem.end - 3].tag != .l_bracket)
            {
                valid_op = false;
                break;
            }
            const right_idx = std.fmt.parseInt(usize, context.tokenText(elem.end - 2), 10) catch {
                valid_op = false;
                break;
            };
            if (right_idx != expected_idx) {
                valid_op = false;
                break;
            }
            const right_name = std.mem.trim(u8, context.source[context.tokens[op_pos + 1].loc.start..context.tokens[elem.end - 3].loc.start], " \t\r\n");

            if (left_name.len == 0 or right_name.len == 0) {
                valid_op = false;
                break;
            }

            if (left_receiver) |lr| {
                if (!std.mem.eql(u8, lr, left_name)) {
                    valid_op = false;
                    break;
                }
            } else {
                left_receiver = left_name;
            }

            if (right_receiver) |rr| {
                if (!std.mem.eql(u8, rr, right_name)) {
                    valid_op = false;
                    break;
                }
            } else {
                right_receiver = right_name;
            }
        }

        if (!valid_op or left_receiver == null or right_receiver == null or common_op == null) continue;

        const op_str: []const u8 = switch (common_op.?) {
            .plus => "+",
            .minus => "-",
            .asterisk => "*",
            .slash => "/",
            else => continue,
        };

        const replacement = try context.allocator.print(
            "{s} {s} {s}",
            .{ left_receiver.?, op_str, right_receiver.? },
        );

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{
                .start = context.tokens[dot_start].loc.start,
                .end = context.tokens[brace_end].loc.end,
            },
            .replacement = replacement,
        };

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Use element-wise vector operation",
            .kind = .refactor_rewrite,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        try context.emit(.{
            .rule = .prefer_vector_op,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "element-wise lane operation can be computed directly with vector '{s}'",
                .{op_str},
            ),
            .fixes = fixes,
        });
    }
}

test "prefer vector op detects element-wise addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn add(a: @Vector(4, f32), b: @Vector(4, f32)) @Vector(4, f32) {\n" ++
        "    return @as(@Vector(4, f32), .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] });\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("a + b", findings[0].fixes[0].edits[0].replacement);
}

test "prefer vector op detects element-wise multiplication in var decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn mul(a: @Vector(4, f32), b: @Vector(4, f32)) @Vector(4, f32) {\n" ++
        "    const c: @Vector(4, f32) = .{ a[0] * b[0], a[1] * b[1], a[2] * b[2], a[3] * b[3] };\n" ++
        "    return c;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("a * b", findings[0].fixes[0].edits[0].replacement);
}

test "prefer vector op honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn add(a: @Vector(4, f32), b: @Vector(4, f32)) @Vector(4, f32) {\n" ++
        "    // zig-analyzer: disable-next-line prefer-vector-op\n" ++
        "    return @as(@Vector(4, f32), .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] });\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.prefer_vector_op)] = .warning;
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
