const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");
const owned_call = @import("owned_call.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_allocator_dupe);
    if (level == .off) return;

    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or call_index + 1 >= context.tokens.len or
            context.tokens[call_index + 1].tag != .l_paren) continue;
        const legacy = context.tokenIs(call_index, "allocPrint") or context.tokenIs(call_index, "allocPrintSentinel");
        const allocator_method = context.tokenIs(call_index, "print") or context.tokenIs(call_index, "printSentinel");
        if (!legacy and !allocator_method) continue;
        const sentinel = context.tokenIs(call_index, "allocPrintSentinel") or context.tokenIs(call_index, "printSentinel");
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;

        if (legacy) {
            const is_std_fmt = call_index >= 4 and context.tokenIs(call_index - 4, "std") and
                context.tokens[call_index - 3].tag == .period and context.tokenIs(call_index - 2, "fmt") and
                context.tokens[call_index - 1].tag == .period;
            const is_fmt = call_index >= 2 and context.tokenIs(call_index - 2, "fmt") and
                context.tokens[call_index - 1].tag == .period;
            if (!is_std_fmt and !is_fmt) continue;
            const call_start = if (is_std_fmt) call_index - 4 else call_index - 2;
            if (sentinel) {
                const args = arguments(4, context, call_index + 1, call_end) orelse continue;
                if (!isZero(context, args[3])) continue;
                try checkAllocPrint(context, level, call_start, call_end, .{ args[0], args[1], args[2] }, true);
            } else {
                const args = arguments(3, context, call_index + 1, call_end) orelse continue;
                try checkAllocPrint(context, level, call_start, call_end, args, false);
            }
        } else {
            if (call_index < 2 or context.tokens[call_index - 1].tag != .period or
                context.tokens[call_index - 2].tag != .identifier) continue;
            var receiver_start = call_index - 2;
            while (receiver_start >= 2 and context.tokens[receiver_start - 1].tag == .period and
                context.tokens[receiver_start - 2].tag == .identifier) receiver_start -= 2;
            if (!owned_call.printReceiverIsAllocator(context.source, context.tokens, call_index - 2)) continue;
            const receiver = ArgumentRange{ .start = receiver_start, .end = call_index - 1 };
            if (sentinel) {
                const args = arguments(3, context, call_index + 1, call_end) orelse continue;
                if (!isZero(context, args[2])) continue;
                try checkAllocPrint(context, level, receiver_start, call_end, .{ receiver, args[0], args[1] }, true);
            } else {
                const args = arguments(2, context, call_index + 1, call_end) orelse continue;
                try checkAllocPrint(context, level, receiver_start, call_end, .{ receiver, args[0], args[1] }, false);
            }
        }
    }
}

const ArgumentRange = struct { start: usize, end: usize };

fn arguments(comptime count: usize, context: RuleRun, opening: usize, closing: usize) ?[count]ArgumentRange {
    var result: [count]ArgumentRange = undefined;
    var argument_start = opening + 1;
    var argument_count: usize = 0;
    var depth: usize = 0;
    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            if (argument_count == count or index == argument_start) return null;
            result[argument_count] = .{ .start = argument_start, .end = index };
            argument_count += 1;
            argument_start = index + 1;
        },
        else => {},
    };
    if (argument_start < closing) {
        if (argument_count == count) return null;
        result[argument_count] = .{ .start = argument_start, .end = closing };
        argument_count += 1;
    }
    return if (argument_count == count) result else null;
}

fn isZero(context: RuleRun, argument: ArgumentRange) bool {
    return argument.end == argument.start + 1 and context.tokenIs(argument.start, "0");
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
    const inner_fmt = std.zig.string_literal.parseAlloc(context.allocator, fmt_text) catch |err| switch (err) {
        error.InvalidLiteral => return,
        error.OutOfMemory => return err,
    };
    defer context.allocator.free(inner_fmt);

    const args_start = args[2].start;
    const args_end = args[2].end;
    if (args_end <= args_start) return;

    // Check args tuple: must be `.{ ... }`
    if (context.tokens[args_start].tag != .period or
        args_start + 1 >= args_end or context.tokens[args_start + 1].tag != .l_brace or
        context.tokens[args_end - 1].tag != .r_brace) return;

    const tuple_open = args_start + 1;
    const tuple_close = args_end - 1;

    const dupe_fn = if (is_sentinel) "dupeSentinel" else "dupe";
    const sentinel_argument: []const u8 = if (is_sentinel) ", 0" else "";

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
        if (inner_arg.len == 0 or std.mem.findScalar(u8, inner_arg, ',') != null) return;
        if (containsComment(inner_arg)) return;

        const replacement = try context.allocator.print(
            "{s}.{s}(u8, {s}{s})",
            .{ allocator_text, dupe_fn, inner_arg, sentinel_argument },
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
            .title = try context.allocator.print("Replace with {s}.{s}", .{ allocator_text, dupe_fn }),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .prefer_allocator_dupe,
            .level = level,
            .span = context.tokens[call_start].loc,
            .message = try context.allocator.print(
                "formatting '{s}' duplicates a slice; use '{s}.{s}(u8, {s}{s})' directly",
                .{ inner_fmt, allocator_text, dupe_fn, inner_arg, sentinel_argument },
            ),
            .fixes = fixes,
        });
    } else if (std.mem.findScalar(u8, inner_fmt, '{') == null and
        std.mem.findScalar(u8, inner_fmt, '}') == null)
    {
        // Static string without format specifiers, tuple should be empty
        const tuple_contents = std.mem.trim(
            u8,
            context.source[context.tokens[tuple_open].loc.end..context.tokens[tuple_close].loc.start],
            " \t\r\n",
        );
        if (tuple_contents.len != 0) return;

        const replacement = try context.allocator.print(
            "{s}.{s}(u8, {s}{s})",
            .{ allocator_text, dupe_fn, fmt_text, sentinel_argument },
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
            .title = try context.allocator.print("Replace with {s}.{s}", .{ allocator_text, dupe_fn }),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .prefer_allocator_dupe,
            .level = level,
            .span = context.tokens[call_start].loc,
            .message = try context.allocator.print(
                "formatting static string has no specifiers; use '{s}.{s}(u8, {s}{s})' directly",
                .{ allocator_text, dupe_fn, fmt_text, sentinel_argument },
            ),
            .fixes = fixes,
        });
    }
}

fn containsComment(text: []const u8) bool {
    return std.mem.find(u8, text, "//") != null or std.mem.find(u8, text, "/*") != null;
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
        "    return try std.fmt.allocPrintSentinel(allocator, \"{s}\", .{path}, 0);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("allocator.dupeSentinel(u8, path, 0)", findings[0].fixes[0].edits[0].replacement);
}

test "allocator print methods preserve the receiver and sentinel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn clone(a: std.mem.Allocator, name: []const u8) ![]u8 { return try a.print(\"{s}\", .{name}); }\n" ++
        "fn cloneZ(a: std.mem.Allocator, name: []const u8) ![:0]u8 { return try a.printSentinel(\"{s}\", .{name}, 0); }\n" ++
        "fn make(self: *Owner) ![]u8 { return try self.allocator.print(\"literal\", .{}); }\n" ++
        "fn keep(a: std.mem.Allocator) ![:1]u8 { return try a.printSentinel(\"literal\", .{}, 1); }\n" ++
        "fn write(allocator: *std.Io.Writer, name: []const u8) !void { try allocator.print(\"{s}\", .{name}); }\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expectEqualStrings("a.dupe(u8, name)", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("a.dupeSentinel(u8, name, 0)", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("self.allocator.dupe(u8, \"literal\")", findings[2].fixes[0].edits[0].replacement);
}

test "allocator aliases qualify while custom allocator-shaped names do not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Memory = std.mem.Allocator; const Allocator = struct {};\n" ++
        "fn clone(a: Memory) ![]u8 { return try a.print(\"literal\", .{}); }\n" ++
        "fn custom(allocator: Allocator) ![]u8 { return try allocator.print(\"literal\", .{}); }\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("a.dupe(u8, \"literal\")", findings[0].fixes[0].edits[0].replacement);
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

test "allocator print escaped braces are not duplicated verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn escaped(a: std.mem.Allocator) !void {\n" ++
        "    _ = try a.print(\"}}\", .{});\n" ++
        "    _ = try a.print(\"\\x7d\\x7d\", .{});\n" ++
        "    _ = try a.print(\"\\u{7d}\\u{7d}\", .{});\n" ++
        "    _ = try std.fmt.allocPrint(a, \"{{\", .{});\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.prefer_allocator_dupe)] = .warning;
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
