//! Casts whose operand already has the target type, and nested casts that repeat it.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .needless_cast,
};

pub fn run(context: RuleRun) !void {
    try findNeedlessCasts(context);
}

fn findNeedlessCasts(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.needless_cast);
    if (level == .off) return;
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or index + 3 >= tokens.len or tokens[index + 1].tag != .l_paren) continue;
        const builtin_name = tokenText(source, token);
        if (tokenIs(source, token, "@as")) {
            if (index + 5 >= tokens.len or tokens[index + 2].tag != .identifier or tokens[index + 3].tag != .comma) continue;
            const outer_close = matchingToken(tokens, index + 1, .l_paren, .r_paren) orelse continue;
            const type_name = tokenText(source, tokens[index + 2]);
            var replacement: []const u8 = undefined;
            var message: []const u8 = undefined;
            if (tokenIs(source, tokens[index + 4], "@as") and tokens[index + 5].tag == .l_paren and index + 7 < tokens.len and
                tokens[index + 6].tag == .identifier and tokens[index + 7].tag == .comma and
                std.mem.eql(u8, type_name, tokenText(source, tokens[index + 6])))
            {
                const inner_close = matchingToken(tokens, index + 5, .l_paren, .r_paren) orelse continue;
                if (inner_close + 1 != outer_close) continue;
                replacement = source[tokens[index + 4].loc.start..tokens[inner_close].loc.end];
                message = try context.allocator.print("nested cast to '{s}' repeats the same proven type", .{type_name});
            } else if (tokens[index + 4].tag == .identifier and index + 5 == outer_close and
                context.scopes.bindingHasType(source, tokens, index + 4, type_name))
            {
                replacement = tokenText(source, tokens[index + 4]);
                message = try context.allocator.print(
                    "cast of '{s}' to its proven type '{s}' is unnecessary",
                    .{ replacement, type_name },
                );
            } else continue;
            const fixes = try Fix.single(context.allocator, .{
                .title = "Remove redundant cast",
                .span = .{ .start = token.loc.start, .end = tokens[outer_close].loc.end },
                .replacement = replacement,
                .preferred = true,
                .fix_all = true,
            });
            try context.emit(.{
                .rule = .needless_cast,
                .level = level,
                .span = token.loc,
                .message = message,
                .fixes = fixes,
            });
        } else if (isSingleArgumentCastBuiltin(builtin_name)) {
            if (tokens[index + 2].tag != .builtin or !std.mem.eql(u8, builtin_name, tokenText(source, tokens[index + 2]))) continue;
            if (tokens[index + 3].tag != .l_paren) continue;
            const outer_close = matchingToken(tokens, index + 1, .l_paren, .r_paren) orelse continue;
            const inner_close = matchingToken(tokens, index + 3, .l_paren, .r_paren) orelse continue;
            if (inner_close + 1 != outer_close and !(inner_close + 2 == outer_close and tokens[inner_close + 1].tag == .comma)) continue;
            const replacement = source[tokens[index + 2].loc.start..tokens[inner_close].loc.end];
            const fixes = try Fix.single(context.allocator, .{
                .title = "Remove redundant cast",
                .span = .{ .start = token.loc.start, .end = tokens[outer_close].loc.end },
                .replacement = replacement,
                .preferred = true,
                .fix_all = true,
            });
            try context.emit(.{
                .rule = .needless_cast,
                .level = level,
                .span = token.loc,
                .message = try context.allocator.print("nested '{s}' is redundant", .{builtin_name}),
                .fixes = fixes,
            });
        }
    }
}

fn isSingleArgumentCastBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "@intCast") or
        std.mem.eql(u8, name, "@floatCast") or
        std.mem.eql(u8, name, "@ptrCast") or
        std.mem.eql(u8, name, "@alignCast") or
        std.mem.eql(u8, name, "@truncate") or
        std.mem.eql(u8, name, "@addrSpaceCast");
}

test "needless cast proof stays within the enclosing function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn widen(size: u32) u32 { return @as(u32, size); }\n" ++
        "fn narrow(size: u16) u32 { return @as(u32, size); }\n";
    const configuration = support.only(&.{.needless_cast}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var cast_count: usize = 0;
    for (found) |finding| if (finding.rule == .needless_cast) {
        cast_count += 1;
        try std.testing.expect(finding.span.start < std.mem.find(u8, source, "fn narrow").?);
    };
    try std.testing.expectEqual(@as(usize, 1), cast_count);
}

test "needless cast catches nested identical casts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn cast(x: u32) u8 {\n" ++
        "    const a = @intCast(@intCast(x));\n" ++
        "    const b = @truncate(@truncate(x));\n" ++
        "    return a + b;\n" ++
        "}\n";
    const configuration = support.only(&.{.needless_cast}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var cast_count: usize = 0;
    for (found) |finding| if (finding.rule == .needless_cast) {
        cast_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), cast_count);
}
