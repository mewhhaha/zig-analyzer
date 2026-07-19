const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.discarded_realloc_result);
    if (level == .off) return;

    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or
            context.tokens[equal_index - 1].tag != .identifier or !context.tokenIs(equal_index - 1, "_")) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        for (context.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or method_index < 2 or method_index + 1 >= statement_end or
                context.tokens[method_index - 1].tag != .period or context.tokens[method_index + 1].tag != .l_paren or
                (!context.tokenIs(method_index, "realloc") and !context.tokenIs(method_index, "reallocAdvanced"))) continue;
            if (context.tokens[method_index - 2].tag != .identifier or
                !allocatorBinding(context, context.tokenText(method_index - 2), method_index)) continue;
            try context.emit(.{
                .rule = .discarded_realloc_result,
                .level = level,
                .span = candidate.loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "discarding {s}'s returned slice keeps a potentially invalid pointer and the old length",
                    .{context.tokenText(method_index)},
                ),
            });
            break;
        }
    }
}

fn allocatorBinding(context: RuleRun, name: []const u8, before: usize) bool {
    if (std.mem.indexOf(u8, name, "alloc") != null) return true;
    var name_index = before;
    while (name_index > 0) {
        name_index -= 1;
        if (!context.tokenIs(name_index, name) or name_index + 2 >= before or
            context.tokens[name_index + 1].tag != .colon) continue;
        var type_index = name_index + 2;
        while (type_index < before) : (type_index += 1) {
            if (context.tokens[type_index].tag == .identifier and context.tokenIs(type_index, "Allocator")) return true;
            if (context.tokens[type_index].tag == .comma or context.tokens[type_index].tag == .r_paren or
                context.tokens[type_index].tag == .equal or context.tokens[type_index].tag == .semicolon) return false;
        }
    }
    return false;
}

test "discarded realloc results report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn resize(allocator: anytype, bytes: []u8) !void {\n" ++
        "    _ = try allocator.realloc(bytes, 32);\n" ++
        "    _ = try allocator.reallocAdvanced(bytes, 64, 0);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "stored realloc results stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn resize(allocator: anytype, bytes: []u8) ![]u8 {\n" ++
        "    const resized = try allocator.realloc(bytes, 32);\n" ++
        "    return resized;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "an unrelated realloc method is not an allocator contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn resize(buffer: *Buffer) void { _ = buffer.realloc(32); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
