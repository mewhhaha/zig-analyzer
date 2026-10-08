//! Completion contexts.
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

test "LSP member completion and rename respect syntax context" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///language_server.zig","languageId":"zig","version":1,"text":"const Profile = struct { display_name: []const u8, login_count: u32 };\nfn show(profile: Profile) []const u8 { return profile.display_name; }\nfn increment(value: u32) u32 { return value + 1; }\nfn describe(value: []const u8) []const u8 { return value; }\nconst std = @import(\"std\");\nfn namesMatch(left: []const u8, right: []const u8) bool { return std.mem.eql(u8, left, right); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///language_server.zig"},"position":{"line":1,"character":54}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///language_server.zig"},"position":{"line":5,"character":73}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///language_server.zig"},"position":{"line":2,"character":15},"newName":"number"}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language_server.zig"},"position":{"line":1,"character":55}}}
        ,
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language_server.zig"},"position":{"line":5,"character":74}}}
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

    try std.testing.expectEqual(@as(usize, 9), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "display_name") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "login_count") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "\"eql\"") != null);
    // Rename reports the mode it used before it answers.
    try std.testing.expect(std.mem.find(u8, transport.output(4), "syntax scoping") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, transport.output(5), "\"newText\":\"number\""));
    try std.testing.expect(std.mem.find(u8, transport.output(6), "```zig\\ndisplay_name: []const u8\\n```\\n```zig\\n([]const u8)\\n```") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(7), "fn eql(comptime T: type") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(7), "Returns true if and only if") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(8), "\"result\":null") != null);
}
