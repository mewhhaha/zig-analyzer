//! Inlay hints the ownership summaries add: who frees a call's result.
const std = @import("std");
const lsp = @import("lsp");
const zig_analyzer = @import("zig_analyzer");
const support = @import("support.zig");

const Server = zig_analyzer.lsp.server.Server;
const TestTransport = support.TestTransport;

test "calls returning owned memory say the caller frees it" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = "file:///owned.zig";
    const source =
        \\const std = @import("std");
        \\fn label(allocator: std.mem.Allocator, id: u32) ![]u8 {
        \\    return std.fmt.allocPrint(allocator, "item {d}", .{id});
        \\}
        \\fn width(text: []const u8) usize {
        \\    return text.len;
        \\}
        \\fn show(allocator: std.mem.Allocator) !usize {
        \\    const text = try label(allocator, 7);
        \\    defer allocator.free(text);
        \\    return width(text);
        \\}
        \\
    ;
    try server.documents.open(uri, 1, source);

    const hints = (try server.@"textDocument/inlayHint"(arena, .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 12, .character = 0 } },
    })).?;
    var owned: std.ArrayList(lsp.types.InlayHint) = .empty;
    for (hints) |hint| {
        if (std.mem.eql(u8, hint.label.string, "caller frees")) try owned.append(arena, hint);
    }
    try std.testing.expectEqual(@as(usize, 1), owned.items.len);
    const hint = owned.items[0];
    try std.testing.expectEqual(@as(u32, 8), hint.position.line);
    try std.testing.expectEqual(@as(u32, 40), hint.position.character);

    const outside = (try server.@"textDocument/inlayHint"(arena, .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = 9, .character = 0 }, .end = .{ .line = 12, .character = 0 } },
    })).?;
    for (outside) |other| try std.testing.expect(!std.mem.eql(u8, other.label.string, "caller frees"));

    // An edit summarizes the text again; the hint lands in UTF-16 units.
    const edited = try std.mem.replaceOwned(u8, arena, source, "label(allocator, 7)", "label(allocator, \"😀\".len)");
    try support.replaceDocument(&server, arena, uri, 2, edited);
    const moved = (try server.@"textDocument/inlayHint"(arena, .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = 8, .character = 0 }, .end = .{ .line = 9, .character = 0 } },
    })).?;
    var moved_count: usize = 0;
    for (moved) |other| if (std.mem.eql(u8, other.label.string, "caller frees")) {
        moved_count += 1;
        try std.testing.expectEqual(@as(u32, 8), other.position.line);
        try std.testing.expectEqual(@as(u32, 47), other.position.character);
    };
    try std.testing.expectEqual(@as(usize, 1), moved_count);
}
