//! Range formatting: only `zig fmt`'s changes on the requested lines.
const std = @import("std");
const lsp = @import("lsp");
const zig_analyzer = @import("zig_analyzer");
const support = @import("support.zig");

const Server = zig_analyzer.lsp.server.Server;
const TestTransport = support.TestTransport;

fn applyEdits(arena: std.mem.Allocator, document: *const zig_analyzer.syntax.document.Document, edits: []const lsp.types.TextEdit) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    for (edits) |edit| {
        const start = document.byteOffset(edit.range.start);
        try result.appendSlice(arena, document.source[copied..start]);
        try result.appendSlice(arena, edit.newText);
        copied = document.byteOffset(edit.range.end);
    }
    try result.appendSlice(arena, document.source[copied..]);
    return result.items;
}

test "range formatting changes only the requested lines" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = "file:///range_format.zig";
    const source = "const a=1;\nfn run() void {\n_ = a;\n}\nconst b=2;\n";
    try server.documents.open(uri, 1, source);
    const document = server.documents.getConst(uri).?;

    const edits = (try server.@"textDocument/rangeFormatting"(arena, .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 3, .character = 1 } },
        .options = .{ .tabSize = 4, .insertSpaces = true },
    })).?;
    try std.testing.expectEqualStrings(
        "const a=1;\nfn run() void {\n    _ = a;\n}\nconst b=2;\n",
        try applyEdits(arena, document, edits),
    );

    const whole = (try server.@"textDocument/rangeFormatting"(arena, .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 5, .character = 0 } },
        .options = .{ .tabSize = 4, .insertSpaces = true },
    })).?;
    try std.testing.expectEqualStrings(
        "const a = 1;\nfn run() void {\n    _ = a;\n}\nconst b = 2;\n",
        try applyEdits(arena, document, whole),
    );
}

test "range formatting of formatted lines returns no edits" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const uri = "file:///range_clean.zig";
    try server.documents.open(uri, 1, "const a = 1;\nconst b=2;\n");
    const edits = (try server.@"textDocument/rangeFormatting"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 12 } },
        .options = .{ .tabSize = 4, .insertSpaces = true },
    })).?;
    try std.testing.expectEqual(@as(usize, 0), edits.len);
}
