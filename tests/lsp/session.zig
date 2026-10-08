//! Session behaviour: configuration lookup, workspace folders, request ordering and robustness.
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

test "configuration comes from the nearest zig-analyzer.json above the open file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "src/deep");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "zig-analyzer.json",
        .data = "{\"lints\":{\"rules\":{\"redundant-boolean-if\":\"warning\",\"prefer-log-over-print\":\"warning\"}}}\n",
    });
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();

    const production_path = try std.Io.Dir.path.join(arena, &.{ root, "src/deep/main.zig" });
    const production_uri = try uri_module.fromPath(arena, production_path);
    try server.documents.open(production_uri, 1, "const value = 1;\n");
    const production = try server.linter().configuration(arena, server.documents.getConst(production_uri).?);
    try std.testing.expectEqual(analysis.Level.warning, production.level(.redundant_boolean_if));
    try std.testing.expectEqual(analysis.Level.warning, production.level(.prefer_log_over_print));

    const test_path = try std.Io.Dir.path.join(arena, &.{ root, "src/deep/main_test.zig" });
    const test_uri = try uri_module.fromPath(arena, test_path);
    try server.documents.open(test_uri, 1, "const value = 1;\n");
    const relaxed = try server.linter().configuration(arena, server.documents.getConst(test_uri).?);
    try std.testing.expectEqual(analysis.Level.warning, relaxed.level(.redundant_boolean_if));
    try std.testing.expectEqual(analysis.Level.off, relaxed.level(.prefer_log_over_print));
}

test "a broken configuration file is reported once and edits take effect" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "zig-analyzer.json", .data = "{ not json" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "const value = 1;\n" });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const uri = try uri_module.fromPath(std.testing.allocator, path);
    defer std.testing.allocator.free(uri);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    try server.documents.open(uri, 1, "const value = 1;\n");

    try server.publishDiagnostics(arena, uri);
    try server.publishDiagnostics(arena, uri);
    var messages: usize = 0;
    for (0..transport.output_count) |index| {
        if (std.mem.find(u8, transport.output(index), "window/showMessage") != null) messages += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), messages);

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "zig-analyzer.json", .data = "{\"lints\":{\"rules\":{\"redundant-boolean-if\":\"warning\"}}}\n" });
    try server.projectConfigurationChanged(arena);
    const document = server.documents.getConst(uri).?;
    const fixed = try server.linter().configuration(arena, document);
    try std.testing.expect(fixed.warning == null);
    try std.testing.expectEqual(analysis.Level.warning, fixed.level(.redundant_boolean_if));
}

test "workspace folders from initialize and folder changes set the project roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();

    _ = try server.initialize(arena, .{
        .capabilities = .{},
        .workspaceFolders = &.{.{ .uri = "file:///work/my%20app", .name = "my app" }},
    });
    try std.testing.expectEqual(@as(usize, 1), server.project_config.workspace_roots.items.len);
    try std.testing.expectEqualStrings("/work/my app", server.project_config.workspace_roots.items[0]);

    try server.@"workspace/didChangeWorkspaceFolders"(arena, .{ .event = .{
        .added = &.{.{ .uri = "file:///work/other", .name = "other" }},
        .removed = &.{.{ .uri = "file:///work/my%20app", .name = "my app" }},
    } });
    try std.testing.expectEqual(@as(usize, 1), server.project_config.workspace_roots.items.len);
    try std.testing.expectEqualStrings("/work/other", server.project_config.workspace_roots.items[0]);

    var root_only: Server = undefined;
    try root_only.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer root_only.deinit();
    _ = try root_only.initialize(arena, .{ .capabilities = .{}, .rootUri = "file:///work/legacy" });
    try std.testing.expectEqualStrings("/work/legacy", root_only.project_config.workspace_roots.items[0]);
}

test "LSP answers from current syntax while the compiler worker is busy" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///busy.zig","languageId":"zig","version":1,"text":"const first = 1;\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///busy.zig","version":2},"contentChanges":[{"text":"const second = 2;\n"}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///busy.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .{ .compiler = .{ .debounce_ms = 0 } });
    // A compile is running: the worker holds the session for the whole session.
    server.backend.session_mutex.lockUncancelable(std.testing.io);
    var worker_locked = true;
    defer {
        if (worker_locked) server.backend.session_mutex.unlock(std.testing.io);
        server.deinit();
    }

    try runBasicServer(std.testing.io, std.testing.allocator, &transport.transport, &server, null);

    try std.testing.expectEqual(@as(usize, 5), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "publishDiagnostics") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "publishDiagnostics") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "second") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "first") == null);

    server.backend.session_mutex.unlock(std.testing.io);
    worker_locked = false;
}

test "LSP discards an out-of-order document version instead of clobbering newer text" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///rapid.zig","languageId":"zig","version":1,"text":"const first = 1;\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///rapid.zig","version":3},"contentChanges":[{"text":"const third = 3;\n"}]}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///rapid.zig","version":2},"contentChanges":[{"text":"const second = 2;\n"}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///rapid.zig"}}}
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

    // The stale version publishes nothing: open, newer change, symbols, shutdown.
    try std.testing.expectEqual(@as(usize, 5), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "third") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "second") == null);
}

test "LSP survives a save notification for a document that was never opened" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"file:///ghost.zig"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///alive.zig","languageId":"zig","version":1,"text":"const answer = 42;\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///alive.zig"}}}
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

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "answer") != null);
}

test "LSP session covers lifecycle synchronization and broad features" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":99}}
        ,
        \\{"jsonrpc":"2.0","method":"workspace/didChangeWorkspaceFolders","params":{"event":{"added":[],"removed":[]}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///fixture.zig","languageId":"zig","version":1,"text":"const answer = 42;\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///fixture.zig","version":2},"contentChanges":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":0}},"text":"const broken ="}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///fixture.zig"},"position":{"line":0,"character":6}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///fixture.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"workspace/symbol","params":{"query":"ans"}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///fixture.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/semanticTokens/range","params":{"textDocument":{"uri":"file:///fixture.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":18}}}}
        ,
        \\{"jsonrpc":"2.0","id":8,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///fixture.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":14}}}}
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

    try std.testing.expectEqual(@as(usize, 10), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(0), "zig-analyzer") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "publishDiagnostics") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "expected") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "answer") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "broken") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "answer") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(6), "\"data\"") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(7), "\"data\"") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(8), "comptime_int") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(9), "\"result\":null") != null);
}
