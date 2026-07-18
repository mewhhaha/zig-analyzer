const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.discarded_write_count);
    if (level == .off) return;

    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or
            context.tokens[equal_index - 1].tag != .identifier or !context.tokenIs(equal_index - 1, "_")) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        for (context.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or !context.tokenIs(method_index, "write") or
                method_index == 0 or method_index + 1 >= statement_end or
                context.tokens[method_index - 1].tag != .period or
                context.tokens[method_index + 1].tag != .l_paren) continue;
            try context.emit(.{
                .rule = .discarded_write_count,
                .level = level,
                .span = candidate.loc,
                .message = try context.allocator.dupe(
                    u8,
                    "discarding write's byte count can silently accept a partial write; use writeAll when the entire buffer must be written",
                ),
            });
            break;
        }
    }
}

test "discarding a partial write count reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn send(writer: anytype, bytes: []const u8) !void { _ = try writer.write(bytes); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "writeAll and used write counts stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn send(writer: anytype, bytes: []const u8) !void {\n" ++
        "    try writer.writeAll(bytes);\n" ++
        "    const written = try writer.write(bytes);\n" ++
        "    consume(written);\n" ++
        "}\n";
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
