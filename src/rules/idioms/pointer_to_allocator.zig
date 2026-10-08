const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .pointer_to_allocator,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.pointer_to_allocator);
    if (level == .off) return;

    for (context.tokens, 0..) |token, colon_index| {
        if (token.tag != .colon or colon_index == 0 or colon_index + 2 >= context.tokens.len) continue;
        if (context.tokens[colon_index - 1].tag != .identifier) continue;

        if (context.tokens[colon_index + 1].tag != .asterisk) continue;

        var type_start = colon_index + 2;
        if (context.tokens[type_start].tag == .keyword_const) {
            type_start += 1;
            if (type_start >= context.tokens.len) continue;
        }

        var type_end: usize = 0;
        var is_allocator = false;

        if (type_start + 4 < context.tokens.len and
            context.tokenIs(type_start, "std") and
            context.tokens[type_start + 1].tag == .period and
            context.tokenIs(type_start + 2, "mem") and
            context.tokens[type_start + 3].tag == .period and
            context.tokenIs(type_start + 4, "Allocator"))
        {
            type_end = type_start + 5;
            is_allocator = true;
        } else if (context.tokenIs(type_start, "Allocator")) {
            type_end = type_start + 1;
            is_allocator = true;
        }

        if (!is_allocator) continue;

        if (type_end < context.tokens.len) {
            switch (context.tokens[type_end].tag) {
                .comma, .r_paren, .semicolon, .equal => {},
                else => continue,
            }
        }

        const asterisk_token = context.tokens[colon_index + 1];
        const fixes = try context.singleFix(.{
            .title = try context.allocator.dupe(u8, "Pass 'Allocator' by value"),
            .span = .{
                .start = asterisk_token.loc.start,
                .end = context.tokens[type_start].loc.start,
            },
            .replacement = "",
            .preferred = true,
            .fix_all = true,
        });

        try context.emit(.{
            .rule = .pointer_to_allocator,
            .level = level,
            .span = .{
                .start = asterisk_token.loc.start,
                .end = context.tokens[type_end - 1].loc.end,
            },
            .message = try context.allocator.dupe(u8, "std.mem.Allocator is an interface fat pointer and should be passed by value rather than by pointer"),
            .fixes = fixes,
        });
    }
}

test "pointer to allocator detects pointers in parameters and fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Context = struct {\n" ++
        "    alloc: *std.mem.Allocator,\n" ++
        "};\n" ++
        "fn run(allocator: *std.mem.Allocator, other: *const std.mem.Allocator, short: *Allocator) void {\n" ++
        "    _ = allocator;\n" ++
        "    _ = other;\n" ++
        "    _ = short;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 4), findings.len);
    try std.testing.expectEqualStrings("", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("", findings[3].fixes[0].edits[0].replacement);
}

test "by-value allocator or concrete allocator pointer stays unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, gpa: *std.heap.GeneralPurposeAllocator(.{})) void {\n" ++
        "    _ = allocator;\n" ++
        "    _ = arena;\n" ++
        "    _ = gpa;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.pointer_to_allocator}, .warning));
}
