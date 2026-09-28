const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_math_pow);
    if (level == .off) return;

    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier) continue;
        const func_name = context.tokenText(call_index);
        const is_pow = std.mem.eql(u8, func_name, "pow");
        const is_powi = std.mem.eql(u8, func_name, "powi");
        if (!is_pow and !is_powi) continue;

        if (call_index + 1 >= context.tokens.len or context.tokens[call_index + 1].tag != .l_paren) continue;

        const is_std_math = (call_index >= 4 and context.tokenIs(call_index - 4, "std") and
            context.tokens[call_index - 3].tag == .period and context.tokenIs(call_index - 2, "math") and
            context.tokens[call_index - 1].tag == .period);
        const is_math = (call_index >= 2 and context.tokenIs(call_index - 2, "math") and
            context.tokens[call_index - 1].tag == .period);
        if (!is_std_math and !is_math) continue;

        const call_start = if (is_std_math) call_index - 4 else call_index - 2;
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;
        const arguments = threeArguments(context, call_index + 1, call_end) orelse continue;

        const prefix = if (is_std_math) "std.math." else "math.";
        const x_text = argumentSource(context, arguments[1]);
        const y_text = argumentSource(context, arguments[2]);

        var replacement: ?[]const u8 = null;
        var message: ?[]const u8 = null;
        var fix_title: ?[]const u8 = null;

        if (std.mem.eql(u8, y_text, "0.5") and is_pow) {
            replacement = try std.fmt.allocPrint(context.allocator, "{s}sqrt({s})", .{ prefix, x_text });
            message = try std.fmt.allocPrint(
                context.allocator,
                "computing square root with {s}pow(..., 0.5); use {s}sqrt for dedicated hardware execution",
                .{ prefix, prefix },
            );
            fix_title = "Use std.math.sqrt";
        } else if (std.mem.eql(u8, y_text, "2") or std.mem.eql(u8, y_text, "2.0")) {
            if (isSimpleOperand(context, arguments[1])) {
                replacement = try std.fmt.allocPrint(context.allocator, "{s} * {s}", .{ x_text, x_text });
                message = try std.fmt.allocPrint(
                    context.allocator,
                    "squaring '{s}' with {s}{s}; use '{s} * {s}' for single-cycle multiplication",
                    .{ x_text, prefix, func_name, x_text, x_text },
                );
                fix_title = "Replace pow with multiplication";
            }
        } else if (std.mem.eql(u8, y_text, "1") or std.mem.eql(u8, y_text, "1.0")) {
            replacement = try context.allocator.dupe(u8, x_text);
            message = try std.fmt.allocPrint(
                context.allocator,
                "raising '{s}' to power 1 is redundant; use '{s}' directly",
                .{ x_text, x_text },
            );
            fix_title = "Remove redundant pow";
        } else if (std.mem.eql(u8, y_text, "0") or std.mem.eql(u8, y_text, "0.0")) {
            replacement = "1";
            message = try context.allocator.dupe(
                u8,
                "raising to power 0 always evaluates to 1; use '1' directly",
            );
            fix_title = "Replace pow with 1";
        }

        if (replacement == null or message == null or fix_title == null) continue;

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{
                .start = context.tokens[call_start].loc.start,
                .end = context.tokens[call_end].loc.end,
            },
            .replacement = replacement.?,
        };

        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = fix_title.?,
            .kind = .refactor_rewrite,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        try context.emit(.{
            .rule = .prefer_math_pow,
            .level = level,
            .span = token.loc,
            .message = message.?,
            .fixes = fixes,
        });
    }
}

fn isSimpleOperand(context: RuleRun, range: ArgumentRange) bool {
    for (context.tokens[range.start..range.end]) |tok| {
        switch (tok.tag) {
            .identifier, .period, .number_literal => {},
            else => return false,
        }
    }
    return range.start < range.end;
}

const ArgumentRange = struct { start: usize, end: usize };

fn threeArguments(context: RuleRun, opening: usize, closing: usize) ?[3]ArgumentRange {
    var commas: [3]usize = undefined;
    var comma_count: usize = 0;
    var depth: usize = 0;
    for (context.tokens[opening + 1 .. closing], opening + 1..) |tok, idx| switch (tok.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            if (comma_count == commas.len) return null;
            commas[comma_count] = idx;
            comma_count += 1;
        },
        else => {},
    };
    if (comma_count != 2 or commas[0] == opening + 1 or commas[1] == commas[0] + 1 or commas[1] + 1 == closing) return null;
    return .{
        .{ .start = opening + 1, .end = commas[0] },
        .{ .start = commas[0] + 1, .end = commas[1] },
        .{ .start = commas[1] + 1, .end = closing },
    };
}

fn argumentSource(context: RuleRun, range: ArgumentRange) []const u8 {
    return std.mem.trim(
        u8,
        context.source[context.tokens[range.start].loc.start..context.tokens[range.end - 1].loc.end],
        " \t\r\n",
    );
}

test "prefer math pow replaces 0.5 with sqrt and 2 with multiplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn calc(x: f32, radius: f64) f64 {\n" ++
        "    const s = std.math.pow(f32, x, 0.5);\n" ++
        "    const sq = std.math.pow(f64, radius, 2.0);\n" ++
        "    const one = std.math.pow(f64, radius, 0.0);\n" ++
        "    const same = std.math.pow(f64, radius, 1.0);\n" ++
        "    return s + sq + one + same;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 4), findings.len);
    try std.testing.expectEqualStrings("std.math.sqrt(x)", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("radius * radius", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("1", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("radius", findings[3].fixes[0].edits[0].replacement);
}

test "complex operand in pow with exponent 2 is not duplicated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn calc() f64 {\n" ++
        "    return std.math.pow(f64, getExpensiveValue(), 2.0);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer math pow honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn calc(x: f32) f32 {\n" ++
        "    // zig-analyzer: disable-next-line prefer-math-pow\n" ++
        "    return std.math.pow(f32, x, 0.5);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_math_pow)] = .warning;
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
