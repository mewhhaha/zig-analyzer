//! Which declarations of each project file the build's module roots expose,
//! for `public-declaration-docs`. A package's API is what its build script
//! publishes (`b.addModule`, the root module of `b.addLibrary`) and what
//! those roots re-export through `pub` declarations, not every `pub`
//! declaration of every file: an executable's files publish nothing.
const std = @import("std");
const tokens_util = @import("../../syntax/tokens.zig");
const types = @import("../types.zig");
const import_graph = @import("import_graph.zig");
const run_module = @import("run.zig");
const tokenText = tokens_util.tokenText;
const tokenIs = tokens_util.tokenIs;
const tokenize = tokens_util.tokenize;
const matchingToken = tokens_util.matchingToken;
const statementEnd = tokens_util.statementEnd;
const resolveImportPath = import_graph.resolveImportPath;
const stringValue = import_graph.stringValue;

const SourceFile = run_module.SourceFile;
const ModuleExposure = types.ModuleExposure;

/// The exposure of each of `files`, in order. A file of a package whose build
/// script names every module it exports is exposed as far as those modules'
/// roots, and the build script itself, re-export it through `pub`
/// declarations; any other file is judged on its own (`.whole`). Allocates
/// from `arena` without freeing.
pub fn exposures(arena: std.mem.Allocator, files: []const SourceFile) ![]const ModuleExposure {
    var packages: std.array_hash_map.String(Package) = .empty;
    for (files, 0..) |file, file_index| {
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(file.path), "build.zig")) continue;
        try packages.put(arena, std.Io.Dir.path.dirname(file.path) orelse "", .{ .build_file = file_index });
    }
    const result = try arena.alloc(ModuleExposure, files.len);
    @memset(result, .whole);
    if (packages.count() == 0) return result;

    var graph: ExposureGraph = try .init(arena, files);
    for (packages.keys(), packages.values()) |directory, *package| try graph.findRoots(directory, package);
    for (packages.values()) |package| {
        if (!package.known) continue;
        try graph.expose(package.build_file, null);
        for (package.roots.items) |root| try graph.expose(root, null);
    }
    try graph.propagate();

    for (files, graph.reach, result) |file, reached, *exposure| {
        const package = owningPackage(&packages, file.path) orelse continue;
        if (!package.known) continue;
        const reach = reached orelse {
            exposure.* = .none;
            continue;
        };
        if (reach.whole) continue;
        exposure.* = .{ .declarations = reach.declarations.keys() };
    }
    return result;
}

const Package = struct {
    build_file: usize,
    /// Whether the build script names the root file of every module it
    /// exports; when it does not, the package's files are judged on their own.
    known: bool = true,
    roots: std.ArrayList(usize) = .empty,
};

/// The package of the nearest directory holding a `build.zig`.
fn owningPackage(packages: *const std.array_hash_map.String(Package), path: []const u8) ?*const Package {
    var directory = std.Io.Dir.path.dirname(path) orelse "";
    while (true) {
        if (packages.getPtr(directory)) |package| return package;
        if (directory.len == 0) return null;
        directory = std.Io.Dir.path.dirname(directory) orelse "";
    }
}

/// How far the module roots reach into one file.
const Reach = struct {
    whole: bool = false,
    declarations: std.array_hash_map.String(void) = .empty,
};

const ExposureGraph = struct {
    arena: std.mem.Allocator,
    files: []const SourceFile,
    tokens: []const []const std.zig.Token,
    by_path: std.StringHashMapUnmanaged(usize) = .empty,
    /// How far the module roots reach into each file; null for files they
    /// do not reach.
    reach: []?Reach,
    /// Files whose reach grew since they were last scanned.
    pending: std.ArrayList(usize) = .empty,
    queued: []bool,

    fn init(arena: std.mem.Allocator, files: []const SourceFile) !ExposureGraph {
        const all_tokens = try arena.alloc([]const std.zig.Token, files.len);
        for (files, all_tokens) |file, *tokens| tokens.* = file.tokens orelse try tokenize(arena, file.source);
        const queued = try arena.alloc(bool, files.len);
        @memset(queued, false);
        const reach = try arena.alloc(?Reach, files.len);
        @memset(reach, null);
        var graph: ExposureGraph = .{ .arena = arena, .files = files, .tokens = all_tokens, .reach = reach, .queued = queued };
        for (files, 0..) |file, file_index| try graph.by_path.put(arena, file.path, file_index);
        return graph;
    }

    /// The project file `spelling` names when `importing` imports it.
    fn imported(graph: *const ExposureGraph, importing: usize, spelling: []const u8) !?usize {
        if (!std.mem.endsWith(u8, spelling, ".zig")) return null;
        return graph.by_path.get(try resolveImportPath(graph.arena, graph.files[importing].path, spelling));
    }

    /// Records the module roots the build script of the package in
    /// `directory` exports, reading `build.zig` and the files it imports.
    fn findRoots(graph: *ExposureGraph, directory: []const u8, package: *Package) !void {
        var scripts: std.ArrayList(usize) = .empty;
        var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
        try scripts.append(graph.arena, package.build_file);
        try seen.put(graph.arena, package.build_file, {});
        var next: usize = 0;
        while (next < scripts.items.len) : (next += 1) {
            const file_index = scripts.items[next];
            const source = graph.files[file_index].source;
            const tokens = graph.tokens[file_index];
            for (tokens, 0..) |token, index| {
                if (token.tag == .builtin and tokenIs(source, token, "@import") and index + 2 < tokens.len and
                    tokens[index + 1].tag == .l_paren and tokens[index + 2].tag == .string_literal)
                {
                    const spelling = stringValue(source, tokens[index + 2]) orelse continue;
                    const script = try graph.imported(file_index, spelling) orelse continue;
                    if ((try seen.getOrPut(graph.arena, script)).found_existing) continue;
                    try scripts.append(graph.arena, script);
                    continue;
                }
                if (token.tag != .identifier or index == 0 or tokens[index - 1].tag != .period or
                    index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren) continue;
                const arguments_end = matchingToken(tokens, index + 1, .l_paren, .r_paren) orelse continue;
                if (tokenIs(source, token, "addModule")) {
                    // A module dependents import: its root must be known.
                    const root = try graph.rootSourceFile(file_index, directory, index + 1, arguments_end) orelse {
                        package.known = false;
                        return;
                    };
                    try package.roots.append(graph.arena, root);
                } else if (tokenIs(source, token, "addLibrary")) {
                    // A library publishes the symbols it exports, so a root
                    // module it names elsewhere is only looked up nearby.
                    const root = try graph.libraryRoot(file_index, directory, index + 1, arguments_end) orelse continue;
                    try package.roots.append(graph.arena, root);
                }
            }
        }
    }

    /// The file `.root_source_file = b.path("...")` names among the arguments
    /// between `opening` and `closing`, relative to the build root
    /// `directory`; null when the field is missing or not a literal path.
    fn rootSourceFile(graph: *ExposureGraph, file_index: usize, directory: []const u8, opening: usize, closing: usize) !?usize {
        const source = graph.files[file_index].source;
        const tokens = graph.tokens[file_index];
        const value = fieldValue(source, tokens, opening, closing, "root_source_file") orelse return null;
        if (value + 5 >= closing or tokens[value].tag != .identifier or tokens[value + 1].tag != .period or
            !tokenIs(source, tokens[value + 2], "path") or tokens[value + 3].tag != .l_paren or
            tokens[value + 4].tag != .string_literal or tokens[value + 5].tag != .r_paren) return null;
        const literal = stringValue(source, tokens[value + 4]) orelse return null;
        const absolute = try std.Io.Dir.path.resolveAlloc(graph.arena, &.{ "/", directory, literal });
        return graph.by_path.get(std.mem.trimStart(u8, absolute, "/"));
    }

    /// The root file of the `.root_module` an `addLibrary` call between
    /// `opening` and `closing` names: a `createModule` or `addModule` call in
    /// place, or a constant of the same file initialized by one.
    fn libraryRoot(graph: *ExposureGraph, file_index: usize, directory: []const u8, opening: usize, closing: usize) !?usize {
        const source = graph.files[file_index].source;
        const tokens = graph.tokens[file_index];
        const value = fieldValue(source, tokens, opening, closing, "root_module") orelse return null;
        var call = value;
        if (tokens[value].tag == .identifier and value + 1 < closing and
            (tokens[value + 1].tag == .comma or tokens[value + 1].tag == .r_brace))
        {
            // The nearest declaration before the call, as helper functions
            // reuse one local name for each artifact's module.
            const name = tokenText(source, tokens[value]);
            var index = opening;
            call = while (index > 0) {
                index -= 1;
                if (tokens[index].tag == .keyword_const and tokens[index + 2].tag == .equal and
                    tokenIs(source, tokens[index + 1], name)) break index + 3;
            } else return null;
        }
        while (call + 2 < tokens.len and tokens[call].tag == .identifier and tokens[call + 1].tag == .period) call += 2;
        if (call + 1 >= tokens.len or tokens[call + 1].tag != .l_paren or
            (!tokenIs(source, tokens[call], "createModule") and !tokenIs(source, tokens[call], "addModule"))) return null;
        const call_end = matchingToken(tokens, call + 1, .l_paren, .r_paren) orelse return null;
        return graph.rootSourceFile(file_index, directory, call + 1, call_end);
    }

    /// Marks `member` of the file at `file_index`, or the whole file when
    /// null, as reached, and queues the file when that is new.
    fn expose(graph: *ExposureGraph, file_index: usize, member: ?[]const u8) !void {
        if (graph.reach[file_index] == null) graph.reach[file_index] = .{};
        const reach = &graph.reach[file_index].?;
        if (reach.whole) return;
        if (member) |name| {
            if ((try reach.declarations.getOrPut(graph.arena, name)).found_existing) return;
        } else {
            reach.whole = true;
        }
        if (graph.queued[file_index]) return;
        graph.queued[file_index] = true;
        try graph.pending.append(graph.arena, file_index);
    }

    fn propagate(graph: *ExposureGraph) !void {
        var next: usize = 0;
        while (next < graph.pending.items.len) : (next += 1) {
            const file_index = graph.pending.items[next];
            graph.queued[file_index] = false;
            try graph.scan(file_index);
        }
    }

    /// Follows the imports the reached `pub` constants of a file re-export:
    /// `pub const a = @import("a.zig");`, `pub const B = @import("b.zig").B;`
    /// and `pub const C = impl.C;` through a private `const impl = @import(...)`.
    fn scan(graph: *ExposureGraph, file_index: usize) !void {
        const source = graph.files[file_index].source;
        const tokens = graph.tokens[file_index];
        const reach = &graph.reach[file_index].?;
        var aliases: std.StringHashMapUnmanaged(Alias) = .empty;
        var depth: usize = 0;
        for (tokens, 0..) |token, index| switch (token.tag) {
            .l_brace => depth += 1,
            .r_brace => depth -|= 1,
            .keyword_const => if (depth == 0 and index + 3 < tokens.len and declaresConstant(tokens, index) and
                tokens[index + 2].tag == .equal)
            {
                const target = try graph.importAt(file_index, index + 3) orelse continue;
                try aliases.put(graph.arena, tokenText(source, tokens[index + 1]), target);
            },
            else => {},
        };

        // Each open brace records whether it is the body of a container a
        // reached `pub` constant declares, so nested re-exports count only
        // inside reached containers.
        var public_braces: std.ArrayList(bool) = .empty;
        var top_level_reached = false;
        for (tokens, 0..) |token, index| switch (token.tag) {
            .l_brace => {
                const enclosing = if (public_braces.items.len == 0) top_level_reached else public_braces.last().?;
                try public_braces.append(graph.arena, enclosing and opensPublicContainer(tokens, index));
            },
            .r_brace => _ = public_braces.pop(),
            .keyword_const => {
                if (index + 2 >= tokens.len or !declaresConstant(tokens, index)) continue;
                const public = index > 0 and tokens[index - 1].tag == .keyword_pub;
                if (public_braces.items.len == 0) {
                    top_level_reached = public and (reach.whole or reach.declarations.contains(tokenText(source, tokens[index + 1])));
                    if (!top_level_reached) continue;
                } else if (!public or !public_braces.last().?) continue;
                try graph.followInitializer(file_index, index + 2, &aliases);
            },
            else => {},
        };
    }

    /// Exposes what the initializer of the constant whose name precedes
    /// `after_name` selects from other files, skipping container bodies,
    /// whose declarations `scan` reaches on their own.
    fn followInitializer(graph: *ExposureGraph, file_index: usize, after_name: usize, aliases: *const std.StringHashMapUnmanaged(Alias)) !void {
        const source = graph.files[file_index].source;
        const tokens = graph.tokens[file_index];
        const end = statementEnd(tokens, after_name) orelse return;
        var index = after_name;
        while (index < end) : (index += 1) {
            switch (tokens[index].tag) {
                .l_brace => if (index > 0 and opensContainer(tokens, index)) {
                    index = matchingToken(tokens, index, .l_brace, .r_brace) orelse return;
                },
                .builtin => {
                    const target = try graph.importAt(file_index, index) orelse continue;
                    try graph.expose(target.file_index, target.member);
                },
                .identifier => {
                    if (tokens[index - 1].tag == .period) continue;
                    const target = aliases.get(tokenText(source, tokens[index])) orelse continue;
                    const member = target.member orelse if (index + 2 < tokens.len and tokens[index + 1].tag == .period and
                        tokens[index + 2].tag == .identifier) tokenText(source, tokens[index + 2]) else null;
                    try graph.expose(target.file_index, member);
                },
                else => {},
            }
        }
    }

    /// The file, and the first member selected from it, of an
    /// `@import("x.zig").Member` expression starting at `index`.
    fn importAt(graph: *ExposureGraph, file_index: usize, index: usize) !?Alias {
        const source = graph.files[file_index].source;
        const tokens = graph.tokens[file_index];
        if (tokens[index].tag != .builtin or !tokenIs(source, tokens[index], "@import") or index + 3 >= tokens.len or
            tokens[index + 1].tag != .l_paren or tokens[index + 2].tag != .string_literal or
            tokens[index + 3].tag != .r_paren) return null;
        const spelling = stringValue(source, tokens[index + 2]) orelse return null;
        const target = try graph.imported(file_index, spelling) orelse return null;
        const member = if (index + 5 < tokens.len and tokens[index + 4].tag == .period and tokens[index + 5].tag == .identifier)
            tokenText(source, tokens[index + 5])
        else
            null;
        return .{ .file_index = target, .member = member };
    }
};

/// Whether the `const` at `index` starts a declaration rather than a pointer
/// or slice type (`[]const u8`).
fn declaresConstant(tokens: []const std.zig.Token, index: usize) bool {
    if (index + 1 >= tokens.len or tokens[index + 1].tag != .identifier) return false;
    if (index == 0) return true;
    return switch (tokens[index - 1].tag) {
        .keyword_pub, .semicolon, .l_brace, .r_brace, .comma, .doc_comment, .container_doc_comment => true,
        else => false,
    };
}

/// A file a top-level constant imports, and the member it selects, if any.
const Alias = struct {
    file_index: usize,
    member: ?[]const u8,
};

/// The value token of `.name = value` among the arguments between `opening`
/// and `closing`.
fn fieldValue(source: []const u8, tokens: []const std.zig.Token, opening: usize, closing: usize, name: []const u8) ?usize {
    var index = opening + 1;
    while (index + 3 < closing) : (index += 1) {
        if (tokens[index].tag == .period and tokens[index + 1].tag == .identifier and
            tokens[index + 2].tag == .equal and tokenIs(source, tokens[index + 1], name)) return index + 3;
    }
    return null;
}

/// Whether the brace at `opening` opens a container body: `struct {`,
/// `enum(u8) {`, `union(enum) {`.
fn opensContainer(tokens: []const std.zig.Token, opening: usize) bool {
    return containerKeyword(tokens, opening) != null;
}

fn containerKeyword(tokens: []const std.zig.Token, opening: usize) ?usize {
    if (opening == 0) return null;
    var keyword = opening - 1;
    if (tokens[keyword].tag == .r_paren) {
        var depth: usize = 0;
        while (keyword > 0) : (keyword -= 1) {
            switch (tokens[keyword].tag) {
                .r_paren => depth += 1,
                .l_paren => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
        }
        if (keyword == 0) return null;
        keyword -= 1;
    }
    return switch (tokens[keyword].tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => keyword,
        else => null,
    };
}

/// Whether the brace at `opening` opens the body of `pub const Name = struct {`.
fn opensPublicContainer(tokens: []const std.zig.Token, opening: usize) bool {
    var cursor = containerKeyword(tokens, opening) orelse return false;
    if (cursor > 0 and (tokens[cursor - 1].tag == .keyword_extern or tokens[cursor - 1].tag == .keyword_packed)) cursor -= 1;
    return cursor >= 4 and tokens[cursor - 1].tag == .equal and tokens[cursor - 2].tag == .identifier and
        tokens[cursor - 3].tag == .keyword_const and tokens[cursor - 4].tag == .keyword_pub;
}

fn exposureOf(found: []const ModuleExposure, files: []const SourceFile, path: []const u8) ModuleExposure {
    for (files, found) |file, exposure| if (std.mem.eql(u8, file.path, path)) return exposure;
    unreachable;
}

fn expectDeclarations(exposure: ModuleExposure, expected: []const []const u8) !void {
    try std.testing.expect(exposure == .declarations);
    try std.testing.expectEqual(expected.len, exposure.declarations.len);
    for (expected, exposure.declarations) |name, declaration| try std.testing.expectEqualStrings(name, declaration);
}

test "an application's files expose nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{
        .{ .path = "build.zig", .source =
        \\pub fn build(b: *std.Build) void {
        \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") }) });
        \\    _ = exe;
        \\}
        },
        .{ .path = "src/main.zig", .source = "pub const util = @import(\"util.zig\"); pub fn main() void {}" },
        .{ .path = "src/util.zig", .source = "pub fn helper() void {}" },
        .{ .path = "vendor/lib.zig", .source = "pub fn vendored() void {}" },
    };
    const found = try exposures(arena.allocator(), &files);
    try std.testing.expect(exposureOf(found, &files, "build.zig") == .whole);
    try std.testing.expect(exposureOf(found, &files, "src/main.zig") == .none);
    try std.testing.expect(exposureOf(found, &files, "src/util.zig") == .none);
    try std.testing.expect(exposureOf(found, &files, "vendor/lib.zig") == .none);
}

test "a library exposes what its module roots re-export" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{
        .{ .path = "build.zig", .source =
        \\const helpers = @import("build/helpers.zig");
        \\pub fn build(b: *std.Build) void { helpers.modules(b); }
        },
        .{ .path = "build/helpers.zig", .source =
        \\fn executable(b: *std.Build) void {
        \\    const c_module = b.createModule(.{ .root_source_file = b.path("src/main.zig") });
        \\    _ = b.addExecutable(.{ .name = "app", .root_module = c_module });
        \\}
        \\pub fn modules(b: *std.Build) void {
        \\    _ = b.addModule("lib", .{ .root_source_file = b.path("src/root.zig") });
        \\    const c_module = b.createModule(.{ .root_source_file = b.path("src/c.zig") });
        \\    _ = b.addLibrary(.{ .name = "c", .root_module = c_module });
        \\}
        },
        .{ .path = "src/root.zig", .source =
        \\const impl = @import("impl.zig");
        \\const Picked = @import("picked.zig").Picked;
        \\const internal = @import("internal.zig");
        \\pub const whole = @import("whole.zig");
        \\pub const Member = @import("member.zig").Member;
        \\pub const Api = impl.Api;
        \\pub const Chosen = Picked;
        \\pub const Nested = struct { pub const deep = @import("deep.zig"); };
        \\const Private = struct { pub const hidden = @import("hidden.zig"); };
        \\pub fn run() void { internal.go(); }
        },
        .{ .path = "src/impl.zig", .source = "pub const Api = struct {}; pub fn other() void {}" },
        .{ .path = "src/picked.zig", .source = "pub const Picked = struct {};" },
        .{ .path = "src/internal.zig", .source = "pub fn go() void {}" },
        .{ .path = "src/whole.zig", .source = "pub fn all() void {}" },
        .{ .path = "src/member.zig", .source = "pub const Member = struct {}; pub const Next = @import(\"next.zig\");" },
        .{ .path = "src/next.zig", .source = "pub fn unreached() void {}" },
        .{ .path = "src/deep.zig", .source = "pub fn deep() void {}" },
        .{ .path = "src/hidden.zig", .source = "pub fn hidden() void {}" },
        .{ .path = "src/c.zig", .source = "pub fn exported() void {}" },
        .{ .path = "src/main.zig", .source = "pub fn helper() void {}" },
    };
    const found = try exposures(arena.allocator(), &files);
    try std.testing.expect(exposureOf(found, &files, "src/root.zig") == .whole);
    try std.testing.expect(exposureOf(found, &files, "src/whole.zig") == .whole);
    try std.testing.expect(exposureOf(found, &files, "src/deep.zig") == .whole);
    try std.testing.expect(exposureOf(found, &files, "src/c.zig") == .whole);
    try expectDeclarations(exposureOf(found, &files, "src/impl.zig"), &.{"Api"});
    try expectDeclarations(exposureOf(found, &files, "src/picked.zig"), &.{"Picked"});
    try expectDeclarations(exposureOf(found, &files, "src/member.zig"), &.{"Member"});
    try std.testing.expect(exposureOf(found, &files, "src/internal.zig") == .none);
    try std.testing.expect(exposureOf(found, &files, "src/next.zig") == .none);
    try std.testing.expect(exposureOf(found, &files, "src/hidden.zig") == .none);
    try std.testing.expect(exposureOf(found, &files, "src/main.zig") == .none);
}

test "files are judged on their own without a known module root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]SourceFile{
        .{ .path = "build.zig", .source =
        \\pub fn build(b: *std.Build) void { _ = b.addModule("lib", .{ .root_source_file = root_path }); }
        },
        .{ .path = "src/root.zig", .source = "pub fn api() void {}" },
        .{ .path = "pkg/build.zig", .source =
        \\pub fn build(b: *std.Build) void { _ = b.addModule("pkg", .{ .root_source_file = b.path("main.zig") }); }
        },
        .{ .path = "pkg/main.zig", .source = "pub fn packaged() void {}" },
        .{ .path = "pkg/unused.zig", .source = "pub fn unused() void {}" },
    };
    const found = try exposures(arena.allocator(), &files);
    try std.testing.expect(exposureOf(found, &files, "src/root.zig") == .whole);
    try std.testing.expect(exposureOf(found, &files, "pkg/main.zig") == .whole);
    try std.testing.expect(exposureOf(found, &files, "pkg/unused.zig") == .none);

    const loose = [_]SourceFile{.{ .path = "lib/thing.zig", .source = "pub fn thing() void {}" }};
    try std.testing.expect((try exposures(arena.allocator(), &loose))[0] == .whole);
}
