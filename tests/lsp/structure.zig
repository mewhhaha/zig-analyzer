//! Document highlights, folding ranges, selection ranges and document links.
const std = @import("std");
const lsp = @import("lsp");
const zig_analyzer = @import("zig_analyzer");
const support = @import("support.zig");

const Server = zig_analyzer.lsp.server.Server;
const runBasicServer = zig_analyzer.lsp.server.runBasicServer;
const TestTransport = support.TestTransport;
const checkoutUri = support.checkoutUri;

test "initialize advertises the structural views" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
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

    const capabilities = transport.output(0);
    for ([_][]const u8{
        "\"documentHighlightProvider\":true",
        "\"foldingRangeProvider\":true",
        "\"selectionRangeProvider\":true",
        "\"documentLinkProvider\":{\"resolveProvider\":false}",
        "\"documentRangeFormattingProvider\":true",
        "zig-analyzer.runTest",
    }) |expected| {
        try std.testing.expect(std.mem.find(u8, capabilities, expected) != null);
    }
}

test "document highlight marks the binding's writes and reads, and only its own" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = "file:///highlight.zig";
    const source =
        \\fn sum(values: []const u32) u32 {
        \\    var total: u32 = 0;
        \\    for (values) |value| total += value;
        \\    return total;
        \\}
        \\fn other() u32 {
        \\    const total: u32 = 1;
        \\    return total;
        \\}
        \\
    ;
    try server.documents.open(uri, 1, source);
    const document = server.documents.getConst(uri).?;
    const use = std.mem.find(u8, source, "return total").? + "return ".len;

    const highlights = (try server.@"textDocument/documentHighlight"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = document.range(.{ .start = use, .end = use }).start,
    })).?;
    try std.testing.expectEqual(@as(usize, 3), highlights.len);
    try std.testing.expectEqual(@as(u32, 1), highlights[0].range.start.line);
    try std.testing.expectEqual(lsp.types.DocumentHighlight.Kind.Write, highlights[0].kind.?);
    try std.testing.expectEqual(@as(u32, 2), highlights[1].range.start.line);
    try std.testing.expectEqual(lsp.types.DocumentHighlight.Kind.Write, highlights[1].kind.?);
    try std.testing.expectEqual(@as(u32, 3), highlights[2].range.start.line);
    try std.testing.expectEqual(lsp.types.DocumentHighlight.Kind.Read, highlights[2].kind.?);

    const keyword = std.mem.find(u8, source, "return").?;
    try std.testing.expect(try server.@"textDocument/documentHighlight"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = document.range(.{ .start = keyword, .end = keyword }).start,
    }) == null);
}

test "folding ranges cover blocks, comments and imports" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///fold.zig","languageId":"zig","version":1,"text":"const std = @import(\"std\");\nconst mem = std.mem;\n\n// First line\n// second line\npub fn main() void {\n    std.debug.print(\"{d}\\n\", .{\n        1,\n    });\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"file:///fold.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
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

    const response = transport.output(2);
    try std.testing.expect(std.mem.find(u8, response, "{\"startLine\":0,\"endLine\":1,\"kind\":\"imports\"}") != null);
    try std.testing.expect(std.mem.find(u8, response, "{\"startLine\":3,\"endLine\":4,\"kind\":\"comment\"}") != null);
    try std.testing.expect(std.mem.find(u8, response, "{\"startLine\":5,\"endLine\":8}") != null);
    // The call's argument list and its `.{` open on the same line; the fold
    // there ends before the line that closes both.
    try std.testing.expect(std.mem.find(u8, response, "{\"startLine\":6,\"endLine\":7}") != null);
}

test "selection ranges grow outward through nested parents" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = "file:///select.zig";
    const source = "fn area(width: u32, height: u32) u32 {\n    return width * height + 1;\n}\n";
    try server.documents.open(uri, 1, source);
    const document = server.documents.getConst(uri).?;
    const offset = std.mem.find(u8, source, "height + 1").? + 2;

    const selections = (try server.@"textDocument/selectionRange"(arena, .{
        .textDocument = .{ .uri = uri },
        .positions = &.{document.range(.{ .start = offset, .end = offset }).start},
    })).?;
    try std.testing.expectEqual(@as(usize, 1), selections.len);
    var texts: std.ArrayList([]const u8) = .empty;
    var current: ?*const lsp.types.SelectionRange = &selections[0];
    while (current) |selection| : (current = selection.parent) {
        const start = document.byteOffset(selection.range.start);
        const end = document.byteOffset(selection.range.end);
        try texts.append(arena, source[start..end]);
    }
    try std.testing.expectEqualStrings("height", texts.items[0]);
    try std.testing.expectEqualStrings("width * height", texts.items[1]);
    try std.testing.expectEqualStrings("width * height + 1", texts.items[2]);
    try std.testing.expectEqualStrings(source, texts.last().?);
}

test "document links point at the relative files that exist" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = try checkoutUri(arena, "examples/lsp/imports/links.zig");
    const source =
        \\const std = @import("std");
        \\const catalog = @import("catalog.zig");
        \\const missing = @import("missing.zig");
        \\const main_text = @embedFile("main.zig");
        \\
    ;
    try server.documents.open(uri, 1, source);

    const links = (try server.@"textDocument/documentLink"(arena, .{ .textDocument = .{ .uri = uri } })).?;
    try std.testing.expectEqual(@as(usize, 2), links.len);
    try std.testing.expect(std.mem.endsWith(u8, links[0].target.?, "/examples/lsp/imports/catalog.zig"));
    try std.testing.expectEqual(@as(u32, 1), links[0].range.start.line);
    try std.testing.expectEqual(@as(u32, 25), links[0].range.start.character);
    try std.testing.expectEqual(@as(u32, 36), links[0].range.end.character);
    try std.testing.expect(std.mem.endsWith(u8, links[1].target.?, "/examples/lsp/imports/main.zig"));
}
