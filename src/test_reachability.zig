//! Guards the analyzer's test root: a source file with `test` blocks that
//! nothing reaches from `zig_analyzer.zig` compiles without its tests, and the
//! suite stays green while they silently stop running. The compiler names every
//! test it did build after the file that declares it (`rules.pipeline.test.x`),
//! so each file under `src/` that declares tests must own at least one built test.

const builtin = @import("builtin");
const std = @import("std");

/// Whether any compiled test belongs to the file whose test-name prefix is `prefix`.
fn hasBuiltTest(prefix: []const u8) bool {
    for (builtin.test_functions) |built| {
        if (!std.mem.startsWith(u8, built.name, prefix)) continue;
        const rest = built.name[prefix.len..];
        if (std.mem.startsWith(u8, rest, ".test") or std.mem.startsWith(u8, rest, ".decltest")) return true;
    }
    return false;
}

fn declaresTests(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .keyword_test => return true,
            .eof => return false,
            else => {},
        }
    }
}

/// `path` relative to `src/`, without `.zig`, with `/` as `.`: the name prefix
/// the compiler gives that file's tests.
fn testPrefix(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const prefix = try arena.dupe(u8, path[0 .. path.len - ".zig".len]);
    std.mem.replaceScalar(u8, prefix, std.Io.Dir.path.sep, '.');
    return prefix;
}

test "every source file with tests is reachable from the test root" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var directory = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(arena);
    defer walker.deinit();
    var unreachable_files: usize = 0;
    var tested_files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const text = try directory.readFileAlloc(io, entry.path, arena, .limited(4 << 20));
        const source = try arena.dupeSentinel(u8, text, 0);
        if (!declaresTests(source)) continue;
        tested_files += 1;
        if (hasBuiltTest(try testPrefix(arena, entry.path))) continue;
        unreachable_files += 1;
        std.debug.print(
            "src/{s} declares tests that no test in the build reaches; reference it from the test block of src/zig_analyzer.zig\n",
            .{entry.path},
        );
    }
    try std.testing.expect(tested_files > 100);
    try std.testing.expectEqual(@as(usize, 0), unreachable_files);
}
