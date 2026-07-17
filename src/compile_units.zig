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
    return try allocator.dupe(u8, if (ambiguous) document_path else selected orelse document_path);
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
