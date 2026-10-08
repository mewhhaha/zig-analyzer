const std = @import("std");
const zig_analyzer = @import("zig_analyzer");
const projects = @import("projects.zig");

const compile_units = zig_analyzer.compiler.compile_units;
const Session = zig_analyzer.compiler.session.Session;

test "compiler session tracks unsaved overlay syntax without changing the file" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "fixtures/comptime/main.zig",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(fixture_path);
    const saved_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        fixture_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(saved_source);

    var session = try startSession(fixture_path);
    defer session.deinit();

    const compiler_declarations = try session.declarations();
    var found_generated_method = false;
    for (compiler_declarations) |name| {
        if (std.mem.endsWith(u8, name, ".diagonal")) found_generated_method = true;
    }
    try std.testing.expect(found_generated_method);

    try std.testing.expectError(
        error.SemanticsUnavailable,
        session.replaceOverlay("file:///workspace/outside-compile-unit.zig", 1, "const value = 1;\n"),
    );
    const uri = try zig_analyzer.uri.fromPath(std.testing.allocator, fixture_path);
    defer std.testing.allocator.free(uri);
    try std.testing.expectError(error.SemanticsUnavailable, session.client.analyzeOverlay(uri, 1));
    const first_source = "const first = 1;\nconst second = 2;\n";
    const first = try session.replaceOverlay(uri, 1, first_source);
    try std.testing.expectEqual(@as(i32, 1), first.document_version);
    try std.testing.expectEqual(@as(u32, 2), first.declaration_count);
    try std.testing.expectEqual(@as(u32, 0), first.syntax_error_count);

    try std.testing.expectError(error.StaleGeneration, session.client.analyzeOverlay(uri, 0));

    const malformed_source = "const broken =";
    const malformed = try session.replaceOverlay(uri, 2, malformed_source);
    try std.testing.expectEqual(@as(i32, 2), malformed.document_version);
    try std.testing.expect(malformed.syntax_error_count > 0);
    try std.testing.expect(first.source_hash != malformed.source_hash);

    const source_after_analysis = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        fixture_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source_after_analysis);
    try std.testing.expectEqualStrings(saved_source, source_after_analysis);
}

test "compiler session accepts a multi-kilobyte unsaved overlay" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "fixtures/comptime/main.zig",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(fixture_path);
    const uri = try zig_analyzer.uri.fromPath(std.testing.allocator, fixture_path);
    defer std.testing.allocator.free(uri);

    var session = try startSession(fixture_path);
    defer session.deinit();

    const source = "const value = 1;\n// " ++ @as([2048]u8, @splat('x')) ++ "\n";
    const facts = try session.replaceOverlay(uri, 1, source);
    try std.testing.expectEqual(@as(i32, 1), facts.document_version);
    try std.testing.expectEqual(@as(u32, 1), facts.declaration_count);
    try std.testing.expectEqual(@as(u32, 0), facts.syntax_error_count);
}

test "compiler diagnostics use the unsaved root overlay" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "examples/diagnostics/compiler_error.zig",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(fixture_path);
    const saved_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        fixture_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(saved_source);
    const uri = try zig_analyzer.uri.fromPath(std.testing.allocator, fixture_path);
    defer std.testing.allocator.free(uri);

    var session = try startSession(fixture_path);
    defer session.deinit();

    const generation_before = (try session.client.workspaceSummary()).last_generation;
    const changed_source = "pub const OverlayOnly = enum { ready }; export fn invalidResult() u32 { return true; }\n";
    _ = try session.replaceOverlay(uri, 1, changed_source);
    const generation_after = (try session.client.workspaceSummary()).last_generation;
    try std.testing.expect(generation_after > generation_before);
    var changed_diagnostics = try session.diagnostics(std.testing.allocator);
    defer changed_diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), changed_diagnostics.errorMessageCount());
    const changed_message = changed_diagnostics.getErrorMessage(changed_diagnostics.getMessages()[0]);
    try std.testing.expect(std.mem.find(
        u8,
        changed_diagnostics.nullTerminatedString(changed_message.msg),
        "found 'bool'",
    ) != null);

    const source_after_analysis = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        fixture_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source_after_analysis);
    try std.testing.expectEqualStrings(saved_source, source_after_analysis);
}

test "incremental diagnostics recover across repeated root overlay edits" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const saved_source = "export fn result() u32 { return true; }\n";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = saved_source });
    const root_path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const uri = try zig_analyzer.uri.fromPath(std.testing.allocator, root_path);
    defer std.testing.allocator.free(uri);
    var session = try startSession(root_path);
    defer session.deinit();

    try expectCompilerDiagnostic(&session, "found 'bool'");
    const edits = [_]struct { source: []const u8, diagnostic: ?[]const u8 }{
        .{ .source = "export fn result() u32 { return 42; }\n", .diagnostic = null },
        .{ .source = "export fn result() u32 { return true; }\n", .diagnostic = "found 'bool'" },
        .{ .source = "export fn result() u32 { return -1; }\n", .diagnostic = "cannot represent integer value '-1'" },
        .{ .source = "export fn result() u32 { return 99; }\n", .diagnostic = null },
    };
    var generation = (try session.client.workspaceSummary()).last_generation;
    for (edits, 1..) |edit, version| {
        _ = try session.replaceOverlay(uri, @intCast(version), edit.source);
        const next_generation = (try session.client.workspaceSummary()).last_generation;
        try std.testing.expect(next_generation > generation);
        generation = next_generation;
        try expectCompilerDiagnostic(&session, edit.diagnostic);
    }
    try session.removeOverlay(uri);
    try expectCompilerDiagnostic(&session, "found 'bool'");
    const disk_source = try temporary.dir.readFileAlloc(std.testing.io, "main.zig", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(disk_source);
    try std.testing.expectEqualStrings(saved_source, disk_source);
}

test "incremental diagnostics refresh disk imports behind an unchanged root overlay" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_source = "const dependency = @import(\"dependency.zig\");\nexport fn result() u32 { return dependency.value; }\n";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = root_source });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "pub const value: u32 = 1;\n" });
    const root_path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const uri = try zig_analyzer.uri.fromPath(std.testing.allocator, root_path);
    defer std.testing.allocator.free(uri);
    var session = try startSession(root_path);
    defer session.deinit();
    _ = try session.replaceOverlay(uri, 1, root_source);
    try expectCompilerDiagnostic(&session, null);

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "pub const value = true;\n" });
    _ = try session.replaceOverlay(uri, 2, root_source);
    try expectCompilerDiagnostic(&session, "found 'bool'");

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "dependency.zig", .data = "pub const value: u32 = 42;\n" });
    _ = try session.replaceOverlay(uri, 3, root_source);
    try expectCompilerDiagnostic(&session, null);
}

fn expectCompilerDiagnostic(session: *zig_analyzer.compiler.session.Session, expected_message: ?[]const u8) !void {
    var diagnostics = try session.diagnostics(std.testing.allocator);
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, if (expected_message != null) 1 else 0), diagnostics.errorMessageCount());
    if (expected_message) |expected| {
        const message = diagnostics.getErrorMessage(diagnostics.getMessages()[0]);
        try std.testing.expect(std.mem.find(u8, diagnostics.nullTerminatedString(message.msg), expected) != null);
    }
}

test "compiler session returns structured semantic errors" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "examples/diagnostics/compiler_error.zig",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(fixture_path);
    var session = try startSession(fixture_path);
    defer session.deinit();

    const uri = try zig_analyzer.uri.fromPath(std.testing.allocator, fixture_path);
    defer std.testing.allocator.free(uri);
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        fixture_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    _ = try session.replaceOverlay(uri, 1, source);
    var diagnostics = try session.diagnostics(std.testing.allocator);
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.errorMessageCount());

    const message = diagnostics.getErrorMessage(diagnostics.getMessages()[0]);
    try std.testing.expect(std.mem.find(
        u8,
        diagnostics.nullTerminatedString(message.msg),
        "expected type 'u32'",
    ) != null);
    const source_location = diagnostics.getSourceLocation(message.src_loc);
    try std.testing.expect(std.mem.endsWith(
        u8,
        diagnostics.nullTerminatedString(source_location.src_path),
        "examples/diagnostics/compiler_error.zig",
    ));

    var document = try zig_analyzer.syntax.document.Document.open(std.testing.allocator, uri, 1, source);
    defer document.deinit();
    const lsp_diagnostics = try zig_analyzer.lsp.diagnostics.compilerDiagnostics(
        &document,
        diagnostics,
        std.testing.allocator,
        &.{},
    );
    defer {
        for (lsp_diagnostics) |diagnostic| {
            std.testing.allocator.free(diagnostic.message.string);
            if (diagnostic.relatedInformation) |related| {
                for (related) |information| {
                    std.testing.allocator.free(information.location.uri);
                    std.testing.allocator.free(information.message);
                }
                std.testing.allocator.free(related);
            }
        }
        std.testing.allocator.free(lsp_diagnostics);
    }
    try std.testing.expectEqual(@as(usize, 1), lsp_diagnostics.len);
    try std.testing.expectEqualStrings("zig compiler", lsp_diagnostics[0].source.?);
    try std.testing.expect(lsp_diagnostics[0].relatedInformation.?.len > 0);
}

test "compiler session returns only resolved comptime type members" {
    var session = try startSession("examples/compiler/conditional_api.zig");
    defer session.deinit();

    const declarations = try session.declarations();
    const active_api = for (declarations) |name| {
        if (std.mem.endsWith(u8, name, ".ActiveApi")) break name;
    } else return error.ActiveApiNotAnalyzed;
    const members = (try session.typeMembers(std.testing.allocator, active_api)).?;
    defer {
        for (members) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(members);
    }
    var found_active = false;
    var found_inactive = false;
    for (members) |name| {
        if (std.mem.eql(u8, name, "recordMetric")) found_active = true;
        if (std.mem.eql(u8, name, "disabled")) found_inactive = true;
    }
    try std.testing.expect(found_active);
    try std.testing.expect(!found_inactive);
}

test "compiler session resolves inline-for generated type members" {
    const fixture_path = "examples/compiler/comptime_pipeline.zig";
    var session = try startSession(fixture_path);
    defer session.deinit();

    const declarations = try session.declarations();
    const active_pipeline = for (declarations) |name| {
        if (std.mem.endsWith(u8, name, ".ActivePipeline")) break name;
    } else return error.ActivePipelineNotAnalyzed;
    const members = (try session.typeMembers(std.testing.allocator, active_pipeline)).?;
    defer {
        for (members) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(members);
    }
    var found_trace = false;
    for (members) |name| {
        if (std.mem.eql(u8, name, "trace")) found_trace = true;
    }
    try std.testing.expect(found_trace);
}

test "compiler protocol returns ordinary and comptime-generated type shapes" {
    var session = try startSession("fixtures/comptime/main.zig");
    defer session.deinit();

    const declarations = try session.declarations();
    const expected_shapes = [_]struct {
        suffix: []const u8,
        kind: zig_analyzer.compiler.protocol.TypeShapeKind,
        fields: []const []const u8,
    }{
        .{ .suffix = ".Color", .kind = .enumeration, .fields = &.{ "red", "green", "blue" } },
        .{ .suffix = ".Message", .kind = .tagged_union, .fields = &.{ "text", "number" } },
        .{ .suffix = ".Point", .kind = .structure, .fields = &.{ "x", "y" } },
        .{ .suffix = ".GeneratedEnum", .kind = .enumeration, .fields = &.{ "pending", "complete" } },
        .{ .suffix = ".GeneratedEnumAlias", .kind = .enumeration, .fields = &.{ "pending", "complete" } },
        .{ .suffix = ".GeneratedUnion", .kind = .tagged_union, .fields = &.{ "success", "failure" } },
        .{ .suffix = ".GeneratedStruct", .kind = .structure, .fields = &.{ "name", "count" } },
    };
    const ordinary_enum_name = declarationWithSuffix(declarations, ".Color") orelse return error.TypeNotAnalyzed;
    session.client.generation -%= 1;
    try std.testing.expectError(
        error.StaleGeneration,
        session.client.typeShape(std.testing.allocator, ordinary_enum_name),
    );
    for (expected_shapes) |expected| {
        const qualified_name = declarationWithSuffix(declarations, expected.suffix) orelse return error.TypeNotAnalyzed;
        var shape = try session.client.typeShape(std.testing.allocator, qualified_name);
        defer shape.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected.kind, shape.kind);
        try std.testing.expectEqual(expected.fields.len, shape.fields.len);
        for (expected.fields, shape.fields) |expected_field, actual_field| {
            try std.testing.expectEqualStrings(expected_field, actual_field);
        }
    }

    const unsupported_shapes = [_][]const u8{ ".Untagged", ".Failure" };
    for (unsupported_shapes) |suffix| {
        const qualified_name = declarationWithSuffix(declarations, suffix) orelse return error.UnsupportedTypeNotAnalyzed;
        try std.testing.expectError(
            error.SemanticsUnavailable,
            session.client.typeShape(std.testing.allocator, qualified_name),
        );
    }
}

test "compiler session resolves shapes by qualified name or bare name" {
    var session = try startSession("fixtures/comptime/main.zig");
    defer session.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const qualified = (try session.qualifiedName("Color")).?;
    try std.testing.expect(std.mem.endsWith(u8, qualified, ".Color"));
    const bare = (try session.resolveShape(arena, "Color")).?;
    try std.testing.expectEqualStrings("Color", bare.type_name);
    try std.testing.expectEqual(zig_analyzer.analysis.ResolvedShape.Kind.enumeration, bare.kind);
    try std.testing.expectEqual(@as(usize, 3), bare.fields.len);
    const exact = (try session.resolveShape(arena, qualified)).?;
    try std.testing.expectEqual(bare.kind, exact.kind);

    const generated = (try session.resolveShape(arena, "GeneratedUnion")).?;
    try std.testing.expectEqual(zig_analyzer.analysis.ResolvedShape.Kind.tagged_union, generated.kind);

    try std.testing.expect(try session.resolveShape(arena, "Untagged") == null);
    try std.testing.expect(try session.resolveShape(arena, "NoSuchType") == null);
    try std.testing.expect(try session.resolveValue(arena, "NoSuchValue") == null);
}

test "compiler session drops cached declarations when an overlay recompiles" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "pub const First = struct { a: u8 };\n" });
    const root_path = try temporary.dir.realPathFileAlloc(std.testing.io, "main.zig", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const uri = try zig_analyzer.uri.fromPath(std.testing.allocator, root_path);
    defer std.testing.allocator.free(uri);
    var session = try startSession(root_path);
    defer session.deinit();

    try std.testing.expect(try session.qualifiedName("Second") == null);
    const epoch = session.epoch;
    _ = try session.replaceOverlay(uri, 1, "pub const First = struct { a: u8 };\npub const Second = struct { b: u8 };\n");
    try std.testing.expect(session.epoch != epoch);
    try std.testing.expect(try session.qualifiedName("Second") != null);
}

test "backend rejects a mismatched protocol, Zig version, and authentication token" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const protocol = zig_analyzer.compiler.protocol;
    const Client = zig_analyzer.compiler.client.Client;
    var backend = (try zig_analyzer.compiler.bootstrap.findBackend(io, allocator)) orelse return error.CompilerBackendNotFound;
    defer backend.deinit(allocator);
    const cache_root = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cache_root);

    var process = try zig_analyzer.compiler.process.Process.start(io, allocator, .empty, .{
        .backend_binary = backend.binary_path,
        .launch = .{ .command = "build-obj", .arguments = &.{"fixtures/comptime/main.zig"} },
        .cache_root = cache_root,
        .zig_lib_directory = try zig_analyzer.compiler.zig_environment.libDirectory(io),
    });
    errdefer process.stop();
    const port = try process.awaitPort(zig_analyzer.compiler.process.default_deadline_ms);

    {
        var client = try Client.connect(io, allocator, port);
        defer client.deinit();
        try std.testing.expectError(
            error.IncompatibleProtocol,
            client.probeHandshake(zig_analyzer.build_options.zig_version, protocol.version + 1, &process.authentication_token),
        );
    }
    {
        var client = try Client.connect(io, allocator, port);
        defer client.deinit();
        try std.testing.expectError(
            error.IncompatibleZig,
            client.probeHandshake("0.15.2", protocol.version, &process.authentication_token),
        );
    }
    {
        var client = try Client.connect(io, allocator, port);
        defer client.deinit();
        var wrong_token = process.authentication_token;
        wrong_token[0] = if (wrong_token[0] == '0') '1' else '0';
        try std.testing.expectError(error.AuthenticationFailed, client.handshake(&wrong_token));
    }

    // The same backend still serves a client that presents the right hello.
    var session = try zig_analyzer.compiler.session.Session.attach(allocator, process);
    defer session.deinit();
    const declarations = try session.declarations();
    try std.testing.expect(declarations.len > 0);
}

test "overlays are matched to files whose paths need percent-encoding" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "my project");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "my project/100% café.zig", .data = "export fn result() u32 { return true; }\n" });
    const root_path = try temporary.dir.realPathFileAlloc(std.testing.io, "my project/100% café.zig", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const uri = try zig_analyzer.uri.fromPath(std.testing.allocator, root_path);
    defer std.testing.allocator.free(uri);
    try std.testing.expect(std.mem.find(u8, uri, "my%20project/100%25%20caf%C3%A9.zig") != null);
    var session = try startSession(root_path);
    defer session.deinit();

    const facts = try session.replaceOverlay(uri, 1, "export fn result() u32 { return 1; }\n");
    try std.testing.expectEqual(@as(u32, 1), facts.declaration_count);
    try expectCompilerDiagnostic(&session, null);
    try session.removeOverlay(uri);
    try expectCompilerDiagnostic(&session, "found 'bool'");
}

test "concurrent backends bind distinct ports chosen by the operating system" {
    var first = try startSession("fixtures/comptime/main.zig");
    defer first.deinit();
    var second = try startSession("fixtures/comptime/main.zig");
    defer second.deinit();
    try std.testing.expect(first.process.port != 0);
    try std.testing.expect(second.process.port != 0);
    try std.testing.expect(first.process.port != second.process.port);
}

test "compiler protocol returns resolved comptime values" {
    var session = try startSession("fixtures/comptime/main.zig");
    defer session.deinit();

    const declarations = try session.declarations();
    const qualified_name = declarationWithSuffix(declarations, ".computed_answer") orelse
        return error.ValueNotAnalyzed;
    var resolved = (try session.resolveValue(std.testing.allocator, qualified_name)).?;
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("u8", resolved.type_name);
    try std.testing.expectEqualStrings("42", resolved.value);
}

test "build_options and write-file modules resolve in compiler analysis" {
    var project = try projects.copy(std.testing.allocator, "generated");
    defer project.deinit(std.testing.allocator);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const main_path = try project.path(arena, "src/main.zig");
    var session = try startForDocument(arena, main_path);
    defer session.deinit();
    try analyzeDocument(&session, arena, main_path);
    try expectNoErrors(&session);
    const answer = declarationWithSuffix(try session.declarations(), ".answer") orelse return error.ValueNotAnalyzed;
    var resolved = (try session.resolveValue(std.testing.allocator, answer)).?;
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("u32", resolved.type_name);
    try std.testing.expectEqualStrings("42", resolved.value);
}

test "dependency modules resolve in compiler analysis" {
    var project = try projects.copy(std.testing.allocator, "dependency");
    defer project.deinit(std.testing.allocator);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const main_path = try project.path(arena, "src/main.zig");
    var session = try startForDocument(arena, main_path);
    defer session.deinit();
    try analyzeDocument(&session, arena, main_path);
    try expectNoErrors(&session);
    const length = declarationWithSuffix(try session.declarations(), ".greeting_length") orelse return error.ValueNotAnalyzed;
    var resolved = (try session.resolveValue(std.testing.allocator, length)).?;
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("5", resolved.value);
}

test "a module that needs a built program is missing from analysis and the program does not run" {
    var project = try projects.copy(std.testing.allocator, "run_generated");
    defer project.deinit(std.testing.allocator);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const main_path = try project.path(arena, "src/main.zig");
    var session = try startForDocument(arena, main_path);
    defer session.deinit();
    try analyzeDocument(&session, arena, main_path);
    var diagnostics = try session.diagnostics(std.testing.allocator);
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expect(diagnostics.errorMessageCount() >= 1);
    const message = diagnostics.getErrorMessage(diagnostics.getMessages()[0]);
    try std.testing.expect(std.mem.find(u8, diagnostics.nullTerminatedString(message.msg), "no module named 'generated'") != null);
    try std.testing.expect(!try project.exists("marker.txt"));
}

test "this checkout's executable analyzes with build_options and lsp resolved" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const main_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, "src/main.zig", arena);

    var session = try startForDocument(arena, main_path);
    defer session.deinit();
    try analyzeDocument(&session, arena, main_path);
    var diagnostics = try session.diagnostics(std.testing.allocator);
    defer diagnostics.deinit(std.testing.allocator);
    for (diagnostics.getMessages()) |message_index| {
        const message = diagnostics.nullTerminatedString(diagnostics.getErrorMessage(message_index).msg);
        try std.testing.expect(std.mem.find(u8, message, "no module named 'build_options'") == null);
        try std.testing.expect(std.mem.find(u8, message, "no module named 'lsp'") == null);
    }
    try std.testing.expect(declarationWithSuffix(try session.declarations(), ".version_string") != null);
}

/// Starts a backend on the compile unit that analyzes `document_path`,
/// chosen through the project's build graph.
fn startForDocument(arena: std.mem.Allocator, document_path: []const u8) !Session {
    const selected = try compile_units.select(std.testing.io, arena, document_path, .discover);
    try std.testing.expect(selected.unit != null);
    const cache_root = try std.process.currentPathAlloc(std.testing.io, arena);
    return Session.start(std.testing.io, std.testing.allocator, .empty, selected.launch, cache_root);
}

/// Sends the saved text of `path` as an overlay, which makes the compiler
/// report on it.
fn analyzeDocument(session: *Session, arena: std.mem.Allocator, path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(1024 * 1024));
    const uri = try zig_analyzer.uri.fromPath(arena, path);
    _ = try session.replaceOverlay(uri, 1, source);
}

fn expectNoErrors(session: *Session) !void {
    var diagnostics = try session.diagnostics(std.testing.allocator);
    defer diagnostics.deinit(std.testing.allocator);
    if (diagnostics.errorMessageCount() == 0) return;
    for (diagnostics.getMessages()) |message_index| {
        std.debug.print("unexpected compiler error: {s}\n", .{diagnostics.nullTerminatedString(diagnostics.getErrorMessage(message_index).msg)});
    }
    return error.UnexpectedCompilerErrors;
}

/// Starts a backend on `root_path` with its caches under this checkout.
fn startSession(root_path: []const u8) !zig_analyzer.compiler.session.Session {
    const cache_root = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cache_root);
    return zig_analyzer.compiler.session.Session.start(
        std.testing.io,
        std.testing.allocator,
        .empty,
        .{ .command = "build-obj", .arguments = &.{root_path} },
        cache_root,
    );
}

fn declarationWithSuffix(declarations: []const []const u8, suffix: []const u8) ?[]const u8 {
    for (declarations) |declaration| {
        if (std.mem.endsWith(u8, declaration, suffix)) return declaration;
    }
    return null;
}

const symbol_query = zig_analyzer.syntax.symbol_query;
const Document = zig_analyzer.syntax.document.Document;

const identity_source =
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

/// Starts a backend on a lone file holding `source` and returns the symbols
/// the compiler resolves for every container-member occurrence of `name`.
fn resolveMemberSites(
    arena: std.mem.Allocator,
    source: []const u8,
    name: []const u8,
    sites_out: *[]const symbol_query.Site,
) ![]const zig_analyzer.compiler.session.Symbol {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = source });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "main.zig", arena);
    const uri = try zig_analyzer.uri.fromPath(arena, path);
    var session = try startSession(path);
    defer session.deinit();
    _ = try session.replaceOverlay(uri, 1, source);

    var document = try Document.open(arena, uri, 1, source);
    defer document.deinit();
    const sites = try symbol_query.memberSites(arena, &document, name);
    var queries: std.ArrayList(symbol_query.Query) = .empty;
    var queryable: std.ArrayList(symbol_query.Site) = .empty;
    for (sites) |site| {
        const query = site.role.member orelse continue;
        try queries.append(arena, query);
        try queryable.append(arena, site);
    }
    sites_out.* = queryable.items;
    return session.resolveSymbols(arena, uri, queries.items);
}

test "resolve_symbol follows aliases, pointers, calls and reflection to one declaration" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sites: []const symbol_query.Site = &.{};
    const symbols = try resolveMemberSites(arena, identity_source, "x", &sites);

    // Declaration of Point.x first, then the uses in source order that the
    // syntax can state a question for.
    try std.testing.expect(sites.len >= 7);
    const declaration = symbols[0];
    try std.testing.expectEqual(zig_analyzer.compiler.protocol.SymbolStatus.resolved, declaration.status);
    try std.testing.expectEqual(zig_analyzer.compiler.protocol.SymbolKind.field, declaration.kind);
    try std.testing.expectEqual(sites[0].span.start, declaration.start);

    var same: usize = 0;
    var other: usize = 0;
    for (sites, symbols) |site, symbol| {
        try std.testing.expectEqual(zig_analyzer.compiler.protocol.SymbolStatus.resolved, symbol.status);
        const text = identity_source[site.span.start - 3 .. site.span.end];
        if (symbol.same(declaration)) {
            same += 1;
        } else {
            // Only Other.x is a different declaration, and it is read by `b.x`
            // and declared in `Other`.
            other += 1;
            try std.testing.expect(std.mem.endsWith(u8, text, "b.x") or std.mem.find(u8, text, "{ x") != null or std.mem.endsWith(u8, text, ".x"));
        }
    }
    // Point.x: its field, the returned `.x = 1`, self.x, a.x, c.x,
    // made.x and the reflection string. Other.x: its field and `b.x`.
    try std.testing.expectEqual(@as(usize, 7), same);
    try std.testing.expectEqual(@as(usize, 2), other);
}

test "resolve_symbol finds methods through aliases and says when a member is absent" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sites: []const symbol_query.Site = &.{};
    const symbols = try resolveMemberSites(arena, identity_source, "norm", &sites);
    try std.testing.expectEqual(@as(usize, 2), sites.len);
    for (symbols) |symbol| try std.testing.expectEqual(zig_analyzer.compiler.protocol.SymbolStatus.resolved, symbol.status);
    try std.testing.expect(symbols[0].same(symbols[1]));
    try std.testing.expectEqual(zig_analyzer.compiler.protocol.SymbolKind.declaration, symbols[0].kind);

    const missing_source =
        \\const Point = struct { x: i32 };
        \\export fn run(p: Point) i32 { return p.y; }
        \\
    ;
    const missing = try resolveMemberSites(arena, missing_source, "y", &sites);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqual(zig_analyzer.compiler.protocol.SymbolStatus.absent, missing[0].status);
}

test "resolve_symbol answers for a file nothing in the compile has referenced yet" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // `util` is imported but never used, so the compiler never analyzes it.
    const main_source =
        \\const util = @import("util.zig");
        \\export fn run() u32 {
        \\    return 1;
        \\}
        \\
    ;
    const util_source =
        \\const helper = @import("helper.zig");
        \\const Sites = helper.Sites;
        \\pub fn total() u32 {
        \\    const sites = helper.sitesOf(1);
        \\    var more: Sites = sites;
        \\    _ = &more;
        \\    return helper.value() + more.count;
        \\}
        \\
    ;
    const helper_source =
        \\pub const Sites = struct { count: u32 };
        \\pub fn sitesOf(count: u32) Sites {
        \\    return .{ .count = count };
        \\}
        \\pub fn value() u32 {
        \\    return 1;
        \\}
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = main_source });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "util.zig", .data = util_source });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "helper.zig", .data = helper_source });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "main.zig", arena);
    const util_path = try tmp.dir.realPathFileAlloc(std.testing.io, "util.zig", arena);
    const uri = try zig_analyzer.uri.fromPath(arena, path);
    const util_uri = try zig_analyzer.uri.fromPath(arena, util_path);
    var session = try startSession(path);
    defer session.deinit();
    _ = try session.replaceOverlay(uri, 1, main_source);
    _ = try session.replaceOverlay(util_uri, 1, util_source);
    var document = try Document.open(arena, util_uri, 1, util_source);
    defer document.deinit();
    for ([_][]const u8{ "value", "sitesOf", "count", "Sites" }) |name| {
        const sites = try symbol_query.memberSites(arena, &document, name);
        var queries: std.ArrayList(symbol_query.Query) = .empty;
        for (sites) |site| if (site.role.member) |query| try queries.append(arena, query);
        try std.testing.expect(queries.items.len > 0);
        const symbols = try session.resolveSymbols(arena, util_uri, queries.items);
        for (symbols) |symbol| {
            try std.testing.expectEqual(zig_analyzer.compiler.protocol.SymbolStatus.resolved, symbol.status);
            // The alias `Sites` is declared in util; everything else in helper.
            if (!std.mem.eql(u8, name, "Sites")) try std.testing.expect(std.mem.endsWith(u8, symbol.file, "helper.zig"));
        }
    }
}
