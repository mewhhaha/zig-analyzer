//! Definition, type definition and import navigation.
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

test "definition follows a constant alias into an imported declaration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        "const catalog = @import(\"catalog.zig\");\n" ++
        "const Alias = catalog.MessagePool;\n" ++
        "fn use() void { _ = Alias; }\n";
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    const uri = try checkoutUri(std.testing.allocator, "examples/lsp/imports/alias.zig");
    defer std.testing.allocator.free(uri);
    try server.documents.open(uri, 1, source);
    const document = server.documents.getConst(uri).?;
    const usage_start = std.mem.findLast(u8, source, "Alias").?;

    const response = (try server.@"textDocument/definition"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = document.range(.{ .start = usage_start, .end = usage_start }).start,
    })).?;
    const location = response.definition.location;
    try std.testing.expect(std.mem.endsWith(u8, location.uri, "/examples/lsp/imports/catalog.zig"));
    try std.testing.expectEqual(@as(u32, 2), location.range.start.line);
    try std.testing.expectEqual(@as(u32, 10), location.range.start.character);
}

test "LSP import completion and definition resolve another file" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://examples/lsp/imports/main.zig","languageId":"zig","version":1,"text":"const catalog = @import(\"catalog.zig\");\nfn result() u32 { return catalog.clampToLimit(100); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file://examples/lsp/imports/main.zig"},"position":{"line":1,"character":33}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://examples/lsp/imports/main.zig"},"position":{"line":1,"character":36}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://examples/lsp/imports/main.zig"},"position":{"line":1,"character":36}}}
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

    try std.testing.expectEqual(@as(usize, 6), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "default_limit") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "clampToLimit") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "catalog.zig") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "fn clampToLimit(value: u32) u32") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "\"result\":null") != null);
}

test "LSP resolves import paths and nested imported definitions" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://examples/lsp/imports/nested.zig","languageId":"zig","version":1,"text":"const Message = @import(\"catalog.zig\").MessagePool.Message;\nfn use(_: *Message.Ping) void {}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file://examples/lsp/imports/nested.zig"},"position":{"line":1,"character":19}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://examples/lsp/imports/nested.zig"},"position":{"line":0,"character":26}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://examples/lsp/imports/nested.zig"},"position":{"line":0,"character":40}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://examples/lsp/imports/nested.zig"},"position":{"line":0,"character":52}}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://examples/lsp/imports/nested.zig"},"position":{"line":1,"character":20}}}
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

    try runBasicServer(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 8), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "unresolved-member") == null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "\"Ping\"") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "catalog.zig") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "\"line\":0,\"character\":0") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "\"line\":2,\"character\":10") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "\"line\":3,\"character\":14") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(6), "\"line\":4,\"character\":18") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(7), "\"result\":null") != null);
}

test "LSP textDocument/typeDefinition resolves variable type definition" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();

    const uri = "file:///type_def.zig";
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

    const response = (try server.@"textDocument/typeDefinition"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = cfg_pos,
    })).?;

    const definition = switch (response) {
        .definition => |value| value,
        .definition_links => return error.ExpectedDefinitionLocation,
    };
    const location = switch (definition) {
        .location => |value| value,
        .locations => return error.ExpectedSingleDefinition,
    };

    const config_decl = document.declarationNamed("Config").?;
    try std.testing.expectEqualStrings(uri, location.uri);
    try std.testing.expectEqual(document.range(config_decl.span).start, location.range.start);
}
