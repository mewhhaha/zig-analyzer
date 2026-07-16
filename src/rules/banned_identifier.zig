const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.banned_identifier);
    if (level == .off or context.configuration.banned.len == 0) return;

    for (context.tokens, 0..) |token, start| {
        if (token.tag != .identifier) continue;
        // A leading period means the first segment is a member access, not the
        // root binding the configured path names.
        if (start > 0 and context.tokens[start - 1].tag == .period) continue;
        for (context.configuration.banned) |banned| {
            const path_end = matchedPathEnd(context, start, banned.path) orelse continue;
            const span: std.zig.Token.Loc = .{
                .start = token.loc.start,
                .end = context.tokens[path_end].loc.end,
            };
            const message = if (banned.hint) |hint|
                try std.fmt.allocPrint(
                    context.allocator,
                    "'{s}' is banned by zig-analyzer.json; {s}",
                    .{ banned.path, hint },
                )
            else
                try std.fmt.allocPrint(context.allocator, "'{s}' is banned by zig-analyzer.json", .{banned.path});
            try context.emit(.{
                .rule = .banned_identifier,
                .level = level,
                .span = span,
                .message = message,
            });
        }
    }
}

/// Matches every dot-separated segment of the configured path against whole
/// identifier tokens, so 'std.BoundedArray' matches neither
/// 'mystd.BoundedArray' nor 'std.BoundedArrayFoo'.
fn matchedPathEnd(context: RuleRun, start: usize, path: []const u8) ?usize {
    var cursor = start;
    var remaining = path;
    while (true) {
        const segment_end = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
        if (context.tokens[cursor].tag != .identifier or
            !context.tokenIs(cursor, remaining[0..segment_end])) return null;
        if (segment_end == remaining.len) return cursor;
        remaining = remaining[segment_end + 1 ..];
        if (cursor + 2 >= context.tokens.len or context.tokens[cursor + 1].tag != .period or
            context.tokens[cursor + 2].tag != .identifier) return null;
        cursor += 2;
    }
}

test "banned dotted paths are reported with their hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Stack = std.BoundedArray(u8, 16);\n" ++
        "const deep = std.BoundedArray.init(0);\n" ++
        "fn wait() void { sleep(1); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expectEqualStrings(
        "'std.BoundedArray' is banned by zig-analyzer.json; use stdx.BoundedArrayType",
        findings[0].message,
    );
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "std.BoundedArray").?, findings[0].span.start);
    try std.testing.expectEqualStrings("'sleep' is banned by zig-analyzer.json", findings[2].message);
}

test "identifier boundaries and member accesses do not match banned paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const a = mystd.BoundedArray(u8, 16);\n" ++
        "const b = std.BoundedArrayFoo(u8, 16);\n" ++
        "const c = shim.std.BoundedArray(u8, 16);\n" ++
        "const d = std.sleep;\n" ++
        "fn nap() void { thread.sleep(1); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "banned identifier diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line banned-identifier\n" ++
        "const Stack = std.BoundedArray(u8, 16);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "an unconfigured banned list leaves every identifier alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const Stack = std.BoundedArray(u8, 16);";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });

    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

const test_banned = [_]types.BannedIdentifier{
    .{ .path = "std.BoundedArray", .hint = "use stdx.BoundedArrayType" },
    .{ .path = "sleep" },
};

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.banned_identifier)] = .warning;
    configuration.banned = &test_banned;
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
