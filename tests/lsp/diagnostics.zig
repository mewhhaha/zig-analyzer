//! Diagnostics published for open documents.
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

test "module diagnostics report only missing public members" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        "const catalog = @import(\"catalog.zig\");\n" ++
        "fn result() u32 { _ = catalog.default_limit; return catalog.missingLimit; }\n";
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    const uri = try checkoutUri(std.testing.allocator, "examples/lsp/imports/main.zig");
    defer std.testing.allocator.free(uri);
    try server.documents.open(uri, 1, source);
    const document = server.documents.getConst(uri).?;
    const found = try server.documentFindings(arena, document, analysis.Configuration.defaults());
    var missing_member_count: usize = 0;
    for (found) |finding| {
        if (finding.rule != .unresolved_member) continue;
        missing_member_count += 1;
        try std.testing.expectEqualStrings("missingLimit", source[finding.span.start..finding.span.end]);
    }
    try std.testing.expectEqual(@as(usize, 1), missing_member_count);
}

test "module diagnostics resolve nested imported aliases once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        "const Message = @import(\"catalog.zig\").MessagePool.Message;\n" ++
        "fn use(_: *Message.Ping, _: *Message.Missing) void {}\n";
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    const uri = try checkoutUri(std.testing.allocator, "examples/lsp/imports/nested.zig");
    defer std.testing.allocator.free(uri);
    try server.documents.open(uri, 1, source);
    const document = server.documents.getConst(uri).?;

    const view = (try zig_analyzer.project.describe.moduleView(server.services().resolver(), arena, document, "Message")).?;
    var ping_member_count: usize = 0;
    for (view.members) |member| {
        if (std.mem.eql(u8, member.name, "Ping")) ping_member_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ping_member_count);

    const found = try server.documentFindings(arena, document, analysis.Configuration.defaults());
    var missing_member_count: usize = 0;
    for (found) |finding| {
        if (finding.rule != .unresolved_member) continue;
        missing_member_count += 1;
        try std.testing.expectEqualStrings("Missing", source[finding.span.start..finding.span.end]);
    }
    try std.testing.expectEqual(@as(usize, 1), missing_member_count);
}

test "module diagnostics respect same-file visibility and nested receivers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        "const namespace = struct { const log = struct { fn scoped() void {} }; };\n" ++
        "const log = struct {};\n" ++
        "const Status = enum { normal };\n" ++
        "const Private = struct { fn run() void {} const Nested = u8; };\n" ++
        "fn use() void { namespace.log.scoped(); _ = Status.normal; Private.run(); _ = Private.Nested; Private.missing(); }\n";
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    try server.documents.open("file:///same_file_visibility.zig", 1, source);
    const document = server.documents.getConst("file:///same_file_visibility.zig").?;

    const found = try server.documentFindings(arena, document, analysis.Configuration.defaults());
    var missing_member_count: usize = 0;
    for (found) |finding| {
        if (finding.rule != .unresolved_member) continue;
        missing_member_count += 1;
        try std.testing.expectEqualStrings("missing", source[finding.span.start..finding.span.end]);
    }
    try std.testing.expectEqual(@as(usize, 1), missing_member_count);
}

test "LSP publishes memory ownership warnings" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///memory.zig","languageId":"zig","version":1,"text":"fn leak(allocator: std.mem.Allocator) !void { const buffer = try allocator.alloc(u8, 16); _ = buffer; }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///memory.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":104}},"context":{"diagnostics":[],"only":["quickfix"]}}}
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
    try std.testing.expect(std.mem.find(u8, transport.output(1), "unreleased-allocation") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "no visible free") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "\"severity\":2") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "Insert defer allocator.free(buffer)") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "\"isPreferred\":false") != null);
}

test "LSP publishes unresolved calls before the document is saved" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///unsaved.zig","languageId":"zig","version":1,"text":"fn compute() u32 { return 1; }\ncomptime { _ = compute(); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///unsaved.zig","version":2},"contentChanges":[{"text":"fn compte() u32 { return 1; }\ncomptime { _ = compute(); }\n"}]}}
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

    try runBasicServer(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "\"diagnostics\":[]") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "unresolved-call") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "unresolved function 'compute'") != null);
}

test "LSP publishes unresolved type references after an unsaved rename" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///unsaved_type.zig","languageId":"zig","version":1,"text":"const pool = @import(\"pool\");\nconst Message = pool.Message;\nfn use(message: *Message.Prepare) void { _ = message; }\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///unsaved_type.zig","version":2},"contentChanges":[{"text":"const pool = @import(\"pool\");\nconst Mssage = pool.Message;\nfn use(message: *Message.Prepare) void { _ = message; }\n"}]}}
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

    try runBasicServer(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "\"diagnostics\":[]") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "unresolved-identifier") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "unresolved identifier 'Message'") != null);
}

test "LSP diagnostics map positions past astral-plane characters in UTF-16" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///astral.zig","languageId":"zig","version":1,"text":"const s = \"😀\"; const broken ="}}}
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

    try std.testing.expectEqual(@as(usize, 3), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "syntax-error") != null);
    // The error sits at the end of the line: 32 bytes but 30 UTF-16 units.
    try std.testing.expect(std.mem.find(u8, transport.output(1), "\"character\":30") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "\"character\":32") == null);
}

test "LSP keeps answering after an edit deletes the import behind a member access" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://examples/lsp/imports/main.zig","languageId":"zig","version":1,"text":"const catalog = @import(\"catalog.zig\");\nfn result() u32 { return catalog.clampToLimit(100); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file://examples/lsp/imports/main.zig","version":2},"contentChanges":[{"text":"fn result() u32 { return catalog.clampToLimit(100); }\n"}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://examples/lsp/imports/main.zig"},"position":{"line":0,"character":35}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file://examples/lsp/imports/main.zig"},"position":{"line":0,"character":33}}}
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

    try runBasicServer(std.testing.io, std.testing.allocator, &transport.transport, &server, null);

    try std.testing.expectEqual(@as(usize, 6), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "\"result\":null") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "\"result\":[]") != null);
}

test "saving a build script reanalyzes the active source document" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    try server.documents.open("file:///workspace/build.zig", 2, "pub fn build() void {}\n");
    try server.documents.open("file:///workspace/src/main.zig", 4, "pub fn main() void {}\n");
    try server.documents.open("file:///other/src/main.zig", 7, "pub fn main() void {}\n");
    server.backend.root_uri = try std.testing.allocator.dupe(u8, "file:///workspace/src/main.zig");

    const document = (try server.analysisDocumentAfterSave(arena_state.allocator(), "file:///workspace/build.zig")).?;

    try std.testing.expectEqualStrings("file:///workspace/src/main.zig", document.uri);
    try std.testing.expectEqual(@as(i32, 4), document.version);
    const manifest_document = (try server.analysisDocumentAfterSave(arena_state.allocator(), "file:///workspace/build.zig.zon")).?;
    try std.testing.expectEqualStrings("file:///workspace/src/main.zig", manifest_document.uri);
}

test "LSP imported deprecations use current unsaved dependency documents" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source = "const api = @import(\"dependency.zig\"); pub fn run() void { api.old(); }";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = source });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "pub fn old() void {}" });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const dependency_path = try temporary.dir.realPathFileAlloc(std.testing.io, "dependency.zig", std.testing.allocator);
    defer std.testing.allocator.free(dependency_path);
    const uri = try uri_module.fromPath(std.testing.allocator, path);
    defer std.testing.allocator.free(uri);
    const dependency_uri = try uri_module.fromPath(std.testing.allocator, dependency_path);
    defer std.testing.allocator.free(dependency_uri);
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    try server.documents.open(uri, 1, source);
    try server.documents.open(dependency_uri, 1, "/// Deprecated, use current\npub fn old() void {}");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var deprecated_count: usize = 0;
    const first = try server.documentFindings(arena.allocator(), server.documents.getConst(uri).?, .defaults());
    for (first) |finding| if (finding.rule == .deprecated_declaration) {
        deprecated_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "use current") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), deprecated_count);
    try server.publishDiagnostics(arena.allocator(), uri);
    try server.@"textDocument/didChange"(arena.allocator(), .{
        .textDocument = .{ .uri = dependency_uri, .version = 2 },
        .contentChanges = &.{.{ .text_document_content_change_whole_document = .{ .text = "pub fn old() void {}" } }},
    });
    try std.testing.expect(std.mem.find(u8, transport.output(1), uri) != null);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "deprecated-declaration") == null);
    try server.@"textDocument/didChange"(arena.allocator(), .{
        .textDocument = .{ .uri = dependency_uri, .version = 3 },
        .contentChanges = &.{.{ .text_document_content_change_whole_document = .{ .text = "/// Deprecated: updated advice\npub fn old() void {}" } }},
    });
    try std.testing.expect(std.mem.find(u8, transport.output(3), uri) != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "updated advice") != null);
    try server.@"textDocument/didClose"(arena.allocator(), .{ .textDocument = .{ .uri = dependency_uri } });
    try std.testing.expect(std.mem.find(u8, transport.output(5), uri) != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "deprecated-declaration") == null);

    // Generated imports may reference deprecated APIs; retain the generated-file
    // policy even when their dependency now carries a deprecation marker.
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "/// Deprecated: use current\npub fn old() void {}" });
    const generated_source =
        "pub const __b" ++ "uiltin_bswap16 = @import(\"std\").zig.c_builtins.__builtin_bswap16;\n" ++
        "pub const __b" ++ "uiltin_bswap32 = @import(\"std\").zig.c_builtins.__builtin_bswap32;\n" ++
        "pub const __b" ++ "uiltin_bswap64 = @import(\"std\").zig.c_builtins.__builtin_bswap64;\n" ++ source;
    try server.documents.change(uri, 2, &.{.{ .text_document_content_change_whole_document = .{ .text = generated_source } }});
    const generated_findings = try server.documentFindings(arena.allocator(), server.documents.getConst(uri).?, .defaults());
    for (generated_findings) |finding| try std.testing.expect(finding.rule != .deprecated_declaration);
}
