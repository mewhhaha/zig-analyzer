const std = @import("std");
const analysis = @import("../analysis.zig");
const uri_module = @import("../uri.zig");
const action_context = @import("context.zig");
const tokenize = @import("../syntax/tokens.zig").tokenize;
const tokenIs = @import("../syntax/tokens.zig").tokenIs;
const matchingToken = @import("../syntax/tokens.zig").matchingToken;

pub const OpenDocument = struct {
    uri: []const u8,
    source: [:0]const u8,
};

pub const FileEdit = struct {
    uri: []const u8,
    edit: analysis.Edit,
};

pub const Candidate = struct {
    title: []const u8,
    kind: analysis.ActionKind = .refactor_rewrite,
    edits: []const FileEdit,
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
    const module_document = try uniqueModuleDocument(allocator, import_name, current_uri, documents) orelse return null;
    const build_document = try uniqueBuildDocument(allocator, documents) orelse return null;
    const existing_import = try allocator.print("addImport(\"{s}\"", .{import_name});
    defer allocator.free(existing_import);
    if (std.mem.find(u8, build_document.source, existing_import) != null) return null;
    const build_tokens = try tokenize(allocator, build_document.source);
    defer allocator.free(build_tokens);
    const build_body = buildFunctionBody(build_tokens, build_document.source) orelse return null;
    const artifact_name = firstRootModuleReceiver(
        build_document.source,
        build_tokens,
        build_body.start,
        build_body.end,
    ) orelse return null;
    const build_path = try uri_module.toPath(allocator, build_document.uri) orelse return null;
    defer allocator.free(build_path);
    const module_path = try uri_module.toPath(allocator, module_document.uri) orelse return null;
    defer allocator.free(module_path);
    const build_directory = std.Io.Dir.path.dirname(build_path) orelse return null;
    const relative_path = try std.Io.Dir.path.relativeAlloc(allocator, "/", null, build_directory, module_path);
    defer allocator.free(relative_path);
    const insertion = build_tokens[build_body.end].loc.start;
    // Ownership is transferred through the returned Candidate.edits slice.
    // zig-analyzer: disable-next-line unreleased-allocation
    const edits = try allocator.alloc(FileEdit, 1);
    errdefer allocator.free(edits);
    const replacement = try allocator.print(
        "    {s}.root_module.addImport(\"{s}\", b.createModule(.{{ .root_source_file = b.path(\"{s}\") }}));\n",
        .{ artifact_name, import_name, relative_path },
    );
    errdefer allocator.free(replacement);
    edits[0] = .{
        .uri = build_document.uri,
        .edit = .{
            .span = .{ .start = insertion, .end = insertion },
            .replacement = replacement,
        },
    };
    return .{
        .title = try allocator.print("Add module '{s}' to build.zig", .{import_name}),
        .edits = edits,
    };
}

fn selectedPackageImport(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    selection: std.zig.Token.Loc,
) !?[]const u8 {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or !tokenIs(source, token, "@import") or index + 2 >= tokens.len or
            tokens[index + 1].tag != .l_paren or tokens[index + 2].tag != .string_literal or
            !action_context.spansOverlap(selection, tokens[index + 2].loc)) continue;
        const name = stringValue(source[tokens[index + 2].loc.start..tokens[index + 2].loc.end]) orelse continue;
        if (std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "root") or std.mem.eql(u8, name, "builtin") or
            std.mem.endsWith(u8, name, ".zig") or std.mem.findScalar(u8, name, '/') != null) return null;
        return name;
    }
    return null;
}

fn uniqueModuleDocument(
    allocator: std.mem.Allocator,
    name: []const u8,
    current_uri: []const u8,
    documents: []const OpenDocument,
) !?OpenDocument {
    var selected: ?OpenDocument = null;
    for (documents) |document| {
        if (std.mem.eql(u8, document.uri, current_uri)) continue;
        const path = try uri_module.toPath(allocator, document.uri) orelse continue;
        defer allocator.free(path);
        const basename = std.Io.Dir.path.basename(path);
        if (!std.mem.endsWith(u8, basename, ".zig") or basename.len != name.len + 4 or
            !std.mem.eql(u8, basename[0..name.len], name)) continue;
        if (selected != null) return null;
        selected = document;
    }
    return selected;
}

fn uniqueBuildDocument(allocator: std.mem.Allocator, documents: []const OpenDocument) !?OpenDocument {
    var selected: ?OpenDocument = null;
    for (documents) |document| {
        const path = try uri_module.toPath(allocator, document.uri) orelse continue;
        defer allocator.free(path);
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(path), "build.zig")) continue;
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

fn stringValue(literal: []const u8) ?[]const u8 {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    const value = literal[1 .. literal.len - 1];
    if (std.mem.findScalar(u8, value, '\\') != null) return null;
    return value;
}

test "build import quick fixes release partial results on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const main: [:0]const u8 = "const feature = @import(\"feature\");";
            const documents = [_]OpenDocument{
                .{ .uri = "file:///project/build.zig", .source = "pub fn build(b: *std.Build) void { const exe = b.addExecutable(.{ .name = \"app\" }); _ = exe.root_module; }" },
                .{ .uri = "file:///project/src/main.zig", .source = main },
                .{ .uri = "file:///project/src/feature.zig", .source = "pub const value = 1;" },
            };
            const start = std.mem.find(u8, main, "\"feature\"").?;
            const action = try buildImportAction(allocator, documents[1].uri, main, .{ .start = start, .end = start + 9 }, &documents) orelse return error.MissingBuildAction;
            defer allocator.free(action.title);
            defer allocator.free(action.edits);
            for (action.edits) |edit| allocator.free(edit.edit.replacement);
        }
    }.run, .{});
}

test "build import paths are percent-decoded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const main: [:0]const u8 = "const feature = @import(\"feature\");";
    const documents = [_]OpenDocument{
        .{ .uri = "file:///my%20project/build.zig", .source = "pub fn build(b: *std.Build) void { const exe = b.addExecutable(.{ .name = \"app\" }); _ = exe.root_module; }" },
        .{ .uri = "file:///my%20project/src/main.zig", .source = main },
        .{ .uri = "file:///my%20project/src/feature.zig", .source = "pub const value = 1;" },
    };
    const import_start = std.mem.find(u8, main, "\"feature\"").?;
    const build_actions = try actions(arena.allocator(), documents[1].uri, main, .{ .start = import_start, .end = import_start + 9 }, &documents);
    try std.testing.expectEqual(@as(usize, 1), build_actions.len);
    try std.testing.expect(std.mem.find(u8, build_actions[0].edits[0].edit.replacement, "b.path(\"src/feature.zig\")") != null);
}

test "project actions repair build imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const build: [:0]const u8 =
        "const std = @import(\"std\"); pub fn build(b: *std.Build) void { " ++
        "const exe = b.addExecutable(.{ .name = \"app\" }); _ = exe.root_module; } " ++
        "fn helper() void { const local = 1; _ = local; }";
    const main: [:0]const u8 = "const feature = @import(\"feature\");";
    const feature: [:0]const u8 = "pub const value = 1;";
    const documents = [_]OpenDocument{
        .{ .uri = "file:///project/build.zig", .source = build },
        .{ .uri = "file:///project/src/main.zig", .source = main },
        .{ .uri = "file:///project/src/feature.zig", .source = feature },
    };
    const import_start = std.mem.find(u8, main, "\"feature\"") orelse unreachable;
    const build_actions = try actions(arena.allocator(), documents[1].uri, main, .{ .start = import_start, .end = import_start + 9 }, &documents);
    try std.testing.expectEqual(@as(usize, 1), build_actions.len);
    try std.testing.expect(std.mem.find(u8, build_actions[0].edits[0].edit.replacement, "root_module.addImport") != null);
    const build_close = (std.mem.find(u8, build, "} fn helper") orelse unreachable);
    try std.testing.expectEqual(build_close, build_actions[0].edits[0].edit.span.start);
    try std.testing.expectEqualStrings("exe", build_actions[0].edits[0].edit.replacement[4..7]);
}
