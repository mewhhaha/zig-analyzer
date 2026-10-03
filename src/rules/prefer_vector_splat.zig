const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
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

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{
                .start = context.tokens[dot_start].loc.start,
                .end = context.tokens[brace_end].loc.end,
            },
            .replacement = try context.allocator.print("@splat({s})", .{first_text}),
        };

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Use @splat",
            .kind = .refactor_rewrite,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        try context.emit(.{
            .rule = .prefer_vector_splat,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("vector literal repeats '{s}' across all lanes; use @splat", .{first_text}),
            .fixes = fixes,
        });
    }
}

pub const ElementSpan = struct { start: usize, end: usize };

pub fn extractElements(context: RuleRun, brace_start: usize, brace_end: usize) ![]const ElementSpan {
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

test "prefer vector splat detects identical elements in @as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn getVec() @Vector(4, f32) {\n" ++
        "    return @as(@Vector(4, f32), .{ 1.0, 1.0, 1.0, 1.0 });\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

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
    const findings = try findingsFor(arena.allocator(), source);

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
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer vector splat honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn getVec() @Vector(4, f32) {\n" ++
        "    // zig-analyzer: disable-next-line prefer-vector-splat\n" ++
        "    return @as(@Vector(4, f32), .{ 1.0, 1.0, 1.0, 1.0 });\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.prefer_vector_splat)] = .warning;
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
