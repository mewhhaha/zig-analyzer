const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findManagedContainers(context);
    try findDeprecatedIo(context);
}

fn findManagedContainers(context: RuleRun) !void {
    const level = context.level(.modernize_managed_container);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "Managed") or index < 4 or
            context.tokens[index - 1].tag != .period or !context.tokenIs(index - 2, "array_list") or
            context.tokens[index - 3].tag != .period or !context.tokenIs(index - 4, "std")) continue;
        try context.emit(.{
            .rule = .modernize_managed_container,
            .level = level,
            .span = token.loc,
            .message = "std.array_list.Managed stores its allocator and is a migration shim; use the unmanaged container and pass the allocator to allocating calls",
        });
    }
}

fn findDeprecatedIo(context: RuleRun) !void {
    const level = context.level(.modernize_deprecated_io);
    if (level == .off) return;
    const adapters = [_]struct { old: []const u8, replacement: []const u8 }{
        .{ .old = "GenericReader", .replacement = "std.Io.Reader" },
        .{ .old = "GenericWriter", .replacement = "std.Io.Writer" },
        .{ .old = "AnyReader", .replacement = "std.Io.Reader" },
        .{ .old = "AnyWriter", .replacement = "std.Io.Writer" },
        .{ .old = "BufferedWriter", .replacement = "std.Io.Writer" },
        .{ .old = "bufferedWriter", .replacement = "std.Io.Writer.Allocating or a caller-owned buffer" },
        .{ .old = "bufferedReader", .replacement = "std.Io.Reader with caller-owned buffering" },
    };
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier) continue;
        for (adapters) |adapter| {
            if (!context.tokenIs(index, adapter.old)) continue;
            if (!isStdIoPath(context, index)) continue;
            try context.emit(.{
                .rule = .modernize_deprecated_io,
                .level = level,
                .span = token.loc,
                .message = try std.fmt.allocPrint(context.allocator, "std I/O adapter '{s}' belongs to the pre-std.Io interface; migrate this use to {s}", .{ adapter.old, adapter.replacement }),
            });
        }
    }
}

fn isStdIoPath(context: RuleRun, index: usize) bool {
    var cursor = index;
    while (cursor >= 2 and context.tokens[cursor - 1].tag == .period and context.tokens[cursor - 2].tag == .identifier) {
        cursor -= 2;
        if (context.tokenIs(cursor, "std")) return true;
    }
    return false;
}

test "modernize profile identifies managed containers and legacy IO adapters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const List = std.array_list.Managed(u8);\n" ++
        "const Writer = std.io.GenericWriter(Context, Error, write);\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.modernize_managed_container)] = .information;
    configuration.levels[@intFromEnum(types.Rule.modernize_deprecated_io)] = .information;
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(arena.allocator(), token);
    }
    var found: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens.items, .configuration = configuration, .findings = &found });
    try std.testing.expectEqual(@as(usize, 2), found.items.len);
}
