//! Pull diagnostics for clients that ask for them, instead of push.
const std = @import("std");
const lsp = @import("lsp");
const zig_analyzer = @import("zig_analyzer");
const support = @import("support.zig");

const Server = zig_analyzer.lsp.server.Server;
const runBasicServer = zig_analyzer.lsp.server.runBasicServer;
const TestTransport = support.TestTransport;

const pulling_client =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{"textDocument":{"diagnostic":{}},"workspace":{"diagnostics":{"refreshSupport":true}}}}}
;
const shutdown =
    \\{"jsonrpc":"2.0","id":99,"method":"shutdown"}
;
const exit =
    \\{"jsonrpc":"2.0","method":"exit"}
;

test "a client that pulls gets diagnostics only by pulling" {
    const incoming = [_][]const u8{
        pulling_client,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///pull.zig","languageId":"zig","version":1,"text":"const broken =\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///pull.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///pull.zig"},"previousResultId":"1"}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///pull.zig","version":2},"contentChanges":[{"text":"const fixed = 1;\n"}]}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///pull.zig"},"previousResultId":"1"}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///never-opened.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"shutdown"}
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

    try std.testing.expect(std.mem.find(u8, transport.output(0), "\"diagnosticProvider\":{\"identifier\":\"zig-analyzer\",\"interFileDependencies\":true,\"workspaceDiagnostics\":false}") != null);
    for (transport.outputs.items) |message| {
        try std.testing.expect(std.mem.find(u8, message, "publishDiagnostics") == null);
    }
    try std.testing.expectEqual(@as(usize, 6), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "\"kind\":\"full\",\"resultId\":\"1\"") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "syntax-error") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "\"kind\":\"unchanged\",\"resultId\":\"1\"") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "\"kind\":\"full\",\"resultId\":\"2\"") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "syntax-error") == null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "\"kind\":\"full\",\"items\":[]") != null);
}

test "a pulled document whose diagnostics change asks the client to pull again" {
    const incoming = [_][]const u8{ pulling_client, shutdown, exit };
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    try runBasicServer(std.testing.io, std.testing.allocator, &transport.transport, &server, null);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = "file:///refresh.zig";
    try support.openDocument(&server, arena, uri, 1, "const value = 1;\n");

    const first = try server.@"textDocument/diagnostic"(arena, .{ .textDocument = .{ .uri = uri } });
    try std.testing.expectEqualStrings("1", first.related_full_document_diagnostic_report.resultId.?);
    const before = transport.output_count;

    // A compile of the version the client already has reports an error.
    const compile_error = [_]lsp.types.Diagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 6 }, .end = .{ .line = 0, .character = 11 } },
        .message = .{ .string = "compile error" },
    }};
    try server.publisher.publishCompiled(uri, 1, &.{}, &compile_error);
    try std.testing.expectEqual(before + 1, transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(before), "\"method\":\"workspace/diagnostic/refresh\"") != null);

    const second = try server.@"textDocument/diagnostic"(arena, .{ .textDocument = .{ .uri = uri }, .previousResultId = "1" });
    const report = second.related_full_document_diagnostic_report;
    try std.testing.expectEqual(@as(usize, 1), report.items.len);
    try std.testing.expectEqualStrings("compile error", report.items[0].message.string);

    // An edit is followed by the client's own pull; no refresh is needed.
    try support.replaceDocument(&server, arena, uri, 2, "const value = 2;\n");
    try std.testing.expectEqual(before + 1, transport.output_count);
}

test "a client that pulls without refresh support keeps push diagnostics" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{"textDocument":{"diagnostic":{}}}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///push.zig","languageId":"zig","version":1,"text":"const value = 1;\n"}}}
        ,
        shutdown,
        exit,
    };
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    try runBasicServer(std.testing.io, std.testing.allocator, &transport.transport, &server, null);
    try std.testing.expect(std.mem.find(u8, transport.output(0), "diagnosticProvider") == null);
    try std.testing.expect(support.lastPublished(&transport, "file:///push.zig") != null);
}
