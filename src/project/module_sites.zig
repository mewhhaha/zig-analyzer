//! Resolves where a dotted type expression or an import alias lives on disk:
//! which file, and which container inside it. The token walking is in
//! `syntax_types.zig`; this module adds the filesystem steps (neighbouring
//! imports, named build modules, the standard library) and the module facts
//! the lint rules consume.
const std = @import("std");

const analysis = @import("../analysis.zig");
const compile_units = @import("../compiler/compile_units.zig");
const zig_environment = @import("../compiler/zig_environment.zig");
const document_module = @import("../syntax/document.zig");
const tokens_util = @import("../syntax/tokens.zig");
const syntax_types = @import("../syntax/types.zig");
const uri_module = @import("../uri.zig");
const source_store = @import("source_store.zig");

const Document = document_module.Document;
const TokenRange = syntax_types.TokenRange;

/// A Zig file read for resolution.
pub const File = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: []const std.zig.Token,

    /// The file an open document stands for, or null for a non-file URI.
    pub fn ofDocument(allocator: std.mem.Allocator, document: *const Document) !?File {
        const path = try uri_module.toPath(allocator, document.uri) orelse return null;
        return .{ .path = path, .source = document.source, .tokens = document.tokens };
    }
};

/// A container inside a file.
pub const Site = struct {
    file: File,
    container: TokenRange,
};

/// A place in a file: a declaration's name, or the start of the file.
pub const Target = struct {
    file: File,
    span: std.zig.Token.Loc,

    pub fn startOf(file: File) Target {
        return .{ .file = file, .span = .{ .start = 0, .end = 0 } };
    }
};

/// One name an `@import("...")` string at the cursor could complete to.
pub const ImportCandidate = struct {
    name: []const u8,
    kind: Kind,

    pub const Kind = enum { module, directory, file };
};

pub const ModuleView = struct {
    file: File,
    members: []const syntax_types.Member,
};

const max_hops = 32;
const max_source_bytes = 16 * 1024 * 1024;

/// Files read by a resolver that serves many lookups (the project check), so
/// a module imported by every file is read and tokenized once.
pub const Cache = struct {
    arena: std.heap.ArenaAllocator,
    files: std.StringHashMapUnmanaged(?File) = .empty,
    /// Files whose contents the caller already holds, by path; they are used
    /// instead of reading the disk.
    known: ?*const std.StringHashMapUnmanaged(File) = null,
    /// Parsed files shared between lookups; used instead of reading the disk
    /// when set. The cache holds what it took until `deinit`.
    store: ?*source_store.Store = null,
    held: std.ArrayList(*source_store.Parsed) = .empty,
    /// Records the paths looked up and the build roots consulted, so a caller
    /// can tell what a result depends on (see `forgetTouched`).
    tracing: bool = false,
    touched_files: std.StringHashMapUnmanaged(void) = .empty,
    touched_roots: std.StringHashMapUnmanaged(void) = .empty,
    directory_roots: std.StringHashMapUnmanaged(?[]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(cache: *Cache) void {
        for (cache.held.items) |file| file.release();
        cache.held.deinit(cache.arena.child_allocator);
        cache.arena.deinit();
        cache.* = undefined;
    }

    /// Starts a new tracing window: what was touched so far is forgotten.
    pub fn forgetTouched(cache: *Cache) void {
        cache.touched_files.clearRetainingCapacity();
        cache.touched_roots.clearRetainingCapacity();
    }

    fn touchFile(cache: *Cache, path: []const u8) !void {
        if (!cache.tracing or cache.touched_files.contains(path)) return;
        const stable = try cache.arena.allocator().dupe(u8, path);
        try cache.touched_files.put(cache.arena.allocator(), stable, {});
    }

    /// Notes the build root that decides what named modules `file_path` sees.
    fn touchBuildRoot(cache: *Cache, io: std.Io, file_path: []const u8) !void {
        if (!cache.tracing) return;
        const arena = cache.arena.allocator();
        const directory = std.Io.Dir.path.dirname(file_path) orelse return;
        const known = try cache.directory_roots.getOrPut(arena, directory);
        if (!known.found_existing) {
            known.key_ptr.* = try arena.dupe(u8, directory);
            known.value_ptr.* = null;
            const absolute = try compile_units.absolutePath(io, arena, file_path);
            known.value_ptr.* = try compile_units.nearestBuildRoot(io, arena, absolute);
        }
        const root = known.value_ptr.* orelse return;
        try cache.touched_roots.put(arena, root, {});
    }
};

pub const Resolver = struct {
    io: std.Io,
    cache: ?*Cache = null,
    /// Whether resolving a named module may configure the project's build
    /// (run its build script) when no build graph or stored module table was discovered yet. The CLI
    /// does; the language server leaves discovery to its compiler worker so a
    /// request never waits for it.
    discover_build: bool = false,

    /// The file at `path`, or null when it does not exist. Results of a
    /// cached resolver live as long as the cache; others belong to `allocator`.
    pub fn readFile(resolver: Resolver, allocator: std.mem.Allocator, path: []const u8) !?File {
        const cache = resolver.cache orelse return try resolver.load(allocator, path);
        try cache.touchFile(path);
        if (cache.files.get(path)) |known| return known;
        const stable_path = try cache.arena.allocator().dupe(u8, path);
        const loaded = if (cache.known) |preloaded|
            preloaded.get(path) orelse try resolver.load(cache.arena.allocator(), stable_path)
        else if (cache.store) |store| shared: {
            const file = try store.acquire(resolver.io, path) orelse break :shared null;
            errdefer file.release();
            try cache.held.append(cache.arena.child_allocator, file);
            break :shared File{ .path = stable_path, .source = file.source, .tokens = file.tokens };
        } else try resolver.load(cache.arena.allocator(), stable_path);
        try cache.files.put(cache.arena.allocator(), stable_path, loaded);
        return loaded;
    }

    fn load(resolver: Resolver, allocator: std.mem.Allocator, path: []const u8) !?File {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            resolver.io,
            path,
            allocator,
            .limited(max_source_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(bytes);
        const source = try allocator.dupeSentinel(u8, bytes, 0);
        errdefer allocator.free(source);
        return .{ .path = path, .source = source, .tokens = try tokens_util.tokenize(allocator, source) };
    }

    /// The path an `@import(import_string)` written in the file at
    /// `current_path` names: the standard library, a build module, or a
    /// neighbouring `.zig` file.
    pub fn importPath(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        current_path: []const u8,
        import_string: []const u8,
    ) !?[]const u8 {
        if (std.mem.eql(u8, import_string, "std")) {
            return try allocator.print("{s}/std/std.zig", .{try zig_environment.libDirectory(resolver.io)});
        }
        if (!std.mem.endsWith(u8, import_string, ".zig")) {
            // The compiler provides these itself; a build never names them.
            if (std.mem.eql(u8, import_string, "builtin") or std.mem.eql(u8, import_string, "root")) return null;
            if (resolver.cache) |cache| try cache.touchBuildRoot(resolver.io, current_path);
            return try compile_units.namedModuleSource(
                resolver.io,
                allocator,
                current_path,
                import_string,
                if (resolver.discover_build) .modules else .cached,
            );
        }
        const directory = std.Io.Dir.path.dirname(current_path) orelse return null;
        return try std.Io.Dir.path.resolveAlloc(allocator, &.{ directory, import_string });
    }

    /// The file of the standard library module `a.b` (`std.a.b`), or `std.zig`
    /// itself for the empty name.
    pub fn standardLibraryPath(resolver: Resolver, allocator: std.mem.Allocator, module_name: []const u8) !?[]const u8 {
        const lib_directory = try zig_environment.libDirectory(resolver.io);
        if (module_name.len == 0) return try allocator.print("{s}/std/std.zig", .{lib_directory});
        if (!syntax_types.isDottedIdentifier(module_name)) return null;
        const relative_path = try std.mem.replaceOwned(u8, allocator, module_name, ".", std.Io.Dir.path.sep_str);
        return try allocator.print("{s}/std/{s}.zig", .{ lib_directory, relative_path });
    }

    /// The file `receiver` (an import alias, `std` followed by module names,
    /// or a plain alias) refers to from the origin file's point of view.
    pub fn modulePath(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        origin: File,
        receiver: []const u8,
    ) !?[]const u8 {
        const separator = std.mem.findScalar(u8, receiver, '.');
        const alias = if (separator) |index| receiver[0..index] else receiver;
        const import_name = syntax_types.importName(origin.source, origin.tokens, alias) orelse return null;
        if (std.mem.eql(u8, import_name, "std")) {
            const module_name = if (separator) |index| receiver[index + 1 ..] else "";
            return try resolver.standardLibraryPath(allocator, module_name);
        }
        if (separator != null or std.Io.Dir.path.isAbsolute(import_name)) return null;
        const directory = std.Io.Dir.path.dirname(origin.path) orelse return null;
        return try std.Io.Dir.path.resolveAlloc(allocator, &.{ directory, import_name });
    }

    /// The container the dotted expression names, resolved from the top of
    /// `origin`.
    pub fn originSite(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        origin: File,
        expression: []const u8,
    ) !?Site {
        const segments = try syntax_types.dottedPathSegments(allocator, syntax_types.bareTypeExpression(expression)) orelse return null;
        if (segments.len == 0) return null;
        var pending: std.ArrayList([]const u8) = .empty;
        try pending.appendSlice(allocator, segments);
        return try resolver.descend(allocator, origin, &pending);
    }

    /// The container a qualified type expression such as `types.Headers.View`
    /// names, where the first segment is an import alias of `origin`.
    pub fn importedTypeSite(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        origin: File,
        type_expression: []const u8,
    ) !?Site {
        const segments = try syntax_types.dottedPathSegments(allocator, syntax_types.bareTypeExpression(type_expression)) orelse return null;
        if (segments.len < 2) return null;
        const initial_path = try resolver.modulePath(allocator, origin, segments[0]) orelse return null;
        const file = try resolver.readFile(allocator, initial_path) orelse return null;
        var pending: std.ArrayList([]const u8) = .empty;
        try pending.appendSlice(allocator, segments[1..]);
        return try resolver.descend(allocator, file, &pending);
    }

    /// The container `type_expression` names, resolved from the top of `file`.
    pub fn siteWithin(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        file: File,
        type_expression: []const u8,
    ) !?Site {
        const segments = try syntax_types.dottedPathSegments(allocator, syntax_types.bareTypeExpression(type_expression)) orelse return null;
        var pending: std.ArrayList([]const u8) = .empty;
        try pending.appendSlice(allocator, segments);
        return try resolver.descend(allocator, file, &pending);
    }

    /// Follows `pending` declaration names from the top of `start_file`,
    /// crossing aliases, type functions and imports.
    pub fn descend(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        start_file: File,
        pending: *std.ArrayList([]const u8),
    ) !?Site {
        var file = start_file;
        var container: TokenRange = .{ .start = 0, .end = file.tokens.len };
        var hops: usize = 0;
        while (pending.items.len != 0) : (hops += 1) {
            if (hops == max_hops) return null;
            const target_name = pending.orderedRemove(0);
            const declaration = syntax_types.containerDeclarationNamed(file.source, file.tokens, container, target_name) orelse return null;
            const descent = switch (declaration.kind) {
                .field => return null,
                .function => syntax_types.typeFunctionResult(file.source, file.tokens, declaration.name_index) orelse return null,
                .constant => try syntax_types.constantTarget(allocator, file.source, file.tokens, declaration.name_index) orelse return null,
            };
            switch (descent) {
                .container => |range| container = range,
                .alias_path => |path_text| {
                    const alias_segments = try syntax_types.dottedPathSegments(allocator, path_text) orelse return null;
                    try pending.insertSlice(allocator, 0, alias_segments);
                    container = .{ .start = 0, .end = file.tokens.len };
                },
                .imported_file => |imported| {
                    try pending.insertSlice(allocator, 0, imported.members);
                    const path = try resolver.importPath(allocator, file.path, imported.file) orelse return null;
                    file = try resolver.readFile(allocator, path) orelse return null;
                    container = .{ .start = 0, .end = file.tokens.len };
                },
            }
        }
        return .{ .file = file, .container = container };
    }

    /// The members `receiver` exposes to `origin`: all of them when it names
    /// a container of the same file, only public ones across files.
    pub fn moduleView(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        origin: File,
        receiver: []const u8,
    ) !?ModuleView {
        const site = try resolver.originSite(allocator, origin, receiver) orelse return null;
        return .{
            .file = site.file,
            .members = try syntax_types.containerMembers(
                allocator,
                site.file.source,
                site.file.tokens,
                site.container,
                std.mem.eql(u8, origin.path, site.file.path),
            ),
        };
    }

    /// Where the constant declared at token `binding_index` of `origin`
    /// (`const alias = other.Thing;`) ends up: follows the alias through
    /// containers, type functions and imports to the declaration it names,
    /// or to the last one it could reach.
    pub fn constantAliasTarget(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        origin: File,
        binding_index: usize,
    ) !?Target {
        const tokens = origin.tokens;
        if (binding_index == 0 or tokens[binding_index - 1].tag != .keyword_const) return null;
        var file = origin;
        var container = syntax_types.TokenRange{ .start = 0, .end = tokens.len };
        var pending: std.ArrayList([]const u8) = .empty;
        const initial_target = try syntax_types.constantTarget(
            allocator,
            origin.source,
            tokens,
            binding_index,
        ) orelse return null;
        switch (initial_target) {
            .container => return null,
            .alias_path => |path_text| {
                const segments = try syntax_types.dottedPathSegments(allocator, path_text) orelse return null;
                try pending.appendSlice(allocator, segments);
            },
            .imported_file => |imported| {
                const path = try resolver.importPath(allocator, file.path, imported.file) orelse return null;
                file = try resolver.readFile(allocator, path) orelse return null;
                container = .{ .start = 0, .end = file.tokens.len };
                if (imported.members.len == 0) return Target.startOf(file);
                try pending.appendSlice(allocator, imported.members);
            },
        }

        var last_target: ?Target = null;
        var hops: usize = 0;
        while (pending.items.len != 0) : (hops += 1) {
            if (hops == max_hops) return last_target;
            const target_name = pending.orderedRemove(0);
            const declaration = syntax_types.containerDeclarationNamed(
                file.source,
                file.tokens,
                container,
                target_name,
            ) orelse return last_target;
            last_target = .{ .file = file, .span = file.tokens[declaration.name_index].loc };
            const descent = switch (declaration.kind) {
                .field => return last_target,
                .function => if (pending.items.len == 0)
                    return last_target
                else
                    syntax_types.typeFunctionResult(file.source, file.tokens, declaration.name_index) orelse return last_target,
                .constant => try syntax_types.constantTarget(
                    allocator,
                    file.source,
                    file.tokens,
                    declaration.name_index,
                ) orelse return last_target,
            };
            switch (descent) {
                .container => |range| {
                    if (pending.items.len == 0) return last_target;
                    container = range;
                },
                .alias_path => |path_text| {
                    const segments = try syntax_types.dottedPathSegments(allocator, path_text) orelse return last_target;
                    try pending.insertSlice(allocator, 0, segments);
                    container = .{ .start = 0, .end = file.tokens.len };
                },
                .imported_file => |imported| {
                    try pending.insertSlice(allocator, 0, imported.members);
                    const path = try resolver.importPath(allocator, file.path, imported.file) orelse return last_target;
                    file = try resolver.readFile(allocator, path) orelse return last_target;
                    container = .{ .start = 0, .end = file.tokens.len };
                    if (pending.items.len == 0) return Target.startOf(file);
                },
            }
        }
        return last_target;
    }

    /// Where `member` names a declaration in `@import("file.zig").a.b.member`
    /// written in `origin`.
    pub fn importExpressionMember(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        origin: File,
        identifier_span: std.zig.Token.Loc,
    ) !?Target {
        const tokens = origin.tokens;
        for (tokens, 0..) |token, import_index| {
            if (token.tag != .builtin or import_index + 5 >= tokens.len or
                !std.mem.eql(u8, origin.source[token.loc.start..token.loc.end], "@import") or
                tokens[import_index + 1].tag != .l_paren or
                tokens[import_index + 2].tag != .string_literal or
                tokens[import_index + 3].tag != .r_paren)
            {
                continue;
            }
            var preceding_members: std.ArrayList([]const u8) = .empty;
            defer preceding_members.deinit(allocator);
            var member_index = import_index + 4;
            while (member_index + 1 < tokens.len and
                tokens[member_index].tag == .period and
                tokens[member_index + 1].tag == .identifier) : (member_index += 2)
            {
                const member_token = tokens[member_index + 1];
                if (std.meta.eql(member_token.loc, identifier_span)) {
                    const literal = origin.source[tokens[import_index + 2].loc.start..tokens[import_index + 2].loc.end];
                    if (literal.len < 2) return null;
                    const path = try resolver.importPath(
                        allocator,
                        origin.path,
                        literal[1 .. literal.len - 1],
                    ) orelse return null;
                    const imported = try resolver.readFile(allocator, path) orelse return null;
                    var site = Site{
                        .file = imported,
                        .container = .{ .start = 0, .end = imported.tokens.len },
                    };
                    if (preceding_members.items.len != 0) {
                        var pending: std.ArrayList([]const u8) = .empty;
                        try pending.appendSlice(allocator, preceding_members.items);
                        site = try resolver.descend(allocator, imported, &pending) orelse return null;
                    }
                    const member_name = origin.source[member_token.loc.start..member_token.loc.end];
                    const declaration = syntax_types.containerDeclarationNamed(
                        site.file.source,
                        site.file.tokens,
                        site.container,
                        member_name,
                    ) orelse return null;
                    return .{ .file = site.file, .span = site.file.tokens[declaration.name_index].loc };
                }
                try preceding_members.append(
                    allocator,
                    origin.source[member_token.loc.start..member_token.loc.end],
                );
            }
        }
        return null;
    }

    /// The names an `@import("<prefix>` could complete to: the built-in
    /// modules and the `.zig` files and directories next to `document_path`.
    pub fn importCandidates(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        document_path: []const u8,
        prefix: []const u8,
    ) ![]const ImportCandidate {
        var candidates: std.ArrayList(ImportCandidate) = .empty;
        errdefer candidates.deinit(allocator);
        if (std.mem.findScalar(u8, prefix, '/') == null) {
            for ([_][]const u8{ "std", "builtin", "root" }) |name| {
                if (std.mem.startsWith(u8, name, prefix)) try candidates.append(allocator, .{ .name = name, .kind = .module });
            }
        }
        const document_directory = std.Io.Dir.path.dirname(document_path) orelse return try candidates.toOwnedSlice(allocator);
        const prefix_directory = std.Io.Dir.path.dirname(prefix) orelse "";
        if (std.Io.Dir.path.isAbsolute(prefix_directory)) return try candidates.toOwnedSlice(allocator);
        const directory_path = try std.Io.Dir.path.join(allocator, &.{ document_directory, prefix_directory });
        defer allocator.free(directory_path);
        var directory = std.Io.Dir.openDirAbsolute(resolver.io, directory_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return try candidates.toOwnedSlice(allocator),
            else => return err,
        };
        defer directory.close(resolver.io);
        var iterator = directory.iterateAssumeFirstIteration();
        const basename_prefix = std.Io.Dir.path.basename(prefix);
        while (try iterator.next(resolver.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, basename_prefix)) continue;
            if (entry.kind == .directory) {
                try candidates.append(allocator, .{ .name = try allocator.print("{s}/", .{entry.name}), .kind = .directory });
            } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
                try candidates.append(allocator, .{ .name = try allocator.dupe(u8, entry.name), .kind = .file });
            }
        }
        return try candidates.toOwnedSlice(allocator);
    }

    /// The start of the file an `@import(import_string)` written in the file
    /// at `current_path` names.
    pub fn importedFileStart(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        current_path: []const u8,
        import_string: []const u8,
    ) !?Target {
        const path = try resolver.importPath(allocator, current_path, import_string) orelse return null;
        const file = try resolver.readFile(allocator, path) orelse return null;
        return Target.startOf(file);
    }

    /// The module facts lint rules need for `origin`: for every top-level
    /// constant that resolves to a container in another file, the public names
    /// it exposes. Containers of the same file are judged by the container
    /// rules, and constants that do not resolve are left out so rules cannot
    /// judge them.
    pub fn fileModules(
        resolver: Resolver,
        allocator: std.mem.Allocator,
        origin: File,
    ) ![]const analysis.ModuleMembers {
        var modules: std.ArrayList(analysis.ModuleMembers) = .empty;
        errdefer modules.deinit(allocator);
        var brace_depth: usize = 0;
        for (origin.tokens, 0..) |token, index| {
            switch (token.tag) {
                .l_brace => brace_depth += 1,
                .r_brace => brace_depth -|= 1,
                else => {},
            }
            if (brace_depth != 0 or token.tag != .keyword_const or index + 2 >= origin.tokens.len) continue;
            const name_token = origin.tokens[index + 1];
            if (name_token.tag != .identifier or origin.tokens[index + 2].tag != .equal) continue;
            const name = origin.source[name_token.loc.start..name_token.loc.end];
            const view = (resolver.moduleView(allocator, origin, name) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    std.log.warn("module facts for '{s}' unavailable: {t}", .{ name, err });
                    continue;
                },
            }) orelse continue;
            if (std.mem.eql(u8, view.file.path, origin.path)) continue;
            const names = try allocator.alloc([]const u8, view.members.len);
            for (view.members, names) |member, *member_name| member_name.* = member.name;
            try modules.append(allocator, .{ .receiver = name, .members = names });
        }
        return try modules.toOwnedSlice(allocator);
    }
};
