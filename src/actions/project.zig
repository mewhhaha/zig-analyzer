const std = @import("std");
const analysis = @import("../analysis.zig");
const action_context = @import("context.zig");

pub const OpenDocument = struct {
    uri: []const u8,
    source: [:0]const u8,
};

pub const FileEdit = struct {
    uri: []const u8,
    edit: analysis.Edit,
};

pub const CreatedFile = struct {
    uri: []const u8,
    source: []const u8,
};

pub const Candidate = struct {
    title: []const u8,
    kind: analysis.ActionKind = .refactor_rewrite,
    edits: []const FileEdit,
    created_file: ?CreatedFile = null,
};

pub fn actions(
    allocator: std.mem.Allocator,
    current_uri: []const u8,
    current_source: [:0]const u8,
    selection: std.zig.Token.Loc,
    documents: []const OpenDocument,
) ![]const Candidate {
    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer candidates.deinit(allocator);
    if (try buildImportAction(allocator, current_uri, current_source, selection, documents)) |candidate| {
        try candidates.append(allocator, candidate);
    }
    if (try cImportAction(allocator, current_uri, current_source, selection, documents)) |candidate| {
        try candidates.append(allocator, candidate);
    }
    return try candidates.toOwnedSlice(allocator);
}

fn buildImportAction(
    allocator: std.mem.Allocator,
    current_uri: []const u8,
    current_source: [:0]const u8,
    selection: std.zig.Token.Loc,
    documents: []const OpenDocument,
) !?Candidate {
    const import_name = try selectedPackageImport(allocator, current_source, selection) orelse return null;
    const module_document = uniqueModuleDocument(import_name, current_uri, documents) orelse return null;
    const build_document = uniqueBuildDocument(documents) orelse return null;
    const existing_import = try std.fmt.allocPrint(allocator, "addImport(\"{s}\"", .{import_name});
    if (std.mem.indexOf(u8, build_document.source, existing_import) != null) return null;
    const build_tokens = try action_context.tokenize(allocator, build_document.source);
    const build_body = buildFunctionBody(build_tokens, build_document.source) orelse return null;
    const artifact_name = firstRootModuleReceiver(
        build_document.source,
        build_tokens,
        build_body.start,
        build_body.end,
    ) orelse return null;
    const build_path = uriPath(build_document.uri) orelse return null;
    const module_path = uriPath(module_document.uri) orelse return null;
    const build_directory = std.fs.path.dirname(build_path) orelse return null;
    const relative_path = try std.fs.path.relative(allocator, "/", null, build_directory, module_path);
    const insertion = build_tokens[build_body.end].loc.start;
    // Ownership is transferred through the returned Candidate.edits slice.
    // zig-analyzer: disable-next-line unreleased-allocation
    const edits = try allocator.alloc(FileEdit, 1);
    edits[0] = .{
        .uri = build_document.uri,
        .edit = .{
            .span = .{ .start = insertion, .end = insertion },
            .replacement = try std.fmt.allocPrint(
                allocator,
                "    {s}.root_module.addImport(\"{s}\", b.createModule(.{{ .root_source_file = b.path(\"{s}\") }}));\n",
                .{ artifact_name, import_name, relative_path },
            ),
        },
    };
    return .{
        .title = try std.fmt.allocPrint(allocator, "Add module '{s}' to build.zig", .{import_name}),
        .edits = edits,
    };
}

fn selectedPackageImport(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    selection: std.zig.Token.Loc,
) !?[]const u8 {
    const tokens = try action_context.tokenize(allocator, source);
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or !tokenIs(source, token, "@import") or index + 2 >= tokens.len or
            tokens[index + 1].tag != .l_paren or tokens[index + 2].tag != .string_literal or
            !action_context.spansOverlap(selection, tokens[index + 2].loc)) continue;
        const name = stringValue(source[tokens[index + 2].loc.start..tokens[index + 2].loc.end]) orelse continue;
        if (std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "root") or std.mem.eql(u8, name, "builtin") or
            std.mem.endsWith(u8, name, ".zig") or std.mem.indexOfScalar(u8, name, '/') != null) return null;
        return name;
    }
    return null;
}

fn uniqueModuleDocument(name: []const u8, current_uri: []const u8, documents: []const OpenDocument) ?OpenDocument {
    var selected: ?OpenDocument = null;
    for (documents) |document| {
        if (std.mem.eql(u8, document.uri, current_uri)) continue;
        const path = uriPath(document.uri) orelse continue;
        const basename = std.fs.path.basename(path);
        if (!std.mem.endsWith(u8, basename, ".zig") or basename.len != name.len + 4 or
            !std.mem.eql(u8, basename[0..name.len], name)) continue;
        if (selected != null) return null;
        selected = document;
    }
    return selected;
}

fn uniqueBuildDocument(documents: []const OpenDocument) ?OpenDocument {
    var selected: ?OpenDocument = null;
    for (documents) |document| {
        const path = uriPath(document.uri) orelse continue;
        if (!std.mem.eql(u8, std.fs.path.basename(path), "build.zig")) continue;
        if (selected != null) return null;
        selected = document;
    }
    return selected;
}

const BuildFunctionBody = struct { start: usize, end: usize };

fn buildFunctionBody(tokens: []const std.zig.Token, source: [:0]const u8) ?BuildFunctionBody {
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_fn or index + 2 >= tokens.len or tokens[index + 1].tag != .identifier or
            !tokenIs(source, tokens[index + 1], "build") or tokens[index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, index + 2, .l_paren, .r_paren) orelse return null;
        var body_start = parameters_end + 1;
        while (body_start < tokens.len and tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= tokens.len) return null;
        const body_end = matchingToken(tokens, body_start, .l_brace, .r_brace) orelse return null;
        return .{ .start = body_start, .end = body_end };
    }
    return null;
}

fn firstRootModuleReceiver(
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    body_start: usize,
    body_end: usize,
) ?[]const u8 {
    for (tokens[body_start..body_end], body_start..) |token, index| {
        if (token.tag == .identifier and index + 2 < body_end and tokens[index + 1].tag == .period and
            tokenIs(source, tokens[index + 2], "root_module")) return source[token.loc.start..token.loc.end];
    }
    return null;
}

fn cImportAction(
    allocator: std.mem.Allocator,
    current_uri: []const u8,
    current_source: [:0]const u8,
    selection: std.zig.Token.Loc,
    documents: []const OpenDocument,
) !?Candidate {
    const selected = try selectedCImport(allocator, current_source, selection) orelse return null;
    const c_import_source = current_source[selected.start..selected.end];
    var occurrences: std.ArrayList(FileEdit) = .empty;
    defer occurrences.deinit(allocator);
    for (documents) |document| {
        const spans = try matchingCImports(allocator, document.source, c_import_source);
        defer allocator.free(spans);
        for (spans) |span| {
            try occurrences.append(allocator, .{ .uri = document.uri, .edit = .{ .span = span, .replacement = "" } });
        }
    }
    if (occurrences.items.len < 2) return null;

    const current_path = uriPath(current_uri) orelse return null;
    const wrapper_path = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(current_path) orelse return null, "c_imports.zig" });
    const wrapper_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{wrapper_path});
    for (documents) |document| if (std.mem.eql(u8, document.uri, wrapper_uri)) return null;
    for (occurrences.items) |*occurrence| {
        const document_path = uriPath(occurrence.uri) orelse return null;
        const document_directory = std.fs.path.dirname(document_path) orelse return null;
        var relative_path = try std.fs.path.relative(allocator, "/", null, document_directory, wrapper_path);
        if (!std.mem.startsWith(u8, relative_path, ".")) {
            relative_path = try std.fmt.allocPrint(allocator, "./{s}", .{relative_path});
        }
        occurrence.edit.replacement = try std.fmt.allocPrint(allocator, "@import(\"{s}\").c", .{relative_path});
    }
    return .{
        .title = "Extract repeated @cImport into c_imports.zig",
        .edits = try occurrences.toOwnedSlice(allocator),
        .created_file = .{
            .uri = wrapper_uri,
            .source = try std.fmt.allocPrint(allocator, "pub const c = {s};\n", .{c_import_source}),
        },
    };
}

fn selectedCImport(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    selection: std.zig.Token.Loc,
) !?std.zig.Token.Loc {
    const tokens = try action_context.tokenize(allocator, source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or !tokenIs(source, token, "@cImport") or index + 1 >= tokens.len or
            tokens[index + 1].tag != .l_paren) continue;
        const closing = matchingToken(tokens, index + 1, .l_paren, .r_paren) orelse continue;
        const span = std.zig.Token.Loc{ .start = token.loc.start, .end = tokens[closing].loc.end };
        if (action_context.spansOverlap(selection, span)) return span;
    }
    return null;
}

fn matchingCImports(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    expected: []const u8,
) ![]const std.zig.Token.Loc {
    const tokens = try action_context.tokenize(allocator, source);
    defer allocator.free(tokens);
    var spans: std.ArrayList(std.zig.Token.Loc) = .empty;
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or !tokenIs(source, token, "@cImport") or index + 1 >= tokens.len or
            tokens[index + 1].tag != .l_paren) continue;
        const closing = matchingToken(tokens, index + 1, .l_paren, .r_paren) orelse continue;
        const span = std.zig.Token.Loc{ .start = token.loc.start, .end = tokens[closing].loc.end };
        if (std.mem.eql(u8, source[span.start..span.end], expected)) try spans.append(allocator, span);
    }
    return try spans.toOwnedSlice(allocator);
}

fn matchingToken(
    tokens: []const std.zig.Token,
    opening: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    for (tokens[opening..], opening..) |token, index| {
        if (token.tag == opening_tag) depth += 1;
        if (token.tag != closing_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

fn tokenIs(source: []const u8, token: std.zig.Token, expected: []const u8) bool {
    return std.mem.eql(u8, source[token.loc.start..token.loc.end], expected);
}

fn stringValue(literal: []const u8) ?[]const u8 {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    const value = literal[1 .. literal.len - 1];
    if (std.mem.indexOfScalar(u8, value, '\\') != null) return null;
    return value;
}

fn uriPath(uri: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    const path = uri["file://".len..];
    if (std.mem.indexOfScalar(u8, path, '%') != null) return null;
    return path;
}

test "project actions repair build imports and consolidate c imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const build: [:0]const u8 =
        "const std = @import(\"std\"); pub fn build(b: *std.Build) void { " ++
        "const exe = b.addExecutable(.{ .name = \"app\" }); _ = exe.root_module; } " ++
        "fn helper() void { const local = 1; _ = local; }";
    const main: [:0]const u8 = "const feature = @import(\"feature\"); const c = @cImport({ @cInclude(\"x.h\"); });";
    const feature: [:0]const u8 = "const c = @cImport({ @cInclude(\"x.h\"); });";
    const documents = [_]OpenDocument{
        .{ .uri = "file:///project/build.zig", .source = build },
        .{ .uri = "file:///project/src/main.zig", .source = main },
        .{ .uri = "file:///project/src/feature.zig", .source = feature },
    };
    const import_start = std.mem.indexOf(u8, main, "\"feature\"") orelse unreachable;
    const build_actions = try actions(arena.allocator(), documents[1].uri, main, .{ .start = import_start, .end = import_start + 9 }, &documents);
    try std.testing.expectEqual(@as(usize, 1), build_actions.len);
    try std.testing.expect(std.mem.indexOf(u8, build_actions[0].edits[0].edit.replacement, "root_module.addImport") != null);
    const build_close = (std.mem.indexOf(u8, build, "} fn helper") orelse unreachable);
    try std.testing.expectEqual(build_close, build_actions[0].edits[0].edit.span.start);
    try std.testing.expectEqualStrings("exe", build_actions[0].edits[0].edit.replacement[4..7]);

    const c_import = std.mem.indexOf(u8, main, "@cImport") orelse unreachable;
    const c_actions = try actions(arena.allocator(), documents[1].uri, main, .{ .start = c_import, .end = c_import + 8 }, &documents);
    try std.testing.expectEqual(@as(usize, 1), c_actions.len);
    try std.testing.expect(c_actions[0].created_file != null);
    try std.testing.expectEqual(@as(usize, 2), c_actions[0].edits.len);
}
