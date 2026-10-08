//! Code action requests: quickfixes, suppressions, rewrites, extraction, organize imports and fix-alls.
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

test "LSP advertises and returns complete filtered code actions" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{"textDocument":{"codeAction":{"codeActionLiteralSupport":{"codeActionKind":{"valueSet":["quickfix","refactor.extract","refactor.rewrite","source.organizeImports","source.fixAll"]}}}}}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://examples/actions.zig","languageId":"zig","version":1,"text":"const Mode = enum { fast, safe };\nfn run(mode: Mode, input: u32) void {\n    var value = 1;\n    _ = value;\n    const generated: u32 = missing(input, 42);\n    _ = generated;\n    switch (mode) { .fast => {} }\n    _ = if (value == 1) true else false;\n    defer { cleanup(); }\n    if (value == 1) {} else {}\n}\nfn cleanup() void {}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file://examples/actions.zig"},"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":17}},"context":{"diagnostics":[],"only":["quickfix"]}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file://examples/actions.zig"},"range":{"start":{"line":6,"character":4},"end":{"line":6,"character":35}},"context":{"diagnostics":[],"only":["quickfix"]}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file://examples/actions.zig"},"range":{"start":{"line":4,"character":27},"end":{"line":4,"character":34}},"context":{"diagnostics":[],"only":["refactor.rewrite"]}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file://examples/actions.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":11,"character":20}},"context":{"diagnostics":[],"only":["source.fixAll"]}}}
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
    try std.testing.expect(std.mem.find(u8, transport.output(0), "source.organizeImports") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(0), "resolveProvider\":false") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(0), "codeLensProvider") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(0), "zig-analyzer.peekResolvedType") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(0), "callHierarchyProvider") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "missing-switch-prong") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "never-mutated-var") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "Change 'value' to const") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "\"newText\":\"const\"") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), "Fill missing switch prongs") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(3), ".safe => @panic") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "Generate function 'missing'") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "fn missing(input: u32, arg2: anytype) u32") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "Fix all safe zig-analyzer findings") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "Fill missing switch prongs") == null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "\"newText\":\"const\"") == null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "value == 1") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "cleanup();") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(5), "\"newText\":\"\"") != null);
}

test "LSP offers line and file suppression quickfixes for a finding" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{"textDocument":{"codeAction":{"codeActionLiteralSupport":{"codeActionKind":{"valueSet":["quickfix"]}}}}}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///suppress.zig","languageId":"zig","version":1,"text":"fn run() void {\n    var value = 1;\n    _ = value;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///suppress.zig"},"range":{"start":{"line":1,"character":8},"end":{"line":1,"character":13}},"context":{"diagnostics":[],"only":["quickfix"]}}}
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
    const response = transport.output(2);
    try std.testing.expect(std.mem.find(u8, response, "Suppress 'never-mutated-var' on this line") != null);
    try std.testing.expect(std.mem.find(u8, response, "Suppress 'never-mutated-var' in this file") != null);
    try std.testing.expect(std.mem.find(u8, response, "    // zig-analyzer: disable-next-line never-mutated-var\\n") != null);
    try std.testing.expect(std.mem.find(u8, response, "// zig-analyzer: disable-file never-mutated-var\\n") != null);
    try std.testing.expect(std.mem.count(u8, response, "Suppress 'never-mutated-var' on this line") == 1);
}

test "LSP returns Zig error recovery actions" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///recovery.zig","languageId":"zig","version":1,"text":"fn load() error{Missing}!u8 { return 1; }\nfn run() !void { _ = load(); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///recovery.zig"},"range":{"start":{"line":1,"character":21},"end":{"line":1,"character":25}},"context":{"diagnostics":[],"only":["refactor.rewrite"]}}}
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
    try std.testing.expect(std.mem.find(u8, transport.output(2), "Propagate the error with try") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "Handle the error with catch") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "Handle every error with a switch") != null);
}

test "LSP returns build repair workspace action" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{"workspace":{"workspaceEdit":{"documentChanges":true,"resourceOperations":["create"]}}}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///project/build.zig","languageId":"zig","version":1,"text":"const std = @import(\"std\"); pub fn build(b: *std.Build) void { const exe = b.addExecutable(.{ .name = \"app\" }); _ = exe.root_module; }"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///project/src/main.zig","languageId":"zig","version":1,"text":"const feature = @import(\"feature\");"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///project/src/feature.zig","languageId":"zig","version":1,"text":"pub const value = 1;"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///project/src/main.zig"},"range":{"start":{"line":0,"character":24},"end":{"line":0,"character":33}},"context":{"diagnostics":[],"only":["refactor.rewrite"]}}}
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

    try std.testing.expectEqual(@as(usize, 6), transport.output_count);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "Add module 'feature' to build.zig") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(4), "root_module.addImport") != null);
}

test "LSP extracts an exact UTF-16 expression selection" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///extract.zig","languageId":"zig","version":1,"text":"fn compute() u32 {\n    const label = \"😀\";\n    _ = label;\n    return 20 + 22;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///extract.zig"},"range":{"start":{"line":3,"character":11},"end":{"line":3,"character":18}},"context":{"diagnostics":[],"only":["refactor.extract"]}}}
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
    try std.testing.expect(std.mem.find(u8, transport.output(2), "Extract into const 'value'") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "const value = 20 + 22;") != null);
}

test "LSP organizes imports when the style lint is disabled" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///imports.zig","languageId":"zig","version":1,"text":"// package\nconst package = @import(\"package\");\n// standard\nconst std = @import(\"std\");\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///imports.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":3,"character":27}},"context":{"diagnostics":[],"only":["source.organizeImports"]}}}
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
    try std.testing.expect(std.mem.find(u8, transport.output(2), "Organize imports") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "source.organizeImports") != null);
    const standard_comment = std.mem.find(u8, transport.output(2), "// standard").?;
    const package_comment = std.mem.find(u8, transport.output(2), "// package").?;
    try std.testing.expect(standard_comment < package_comment);
}

test "LSP code action offers rule-wide fix-all for deterministic rule" {
    var transport = TestTransport.init(&.{});
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();

    const uri = try checkoutUri(std.testing.allocator, "examples/fix_all_rule.zig");
    defer std.testing.allocator.free(uri);
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "pub fn run(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !void {\n" ++
        "    _ = try std.fmt.allocPrint(allocator, \"{s}\", .{a});\n" ++
        "    _ = try std.fmt.allocPrint(allocator, \"{s}\", .{b});\n" ++
        "}\n";

    try server.documents.open(uri, 1, source);
    const document = server.documents.getConst(uri).?;

    const first_call = std.mem.find(u8, source, "std.fmt.allocPrint(allocator, \"{s}\", .{a})").?;
    const action_range = document.range(.{ .start = first_call, .end = first_call + 10 });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = (try server.@"textDocument/codeAction"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .range = action_range,
        .context = .{ .diagnostics = &.{} },
    })).?;

    var found_rule_fix_all = false;
    for (result) |action_res| {
        const action = switch (action_res) {
            .code_action => |ca| ca,
            else => continue,
        };
        if (std.mem.eql(u8, action.title, "Fix all 'prefer-allocator-dupe' in this file")) {
            found_rule_fix_all = true;
            const edit = action.edit.?;
            const text_edits = edit.changes.?.map.get(uri).?;
            try std.testing.expectEqual(@as(usize, 2), text_edits.len);
        }
    }
    try std.testing.expect(found_rule_fix_all);
}
