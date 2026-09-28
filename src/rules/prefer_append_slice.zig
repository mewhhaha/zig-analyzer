const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_append_slice);
    if (level == .off) return;

    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 6 >= context.tokens.len or
            context.tokens[for_index + 1].tag != .l_paren) continue;

        const paren_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (paren_end + 3 >= context.tokens.len or context.tokens[paren_end + 1].tag != .pipe) continue;

        if (paren_end + 3 >= context.tokens.len or context.tokens[paren_end + 1].tag != .pipe or
            context.tokens[paren_end + 2].tag != .identifier or context.tokens[paren_end + 3].tag != .pipe) continue;
        const capture_end = paren_end + 3;
        const capture_name = context.tokenText(paren_end + 2);

        if (capture_end + 1 >= context.tokens.len or context.tokens[capture_end + 1].tag != .l_brace) continue;
        const brace_end = context.matchingToken(capture_end + 1, .l_brace, .r_brace) orelse continue;

        const body_tokens = context.tokens[capture_end + 2 .. brace_end];
        if (body_tokens.len < 4) continue;

        const loop_source = context.source[token.loc.start..context.tokens[brace_end].loc.end];
        if (containsComment(loop_source)) continue;

        const iterable = std.mem.trim(
            u8,
            context.source[context.tokens[for_index + 2].loc.start..context.tokens[paren_end - 1].loc.end],
            " \t\r\n",
        );
        if (iterable.len == 0 or std.mem.indexOfScalar(u8, iterable, ',') != null) continue;

        var cursor: usize = capture_end + 2;
        const has_try = context.tokens[cursor].tag == .keyword_try;
        if (has_try) cursor += 1;

        // Receiver: path before .append or .appendAssumeCapacity
        const method_call_start = cursor;
        var dot_index: ?usize = null;
        while (cursor < brace_end and context.tokens[cursor].tag != .l_paren) : (cursor += 1) {
            if (context.tokens[cursor].tag == .period) dot_index = cursor;
        }
        if (dot_index == null or cursor >= brace_end or context.tokens[cursor].tag != .l_paren) continue;

        const dot = dot_index.?;
        const method_name_token = dot + 1;
        if (method_name_token + 1 != cursor) continue;

        const method_name = context.tokenText(method_name_token);
        const is_append = std.mem.eql(u8, method_name, "append");
        const is_assume = std.mem.eql(u8, method_name, "appendAssumeCapacity");
        if (!is_append and !is_assume) continue;

        const slice_method_name: []const u8 = if (is_append) "appendSlice" else "appendSliceAssumeCapacity";

        const call_args_end = context.matchingToken(cursor, .l_paren, .r_paren) orelse continue;
        if (call_args_end + 1 >= brace_end or context.tokens[call_args_end + 1].tag != .semicolon or
            call_args_end + 2 != brace_end) continue;

        // Check call arguments
        const args_text = std.mem.trim(
            u8,
            context.source[context.tokens[cursor].loc.end..context.tokens[call_args_end].loc.start],
            " \t\r\n",
        );

        const receiver_text = std.mem.trim(
            u8,
            context.source[context.tokens[method_call_start].loc.start..context.tokens[dot].loc.start],
            " \t\r\n",
        );

        var replacement: []const u8 = undefined;
        if (std.mem.eql(u8, args_text, capture_name)) {
            // single argument: receiver.appendSlice(iterable)
            replacement = if (has_try)
                try std.fmt.allocPrint(context.allocator, "try {s}.{s}({s});", .{ receiver_text, slice_method_name, iterable })
            else
                try std.fmt.allocPrint(context.allocator, "{s}.{s}({s});", .{ receiver_text, slice_method_name, iterable });
        } else if (std.mem.endsWith(u8, args_text, capture_name) and std.mem.indexOfScalar(u8, args_text, ',') != null) {
            const comma_pos = std.mem.lastIndexOfScalar(u8, args_text, ',').?;
            const first_arg = std.mem.trim(u8, args_text[0..comma_pos], " \t\r\n");
            const second_arg = std.mem.trim(u8, args_text[comma_pos + 1 ..], " \t\r\n");
            if (!std.mem.eql(u8, second_arg, capture_name)) continue;
            replacement = if (has_try)
                try std.fmt.allocPrint(context.allocator, "try {s}.{s}({s}, {s});", .{ receiver_text, slice_method_name, first_arg, iterable })
            else
                try std.fmt.allocPrint(context.allocator, "{s}.{s}({s}, {s});", .{ receiver_text, slice_method_name, first_arg, iterable });
        } else continue;

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{
                .start = token.loc.start,
                .end = context.tokens[brace_end].loc.end,
            },
            .replacement = replacement,
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = try std.fmt.allocPrint(context.allocator, "Replace loop with {s}", .{slice_method_name}),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .prefer_append_slice,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "loop appends elements one by one; use '{s}.{s}' for better performance",
                .{ receiver_text, slice_method_name },
            ),
            .fixes = fixes,
        });
    }
}

fn containsComment(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "//") != null or std.mem.indexOf(u8, text, "/*") != null;
}

test "prefer append slice detects element loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn fill(list: *std.ArrayList(u8), items: []const u8) !void {\n" ++
        "    for (items) |item| {\n" ++
        "        try list.append(item);\n" ++
        "    }\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("try list.appendSlice(items);", findings[0].fixes[0].edits[0].replacement);
}

test "prefer append slice detects unmanaged append with allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn fill(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, items: []const u8) !void {\n" ++
        "    for (items) |item| {\n" ++
        "        try list.append(allocator, item);\n" ++
        "    }\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("try list.appendSlice(allocator, items);", findings[0].fixes[0].edits[0].replacement);
}

test "prefer append slice detects appendAssumeCapacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn fill(list: *std.ArrayList(u8), items: []const u8) void {\n" ++
        "    for (items) |item| {\n" ++
        "        list.appendAssumeCapacity(item);\n" ++
        "    }\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("list.appendSliceAssumeCapacity(items);", findings[0].fixes[0].edits[0].replacement);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_append_slice)] = .warning;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    return findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokenizer = std.zig.Tokenizer.init(source);
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }
    return tokens.toOwnedSlice(allocator);
}
