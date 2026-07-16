const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;

pub fn run(context: RuleRun) !void {
    const level = context.level(.unsafe_orelse_unreachable);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .keyword_orelse or index + 1 >= context.tokens.len or
            context.tokens[index + 1].tag != .keyword_unreachable or insideTestBody(context.tokens, index)) continue;
        try context.emit(.{
            .rule = .unsafe_orelse_unreachable,
            .level = level,
            .span = context.tokens[index + 1].loc,
            .message = try context.allocator.dupe(
                u8,
                "orelse unreachable turns an absent optional into a panic; handle null or document the invariant with an assertion",
            ),
        });
    }
}

fn insideTestBody(tokens: []const std.zig.Token, index: usize) bool {
    var nested_closing_braces: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => nested_closing_braces += 1,
            .l_brace => {
                if (nested_closing_braces != 0) {
                    nested_closing_braces -= 1;
                    continue;
                }
                var signature_cursor = cursor;
                while (signature_cursor > 0) {
                    signature_cursor -= 1;
                    switch (tokens[signature_cursor].tag) {
                        .keyword_test => return true,
                        .keyword_fn, .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return false,
                        .semicolon, .l_brace, .r_brace => break,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

test "orelse unreachable warns only when the idiomatic rule is enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 = "const value = optional orelse unreachable;";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unsafe_orelse_unreachable)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
}

test "test fixtures may use orelse unreachable as an assertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 = "test \"fixture\" { _ = optional orelse unreachable; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unsafe_orelse_unreachable)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "modular rules honor source suppressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line unsafe-orelse-unreachable\n" ++
        "const value = optional orelse unreachable;";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.unsafe_orelse_unreachable)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
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
