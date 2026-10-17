//! Code lenses: "Run test" above each named test, and the command it runs.
const std = @import("std");
const lsp = @import("lsp");
const zig_analyzer = @import("zig_analyzer");
const support = @import("support.zig");

const Server = zig_analyzer.lsp.server.Server;
const TestTransport = support.TestTransport;

test "each named test gets a run lens carrying its file and name" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = "file:///lenses.zig";
    try server.documents.open(uri, 1, "fn add(a: u32, b: u32) u32 { return a + b; }\ntest \"add sums\" {}\ntest {}\ntest add {}\n");

    const lenses = (try server.@"textDocument/codeLens"(arena, .{ .textDocument = .{ .uri = uri } })).?;
    try std.testing.expectEqual(@as(usize, 2), lenses.len);
    const first = lenses[0].command.?;
    try std.testing.expectEqualStrings("Run test", first.title);
    try std.testing.expectEqualStrings("zig-analyzer.runTest", first.command);
    try std.testing.expectEqualStrings(uri, first.arguments.?[0].string);
    try std.testing.expectEqualStrings("add sums", first.arguments.?[1].string);
    try std.testing.expectEqual(@as(u32, 1), lenses[0].range.start.line);
    try std.testing.expectEqualStrings("add", lenses[1].command.?.arguments.?[1].string);
}

test "run test without the lens's arguments is rejected and starts nothing" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Helix's workspace-command picker sends a listed command bare.
    try std.testing.expectError(error.InvalidParams, server.@"workspace/executeCommand"(arena, .{ .command = "zig-analyzer.runTest" }));
    const only_uri = try arena.alloc(std.json.Value, 1);
    only_uri[0] = .{ .string = "file:///lenses.zig" };
    try std.testing.expectError(error.InvalidParams, server.@"workspace/executeCommand"(arena, .{ .command = "zig-analyzer.runTest", .arguments = only_uri }));
    try std.testing.expectEqual(@as(usize, 0), transport.output_count);
}

test "run test runs the named test and reports the result" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sums.zig",
        .data = "const std = @import(\"std\");\ntest \"sums add\" { try std.testing.expect(1 + 1 == 2); }\ntest \"sums fail\" { try std.testing.expect(1 + 1 == 3); }\n",
    });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "sums.zig", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const uri = try zig_analyzer.uri.fromPath(std.testing.allocator, path);
    defer std.testing.allocator.free(uri);

    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "sums add", "sums fail", "no such test" }) |name| {
        const arguments = try arena.alloc(std.json.Value, 2);
        arguments[0] = .{ .string = uri };
        arguments[1] = .{ .string = name };
        try std.testing.expect(try server.@"workspace/executeCommand"(arena, .{ .command = "zig-analyzer.runTest", .arguments = arguments }) == null);
    }
    server.tests.waitIdle();

    var passed = false;
    var failed = false;
    var unmatched = false;
    for (transport.outputs.items) |message| {
        if (std.mem.find(u8, message, "window/showMessage") == null) continue;
        if (std.mem.find(u8, message, "Test \\\"sums add\\\" passed.") != null) passed = true;
        if (std.mem.find(u8, message, "Test \\\"sums fail\\\" failed: 0 passed; 0 skipped; 1 failed.") != null) failed = true;
        if (std.mem.find(u8, message, "No test matched \\\"no such test\\\".") != null) unmatched = true;
    }
    try std.testing.expect(passed);
    try std.testing.expect(failed);
    try std.testing.expect(unmatched);
}
