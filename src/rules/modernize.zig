const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findManagedContainers(context);
    try findDeprecatedIo(context);
    try findDeprecatedStdlib(context);
}

const StdlibReplacement = struct {
    path: []const u8,
    advice: []const u8,
    removed: bool = false,
    /// The advice minus its `std.` root is a signature-identical replacement
    /// for the matched path, so the finding carries a fix.
    drop_in: bool = false,
};

// Verified against the Zig 0.16.0 standard library: entries marked removed are
// absent from that release; the rest carry `Deprecated` doc comments there.
const stdlib_replacements = [_]StdlibReplacement{
    .{ .path = "mem.indexOf", .advice = "std.mem.find", .drop_in = true },
    .{ .path = "mem.indexOfPos", .advice = "std.mem.findPos", .drop_in = true },
    .{ .path = "mem.lastIndexOf", .advice = "std.mem.findLast", .drop_in = true },
    .{ .path = "mem.indexOfScalar", .advice = "std.mem.findScalar", .drop_in = true },
    .{ .path = "mem.indexOfScalarPos", .advice = "std.mem.findScalarPos", .drop_in = true },
    .{ .path = "mem.lastIndexOfScalar", .advice = "std.mem.findScalarLast", .drop_in = true },
    .{ .path = "mem.indexOfAny", .advice = "std.mem.findAny", .drop_in = true },
    .{ .path = "mem.indexOfAnyPos", .advice = "std.mem.findAnyPos", .drop_in = true },
    .{ .path = "mem.lastIndexOfAny", .advice = "std.mem.findLastAny", .drop_in = true },
    .{ .path = "mem.indexOfNone", .advice = "std.mem.findNone", .drop_in = true },
    .{ .path = "mem.lastIndexOfNone", .advice = "std.mem.findLastNone", .drop_in = true },
    .{ .path = "mem.indexOfDiff", .advice = "std.mem.findDiff", .drop_in = true },
    .{ .path = "mem.indexOfSentinel", .advice = "std.mem.findSentinel", .drop_in = true },
    .{ .path = "mem.indexOfMin", .advice = "std.mem.findMin", .drop_in = true },
    .{ .path = "mem.indexOfMinMax", .advice = "std.mem.findMinMax", .drop_in = true },
    .{ .path = "ascii.indexOfIgnoreCase", .advice = "std.ascii.findIgnoreCase", .drop_in = true },
    .{ .path = "ascii.indexOfIgnoreCasePos", .advice = "std.ascii.findIgnoreCasePos", .drop_in = true },
    .{ .path = "mem.copyForwards", .advice = "@memmove" },
    .{ .path = "mem.copyBackwards", .advice = "@memmove" },
    .{ .path = "fmt.bufPrintZ", .advice = "std.fmt.bufPrintSentinel with a 0 sentinel" },
    .{ .path = "meta.Int", .advice = "the @Int builtin" },
    .{ .path = "meta.Tuple", .advice = "the @Tuple builtin" },
    .{ .path = "ArrayListUnmanaged", .advice = "std.ArrayList", .drop_in = true },
    .{ .path = "ArrayListAligned", .advice = "std.array_list.Aligned", .drop_in = true },
    .{ .path = "ArrayListAlignedUnmanaged", .advice = "std.array_list.Aligned", .drop_in = true },
    .{ .path = "ArrayHashMapUnmanaged", .advice = "std.array_hash_map.Custom", .drop_in = true },
    .{ .path = "AutoArrayHashMapUnmanaged", .advice = "std.array_hash_map.Auto", .drop_in = true },
    .{ .path = "StringArrayHashMapUnmanaged", .advice = "std.array_hash_map.String", .drop_in = true },
    .{ .path = "heap.MemoryPoolAligned", .advice = "std.heap.memory_pool.Aligned", .drop_in = true },
    .{ .path = "heap.MemoryPoolExtra", .advice = "std.heap.memory_pool.Extra", .drop_in = true },
    .{ .path = "heap.MemoryPoolOptions", .advice = "std.heap.memory_pool.Options", .drop_in = true },
    .{ .path = "fs.path", .advice = "std.Io.Dir.path", .drop_in = true },
    .{ .path = "fs.max_path_bytes", .advice = "std.Io.Dir.max_path_bytes", .drop_in = true },
    .{ .path = "fs.max_name_bytes", .advice = "std.Io.Dir.max_name_bytes", .drop_in = true },
    .{ .path = "mem.trimLeft", .advice = "std.mem.trimStart", .removed = true, .drop_in = true },
    .{ .path = "mem.trimRight", .advice = "std.mem.trimEnd", .removed = true, .drop_in = true },
    .{ .path = "mem.tokenize", .advice = "std.mem.tokenizeAny", .removed = true, .drop_in = true },
    .{ .path = "mem.split", .advice = "std.mem.splitSequence", .removed = true, .drop_in = true },
    .{ .path = "mem.splitBackwards", .advice = "std.mem.splitBackwardsSequence", .removed = true, .drop_in = true },
    .{ .path = "ChildProcess", .advice = "std.process.Child", .removed = true, .drop_in = true },
    .{ .path = "rand", .advice = "std.Random", .removed = true, .drop_in = true },
    .{ .path = "mem.copy", .advice = "@memcpy for distinct buffers or @memmove", .removed = true },
    .{ .path = "mem.set", .advice = "@memset", .removed = true },
    .{ .path = "io.getStdOut", .advice = "std.Io.File.stdout()", .removed = true },
    .{ .path = "io.getStdIn", .advice = "std.Io.File.stdin()", .removed = true },
    .{ .path = "io.getStdErr", .advice = "std.Io.File.stderr()", .removed = true },
    .{ .path = "time.sleep", .advice = "std.Io.sleep with an Io instance and clock", .removed = true },
    .{ .path = "BoundedArray", .advice = "std.ArrayList.initBuffer over a caller-owned buffer", .removed = true },
    .{ .path = "fifo.LinearFifo", .advice = "std.Io.Reader/std.Io.Writer buffering or an explicit ring buffer", .removed = true },
    .{ .path = "math.min", .advice = "@min", .removed = true },
    .{ .path = "math.max", .advice = "@max", .removed = true },
    .{ .path = "math.absInt", .advice = "@abs", .removed = true },
    .{ .path = "math.fabs", .advice = "@abs", .removed = true },
};

fn findDeprecatedStdlib(context: RuleRun) !void {
    const level = context.level(.modernize_deprecated_stdlib);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (!context.refersToBinding(index, "std")) continue;
        for (&stdlib_replacements) |entry| {
            const path_end = matchedStdPathEnd(context, index, entry.path) orelse continue;
            var fixes: []const types.Fix = &.{};
            if (entry.drop_in) {
                const edits = try context.allocator.alloc(types.Edit, 1);
                edits[0] = .{
                    .span = .{ .start = context.tokens[index + 2].loc.start, .end = context.tokens[path_end].loc.end },
                    .replacement = entry.advice["std.".len..],
                };
                const drop_in_fixes = try context.allocator.alloc(types.Fix, 1);
                drop_in_fixes[0] = .{
                    .title = try std.fmt.allocPrint(context.allocator, "Replace with {s}", .{entry.advice}),
                    .kind = .quickfix,
                    .edits = edits,
                    .preferred = true,
                    .fix_all = true,
                };
                fixes = drop_in_fixes;
            }
            try context.emit(.{
                .rule = .modernize_deprecated_stdlib,
                .level = level,
                .span = .{ .start = token.loc.start, .end = context.tokens[path_end].loc.end },
                .message = try std.fmt.allocPrint(context.allocator, "std.{s} {s}; use {s}", .{
                    entry.path,
                    if (entry.removed) "was removed from the standard library" else "is deprecated",
                    entry.advice,
                }),
                .fixes = fixes,
            });
            break;
        }
    }
}

/// Matches every dot-separated segment of the path as whole member tokens
/// after the `std` root, so 'mem.indexOf' matches neither 'mem.indexOfPos'
/// nor 'memx.indexOf'.
fn matchedStdPathEnd(context: RuleRun, std_index: usize, path: []const u8) ?usize {
    var cursor = std_index;
    var remaining = path;
    while (remaining.len != 0) {
        const segment_end = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
        if (cursor + 2 >= context.tokens.len or context.tokens[cursor + 1].tag != .period or
            context.tokens[cursor + 2].tag != .identifier or
            !context.tokenIs(cursor + 2, remaining[0..segment_end])) return null;
        cursor += 2;
        remaining = remaining[if (segment_end == remaining.len) remaining.len else segment_end + 1..];
    }
    return cursor;
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

test "deprecated stdlib members name their replacement and carry drop-in fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const at = std.mem.indexOfScalar(u8, name, '.');\n" ++
        "const trimmed = std.mem.trimLeft(u8, name, \" \");\n" ++
        "std.mem.copyForwards(u8, sink, filled);\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expectEqualStrings("std.mem.indexOfScalar is deprecated; use std.mem.findScalar", findings[0].message);
    try std.testing.expectEqualStrings("mem.findScalar", findings[0].fixes[0].edits[0].replacement);
    const fixed_span = findings[0].fixes[0].edits[0].span;
    try std.testing.expectEqualStrings("mem.indexOfScalar", source[fixed_span.start..fixed_span.end]);
    try std.testing.expect(findings[0].fixes[0].fix_all);
    try std.testing.expectEqualStrings("std.mem.trimLeft was removed from the standard library; use std.mem.trimStart", findings[1].message);
    try std.testing.expectEqualStrings("mem.trimStart", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("std.mem.copyForwards is deprecated; use @memmove", findings[2].message);
    try std.testing.expectEqual(@as(usize, 0), findings[2].fixes.len);
}

test "current stdlib members and non-std roots stay unreported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const at = std.mem.findScalar(u8, name, '.');\n" ++
        "const pieces = std.mem.splitScalar(u8, name, ' ');\n" ++
        "const words = std.mem.tokenizeScalar(u8, name, ' ');\n" ++
        "const local = mystd.mem.indexOf(u8, name, item);\n" ++
        "const nested = shim.std.mem.indexOf(u8, name, item);\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "deprecated stdlib diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line modernize-deprecated-stdlib\n" ++
        "const at = std.mem.indexOf(u8, name, item);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "drop-in stdlib advice stays rooted in std" {
    for (stdlib_replacements) |entry| {
        if (!entry.drop_in) continue;
        try std.testing.expect(std.mem.startsWith(u8, entry.advice, "std."));
    }
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.modernize_deprecated_stdlib)] = .information;
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
