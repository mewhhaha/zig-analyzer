const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.discarded_read_count);
    if (level == .off) return;

    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or
            context.tokens[equal_index - 1].tag != .identifier or !context.tokenIs(equal_index - 1, "_")) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        for (context.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or method_index == 0 or method_index + 1 >= statement_end or
                context.tokens[method_index - 1].tag != .period or context.tokens[method_index + 1].tag != .l_paren) continue;
            const method = context.tokenText(method_index);
            const partial_read = partialRead(method) orelse continue;
            try context.emit(.{
                .rule = .discarded_read_count,
                .level = level,
                .span = candidate.loc,
                .message = if (partial_read.complete_method) |complete_method|
                    try std.fmt.allocPrint(
                        context.allocator,
                        "discarding {s}'s byte count loses how much of the destination was initialized; use {s} when the destination must be filled",
                        .{ method, complete_method },
                    )
                else
                    try std.fmt.allocPrint(
                        context.allocator,
                        "discarding {s}'s byte count loses how much of the destination was initialized",
                        .{method},
                    ),
            });
            break;
        }
    }
}

const PartialRead = struct {
    complete_method: ?[]const u8,
};

fn partialRead(method: []const u8) ?PartialRead {
    if (std.mem.eql(u8, method, "readVec")) return .{ .complete_method = "readVecAll" };
    if (std.mem.eql(u8, method, "readSliceShort")) return .{ .complete_method = "readSliceAll" };
    const partial_methods = [_][]const u8{ "read", "pread", "readv", "preadv" };
    for (partial_methods) |candidate| {
        if (std.mem.eql(u8, method, candidate)) return .{ .complete_method = null };
    }
    return null;
}

test "discarded partial read counts report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn receive(reader: anytype, buffers: [][]u8, bytes: []u8) !void {\n" ++
        "    _ = try reader.readVec(buffers);\n" ++
        "    _ = try reader.readSliceShort(bytes);\n" ++
        "    _ = try reader.read(bytes);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "readVecAll") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "readSliceAll") != null);
}

test "complete reads and handled counts stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn receive(reader: anytype, buffers: [][]u8, bytes: []u8) !void {\n" ++
        "    try reader.readVecAll(buffers);\n" ++
        "    try reader.readSliceAll(bytes);\n" ++
        "    const count = try reader.readVec(buffers);\n" ++
        "    consume(count);\n" ++
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
