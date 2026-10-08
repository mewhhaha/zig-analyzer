const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .prefer_eql_over_order,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_eql_over_order);
    if (level == .off) return;

    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or !context.tokenIs(call_index, "order") or
            call_index + 1 >= context.tokens.len or
            context.tokens[call_index + 1].tag != .l_paren) continue;

        const is_std_mem = (call_index >= 4 and context.tokenIs(call_index - 4, "std") and
            context.tokens[call_index - 3].tag == .period and context.tokenIs(call_index - 2, "mem") and
            context.tokens[call_index - 1].tag == .period);
        const is_mem = (call_index >= 2 and context.tokenIs(call_index - 2, "mem") and
            context.tokens[call_index - 1].tag == .period);
        if (!is_std_mem and !is_mem) continue;

        const call_start = if (is_std_mem) call_index - 4 else call_index - 2;
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;
        const arguments = context.threeArguments(call_index + 1, call_end) orelse continue;

        const prefix = if (is_std_mem) "std.mem." else "mem.";

        // Check if comparison follows: call == .eq or call != .eq
        var is_equality: ?bool = null;
        var start_token = call_start;
        var end_token = call_end;

        if (call_end + 2 < context.tokens.len) {
            const op_tok = context.tokens[call_end + 1];
            if (op_tok.tag == .equal_equal or op_tok.tag == .bang_equal) {
                if (isEqOperand(context, call_end + 2)) |eq_end| {
                    is_equality = (op_tok.tag == .equal_equal);
                    end_token = eq_end;
                }
            }
        }

        // Check if comparison precedes: .eq == call or .eq != call
        if (is_equality == null and call_start >= 3) {
            const op_tok = context.tokens[call_start - 1];
            if (op_tok.tag == .equal_equal or op_tok.tag == .bang_equal) {
                if (findPrecedingEq(context, call_start - 1)) |eq_start| {
                    is_equality = (op_tok.tag == .equal_equal);
                    start_token = eq_start;
                }
            }
        }

        if (is_equality == null) continue;

        const type_arg = context.argumentSource(arguments[0]);
        const a_arg = context.argumentSource(arguments[1]);
        const b_arg = context.argumentSource(arguments[2]);

        const replacement = if (is_equality.?)
            try context.allocator.print("{s}eql({s}, {s}, {s})", .{ prefix, type_arg, a_arg, b_arg })
        else
            try context.allocator.print("!{s}eql({s}, {s}, {s})", .{ prefix, type_arg, a_arg, b_arg });

        const fixes = try context.singleFix(.{
            .title = "Use std.mem.eql for equality check",
            .kind = .refactor_rewrite,
            .span = .{
                .start = context.tokens[start_token].loc.start,
                .end = context.tokens[end_token].loc.end,
            },
            .replacement = replacement,
            .preferred = true,
            .fix_all = true,
        });

        try context.emit(.{
            .rule = .prefer_eql_over_order,
            .level = level,
            .span = token.loc,
            .message = "using 'order' to check equality performs unnecessary ordering scans; use 'std.mem.eql'",
            .fixes = fixes,
        });
    }
}

fn isEqOperand(context: RuleRun, start: usize) ?usize {
    // Matches .eq or std.math.Order.eq
    if (context.tokens[start].tag == .period and start + 1 < context.tokens.len and
        context.tokenIs(start + 1, "eq"))
    {
        return start + 1;
    }
    if (start + 6 < context.tokens.len and
        context.tokenIs(start, "std") and
        context.tokens[start + 1].tag == .period and
        context.tokenIs(start + 2, "math") and
        context.tokens[start + 3].tag == .period and
        context.tokenIs(start + 4, "Order") and
        context.tokens[start + 5].tag == .period and
        context.tokenIs(start + 6, "eq"))
    {
        return start + 6;
    }
    return null;
}

fn findPrecedingEq(context: RuleRun, op_index: usize) ?usize {
    if (op_index >= 2 and context.tokens[op_index - 2].tag == .period and
        context.tokenIs(op_index - 1, "eq"))
    {
        return op_index - 2;
    }
    if (op_index >= 7 and
        context.tokenIs(op_index - 7, "std") and
        context.tokens[op_index - 6].tag == .period and
        context.tokenIs(op_index - 5, "math") and
        context.tokens[op_index - 4].tag == .period and
        context.tokenIs(op_index - 3, "Order") and
        context.tokens[op_index - 2].tag == .period and
        context.tokenIs(op_index - 1, "eq"))
    {
        return op_index - 7;
    }
    return null;
}

test "prefer eql over order detects equality comparisons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(a: []const u8, b: []const u8) bool {\n" ++
        "    const eq1 = std.mem.order(u8, a, b) == .eq;\n" ++
        "    const ne1 = std.mem.order(u8, a, b) != .eq;\n" ++
        "    const rev = .eq == std.mem.order(u8, a, b);\n" ++
        "    return eq1 and ne1 and rev;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expectEqualStrings("std.mem.eql(u8, a, b)", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("!std.mem.eql(u8, a, b)", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("std.mem.eql(u8, a, b)", findings[2].fixes[0].edits[0].replacement);
}

test "order for less-than or greater-than is preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(a: []const u8, b: []const u8) bool {\n" ++
        "    return std.mem.order(u8, a, b) == .lt;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.prefer_eql_over_order}, .warning));
}
