const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");
const extractElements = @import("prefer_vector_splat.zig").extractElements;

pub fn run(context: RuleRun) !void {
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

        if (!is_iota) continue;

        const replacement = try std.fmt.allocPrint(context.allocator, "std.simd.iota({s}, {s})", .{ type_str, len_str });

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
            .message = try std.fmt.allocPrint(
                context.allocator,
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

test "prefer_simd_iota flags sequential integers in @as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn testIota() void {\n" ++
        "    const v = @as(@Vector(4, u32), .{ 0, 1, 2, 3 });\n" ++
        "    _ = v;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("std.simd.iota(u32, 4)", findings[0].fixes[0].edits[0].replacement);
}

test "prefer_simd_iota flags sequential integers in typed const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn testIota() void {\n" ++
        "    const v: @Vector(4, i32) = .{ 0, 1, 2, 3 };\n" ++
        "    _ = v;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("std.simd.iota(i32, 4)", findings[0].fixes[0].edits[0].replacement);
}

test "prefer_simd_iota ignores non-sequential values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn testNonIota() void {\n" ++
        "    const v = @as(@Vector(4, u32), .{ 0, 1, 4, 3 });\n" ++
        "    _ = v;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.prefer_simd_iota)] = .warning;
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
