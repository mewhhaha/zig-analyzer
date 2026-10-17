//! Rename preparation: what a rename at the cursor would replace.
const std = @import("std");
const lsp = @import("lsp");
const zig_analyzer = @import("zig_analyzer");
const support = @import("support.zig");

const Server = zig_analyzer.lsp.server.Server;
const runBasicServer = zig_analyzer.lsp.server.runBasicServer;
const TestTransport = support.TestTransport;

test "prepareRename is advertised only to clients that send it" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{"textDocument":{"rename":{"prepareSupport":true}}}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    try runBasicServer(std.testing.io, std.testing.allocator, &transport.transport, &server, null);
    try std.testing.expect(std.mem.find(u8, transport.output(0), "\"renameProvider\":{\"prepareProvider\":true}") != null);

    const without = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var plain_transport = TestTransport.init(&without);
    defer plain_transport.deinit();
    var plain: Server = undefined;
    try plain.init(std.testing.io, std.testing.allocator, .empty, &plain_transport.transport, .syntax_only);
    defer plain.deinit();
    try runBasicServer(std.testing.io, std.testing.allocator, &plain_transport.transport, &plain, null);
    try std.testing.expect(std.mem.find(u8, plain_transport.output(0), "\"renameProvider\":{\"prepareProvider\":false}") != null);
}

test "prepareRename returns the name's range or refuses names rename would not edit" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = "file:///prepare.zig";
    const source =
        \\fn scale(value: u32) u32 {
        \\    const factor: u32 = 3;
        \\    return value * factor + unknown;
        \\}
        \\
    ;
    try server.documents.open(uri, 1, source);
    const document = server.documents.getConst(uri).?;
    const at = struct {
        fn position(doc: *const zig_analyzer.syntax.document.Document, text: []const u8, needle: []const u8, skip: usize) lsp.types.Position {
            const offset = std.mem.find(u8, text, needle).? + skip;
            return doc.range(.{ .start = offset, .end = offset }).start;
        }
    }.position;

    const local = (try server.@"textDocument/prepareRename"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = at(document, source, "factor +", 2),
    })).?;
    const placeholder = local.prepare_rename_placeholder;
    try std.testing.expectEqualStrings("factor", placeholder.placeholder);
    try std.testing.expectEqual(@as(u32, 2), placeholder.range.start.line);
    try std.testing.expectEqual(@as(u32, 19), placeholder.range.start.character);
    try std.testing.expectEqual(@as(u32, 25), placeholder.range.end.character);

    const function = (try server.@"textDocument/prepareRename"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = at(document, source, "scale", 0),
    })).?;
    try std.testing.expectEqualStrings("scale", function.prepare_rename_placeholder.placeholder);

    try std.testing.expectError(error.RequestFailed, server.@"textDocument/prepareRename"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = at(document, source, "u32 {", 1),
    }));
    try std.testing.expectError(error.RequestFailed, server.@"textDocument/prepareRename"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = at(document, source, "unknown", 1),
    }));
    try std.testing.expect(try server.@"textDocument/prepareRename"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = at(document, source, "return", 2),
    }) == null);
}
