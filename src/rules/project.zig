const std = @import("std");
const types = @import("types.zig");

pub const SourceFile = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: ?[]const std.zig.Token = null,
};

const IndexedSourceFile = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
};

pub const Finding = struct {
    file_index: usize,
    rule: types.Rule,
    span: std.zig.Token.Loc,
    message: []const u8,
};

const Import = struct {
    file_index: usize,
    span: std.zig.Token.Loc,
    spelling: []const u8,
    resolved_path: []const u8,
};

pub fn findings(
    allocator: std.mem.Allocator,
    files: []const SourceFile,
    configuration: types.Configuration,
) ![]const Finding {
    if (configuration.level(.duplicate_module_import) == .off and
        configuration.level(.duplicate_c_import) == .off and
        configuration.level(.unreferenced_test_file) == .off and
        configuration.level(.conflicting_build_options) == .off) return &.{};
    const indexed_files = try allocator.alloc(IndexedSourceFile, files.len);
    for (files, indexed_files) |file, *indexed_file| indexed_file.* = .{
        .path = file.path,
        .source = file.source,
        .tokens = file.tokens orelse try tokenize(allocator, file.source),
    };
    var found: std.ArrayList(Finding) = .empty;
    const imports = if (configuration.level(.duplicate_module_import) != .off or
        configuration.level(.unreferenced_test_file) != .off)
        try collectImports(allocator, indexed_files)
    else
        &.{};
    try findDuplicateModuleImports(allocator, imports, configuration, &found);
    try findDuplicateCImports(allocator, indexed_files, configuration, &found);
    try findUnreferencedTests(allocator, indexed_files, imports, configuration, &found);
    try findConflictingBuildOptions(allocator, indexed_files, configuration, &found);
    std.mem.sort(Finding, found.items, {}, struct {
        fn lessThan(_: void, left: Finding, right: Finding) bool {
            if (left.file_index != right.file_index) return left.file_index < right.file_index;
            if (left.span.start != right.span.start) return left.span.start < right.span.start;
            return @intFromEnum(left.rule) < @intFromEnum(right.rule);
        }
    }.lessThan);
    return try found.toOwnedSlice(allocator);
}

fn findDuplicateModuleImports(
    allocator: std.mem.Allocator,
    imports: []const Import,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.duplicate_module_import) == .off) return;
    for (imports, 0..) |current, index| {
        for (imports[0..index]) |previous| {
            if (previous.file_index != current.file_index or
                !std.mem.eql(u8, previous.resolved_path, current.resolved_path) or
                std.mem.eql(u8, previous.spelling, current.spelling)) continue;
            try found.append(allocator, .{
                .file_index = current.file_index,
                .rule = .duplicate_module_import,
                .span = current.span,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "imports '{s}' and '{s}' resolve to the same module '{s}'",
                    .{ previous.spelling, current.spelling, current.resolved_path },
                ),
            });
            break;
        }
    }
}

fn findDuplicateCImports(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.duplicate_c_import) == .off) return;
    var signatures: std.StringHashMapUnmanaged(struct { file_index: usize, span: std.zig.Token.Loc }) = .empty;
    for (files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, index| {
            if (token.tag != .builtin or !tokenIs(file.source, token, "@cImport") or
                index + 1 >= file.tokens.len or file.tokens[index + 1].tag != .l_paren) continue;
            const closing = matchingToken(file.tokens, index + 1, .l_paren, .r_paren) orelse continue;
            var signature_writer: std.Io.Writer.Allocating = .init(allocator);
            for (file.source[file.tokens[index + 1].loc.end..file.tokens[closing].loc.start]) |character| {
                if (!std.ascii.isWhitespace(character)) try signature_writer.writer.writeByte(character);
            }
            const signature = try signature_writer.toOwnedSlice();
            if (signatures.get(signature)) |first| {
                if (first.file_index == file_index) continue;
                try found.append(allocator, .{
                    .file_index = file_index,
                    .rule = .duplicate_c_import,
                    .span = token.loc,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "@cImport duplicates the translation already declared in '{s}'; expose one translated namespace instead",
                        .{files[first.file_index].path},
                    ),
                });
            } else try signatures.put(allocator, signature, .{ .file_index = file_index, .span = token.loc });
        }
    }
}

fn findUnreferencedTests(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    imports: []const Import,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.unreferenced_test_file) == .off) return;
    for (files, 0..) |file, file_index| {
        if (!looksLikeTestPath(file.path) or !containsTestDeclaration(file.tokens)) continue;
        var referenced = false;
        for (imports) |import| {
            if (import.file_index != file_index and std.mem.eql(u8, import.resolved_path, file.path)) {
                referenced = true;
                break;
            }
        }
        if (!referenced) for (files, 0..) |build_file, build_index| {
            if (build_index == file_index or !std.mem.eql(u8, std.fs.path.basename(build_file.path), "build.zig")) continue;
            if (sourceMentionsPath(build_file.source, file.path)) {
                referenced = true;
                break;
            }
        };
        if (referenced) continue;
        try found.append(allocator, .{
            .file_index = file_index,
            .rule = .unreferenced_test_file,
            .span = .{ .start = 0, .end = @min(file.source.len, 1) },
            .message = try std.fmt.allocPrint(
                allocator,
                "test source '{s}' is not imported by another Zig file or referenced from build.zig",
                .{file.path},
            ),
        });
    }
}

fn findConflictingBuildOptions(
    allocator: std.mem.Allocator,
    files: []const IndexedSourceFile,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.conflicting_build_options) == .off) return;
    var roots: std.StringHashMapUnmanaged(struct { signature: []const u8, file_index: usize }) = .empty;
    var reported: std.StringHashMapUnmanaged(void) = .empty;
    for (files, 0..) |file, file_index| {
        if (!std.mem.eql(u8, std.fs.path.basename(file.path), "build.zig")) continue;
        for (file.tokens, 0..) |token, index| {
            if (token.tag != .identifier or !tokenIs(file.source, token, "root_source_file") or index + 6 >= file.tokens.len) continue;
            var string_index = index + 1;
            while (string_index < file.tokens.len and string_index - index < 12 and file.tokens[string_index].tag != .string_literal) : (string_index += 1) {}
            if (string_index >= file.tokens.len or string_index - index >= 12) continue;
            const root_spelling = stringValue(file.source, file.tokens[string_index]) orelse continue;
            if (!std.mem.endsWith(u8, root_spelling, ".zig")) continue;
            const root_path = try resolveImportPath(allocator, file.path, root_spelling);
            const block = enclosingInitializer(file.tokens, index) orelse continue;
            const signature = try optionSignature(allocator, file.source, file.tokens, block.opening + 1, block.closing);
            if (std.mem.eql(u8, signature, "target=<default>;optimize=<default>")) continue;
            if (roots.get(root_path)) |first| {
                if (std.mem.eql(u8, first.signature, signature)) continue;
                const conflict_key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ root_path, signature });
                if (reported.contains(conflict_key)) continue;
                try reported.put(allocator, conflict_key, {});
                try found.append(allocator, .{
                    .file_index = file_index,
                    .rule = .conflicting_build_options,
                    .span = file.tokens[string_index].loc,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "root source '{s}' is configured with both '{s}' and '{s}'; semantic results may differ between compile units",
                        .{ root_path, first.signature, signature },
                    ),
                });
            } else try roots.put(allocator, root_path, .{ .signature = signature, .file_index = file_index });
        }
    }
}

fn collectImports(allocator: std.mem.Allocator, files: []const IndexedSourceFile) ![]const Import {
    var imports: std.ArrayList(Import) = .empty;
    for (files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, index| {
            if (token.tag != .builtin or !tokenIs(file.source, token, "@import") or index + 2 >= file.tokens.len or
                file.tokens[index + 1].tag != .l_paren or file.tokens[index + 2].tag != .string_literal) continue;
            const spelling = stringValue(file.source, file.tokens[index + 2]) orelse continue;
            if (!std.mem.endsWith(u8, spelling, ".zig")) continue;
            try imports.append(allocator, .{
                .file_index = file_index,
                .span = file.tokens[index + 2].loc,
                .spelling = spelling,
                .resolved_path = try resolveImportPath(allocator, file.path, spelling),
            });
        }
    }
    return try imports.toOwnedSlice(allocator);
}

fn resolveImportPath(allocator: std.mem.Allocator, importing_path: []const u8, spelling: []const u8) ![]const u8 {
    const directory = std.fs.path.dirname(importing_path) orelse "";
    const absolute = try std.fs.path.resolve(allocator, &.{ "/", directory, spelling });
    return std.mem.trimStart(u8, absolute, "/");
}

fn looksLikeTestPath(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, basename, "_test.zig")) return true;
    var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (components.next()) |component| if (std.mem.eql(u8, component, "test") or std.mem.eql(u8, component, "tests")) return true;
    return false;
}

fn containsTestDeclaration(tokens: []const std.zig.Token) bool {
    for (tokens) |token| if (token.tag == .keyword_test) return true;
    return false;
}

fn sourceMentionsPath(source: []const u8, path: []const u8) bool {
    if (std.mem.indexOf(u8, source, path) != null) return true;
    const basename = std.fs.path.basename(path);
    return std.mem.indexOf(u8, source, basename) != null;
}

const Block = struct { opening: usize, closing: usize };

fn enclosingInitializer(tokens: []const std.zig.Token, index: usize) ?Block {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == .r_brace) depth += 1;
        if (tokens[cursor].tag != .l_brace) continue;
        if (depth != 0) {
            depth -= 1;
            continue;
        }
        const closing = matchingToken(tokens, cursor, .l_brace, .r_brace) orelse return null;
        return .{ .opening = cursor, .closing = closing };
    }
    return null;
}

fn optionSignature(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    start: usize,
    end: usize,
) ![]const u8 {
    const target = optionValue(source, tokens, start, end, "target") orelse "<default>";
    const optimize = optionValue(source, tokens, start, end, "optimize") orelse "<default>";
    return try std.fmt.allocPrint(allocator, "target={s};optimize={s}", .{ target, optimize });
}

fn optionValue(source: []const u8, tokens: []const std.zig.Token, start: usize, end: usize, name: []const u8) ?[]const u8 {
    for (tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !tokenIs(source, token, name) or index + 2 >= end or tokens[index + 1].tag != .equal) continue;
        var value_end = index + 2;
        while (value_end < end and tokens[value_end].tag != .comma) : (value_end += 1) {}
        if (value_end == index + 2) return null;
        return std.mem.trim(u8, source[tokens[index + 2].loc.start..tokens[value_end - 1].loc.end], " \t\r\n");
    }
    return null;
}

fn stringValue(source: []const u8, token: std.zig.Token) ?[]const u8 {
    const literal = source[token.loc.start..token.loc.end];
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    return literal[1 .. literal.len - 1];
}

fn tokenIs(source: []const u8, token: std.zig.Token, expected: []const u8) bool {
    return std.mem.eql(u8, source[token.loc.start..token.loc.end], expected);
}

fn matchingToken(tokens: []const std.zig.Token, opening: usize, opening_tag: std.zig.Token.Tag, closing_tag: std.zig.Token.Tag) ?usize {
    var depth: usize = 0;
    for (tokens[opening..], opening..) |token, index| {
        if (token.tag == opening_tag) depth += 1;
        if (token.tag != closing_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}

test "project findings compose imports tests c imports and build options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.duplicate_c_import)] = .information;
    configuration.levels[@intFromEnum(types.Rule.unreferenced_test_file)] = .information;
    configuration.levels[@intFromEnum(types.Rule.conflicting_build_options)] = .information;
    const files = [_]SourceFile{
        .{ .path = "src/a.zig", .source = "const one = @import(\"../shared.zig\"); const two = @import(\"../src/../shared.zig\"); const c = @cImport({ @cInclude(\"x.h\"); });" },
        .{ .path = "src/b.zig", .source = "const c = @cImport({ @cInclude(\"x.h\"); });" },
        .{ .path = "tests/orphan_test.zig", .source = "test \"orphan\" {}" },
        .{ .path = "build.zig", .source =
        \\const one = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = linux, .optimize = .Debug });
        \\const two = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = windows, .optimize = .Debug });
        },
    };
    const found = try findings(arena.allocator(), &files, configuration);
    try std.testing.expectEqual(@as(usize, 4), found.len);
}
