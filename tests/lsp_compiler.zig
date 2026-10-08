//! Language-server exchanges that need the patched compiler. `zig build
//! backend-test` builds the backend first; without one these fail, they never
//! skip.
const std = @import("std");
const lsp = @import("lsp");
const zig_analyzer = @import("zig_analyzer");
const support = @import("lsp/support.zig");
const projects = @import("projects.zig");

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

test "compiler-generated member definitions return the generating type declaration" {
    // The example itself, opened in the editor: the build graph's examples test
    // unit contains it, so it gets compiler facts without being its own root.
    const uri = try checkoutUri(std.testing.allocator, "examples/compiler/comptime_pipeline.zig");
    defer std.testing.allocator.free(uri);
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "examples/compiler/comptime_pipeline.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .{ .compiler = .{ .debounce_ms = 0 } });
    defer server.deinit();
    try server.documents.open(uri, 1, source);
    const document = server.documents.getConst(uri).?;
    try server.backend.documentChanged(document, .edited);
    server.backend.waitIdle();
    try std.testing.expect(server.backend.isAnalyzed(uri, 1));
    const member_start = std.mem.findLast(u8, source, "trace();").?;
    const member_position = document.range(.{ .start = member_start, .end = member_start + "trace".len }).start;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = (try server.@"textDocument/definition"(arena_state.allocator(), .{
        .textDocument = .{ .uri = uri },
        .position = member_position,
    })).?;
    const definition = switch (response) {
        .definition => |value| value,
        .definition_links => return error.ExpectedDefinitionLocation,
    };
    const location = switch (definition) {
        .location => |value| value,
        .locations => return error.ExpectedSingleDefinition,
    };
    const declaration = document.declarationNamed("ActivePipeline").?;

    try std.testing.expectEqualStrings(uri, location.uri);
    try std.testing.expectEqualDeep(document.range(declaration.span), location.range);
}

test "source saves retain the compiler and refresh imported diagnostics" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source = "const dependency = @import(\"dependency.zig\");\nexport fn result() u32 { return dependency.value; }\n";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = source });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "pub const value: u32 = 1;\n" });
    const root_path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const uri = try uri_module.fromPath(std.testing.allocator, root_path);
    defer std.testing.allocator.free(uri);
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .{ .compiler = .{ .debounce_ms = 0 } });
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try server.documents.open(uri, 1, source);
    try server.backend.documentChanged(server.documents.getConst(uri).?, .edited);
    server.backend.waitIdle();
    try std.testing.expect(server.backend.isAnalyzed(uri, 1));
    const original_process_id = server.backend.compiler.?.process.child.id;
    var generation = (try server.backend.compiler.?.client.workspaceSummary()).last_generation;

    const changes = [_]struct { source: []const u8, error_count: u32 }{
        .{ .source = "pub const value = true;\n", .error_count = 1 },
        .{ .source = "pub const value: u32 = 42;\n", .error_count = 0 },
    };
    for (changes) |change| {
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = change.source });
        try server.@"textDocument/didSave"(arena_state.allocator(), .{ .textDocument = .{ .uri = uri } });
        server.backend.waitIdle();
        const compiler = &server.backend.compiler.?;
        const next_generation = (try compiler.client.workspaceSummary()).last_generation;
        try std.testing.expect(next_generation > generation);
        try std.testing.expectEqual(original_process_id, compiler.process.child.id);
        var diagnostics = try compiler.diagnostics(std.testing.allocator);
        defer diagnostics.deinit(std.testing.allocator);
        try std.testing.expectEqual(change.error_count, diagnostics.errorMessageCount());
        generation = next_generation;
    }

    const dependency_path = try temporary.dir.realPathFileAlloc(std.testing.io, "dependency.zig", std.testing.allocator);
    defer std.testing.allocator.free(dependency_path);
    const dependency_uri = try uri_module.fromPath(std.testing.allocator, dependency_path);
    defer std.testing.allocator.free(dependency_uri);
    const unsaved_dependency = "pub const value = true;\n";
    try server.documents.open(dependency_uri, 1, unsaved_dependency);
    try server.backend.documentChanged(server.documents.getConst(dependency_uri).?, .edited);
    server.backend.waitIdle();
    {
        var diagnostics = try server.backend.compiler.?.diagnostics(std.testing.allocator);
        defer diagnostics.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), diagnostics.errorMessageCount());
    }
    try server.@"textDocument/didClose"(arena_state.allocator(), .{ .textDocument = .{ .uri = dependency_uri } });
    server.backend.waitIdle();
    try std.testing.expect(server.backend.documents.getConst(dependency_uri) == null);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "pub const value: u32 = 77;\n" });
    try server.@"textDocument/didSave"(arena_state.allocator(), .{ .textDocument = .{ .uri = uri } });
    server.backend.waitIdle();
    {
        const compiler = &server.backend.compiler.?;
        try std.testing.expectEqual(original_process_id, compiler.process.child.id);
        var diagnostics = try compiler.diagnostics(std.testing.allocator);
        defer diagnostics.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 0), diagnostics.errorMessageCount());
    }

    const other_source = "export fn independent() u32 { return 7; }\n";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "other.zig", .data = other_source });
    const other_path = try temporary.dir.realPathFileAlloc(std.testing.io, "other.zig", std.testing.allocator);
    defer std.testing.allocator.free(other_path);
    const other_uri = try uri_module.fromPath(std.testing.allocator, other_path);
    defer std.testing.allocator.free(other_uri);
    try server.documents.open(other_uri, 1, other_source);
    try server.@"textDocument/didSave"(arena_state.allocator(), .{ .textDocument = .{ .uri = other_uri } });
    server.backend.waitIdle();
    try std.testing.expect(server.backend.isAnalyzed(other_uri, 1));
    try std.testing.expect(original_process_id != server.backend.compiler.?.process.child.id);
}

test "edits to two documents within the debounce both receive compiler diagnostics" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const main_good = "const other = @import(\"other.zig\");\nexport fn first() u32 { return other.second(); }\n";
    const other_good = "pub fn second() u32 { return 2; }\n";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = main_good });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "other.zig", .data = other_good });
    const main_path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(main_path);
    const other_path = try temporary.dir.realPathFileAlloc(std.testing.io, "other.zig", std.testing.allocator);
    defer std.testing.allocator.free(other_path);
    const main_uri = try uri_module.fromPath(std.testing.allocator, main_path);
    defer std.testing.allocator.free(main_uri);
    const other_uri = try uri_module.fromPath(std.testing.allocator, other_path);
    defer std.testing.allocator.free(other_uri);
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .{ .compiler = .{ .debounce_ms = 60 } });
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try openDocument(&server, arena, main_uri, 1, main_good);
    try openDocument(&server, arena, other_uri, 1, other_good);
    server.backend.waitIdle();
    try std.testing.expect(server.backend.isAnalyzed(main_uri, 1));

    // Both documents change inside one debounce window; each must be compiled.
    try replaceDocument(&server, arena, main_uri, 2, "const other = @import(\"other.zig\");\nexport fn first() u32 { return other.second(); }\nexport fn third() u32 { return \"text\"; }\n");
    try replaceDocument(&server, arena, other_uri, 2, "pub fn second() u32 { return \"text\"; }\n");
    server.backend.waitIdle();

    const main_published = lastPublished(&transport, main_uri) orelse return error.NothingPublished;
    const other_published = lastPublished(&transport, other_uri) orelse return error.NothingPublished;
    try std.testing.expect(std.mem.find(u8, main_published, "compiler-error") != null);
    try std.testing.expect(std.mem.find(u8, other_published, "compiler-error") != null);

    // A lint-only republish of the same version keeps the compiler errors.
    try server.publishDiagnostics(arena, main_uri);
    try std.testing.expect(std.mem.find(u8, lastPublished(&transport, main_uri).?, "compiler-error") != null);

    // A newer version retires them until the compiler catches up.
    server.backend.session_mutex.lockUncancelable(std.testing.io);
    try replaceDocument(&server, arena, main_uri, 3, "const other = @import(\"other.zig\");\nexport fn first() u32 { return other.second(); }\nexport fn third() u32 { return true; }\n");
    try std.testing.expect(std.mem.find(u8, lastPublished(&transport, main_uri).?, "compiler-error") == null);
    server.backend.session_mutex.unlock(std.testing.io);
    server.backend.waitIdle();
    try std.testing.expect(std.mem.find(u8, lastPublished(&transport, main_uri).?, "compiler-error") != null);
}

test "a fresh compiler replays every open buffer with a single recompile" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const main_source = "const left = @import(\"left.zig\");\nconst right = @import(\"right.zig\");\nexport fn total() u32 { return left.value + right.value; }\n";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = main_source });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "left.zig", .data = "pub const value: u32 = 1;\n" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "right.zig", .data = "pub const value: u32 = 2;\n" });
    var uris: [3][]u8 = undefined;
    const names = [_][]const u8{ "main.zig", "left.zig", "right.zig" };
    for (names, &uris) |name, *uri| {
        const path = try temporary.dir.realPathFileAlloc(std.testing.io, name, std.testing.allocator);
        defer std.testing.allocator.free(path);
        uri.* = try uri_module.fromPath(std.testing.allocator, path);
    }
    defer for (uris) |uri| std.testing.allocator.free(uri);
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .{ .compiler = .{ .debounce_ms = 100 } });
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The root and unsaved edits to both dependencies inside one debounce.
    try openDocument(&server, arena, uris[0], 1, main_source);
    try openDocument(&server, arena, uris[1], 1, "pub const value: u32 = 10;\n");
    try openDocument(&server, arena, uris[2], 1, "pub const value: u32 = 20;\n");
    server.backend.waitIdle();
    for (uris) |uri| try std.testing.expect(server.backend.isAnalyzed(uri, 1));
    try std.testing.expectEqual(@as(u32, 1), server.backend.compiler.?.epoch);

    // A build change restarts the compiler; only the root is queued, yet the
    // dependencies' buffers return with the same single recompile.
    try server.backend.documentChanged(server.documents.getConst(uris[0]).?, .build_changed);
    server.backend.waitIdle();
    for (uris) |uri| try std.testing.expect(server.backend.isAnalyzed(uri, 1));
    try std.testing.expectEqual(@as(u32, 1), server.backend.compiler.?.epoch);
}

// ---- rename ------------------------------------------------------------------

const rename_source =
    \\const Point = struct {
    \\    x: i32,
    \\    pub fn make() Point {
    \\        return .{ .x = 1 };
    \\    }
    \\    pub fn norm(self: *const Point) i32 {
    \\        return self.x;
    \\    }
    \\};
    \\const Other = struct { x: i32 };
    \\const Alias = Point;
    \\fn sum(a: Alias, b: Other, c: *const Alias) i32 {
    \\    const made = Alias.make();
    \\    return a.x + b.x + c.x + made.x + @field(a, "x") + a.norm();
    \\}
    \\export fn run() i32 {
    \\    return sum(Point.make(), .{ .x = 2 }, &Alias.make());
    \\}
    \\
;

/// Renames the identifier at `needle` + `skip` of the open document `uri`.
fn renameAt(
    server: *Server,
    arena: std.mem.Allocator,
    uri: []const u8,
    source: []const u8,
    needle: []const u8,
    skip: usize,
    new_name: []const u8,
) !?lsp.types.WorkspaceEdit {
    const document = server.documents.getConst(uri).?;
    const offset = (std.mem.find(u8, source, needle) orelse return error.MissingNeedle) + skip;
    return server.@"textDocument/rename"(arena, .{
        .textDocument = .{ .uri = uri },
        .position = document.range(.{ .start = offset, .end = offset + 1 }).start,
        .newName = new_name,
    });
}

fn editCount(edit: lsp.types.WorkspaceEdit, uri: []const u8) usize {
    const edits = edit.changes.?.map.get(uri) orelse return 0;
    return edits.len;
}

/// The first server message containing `needle`, or null.
fn messageContaining(transport: *const TestTransport, needle: []const u8) ?[]const u8 {
    for (0..transport.output_count) |index| {
        if (std.mem.find(u8, transport.output(index), needle) != null) return transport.output(index);
    }
    return null;
}

test "rename follows compiler identity through aliases, pointers, methods and reflection" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = rename_source });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const uri = try uri_module.fromPath(std.testing.allocator, path);
    defer std.testing.allocator.free(uri);
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .{ .compiler = .{ .debounce_ms = 0 } });
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try openDocument(&server, arena, uri, 1, rename_source);
    server.backend.waitIdle();
    try std.testing.expect(server.backend.isAnalyzed(uri, 1));

    // The field, asked for at a use through an alias: the declaration, `self.x`,
    // `a.x`, `c.x`, `made.x`, the reflection string and the returned
    // `.{ .x = 1 }` are Point.x. `b.x` and
    // Other.x are another declaration spelled the same, which syntax scoping
    // cannot tell apart; the `.{ .x = 2 }` passed as an argument has no
    // type the syntax can name and is reported rather than guessed.
    const edit = (try renameAt(&server, arena, uri, rename_source, "a.x +", 2, "px")).?;
    try std.testing.expectEqual(@as(usize, 7), editCount(edit, uri));
    const edits = edit.changes.?.map.get(uri).?;
    for (edits) |text_edit| {
        const start = server.documents.getConst(uri).?.byteOffset(text_edit.range.start);
        try std.testing.expect(!std.mem.startsWith(u8, rename_source[start - 2 ..], "b."));
        try std.testing.expectEqualStrings("px", text_edit.newText);
    }
    try std.testing.expect(messageContaining(&transport, "compiler identity") != null);
    try std.testing.expect(messageContaining(&transport, "left unchanged") != null);

    // A method called through an alias and declared in the struct.
    const method = (try renameAt(&server, arena, uri, rename_source, "a.norm", 2, "length")).?;
    try std.testing.expectEqual(@as(usize, 2), editCount(method, uri));

    // The other declaration spelled `x` is renamed alone.
    const other = (try renameAt(&server, arena, uri, rename_source, "b.x", 2, "ox")).?;
    try std.testing.expectEqual(@as(usize, 2), editCount(other, uri));

    // A taken name is refused.
    try std.testing.expectError(error.RequestFailed, renameAt(&server, arena, uri, rename_source, "a.x +", 2, "norm"));
    try std.testing.expect(messageContaining(&transport, "already declared") != null);
}

test "rename falls back to syntax scoping without a compiler and says so" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = rename_source });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const uri = try uri_module.fromPath(std.testing.allocator, path);
    defer std.testing.allocator.free(uri);
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .syntax_only);
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try openDocument(&server, arena, uri, 1, rename_source);

    // Syntax scoping renames the declaration and its lexical uses.
    const edit = (try renameAt(&server, arena, uri, rename_source, "Other =", 0, "Another")).?;
    try std.testing.expectEqual(@as(usize, 2), editCount(edit, uri));
    try std.testing.expect(messageContaining(&transport, "syntax scoping") != null);
    try std.testing.expect(messageContaining(&transport, "compiler identity") == null);
}

test "rename is refused when the declaration differs between compile units" {
    var project = try projects.copy(std.testing.allocator, "units_differ");
    defer project.deinit(std.testing.allocator);
    const path = try project.path(std.testing.allocator, "src/main.zig");
    defer std.testing.allocator.free(path);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(source);
    const uri = try uri_module.fromPath(std.testing.allocator, path);
    defer std.testing.allocator.free(uri);
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .{ .compiler = .{ .debounce_ms = 0 } });
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try openDocument(&server, arena, uri, 1, source);
    server.backend.waitIdle();
    try std.testing.expect(server.backend.isAnalyzed(uri, 1));

    // `Backend.start` is Threaded.start in one unit and Single.start in the
    // other, so `start` means different things depending on the build.
    try std.testing.expectError(error.RequestFailed, renameAt(&server, arena, uri, source, "Backend.start", "Backend.".len, "begin"));
    const refusal = messageContaining(&transport, "differs between compile units") orelse return error.NoRefusal;
    try std.testing.expect(std.mem.find(u8, refusal, "threaded") != null);
    try std.testing.expect(std.mem.find(u8, refusal, "single") != null);

    // The alias itself is the same declaration in both units: renamed, in the
    // declaration and its use, after comparing both.
    const edit = (try renameAt(&server, arena, uri, source, "const Backend", "const ".len, "Chosen")).?;
    try std.testing.expectEqual(@as(usize, 2), editCount(edit, uri));
    const report = messageContaining(&transport, "units: ") orelse return error.NoReport;
    try std.testing.expect(std.mem.find(u8, report, "threaded") != null);
    try std.testing.expect(std.mem.find(u8, report, "single") != null);
}

// ---- unavailable modules ----------------------------------------------------

test "an import of a module the analyzer never builds is information, other errors still show" {
    var project = try projects.copy(std.testing.allocator, "run_generated");
    defer project.deinit(std.testing.allocator);
    const path = try project.path(std.testing.allocator, "src/main.zig");
    defer std.testing.allocator.free(path);
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(source);
    const uri = try uri_module.fromPath(std.testing.allocator, path);
    defer std.testing.allocator.free(uri);
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    defer transport.deinit();
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport, .{ .compiler = .{ .debounce_ms = 0 } });
    defer server.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try openDocument(&server, arena, uri, 1, source);
    server.backend.waitIdle();
    try std.testing.expect(server.backend.isAnalyzed(uri, 1));
    const published = lastPublished(&transport, uri) orelse return error.NothingPublished;
    try std.testing.expect(std.mem.find(u8, published, "compiler-error") == null);
    try std.testing.expect(std.mem.find(u8, published, "module-unavailable") != null);
    try std.testing.expect(std.mem.find(u8, published, "run exe generator") != null);
    // The project is told once, as information, not as a warning.
    const notice = messageContaining(&transport, "window/showMessage") orelse return error.NoNotice;
    try std.testing.expect(std.mem.find(u8, notice, "\"type\":3") != null);
    try std.testing.expect(std.mem.find(u8, notice, "run exe generator") != null);

    // A real mistake next to the unavailable import is still an error.
    const broken = try std.mem.concat(arena, u8, &.{ source, "export fn broken() u32 { return true; }\n" });
    try replaceDocument(&server, arena, uri, 2, broken);
    server.backend.waitIdle();
    const after = lastPublished(&transport, uri) orelse return error.NothingPublished;
    try std.testing.expect(std.mem.find(u8, after, "compiler-error") != null);
    try std.testing.expect(std.mem.find(u8, after, "module-unavailable") != null);
}
