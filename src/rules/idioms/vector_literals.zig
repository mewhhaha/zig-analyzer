//! Array literals that a vector construct expresses directly: a repeated
//! element (`@splat`), a lane-wise load, an element-wise operation, and an
//! index sequence (`std.simd.iota`). All four read the literal's elements.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .prefer_vector_splat,
    .prefer_vector_load,
    .prefer_vector_op,
    .prefer_simd_iota,
};

pub fn run(context: RuleRun) !void {
    try findSplat(context);
    try findLoad(context);
    try findOp(context);
    try findIota(context);
}

fn findSplat(context: RuleRun) !void {
    const level = context.level(.prefer_vector_splat);
    if (level == .off) return;

    for (context.tokens, 0..) |token, index| {
        var dot_brace_start: ?usize = null;

        // Pattern A: @as(@Vector(...), .{ ... })
        if (token.tag == .builtin and context.tokenIs(index, "@as") and index + 4 < context.tokens.len and
            context.tokens[index + 1].tag == .l_paren)
        {
            if (context.tokens[index + 2].tag == .builtin and context.tokenIs(index + 2, "@Vector")) {
                const paren_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
                // Find comma at depth 1 (separating @as type and value)
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

        const first_elem = elements[0];
        const first_text = std.mem.trim(u8, context.source[context.tokens[first_elem.start].loc.start..context.tokens[first_elem.end - 1].loc.end], " \t\r\n");
        if (first_text.len == 0) continue;

        var all_identical = true;
        for (elements[1..]) |elem| {
            const elem_text = std.mem.trim(u8, context.source[context.tokens[elem.start].loc.start..context.tokens[elem.end - 1].loc.end], " \t\r\n");
            if (!std.mem.eql(u8, first_text, elem_text)) {
                all_identical = false;
                break;
            }
        }

        if (!all_identical) continue;

        const fixes = try context.singleFix(.{
            .title = "Use @splat",
            .kind = .refactor_rewrite,
            .span = .{
                .start = context.tokens[dot_start].loc.start,
                .end = context.tokens[brace_end].loc.end,
            },
            .replacement = try context.allocator.print("@splat({s})", .{first_text}),
            .preferred = true,
            .fix_all = true,
        });

        try context.emit(.{
            .rule = .prefer_vector_splat,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("vector literal repeats '{s}' across all lanes; use @splat", .{first_text}),
            .fixes = fixes,
        });
    }
}

const ElementSpan = struct { start: usize, end: usize };

fn extractElements(context: RuleRun, brace_start: usize, brace_end: usize) ![]const ElementSpan {
    var commas: [64]usize = undefined;
    var comma_count: usize = 0;
    var depth: usize = 0;
    for (context.tokens[brace_start + 1 .. brace_end], brace_start + 1..) |tok, idx| switch (tok.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            if (comma_count < commas.len) {
                commas[comma_count] = idx;
                comma_count += 1;
            }
        },
        else => {},
    };

    var list: std.ArrayList(ElementSpan) = .empty;
    errdefer list.deinit(context.allocator);
    var current_start = brace_start + 1;
    for (commas[0..comma_count]) |comma_idx| {
        if (current_start < comma_idx) {
            try list.append(context.allocator, .{ .start = current_start, .end = comma_idx });
        }
        current_start = comma_idx + 1;
    }
    if (current_start < brace_end) {
        try list.append(context.allocator, .{ .start = current_start, .end = brace_end });
    }
    return try list.toOwnedSlice(context.allocator);
}

fn findLoad(context: RuleRun) !void {
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

        const fixes = try context.singleFix(.{
            .title = "Use direct vector load from array",
            .kind = .refactor_rewrite,
            .span = .{
                .start = context.tokens[dot_start].loc.start,
                .end = context.tokens[brace_end].loc.end,
            },
            .replacement = try context.allocator.dupe(u8, array_receiver.?),
            .preferred = true,
            .fix_all = true,
        });

        try context.emit(.{
            .rule = .prefer_vector_load,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("manually unpacking array '{s}' into vector; use direct vector coercion/cast", .{array_receiver.?}),
            .fixes = fixes,
        });
    }
}

fn findOp(context: RuleRun) !void {
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

        const fixes = try context.singleFix(.{
            .title = "Use element-wise vector operation",
            .kind = .refactor_rewrite,
            .span = .{
                .start = context.tokens[dot_start].loc.start,
                .end = context.tokens[brace_end].loc.end,
            },
            .replacement = replacement,
            .preferred = true,
            .fix_all = true,
        });

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

/// Whether the file binds `std`, which the rewrite needs.
fn declaresStd(context: RuleRun) bool {
    for (context.tokens[0 .. context.tokens.len - 1], 0..) |token, index| {
        if (token.tag == .keyword_const and context.tokenIs(index + 1, "std")) return true;
    }
    return false;
}

fn findIota(context: RuleRun) !void {
    const level = context.level(.prefer_simd_iota);
    if (level == .off) return;

    for (context.tokens, 0..) |token, index| {
        var dot_brace_start: ?usize = null;
        var vec_type_text: ?[]const u8 = null;
        var vec_len_text: ?[]const u8 = null;
        var whole_call_start: ?usize = null;

        // Pattern A: @as(@Vector(len, type), .{ 0, 1, 2, ... })
        if (token.tag == .builtin and context.tokenIs(index, "@as") and index + 4 < context.tokens.len and
            context.tokens[index + 1].tag == .l_paren)
        {
            if (context.tokens[index + 2].tag == .builtin and context.tokenIs(index + 2, "@Vector")) {
                const paren_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
                const vec_paren_end = context.matchingToken(index + 3, .l_paren, .r_paren) orelse continue;

                // Extract len and type inside @Vector(len, type)
                if (extractVectorParams(context, index + 3, vec_paren_end)) |params| {
                    vec_len_text = params.len_text;
                    vec_type_text = params.type_text;
                }

                // Find comma at depth 1 (separating @as type and value)
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
                        whole_call_start = index;
                    }
                }
            }
        }

        // Pattern B: const/var name: @Vector(len, type) = .{ 0, 1, 2, ... };
        if (dot_brace_start == null and (token.tag == .keyword_const or token.tag == .keyword_var) and
            index + 8 < context.tokens.len and context.tokens[index + 1].tag == .identifier and
            context.tokens[index + 2].tag == .colon and context.tokens[index + 3].tag == .builtin and
            context.tokenIs(index + 3, "@Vector"))
        {
            const vec_paren_end = context.matchingToken(index + 4, .l_paren, .r_paren) orelse continue;
            if (extractVectorParams(context, index + 4, vec_paren_end)) |params| {
                vec_len_text = params.len_text;
                vec_type_text = params.type_text;
            }
            if (vec_paren_end + 3 < context.tokens.len and context.tokens[vec_paren_end + 1].tag == .equal and
                context.tokens[vec_paren_end + 2].tag == .period and context.tokens[vec_paren_end + 3].tag == .l_brace)
            {
                dot_brace_start = vec_paren_end + 2;
            }
        }

        const dot_start = dot_brace_start orelse continue;
        const type_str = vec_type_text orelse continue;
        const len_str = vec_len_text orelse continue;

        const brace_start = dot_start + 1;
        const brace_end = context.matchingToken(brace_start, .l_brace, .r_brace) orelse continue;

        const elements = try extractElements(context, brace_start, brace_end);
        if (elements.len < 3) continue;

        var is_iota = true;
        for (elements, 0..) |elem, expected_idx| {
            const elem_text = std.mem.trim(u8, context.source[context.tokens[elem.start].loc.start..context.tokens[elem.end - 1].loc.end], " \t\r\n");
            const parsed_val = std.fmt.parseInt(usize, elem_text, 10) catch {
                is_iota = false;
                break;
            };
            if (parsed_val != expected_idx) {
                is_iota = false;
                break;
            }
        }

        if (!is_iota or !declaresStd(context)) continue;

        const replacement = try context.allocator.print("std.simd.iota({s}, {s})", .{ type_str, len_str });

        const edits = try context.allocator.alloc(types.Edit, 1);
        if (whole_call_start) |as_start| {
            const paren_end = context.matchingToken(as_start + 1, .l_paren, .r_paren) orelse continue;
            edits[0] = .{
                .span = .{
                    .start = context.tokens[as_start].loc.start,
                    .end = context.tokens[paren_end].loc.end,
                },
                .replacement = replacement,
            };
        } else {
            edits[0] = .{
                .span = .{
                    .start = context.tokens[dot_start].loc.start,
                    .end = context.tokens[brace_end].loc.end,
                },
                .replacement = replacement,
            };
        }

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Use std.simd.iota",
            .kind = .refactor_rewrite,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        try context.emit(.{
            .rule = .prefer_simd_iota,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
                "vector literal initializes sequential integers 0..{d}; use 'std.simd.iota({s}, {s})'",
                .{ elements.len - 1, type_str, len_str },
            ),
            .fixes = fixes,
        });
    }
}

const VectorParams = struct {
    len_text: []const u8,
    type_text: []const u8,
};

fn extractVectorParams(context: RuleRun, opening: usize, closing: usize) ?VectorParams {
    var comma_idx: ?usize = null;
    var depth: usize = 0;
    for (context.tokens[opening + 1 .. closing], opening + 1..) |t, i| switch (t.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0 and comma_idx == null) {
            comma_idx = i;
        },
        else => {},
    };

    const c = comma_idx orelse return null;
    const len_part = std.mem.trim(u8, context.source[context.tokens[opening + 1].loc.start..context.tokens[c].loc.start], " \t\r\n");
    const type_part = std.mem.trim(u8, context.source[context.tokens[c + 1].loc.start..context.tokens[closing].loc.start], " \t\r\n");
    if (len_part.len == 0 or type_part.len == 0) return null;
    return .{
        .len_text = len_part,
        .type_text = type_part,
    };
}

test "prefer vector splat detects identical elements in @as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn getVec() @Vector(4, f32) {\n" ++
        "    return @as(@Vector(4, f32), .{ 1.0, 1.0, 1.0, 1.0 });\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_vector_splat}, .warning));

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("@splat(1.0)", findings[0].fixes[0].edits[0].replacement);
}

test "prefer vector splat detects identical elements in variable declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn getVec(x: f32) @Vector(4, f32) {\n" ++
        "    const v: @Vector(4, f32) = .{ x, x, x, x };\n" ++
        "    return v;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_vector_splat}, .warning));

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("@splat(x)", findings[0].fixes[0].edits[0].replacement);
}

test "differing vector elements are not flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn getVec() @Vector(4, f32) {\n" ++
        "    return @as(@Vector(4, f32), .{ 1.0, 2.0, 3.0, 4.0 });\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_vector_splat}, .warning));

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer vector load detects consecutive array unpacking in @as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn toVec(arr: [4]f32) @Vector(4, f32) {\n" ++
        "    return @as(@Vector(4, f32), .{ arr[0], arr[1], arr[2], arr[3] });\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_vector_load}, .warning));

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
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_vector_load}, .warning));

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
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_vector_load}, .warning));

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer vector op detects element-wise addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn add(a: @Vector(4, f32), b: @Vector(4, f32)) @Vector(4, f32) {\n" ++
        "    return @as(@Vector(4, f32), .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] });\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_vector_op}, .warning));

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
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_vector_op}, .warning));

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("a * b", findings[0].fixes[0].edits[0].replacement);
}

test "prefer_simd_iota flags sequential integers in @as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "pub fn testIota() void {\n" ++
        "    const v = @as(@Vector(4, u32), .{ 0, 1, 2, 3 });\n" ++
        "    _ = v;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_simd_iota}, .warning));
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("std.simd.iota(u32, 4)", findings[0].fixes[0].edits[0].replacement);
}

test "prefer_simd_iota flags sequential integers in typed const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "pub fn testIota() void {\n" ++
        "    const v: @Vector(4, i32) = .{ 0, 1, 2, 3 };\n" ++
        "    _ = v;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_simd_iota}, .warning));
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("std.simd.iota(i32, 4)", findings[0].fixes[0].edits[0].replacement);
}

test "prefer_simd_iota needs std in scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const lanes: @Vector(4, u32) = .{ 0, 1, 2, 3 };\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_simd_iota}, .warning));
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer_simd_iota ignores non-sequential values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn testNonIota() void {\n" ++
        "    const v = @as(@Vector(4, u32), .{ 0, 1, 4, 3 });\n" ++
        "    _ = v;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_simd_iota}, .warning));
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
