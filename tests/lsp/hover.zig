//! Hover requests: language tokens, bindings, imported and constructed types, and the type commands.
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

test "LSP hover describes parameters locals functions and bounded constants" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///hover.zig","languageId":"zig","version":1,"text":"/// Maximum number of attempts made by the example.\nconst retry_limit: u8 = 3;\n\n/// Adds an incoming sample to an accumulated value.\nfn addSample(accumulated: u32, incoming: u32) u32 {\n    return accumulated + incoming;\n}\n\nfn compute(incoming: u32) u32 {\n    const doubled: u32 = incoming * 2;\n    return addSample(doubled, incoming) + retry_limit;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///hover.zig"},"position":{"line":9,"character":26}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///hover.zig"},"position":{"line":10,"character":22}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///hover.zig"},"position":{"line":10,"character":12}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///hover.zig"},"position":{"line":10,"character":43}}}
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

    try runBasicServer(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 7), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "\"kind\":\"markdown\"") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "```zig\\nincoming: u32\\n```\\n```zig\\n(u32)\\n```") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "```zig\\nconst doubled: u32 = incoming * 2\\n```\\n```zig\\n(u32)\\n```") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "```zig\\nfn addSample(accumulated: u32, incoming: u32) u32\\n```") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "Adds an incoming sample") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "```zig\\nconst retry_limit: u8 = 3\\n```\\n```zig\\n(u8 = 3)\\n```") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "Maximum number of attempts") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(6), "\"result\":null") != null);
}

test "LSP hover documents Zig keywords primitive types and values" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///language.zig","languageId":"zig","version":1,"text":"const count: u8 = 1;\nvar enabled: bool = true;\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language.zig"},"position":{"line":0,"character":1}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language.zig"},"position":{"line":0,"character":13}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language.zig"},"position":{"line":1,"character":1}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language.zig"},"position":{"line":1,"character":13}}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language.zig"},"position":{"line":1,"character":21}}}
        ,
        \\{"jsonrpc":"2.0","id":7,"method":"shutdown"}
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

    try std.testing.expectEqual(@as(usize, 8), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "```zig\\nconst\\n```\\n```zig\\n(keyword)\\n```") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "cannot be reassigned") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "#Keyword-Reference") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "An unsigned integer type with 8 bits") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "mutable binding") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "boolean type") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(6), "```zig\\ntrue\\n```\\n```zig\\n(bool)\\n```") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(6), "#Primitive-Values") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(7), "\"result\":null") != null);
}

test "LSP hover documents builtins operators literals and semicolons" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tokens.zig","languageId":"zig","version":1,"text":"const value = @as(u8, 1 + 2);\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tokens.zig"},"position":{"line":0,"character":15}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tokens.zig"},"position":{"line":0,"character":22}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tokens.zig"},"position":{"line":0,"character":24}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tokens.zig"},"position":{"line":0,"character":28}}}
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

    try std.testing.expectEqual(@as(usize, 7), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "@as(comptime T: type, expression: anytype) T") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "builtin function") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "#@as") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "integer literal") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "comptime_int") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "(operator)") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "Terminates a declaration") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "#Grammar") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(6), "\"result\":null") != null);
}

test "LSP hover follows inferred returns through imported type aliases" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://fixtures/hover_main.zig","languageId":"zig","version":1,"text":"const types = @import(\"hover_types.zig\");\nfn make() types.Headers.View { return .{ .slice = \"zig\" }; }\nfn inspect() usize { const view = make(); return view.slice.len; }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://fixtures/hover_main.zig"},"position":{"line":2,"character":50}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://fixtures/hover_main.zig"},"position":{"line":2,"character":55}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
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

    try std.testing.expectEqual(@as(usize, 5), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "const view = make()") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "types.Headers.View") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "slice: []const u8") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "Headers decoded from the used message body") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "\"result\":null") != null);
}

test "LSP hover resolves constructed types through imports and type functions" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://fixtures/member_main.zig","languageId":"zig","version":1,"text":"const registry = @import(\"store_registry.zig\");\nfn run() void {\n    var store = registry.Store.init(8);\n    store.close();\n    var queue = registry.Queue(u8).empty;\n    queue.push(1);\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://fixtures/member_main.zig"},"position":{"line":3,"character":11}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://fixtures/member_main.zig"},"position":{"line":5,"character":11}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
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

    try std.testing.expectEqual(@as(usize, 5), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "fn close(self: *Store) void") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "Releases every resource owned by the store.") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "fn push(self: *@This(), entry: T) void") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "Appends one entry to the queue tail.") != null);
}

test "LSP workspace/executeCommand zig-analyzer.typeAtPosition rejects out-of-range positions" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    const uri = "file:///type_pos_invalid.zig";
    try server.documents.open(uri, 1, "const a = 1;\n");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const invalid = [_][2]i64{ .{ -1, 0 }, .{ 0, -1 }, .{ 1 << 40, 0 }, .{ 0, 1 << 40 } };
    for (invalid) |pair| {
        const args = try arena_state.allocator().alloc(std.json.Value, 3);
        args[0] = .{ .string = uri };
        args[1] = .{ .integer = pair[0] };
        args[2] = .{ .integer = pair[1] };
        try std.testing.expectError(error.InvalidParams, server.@"workspace/executeCommand"(arena_state.allocator(), .{
            .command = "zig-analyzer.typeAtPosition",
            .arguments = args,
        }));
    }
}

test "LSP workspace/executeCommand zig-analyzer.typeAtPosition returns type description" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();

    const uri = "file:///type_pos.zig";
    const source: [:0]const u8 =
        "const Config = struct {\n" ++
        "    port: u16,\n" ++
        "};\n" ++
        "\n" ++
        "pub fn main() void {\n" ++
        "    const cfg: Config = .{ .port = 8080 };\n" ++
        "    _ = cfg;\n" ++
        "}\n";

    try server.documents.open(uri, 1, source);
    const document = server.documents.getConst(uri).?;

    const cfg_start = std.mem.find(u8, source, "cfg: Config").?;
    const cfg_pos = document.range(.{ .start = cfg_start, .end = cfg_start + 3 }).start;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const args = try arena_state.allocator().alloc(std.json.Value, 3);
    args[0] = .{ .string = uri };
    args[1] = .{ .integer = cfg_pos.line };
    args[2] = .{ .integer = cfg_pos.character };

    const result = (try server.@"workspace/executeCommand"(arena_state.allocator(), .{
        .command = "zig-analyzer.typeAtPosition",
        .arguments = args,
    })).?;

    try std.testing.expectEqualStrings("Config", result.string);
}
