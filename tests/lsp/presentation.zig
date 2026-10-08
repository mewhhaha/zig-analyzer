//! Read-only views: call hierarchy and formatting.
const std = @import("std");
const lsp = @import("lsp");
const zig_analyzer = @import("zig_analyzer");
const support = @import("support.zig");

const analysis = zig_analyzer.analysis;
const uri_module = zig_analyzer.uri;
const Document = zig_analyzer.syntax.document.Document;
const Server = zig_analyzer.lsp.server.Server;
const runBasicServer = zig_analyzer.lsp.server.runBasicServer;
const TestTransport = support.TestTransport;
const checkoutUri = support.checkoutUri;
const openDocument = support.openDocument;
const replaceDocument = support.replaceDocument;
const lastPublished = support.lastPublished;

test "LSP call hierarchy connects callers and callees" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///calls.zig","languageId":"zig","version":1,"text":"fn callee() void {}\nfn caller() void { callee(); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/prepareCallHierarchy","params":{"textDocument":{"uri":"file:///calls.zig"},"position":{"line":0,"character":4}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"callHierarchy/outgoingCalls","params":{"item":{"name":"caller","kind":12,"uri":"file:///calls.zig","range":{"start":{"line":1,"character":3},"end":{"line":1,"character":9}},"selectionRange":{"start":{"line":1,"character":3},"end":{"line":1,"character":9}}}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"callHierarchy/incomingCalls","params":{"item":{"name":"callee","kind":12,"uri":"file:///calls.zig","range":{"start":{"line":0,"character":3},"end":{"line":0,"character":9}},"selectionRange":{"start":{"line":0,"character":3},"end":{"line":0,"character":9}}}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();

    try runBasicServer(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 6), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "\"name\":\"callee\"") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "\"name\":\"callee\"") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "\"name\":\"caller\"") != null);
}

test "LSP formatting delegates to zig fmt without applying lint fixes" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///format.zig","languageId":"zig","version":1,"text":"fn run(enabled:bool)void{var value=if(enabled)true else false;_=value;}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///format.zig"},"options":{"tabSize":4,"insertSpaces":true}}}
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

    try runBasicServer(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "var value = if (enabled) true else false;") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "const value") == null);
}
