const std = @import("std");
const zig_analyzer = @import("zig_analyzer");

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

    var session = try zig_analyzer.compiler_session.Session.start(
        std.testing.io,
        std.testing.allocator,
        .empty,
        fixture_path,
    );
    defer session.deinit();

    const compiler_declarations = try session.workspaceDeclarations(std.testing.allocator);
    defer {
        for (compiler_declarations) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(compiler_declarations);
    }
    var found_generated_method = false;
    for (compiler_declarations) |name| {
        if (std.mem.endsWith(u8, name, ".diagonal")) found_generated_method = true;
    }
    try std.testing.expect(found_generated_method);

    try std.testing.expectError(
        error.SemanticsUnavailable,
        session.replaceOverlay("file:///workspace/outside-compile-unit.zig", 1, "const value = 1;\n"),
    );
    const uri = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{fixture_path});
    defer std.testing.allocator.free(uri);
    try std.testing.expectError(error.SemanticsUnavailable, session.analyzeOverlay(uri, 1));
    const first_source = "const first = 1;\nconst second = 2;\n";
    const first = try session.replaceOverlay(uri, 1, first_source);
    try std.testing.expectEqual(@as(i32, 1), first.document_version);
    try std.testing.expectEqual(@as(u32, 2), first.declaration_count);
    try std.testing.expectEqual(@as(u32, 0), first.syntax_error_count);

    try std.testing.expectError(error.StaleGeneration, session.analyzeOverlay(uri, 0));

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
    const uri = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{fixture_path});
    defer std.testing.allocator.free(uri);

    var session = try zig_analyzer.compiler_session.Session.start(
        std.testing.io,
        std.testing.allocator,
        .empty,
        fixture_path,
    );
    defer session.deinit();

    const source = "const value = 1;\n// " ++ ("x" ** 2048) ++ "\n";
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
    const uri = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{fixture_path});
    defer std.testing.allocator.free(uri);

    var session = try zig_analyzer.compiler_session.Session.start(
        std.testing.io,
        std.testing.allocator,
        .empty,
        fixture_path,
    );
    defer session.deinit();

    const generation_before = (try session.workspaceSummary()).last_generation;
    const changed_source = "pub const OverlayOnly = enum { ready }; export fn invalidResult() u32 { return true; }\n";
    _ = try session.replaceOverlay(uri, 1, changed_source);
    const generation_after = (try session.workspaceSummary()).last_generation;
    try std.testing.expect(generation_after > generation_before);
    var changed_diagnostics = try session.diagnostics(std.testing.allocator);
    defer changed_diagnostics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), changed_diagnostics.errorMessageCount());
    const changed_message = changed_diagnostics.getErrorMessage(changed_diagnostics.getMessages()[0]);
    try std.testing.expect(std.mem.indexOf(
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

test "compiler session returns structured semantic errors" {
    const fixture_path = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "examples/diagnostics/compiler_error.zig",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(fixture_path);
    var session = try zig_analyzer.compiler_session.Session.start(
        std.testing.io,
        std.testing.allocator,
        .empty,
        fixture_path,
    );
    defer session.deinit();

    const uri = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{fixture_path});
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
    try std.testing.expect(std.mem.indexOf(
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

    var document = try zig_analyzer.document.Document.open(std.testing.allocator, uri, 1, source);
    defer document.deinit();
    const lsp_diagnostics = try zig_analyzer.lsp_server.compilerDiagnostics(
        &document,
        diagnostics,
        std.testing.allocator,
    );
    defer {
        for (lsp_diagnostics) |diagnostic| {
            std.testing.allocator.free(diagnostic.message);
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
    var session = try zig_analyzer.compiler_session.Session.start(
        std.testing.io,
        std.testing.allocator,
        .empty,
        "examples/compiler/conditional_api.zig",
    );
    defer session.deinit();

    const declarations = try session.workspaceDeclarations(std.testing.allocator);
    defer {
        for (declarations) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(declarations);
    }
    const active_api = for (declarations) |name| {
        if (std.mem.endsWith(u8, name, ".ActiveApi")) break name;
    } else return error.ActiveApiNotAnalyzed;
    const members = try session.typeMembers(std.testing.allocator, active_api);
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
    var session = try zig_analyzer.compiler_session.Session.start(
        std.testing.io,
        std.testing.allocator,
        .empty,
        fixture_path,
    );
    defer session.deinit();

    const declarations = try session.workspaceDeclarations(std.testing.allocator);
    defer {
        for (declarations) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(declarations);
    }
    const active_pipeline = for (declarations) |name| {
        if (std.mem.endsWith(u8, name, ".ActivePipeline")) break name;
    } else return error.ActivePipelineNotAnalyzed;
    const members = try session.typeMembers(std.testing.allocator, active_pipeline);
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
    var session = try zig_analyzer.compiler_session.Session.start(
        std.testing.io,
        std.testing.allocator,
        .empty,
        "fixtures/comptime/main.zig",
    );
    defer session.deinit();

    const declarations = try session.workspaceDeclarations(std.testing.allocator);
    defer {
        for (declarations) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(declarations);
    }
    const expected_shapes = [_]struct {
        suffix: []const u8,
        kind: zig_analyzer.compiler_protocol.TypeShapeKind,
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
        session.typeShape(std.testing.allocator, ordinary_enum_name),
    );
    for (expected_shapes) |expected| {
        const qualified_name = declarationWithSuffix(declarations, expected.suffix) orelse return error.TypeNotAnalyzed;
        var shape = try session.typeShape(std.testing.allocator, qualified_name);
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
            session.typeShape(std.testing.allocator, qualified_name),
        );
    }
}

test "compiler protocol returns resolved comptime values" {
    var session = try zig_analyzer.compiler_session.Session.start(
        std.testing.io,
        std.testing.allocator,
        .empty,
        "fixtures/comptime/main.zig",
    );
    defer session.deinit();

    const declarations = try session.workspaceDeclarations(std.testing.allocator);
    defer {
        for (declarations) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(declarations);
    }
    const qualified_name = declarationWithSuffix(declarations, ".computed_answer") orelse
        return error.ValueNotAnalyzed;
    var resolved = try session.resolvedValue(std.testing.allocator, qualified_name);
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("u8", resolved.type_name);
    try std.testing.expectEqualStrings("42", resolved.value);
}

fn declarationWithSuffix(declarations: []const []const u8, suffix: []const u8) ?[]const u8 {
    for (declarations) |declaration| {
        if (std.mem.endsWith(u8, declaration, suffix)) return declaration;
    }
    return null;
}
