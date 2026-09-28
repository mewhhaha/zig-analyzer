const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_allocator_dupe);
    if (level == .off) return;

    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or call_index + 1 >= context.tokens.len or
            context.tokens[call_index + 1].tag != .l_paren) continue;

        const is_alloc_print = context.tokenIs(call_index, "allocPrint");
        const is_alloc_print_sentinel = context.tokenIs(call_index, "allocPrintSentinel");
        if (!is_alloc_print and !is_alloc_print_sentinel) continue;

        const is_std_fmt = (call_index >= 4 and context.tokenIs(call_index - 4, "std") and
            context.tokens[call_index - 3].tag == .period and context.tokenIs(call_index - 2, "fmt") and
            context.tokens[call_index - 1].tag == .period);
        const is_fmt = (call_index >= 2 and context.tokenIs(call_index - 2, "fmt") and
            context.tokens[call_index - 1].tag == .period);
        if (!is_std_fmt and !is_fmt) continue;

        const call_prefix_start = if (is_std_fmt) call_index - 4 else call_index - 2;

        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;

        if (is_alloc_print) {
            const args = threeArguments(context, call_index + 1, call_end) orelse continue;
            try checkAllocPrint(context, level, call_prefix_start, call_end, args, false);
        } else {
            const args = fourArguments(context, call_index + 1, call_end) orelse continue;
            // Sentinel must be 0 for dupeZ
            const sentinel_text = context.source[context.tokens[args[1].start].loc.start..context.tokens[args[1].end - 1].loc.end];
            if (!std.mem.eql(u8, std.mem.trim(u8, sentinel_text, " \t\r\n"), "0")) continue;
            const shifted_args = [3]ArgumentRange{ args[0], args[2], args[3] };
            try checkAllocPrint(context, level, call_prefix_start, call_end, shifted_args, true);
        }
    }
}

const ArgumentRange = struct { start: usize, end: usize };

fn threeArguments(context: RuleRun, opening: usize, closing: usize) ?[3]ArgumentRange {
    var commas: [3]usize = undefined;
    var comma_count: usize = 0;
    var depth: usize = 0;
    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, index| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (comma_count < commas.len) commas[comma_count] = index;
                comma_count += 1;
            },
            else => {},
        }
    }
    if (comma_count == 2) {
        if (commas[0] == opening + 1 or commas[1] == commas[0] + 1 or closing == commas[1] + 1) return null;
        return .{
            .{ .start = opening + 1, .end = commas[0] },
            .{ .start = commas[0] + 1, .end = commas[1] },
            .{ .start = commas[1] + 1, .end = closing },
        };
    } else if (comma_count == 3 and commas[2] + 1 == closing) {
        if (commas[0] == opening + 1 or commas[1] == commas[0] + 1 or commas[2] == commas[1] + 1) return null;
        return .{
            .{ .start = opening + 1, .end = commas[0] },
            .{ .start = commas[0] + 1, .end = commas[1] },
            .{ .start = commas[1] + 1, .end = commas[2] },
        };
    }
    return null;
}

fn fourArguments(context: RuleRun, opening: usize, closing: usize) ?[4]ArgumentRange {
    var commas: [4]usize = undefined;
    var comma_count: usize = 0;
    var depth: usize = 0;
    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, index| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (comma_count < commas.len) commas[comma_count] = index;
                comma_count += 1;
            },
            else => {},
        }
    }
    if (comma_count == 3) {
        if (commas[0] == opening + 1 or commas[1] == commas[0] + 1 or commas[2] == commas[1] + 1 or closing == commas[2] + 1) return null;
        return .{
            .{ .start = opening + 1, .end = commas[0] },
            .{ .start = commas[0] + 1, .end = commas[1] },
            .{ .start = commas[1] + 1, .end = commas[2] },
            .{ .start = commas[2] + 1, .end = closing },
        };
    } else if (comma_count == 4 and commas[3] + 1 == closing) {
        if (commas[0] == opening + 1 or commas[1] == commas[0] + 1 or commas[2] == commas[1] + 1 or commas[3] == commas[2] + 1) return null;
        return .{
            .{ .start = opening + 1, .end = commas[0] },
            .{ .start = commas[0] + 1, .end = commas[1] },
            .{ .start = commas[1] + 1, .end = commas[2] },
            .{ .start = commas[2] + 1, .end = commas[3] },
        };
    }
    return null;
}

fn checkAllocPrint(
    context: RuleRun,
    level: types.Level,
    call_start: usize,
    call_end: usize,
    args: [3]ArgumentRange,
    is_sentinel: bool,
) !void {
    const fmt_token = context.tokens[args[1].start];
    if (fmt_token.tag != .string_literal or args[1].end != args[1].start + 1) return;

    const fmt_text = context.tokenText(args[1].start);
    if (fmt_text.len < 2 or fmt_text[0] != '"' or fmt_text[fmt_text.len - 1] != '"') return;
    const inner_fmt = fmt_text[1 .. fmt_text.len - 1];

    const args_start = args[2].start;
    const args_end = args[2].end;
    if (args_end <= args_start) return;

    // Check args tuple: must be `.{ ... }`
    if (context.tokens[args_start].tag != .period or
        args_start + 1 >= args_end or context.tokens[args_start + 1].tag != .l_brace or
        context.tokens[args_end - 1].tag != .r_brace) return;

    const tuple_open = args_start + 1;
    const tuple_close = args_end - 1;

    const dupe_fn = if (is_sentinel) "dupeZ" else "dupe";

    const allocator_text = std.mem.trim(
        u8,
        context.source[context.tokens[args[0].start].loc.start..context.tokens[args[0].end - 1].loc.end],
        " \t\r\n",
    );

    if (std.mem.eql(u8, inner_fmt, "{s}")) {
        // Single argument inside tuple
        const inner_arg = std.mem.trim(
            u8,
            context.source[context.tokens[tuple_open].loc.end..context.tokens[tuple_close].loc.start],
            " \t\r\n,",
        );
        if (inner_arg.len == 0 or std.mem.indexOfScalar(u8, inner_arg, ',') != null) return;
        if (containsComment(inner_arg)) return;

        const replacement = try std.fmt.allocPrint(
            context.allocator,
            "{s}.{s}(u8, {s})",
            .{ allocator_text, dupe_fn, inner_arg },
        );
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{
                .start = context.tokens[call_start].loc.start,
                .end = context.tokens[call_end].loc.end,
            },
            .replacement = replacement,
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = try std.fmt.allocPrint(context.allocator, "Replace with {s}.{s}", .{ allocator_text, dupe_fn }),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .prefer_allocator_dupe,
            .level = level,
            .span = context.tokens[call_start].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "formatting '{s}' duplicates a slice; use '{s}.{s}(u8, {s})' directly for better performance",
                .{ inner_fmt, allocator_text, dupe_fn, inner_arg },
            ),
            .fixes = fixes,
        });
    } else if (std.mem.indexOfScalar(u8, inner_fmt, '{') == null) {
        // Static string without format specifiers, tuple should be empty
        const tuple_contents = std.mem.trim(
            u8,
            context.source[context.tokens[tuple_open].loc.end..context.tokens[tuple_close].loc.start],
            " \t\r\n",
        );
        if (tuple_contents.len != 0) return;

        const replacement = try std.fmt.allocPrint(
            context.allocator,
            "{s}.{s}(u8, {s})",
            .{ allocator_text, dupe_fn, fmt_text },
        );
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{
                .start = context.tokens[call_start].loc.start,
                .end = context.tokens[call_end].loc.end,
            },
            .replacement = replacement,
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = try std.fmt.allocPrint(context.allocator, "Replace with {s}.{s}", .{ allocator_text, dupe_fn }),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .prefer_allocator_dupe,
            .level = level,
            .span = context.tokens[call_start].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "formatting static string has no specifiers; use '{s}.{s}(u8, {s})' directly for better performance",
                .{ allocator_text, dupe_fn, fmt_text },
            ),
            .fixes = fixes,
        });
    }
}

fn containsComment(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "//") != null or std.mem.indexOf(u8, text, "/*") != null;
}

test "prefer allocator dupe detects single slice format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn clone(allocator: std.mem.Allocator, name: []const u8) ![]u8 {\n" ++
        "    return try std.fmt.allocPrint(allocator, \"{s}\", .{name});\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("allocator.dupe(u8, name)", findings[0].fixes[0].edits[0].replacement);
}

test "prefer allocator dupe detects static literal format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn makeDefault(allocator: std.mem.Allocator) ![]u8 {\n" ++
        "    return try fmt.allocPrint(allocator, \"default_value\", .{});\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("allocator.dupe(u8, \"default_value\")", findings[0].fixes[0].edits[0].replacement);
}

test "prefer allocator dupe detects allocPrintSentinel with 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn cloneZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {\n" ++
        "    return try std.fmt.allocPrintSentinel(allocator, 0, \"{s}\", .{path});\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("allocator.dupeZ(u8, path)", findings[0].fixes[0].edits[0].replacement);
}

test "formatting with multiple specifiers is untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn format(allocator: std.mem.Allocator, a: []const u8, b: usize) ![]u8 {\n" ++
        "    return try std.fmt.allocPrint(allocator, \"{s}:{d}\", .{ a, b });\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_allocator_dupe)] = .warning;
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
