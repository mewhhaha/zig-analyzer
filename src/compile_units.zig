const std = @import("std");

pub fn rootSourceForDocument(
    io: std.Io,
    allocator: std.mem.Allocator,
    document_path: []const u8,
) ![]const u8 {
    const build_path = try nearestBuildFile(io, allocator, document_path) orelse
        return try allocator.dupe(u8, document_path);
    defer allocator.free(build_path);
    const source_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        build_path,
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(source_bytes);
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    const build_directory = std.fs.path.dirname(build_path) orelse ".";
    const roots = try declaredRootSources(allocator, source, build_directory);
    defer {
        for (roots) |root| allocator.free(root);
        allocator.free(roots);
    }

    var selected: ?[]const u8 = null;
    var selected_prefix_length: usize = 0;
    var ambiguous = false;
    for (roots) |root| {
        if (!try pathExists(io, root)) continue;
        const root_directory = std.fs.path.dirname(root) orelse continue;
        if (!pathIsWithin(document_path, root_directory)) continue;
        if (root_directory.len < selected_prefix_length) continue;
        if (root_directory.len == selected_prefix_length) {
            if (selected) |previous| {
                if (!std.mem.eql(u8, previous, root)) ambiguous = true;
            }
            continue;
        }
        selected = root;
        selected_prefix_length = root_directory.len;
        ambiguous = false;
    }
    const chosen = if (ambiguous) document_path else selected orelse document_path;
    if (!std.mem.eql(u8, chosen, document_path) and
        !try documentReachableFromRoot(io, allocator, chosen, document_path))
    {
        return try allocator.dupe(u8, document_path);
    }
    return try allocator.dupe(u8, chosen);
}

fn documentReachableFromRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    document_path: []const u8,
) !bool {
    const normalized_document = try std.fs.path.resolve(allocator, &.{document_path});
    defer allocator.free(normalized_document);
    var visited: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer {
        for (visited.keys()) |path| allocator.free(path);
        visited.deinit(allocator);
    }
    try visited.put(allocator, try std.fs.path.resolve(allocator, &.{root_path}), {});

    const maximum_imported_files = 512;
    var scan_index: usize = 0;
    while (scan_index < visited.count()) : (scan_index += 1) {
        const current_path = visited.keys()[scan_index];
        const source_bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            current_path,
            allocator,
            .limited(4 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer allocator.free(source_bytes);
        const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
        defer allocator.free(source);
        @memcpy(source, source_bytes);
        const tokens = try tokenize(allocator, source);
        defer allocator.free(tokens);
        const current_directory = std.fs.path.dirname(current_path) orelse continue;

        for (tokens, 0..) |token, index| {
            if (token.tag != .builtin or !tokenIs(source, token, "@import") or
                index + 3 >= tokens.len or tokens[index + 1].tag != .l_paren or
                tokens[index + 2].tag != .string_literal or tokens[index + 3].tag != .r_paren) continue;
            const literal = tokenText(source, tokens[index + 2]);
            const import_path = std.zig.string_literal.parseAlloc(allocator, literal) catch |err| switch (err) {
                error.InvalidLiteral => continue,
                error.OutOfMemory => return error.OutOfMemory,
            };
            defer allocator.free(import_path);
            if (!std.mem.endsWith(u8, import_path, ".zig")) continue;

            const resolved = try std.fs.path.resolve(allocator, &.{ current_directory, import_path });
            if (std.mem.eql(u8, resolved, normalized_document)) {
                allocator.free(resolved);
                return true;
            }
            if (visited.count() == maximum_imported_files) {
                allocator.free(resolved);
                continue;
            }
            const entry = try visited.getOrPut(allocator, resolved);
            if (entry.found_existing) allocator.free(resolved);
        }
    }
    return false;
}

pub fn namedModuleSourceForDocument(
    io: std.Io,
    allocator: std.mem.Allocator,
    document_path: []const u8,
    module_name: []const u8,
) !?[]const u8 {
    const build_path = try nearestBuildFile(io, allocator, document_path) orelse return null;
    defer allocator.free(build_path);
    const source_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        build_path,
        allocator,
        .limited(4 * 1024 * 1024),
    );
    defer allocator.free(source_bytes);
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    return try declaredNamedModuleSource(
        allocator,
        source,
        std.fs.path.dirname(build_path) orelse ".",
        module_name,
    );
}

pub fn declaredRootSources(
    allocator: std.mem.Allocator,
    build_source: [:0]const u8,
    build_directory: []const u8,
) ![]const []const u8 {
    const tokens = try tokenize(allocator, build_source);
    defer allocator.free(tokens);
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (roots.items) |root| allocator.free(root);
        roots.deinit(allocator);
    }
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or !tokenIs(build_source, token, "root_source_file")) continue;
        var path_builtin = index + 1;
        while (path_builtin < tokens.len and path_builtin - index < 12 and
            tokens[path_builtin].tag != .l_paren) : (path_builtin += 1)
        {}
        if (path_builtin == tokens.len or path_builtin - index >= 12 or path_builtin < 2 or
            tokens[path_builtin - 1].tag != .identifier or
            (!tokenIs(build_source, tokens[path_builtin - 1], "path") and
                !tokenIs(build_source, tokens[path_builtin - 1], "pathFromRoot"))) continue;
        if (path_builtin + 1 >= tokens.len or tokens[path_builtin + 1].tag != .string_literal) continue;
        const literal = tokenText(build_source, tokens[path_builtin + 1]);
        if (literal.len < 2) continue;
        const relative_path = literal[1 .. literal.len - 1];
        const resolved = try std.fs.path.resolve(allocator, &.{ build_directory, relative_path });
        if (containsString(roots.items, resolved)) {
            allocator.free(resolved);
            continue;
        }
        try roots.append(allocator, resolved);
    }
    return try roots.toOwnedSlice(allocator);
}

fn declaredNamedModuleSource(
    allocator: std.mem.Allocator,
    build_source: [:0]const u8,
    build_directory: []const u8,
    module_name: []const u8,
) !?[]const u8 {
    const tokens = try tokenize(allocator, build_source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or !tokenIs(build_source, token, "addModule") or
            index + 2 >= tokens.len or tokens[index + 1].tag != .l_paren or
            tokens[index + 2].tag != .string_literal) continue;
        const name_literal = tokenText(build_source, tokens[index + 2]);
        if (name_literal.len < 2 or !std.mem.eql(u8, name_literal[1 .. name_literal.len - 1], module_name)) continue;

        var parenthesis_depth: usize = 1;
        var cursor = index + 2;
        while (cursor + 1 < tokens.len and parenthesis_depth != 0) {
            cursor += 1;
            switch (tokens[cursor].tag) {
                .l_paren => parenthesis_depth += 1,
                .r_paren => parenthesis_depth -= 1,
                else => {},
            }
            if (parenthesis_depth == 0) break;
            if (tokens[cursor].tag != .identifier or
                !tokenIs(build_source, tokens[cursor], "root_source_file")) continue;
            var path_call = cursor + 1;
            while (path_call + 1 < tokens.len and path_call - cursor < 12 and
                tokens[path_call].tag != .l_paren) : (path_call += 1)
            {}
            if (path_call + 1 >= tokens.len or path_call - cursor >= 12 or path_call < 1 or
                tokens[path_call - 1].tag != .identifier or
                (!tokenIs(build_source, tokens[path_call - 1], "path") and
                    !tokenIs(build_source, tokens[path_call - 1], "pathFromRoot")) or
                tokens[path_call + 1].tag != .string_literal) continue;
            const path_literal = tokenText(build_source, tokens[path_call + 1]);
            if (path_literal.len < 2) return null;
            return try std.fs.path.resolve(
                allocator,
                &.{ build_directory, path_literal[1 .. path_literal.len - 1] },
            );
        }
        return null;
    }
    return null;
}

fn nearestBuildFile(io: std.Io, allocator: std.mem.Allocator, document_path: []const u8) !?[]const u8 {
    var directory = std.fs.path.dirname(document_path) orelse return null;
    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ directory, "build.zig" });
        if (try pathExists(io, candidate)) return candidate;
        allocator.free(candidate);
        const parent = std.fs.path.dirname(directory) orelse return null;
        if (std.mem.eql(u8, parent, directory)) return null;
        directory = parent;
    }
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

fn pathIsWithin(path: []const u8, directory: []const u8) bool {
    if (!std.mem.startsWith(u8, path, directory)) return false;
    if (path.len == directory.len) return true;
    if (directory.len == 0 or std.fs.path.isSep(directory[directory.len - 1])) return true;
    return std.fs.path.isSep(path[directory.len]);
}

fn containsString(strings: []const []const u8, candidate: []const u8) bool {
    for (strings) |string| if (std.mem.eql(u8, string, candidate)) return true;
    return false;
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }
    return try tokens.toOwnedSlice(allocator);
}

fn tokenText(source: []const u8, token: std.zig.Token) []const u8 {
    return source[token.loc.start..token.loc.end];
}

fn tokenIs(source: []const u8, token: std.zig.Token, expected: []const u8) bool {
    return std.mem.eql(u8, tokenText(source, token), expected);
}

test "build roots are deduplicated and resolved from the build directory" {
    const source: [:0]const u8 =
        "const app = b.addExecutable(.{ .root_source_file = b.path(\"src/main.zig\") });\n" ++
        "const check = b.addTest(.{ .root_source_file = b.path(\"src/main.zig\") });\n" ++
        "const tool = b.addExecutable(.{ .root_source_file = b.pathFromRoot(\"tools/tool.zig\") });\n";
    const roots = try declaredRootSources(std.testing.allocator, source, "/workspace");
    defer {
        for (roots) |root| std.testing.allocator.free(root);
        std.testing.allocator.free(roots);
    }
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqualStrings("/workspace/src/main.zig", roots[0]);
    try std.testing.expectEqualStrings("/workspace/tools/tool.zig", roots[1]);
}

test "root selection follows actual imports and isolates unrelated documents" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "src");
    try temporary.dir.writeFile(io, .{
        .sub_path = "build.zig",
        .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/root.zig") }) });
        \\}
        ,
    });
    try temporary.dir.writeFile(io, .{
        .sub_path = "src/root.zig",
        .data =
        \\const real = @import ("real.zig");
        \\// const commented = @import("unrelated.zig");
        \\const text = "@import(\"unrelated.zig\")";
        \\comptime { _ = real; _ = text; }
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/real.zig", .data = "pub const value = 1;\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "src/unrelated.zig", .data = "pub const value = 2;\n" });

    const temporary_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(temporary_path);
    const root_path = try std.fs.path.resolve(std.testing.allocator, &.{ temporary_path, "src/root.zig" });
    defer std.testing.allocator.free(root_path);
    const real_path = try std.fs.path.resolve(std.testing.allocator, &.{ temporary_path, "src/real.zig" });
    defer std.testing.allocator.free(real_path);
    const unrelated_path = try std.fs.path.resolve(std.testing.allocator, &.{ temporary_path, "src/unrelated.zig" });
    defer std.testing.allocator.free(unrelated_path);

    const real_root = try rootSourceForDocument(io, std.testing.allocator, real_path);
    defer std.testing.allocator.free(real_root);
    try std.testing.expectEqualStrings(root_path, real_root);
    const unrelated_root = try rootSourceForDocument(io, std.testing.allocator, unrelated_path);
    defer std.testing.allocator.free(unrelated_root);
    try std.testing.expectEqualStrings(unrelated_path, unrelated_root);
}

test "example root selection isolates standalone examples" {
    const io = std.testing.io;
    const repository = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);
    const compiler_error = try std.fs.path.join(
        std.testing.allocator,
        &.{ repository, "examples/diagnostics/compiler_error.zig" },
    );
    defer std.testing.allocator.free(compiler_error);
    const memory_management = try std.fs.path.join(
        std.testing.allocator,
        &.{ repository, "examples/diagnostics/memory_management.zig" },
    );
    defer std.testing.allocator.free(memory_management);
    const compiler_example = try std.fs.path.join(
        std.testing.allocator,
        &.{ repository, "examples/compiler/comptime_pipeline.zig" },
    );
    defer std.testing.allocator.free(compiler_example);

    const isolated_root = try rootSourceForDocument(io, std.testing.allocator, compiler_error);
    defer std.testing.allocator.free(isolated_root);
    try std.testing.expectEqualStrings(compiler_error, isolated_root);
    const examples_root = try rootSourceForDocument(io, std.testing.allocator, memory_management);
    defer std.testing.allocator.free(examples_root);
    try std.testing.expect(std.mem.endsWith(u8, examples_root, "examples/examples.zig"));
    const compiler_example_root = try rootSourceForDocument(io, std.testing.allocator, compiler_example);
    defer std.testing.allocator.free(compiler_example_root);
    try std.testing.expectEqualStrings(compiler_example, compiler_example_root);
}

test "named modules resolve their declared root source" {
    const source: [:0]const u8 =
        "const stdx_module = b.addModule(\"stdx\", .{\n" ++
        "    .root_source_file = b.path(\"src/stdx/stdx.zig\"),\n" ++
        "});\n" ++
        "const other = b.addModule(\"other\", .{ .root_source_file = b.path(\"src/other.zig\") });\n";
    const path = (try declaredNamedModuleSource(
        std.testing.allocator,
        source,
        "/workspace",
        "stdx",
    )).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/workspace/src/stdx/stdx.zig", path);
}
