//! The compile units a project's build script declares, as the analyzer sees
//! them: for each compile step, its module graph (import name to module root
//! source), target, and optimization mode. A graph is immutable once built and
//! shared by reference count; it answers which units contain a file and lowers
//! a unit to patched-compiler arguments.
const std = @import("std");

const tokens_util = @import("../syntax/tokens.zig");
const generated_sources = @import("generated_sources.zig");

pub const Unavailable = generated_sources.Unavailable;

/// What a compile step builds. Test kinds are analyzed with `test-obj` so
/// their `test` blocks are checked too.
pub const Kind = enum {
    exe,
    lib,
    obj,
    @"test",
    test_obj,

    pub fn isTest(kind: Kind) bool {
        return kind == .@"test" or kind == .test_obj;
    }
};

/// The top-level build step the units were discovered from.
pub const Selection = enum { check, install };

/// Where a module's root source comes from.
pub const Source = union(enum) {
    /// A file in the source tree or in a dependency package.
    file: []const u8,
    /// A file the analyzer produced from a generation step.
    generated: generated_sources.Generated,
    /// Produced by a step the analyzer does not run; the module is analyzed
    /// without.
    unavailable: Unavailable,
    /// No Zig root (C or assembly objects only).
    none,

    /// The absolute path of the root source when the analyzer has one.
    pub fn path(source: Source) ?[]const u8 {
        return switch (source) {
            .file => |file| file,
            .generated => |generated| generated.path,
            .unavailable, .none => null,
        };
    }
};

/// What the analyzer tells the user about their build, once per project.
pub const Notice = struct {
    level: enum { information, warning },
    text: []const u8,
};

/// A module the unit imports under `import_name` that the analyzer cannot
/// provide. Compiler errors saying the import does not resolve are the
/// expected consequence, not mistakes in the user's code.
pub const UnavailableImport = struct {
    import_name: []const u8,
    /// Name of the step that would have produced the module.
    step: []const u8,
    reason: []const u8,
};

pub const Import = struct {
    /// The name written in `@import("name")`.
    name: []const u8,
    /// Index into `Unit.modules`.
    module: u32,
};

pub const Target = struct {
    triple: []const u8,
    cpu: []const u8,
};

pub const Module = struct {
    /// Unique name on the compiler command line; `root` for a unit's root.
    name: []const u8,
    source: Source,
    imports: []const Import,
    /// Null when the module builds for the host.
    target: ?Target = null,
    /// Null when the build script leaves the mode to the compiler default.
    optimize: ?std.lang.Optimize = null,
    link_libc: bool = false,
};

pub const Unit = struct {
    /// The compile step's name, e.g. `compile exe zig-analyzer debug native`.
    name: []const u8,
    kind: Kind,
    /// Every module reachable from the root; index 0 is the root module.
    modules: []const Module,

    pub fn root(unit: *const Unit) *const Module {
        return &unit.modules[0];
    }

    /// The imports of this unit's modules that name unavailable modules, one
    /// per import name. Owned by `arena`.
    pub fn unavailableImports(unit: *const Unit, arena: std.mem.Allocator) ![]const UnavailableImport {
        var found: std.ArrayList(UnavailableImport) = .empty;
        for (unit.modules) |module| {
            for (module.imports) |import| {
                const unavailable = switch (unit.modules[import.module].source) {
                    .unavailable => |unavailable| unavailable,
                    else => continue,
                };
                const known = for (found.items) |entry| {
                    if (std.mem.eql(u8, entry.import_name, import.name)) break true;
                } else false;
                if (known) continue;
                try found.append(arena, .{
                    .import_name = try arena.dupe(u8, import.name),
                    .step = try arena.dupe(u8, unavailable.step),
                    .reason = try arena.dupe(u8, unavailable.reason),
                });
            }
        }
        return found.items;
    }

    /// The module `import_name` names inside `module`, if it imports one.
    pub fn imported(unit: *const Unit, module: *const Module, import_name: []const u8) ?*const Module {
        for (module.imports) |import| {
            if (std.mem.eql(u8, import.name, import_name)) return &unit.modules[import.module];
        }
        return null;
    }
};

/// Arguments that make the patched compiler analyze one unit.
pub const Launch = struct {
    /// The `zig` subcommand: `build-obj`, or `test-obj` for test units.
    command: []const u8,
    /// Everything between the command and the flags every analysis shares:
    /// target, optimization, `--dep` and `-M` module arguments.
    arguments: []const []const u8,

    /// Identifies the analysis these arguments request: equal launches start
    /// the same compile.
    pub fn fingerprint(launch: Launch) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(launch.command);
        for (launch.arguments) |argument| {
            hasher.update(argument);
            hasher.update("\x00");
        }
        return hasher.final();
    }

    /// A single file with no module graph.
    pub fn standalone(arena: std.mem.Allocator, path: []const u8) !Launch {
        return .{ .command = "build-obj", .arguments = try arena.dupe([]const u8, &.{path}) };
    }
};

/// Most files followed from one module root when asking what it contains.
const max_reachable_files = 8192;
const max_source_bytes = 4 * 1024 * 1024;

pub const BuildGraph = struct {
    /// Owns everything the graph and the units point to.
    arena: std.heap.ArenaAllocator,
    references: std.atomic.Value(u32) = .init(1),
    build_root: []const u8 = "",
    /// Null when discovery failed.
    selection: ?Selection = null,
    units: []const Unit = &.{},
    /// Why the build script could not be configured.
    failure: ?[]const u8 = null,
    /// What the analyzer could not provide (unavailable modules, units
    /// skipped).
    notices: []const Notice = &.{},
    /// Whether `takeNotices` already handed out the messages.
    reported: std.atomic.Value(bool) = .init(false),
    /// Restored from `NamedModules`: it knows which module each import names
    /// but nothing about targets or launches, so it only answers
    /// `importedModuleSource`.
    modules_only: bool = false,

    reach_mutex: std.Io.Mutex = .init,
    /// Files each module root reaches through relative imports, keyed by the
    /// root path. Filled on demand.
    reach: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty,

    /// The graph starts with one reference, owned by the caller.
    pub fn create(backing: std.mem.Allocator) !*BuildGraph {
        const graph = try backing.create(BuildGraph);
        graph.* = .{ .arena = .init(backing) };
        return graph;
    }

    pub fn retain(graph: *BuildGraph) *BuildGraph {
        _ = graph.references.fetchAdd(1, .monotonic);
        return graph;
    }

    pub fn release(graph: *BuildGraph) void {
        if (graph.references.fetchSub(1, .acq_rel) != 1) return;
        const backing = graph.arena.child_allocator;
        graph.arena.deinit();
        backing.destroy(graph);
    }

    /// The failure and notice lines the first caller has not seen yet, so a
    /// project is told about its build problems once, not per document.
    pub fn takeNotices(graph: *BuildGraph, arena: std.mem.Allocator) ![]const Notice {
        if (graph.reported.swap(true, .acq_rel)) return &.{};
        var notices: std.ArrayList(Notice) = .empty;
        if (graph.failure) |failure| {
            try notices.append(arena, .{
                .level = .warning,
                .text = try arena.print("could not configure the build in {s}; analyzing files on their own: {s}", .{ graph.build_root, failure }),
            });
        }
        for (graph.notices) |notice| try notices.append(arena, .{ .level = notice.level, .text = try arena.dupe(u8, notice.text) });
        return notices.items;
    }

    /// The units whose module graph contains `file`, in build-step order.
    pub fn unitsContaining(
        graph: *BuildGraph,
        io: std.Io,
        allocator: std.mem.Allocator,
        file: []const u8,
    ) ![]const *const Unit {
        var found: std.ArrayList(*const Unit) = .empty;
        errdefer found.deinit(allocator);
        for (graph.units) |*unit| {
            for (unit.modules) |*module| {
                if (try graph.moduleContains(io, module, file)) {
                    try found.append(allocator, unit);
                    break;
                }
            }
        }
        return found.toOwnedSlice(allocator);
    }

    /// Every source file `unit` reaches: its module roots and the files they
    /// import by relative path. Owned by `allocator`; the paths are copies.
    pub fn unitFiles(
        graph: *BuildGraph,
        io: std.Io,
        allocator: std.mem.Allocator,
        unit: *const Unit,
    ) ![]const []const u8 {
        var files: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (files.items) |file| allocator.free(file);
            files.deinit(allocator);
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        graph.reach_mutex.lockUncancelable(io);
        defer graph.reach_mutex.unlock(io);
        for (unit.modules) |module| {
            const root_path = module.source.path() orelse continue;
            const entry = try graph.reach.getOrPut(graph.arena.allocator(), root_path);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
                try graph.collectReach(io, root_path, entry.value_ptr);
            }
            var reached = entry.value_ptr.keyIterator();
            while (reached.next()) |file| {
                if ((try seen.getOrPut(allocator, file.*)).found_existing) continue;
                const copy = try allocator.dupe(u8, file.*);
                errdefer allocator.free(copy);
                try files.append(allocator, copy);
            }
        }
        return files.toOwnedSlice(allocator);
    }

    /// Identifies how `unit` analyzes `file`: whether it is a test build, and
    /// the configuration (root source, target, optimization, libc, and the same
    /// for every module it imports) of each module that contains the file.
    /// Units with equal keys analyze the file identically, so comparing one of
    /// them stands for all.
    pub fn analysisKey(graph: *BuildGraph, io: std.Io, allocator: std.mem.Allocator, unit: *const Unit, file: []const u8) !u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, unit.kind.isTest());
        const visited = try allocator.alloc(bool, unit.modules.len);
        defer allocator.free(visited);
        @memset(visited, false);
        for (unit.modules, 0..) |*module, index| {
            if (!try graph.moduleContains(io, module, file)) continue;
            hashModule(&hasher, unit, index, visited);
        }
        return hasher.final();
    }

    /// The unit that analyzes `file` for the editor: one whose root source is
    /// the file, else the first containing unit that is not a test unit, else
    /// the first containing test unit.
    pub fn unitFor(graph: *BuildGraph, io: std.Io, file: []const u8) !?*const Unit {
        var first_test: ?*const Unit = null;
        var first_other: ?*const Unit = null;
        for (graph.units) |*unit| {
            if (unit.root().source.path()) |root_path| {
                if (std.mem.eql(u8, root_path, file)) return unit;
            }
        }
        for (graph.units) |*unit| {
            var contains = false;
            for (unit.modules) |*module| {
                if (try graph.moduleContains(io, module, file)) {
                    contains = true;
                    break;
                }
            }
            if (!contains) continue;
            if (unit.kind.isTest()) {
                if (first_test == null) first_test = unit;
            } else if (first_other == null) first_other = unit;
        }
        return first_other orelse first_test;
    }

    /// The root source of the module `import_name` names when written in
    /// `file`, resolved through the build graph. Null when `file` belongs to
    /// no unit or its module has no such import.
    pub fn importedModuleSource(
        graph: *BuildGraph,
        io: std.Io,
        file: []const u8,
        import_name: []const u8,
    ) !?[]const u8 {
        for (graph.units) |*unit| {
            for (unit.modules) |*module| {
                if (!try graph.moduleContains(io, module, file)) continue;
                const target = unit.imported(module, import_name) orelse continue;
                if (target.source.path()) |path| return path;
            }
        }
        return null;
    }

    /// Whether `file` is the root source of `module` or reachable from it
    /// through relative `.zig` imports.
    pub fn moduleContains(graph: *BuildGraph, io: std.Io, module: *const Module, file: []const u8) !bool {
        const root_path = module.source.path() orelse return false;
        if (std.mem.eql(u8, root_path, file)) return true;
        graph.reach_mutex.lockUncancelable(io);
        defer graph.reach_mutex.unlock(io);
        const entry = try graph.reach.getOrPut(graph.arena.allocator(), root_path);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
            try graph.collectReach(io, root_path, entry.value_ptr);
        }
        return entry.value_ptr.contains(file);
    }

    fn collectReach(graph: *BuildGraph, io: std.Io, root_path: []const u8, reached: *std.StringHashMapUnmanaged(void)) !void {
        try reachableFiles(io, graph.arena.allocator(), root_path, reached);
    }

    /// The module structure of this graph, without anything a launch needs.
    /// Null when discovery failed for a reason that may pass (no compiler,
    /// a timeout, a dependency that could not be fetched); a build script
    /// that does not compile or builds no unit stores as having no modules.
    /// Owned by `arena`.
    pub fn namedModules(graph: *const BuildGraph, arena: std.mem.Allocator) !?NamedModules {
        if (graph.modules_only) return null;
        if (graph.failure) |failure| {
            const script_error = std.mem.find(u8, failure, ".zig:") != null and std.mem.find(u8, failure, ": error: ") != null;
            return if (script_error) .{ .units = &.{} } else null;
        }
        const units = try arena.alloc([]const NamedModule, graph.units.len);
        for (graph.units, units) |unit, *stored_unit| {
            const stored = try arena.alloc(NamedModule, unit.modules.len);
            for (unit.modules, stored) |module, *entry| entry.* = .{
                .root = if (module.source.path()) |path| try arena.dupe(u8, path) else null,
                .imports = try arena.dupe(Import, module.imports),
            };
            stored_unit.* = stored;
        }
        return .{ .units = units };
    }

    /// A graph for `build_root` rebuilt from `table`, or null when the table
    /// is inconsistent. The caller owns one reference.
    pub fn restore(backing: std.mem.Allocator, build_root: []const u8, table: NamedModules) !?*BuildGraph {
        for (table.units) |unit| {
            if (unit.len == 0) return null;
            for (unit) |module| {
                for (module.imports) |import| if (import.module >= unit.len) return null;
            }
        }
        const graph = try create(backing);
        errdefer graph.release();
        const arena = graph.arena.allocator();
        graph.build_root = try arena.dupe(u8, build_root);
        graph.modules_only = true;
        const units = try arena.alloc(Unit, table.units.len);
        for (table.units, units) |stored_unit, *unit| {
            const modules = try arena.alloc(Module, stored_unit.len);
            for (stored_unit, modules) |stored, *module| module.* = .{
                .name = "",
                .source = if (stored.root) |root| .{ .file = try arena.dupe(u8, root) } else .none,
                .imports = try cloneImports(arena, stored.imports),
            };
            unit.* = .{ .name = "", .kind = .exe, .modules = modules };
        }
        graph.units = units;
        return graph;
    }
};

fn cloneImports(arena: std.mem.Allocator, imports: []const Import) ![]const Import {
    const copy = try arena.dupe(Import, imports);
    for (copy) |*import| import.name = try arena.dupe(u8, import.name);
    return copy;
}

/// One module of a stored unit: where its root source is, if it has one, and
/// which module each import name stands for (an index into the unit).
pub const NamedModule = struct {
    root: ?[]const u8,
    imports: []const Import,
};

/// What a build graph says about named modules, in a form the check cache can
/// keep between runs: per unit, its modules (index 0 is the root module).
pub const NamedModules = struct {
    units: []const []const NamedModule,
};

/// Follows `@import("x.zig")` from `root_path`, recording every file seen.
pub fn reachableFiles(io: std.Io, arena: std.mem.Allocator, root_path: []const u8, reached: *std.StringHashMapUnmanaged(void)) !void {
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(arena);
    try reached.put(arena, root_path, {});
    try queue.append(arena, root_path);
    var scratch: std.heap.ArenaAllocator = .init(arena);
    defer scratch.deinit();
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        _ = scratch.reset(.retain_capacity);
        const temporary = scratch.allocator();
        const current = queue.items[next];
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, current, temporary, .limited(max_source_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const source = try temporary.dupeSentinel(u8, bytes, 0);
        const tokens = try tokens_util.tokenize(temporary, source);
        const directory = std.Io.Dir.path.dirname(current) orelse continue;
        for (tokens, 0..) |token, index| {
            if (token.tag != .builtin or !tokens_util.tokenIs(source, token, "@import") or
                index + 3 >= tokens.len or tokens[index + 1].tag != .l_paren or
                tokens[index + 2].tag != .string_literal or tokens[index + 3].tag != .r_paren) continue;
            const import_path = std.zig.string_literal.parseAlloc(temporary, tokens_util.tokenText(source, tokens[index + 2])) catch |err| switch (err) {
                error.InvalidLiteral => continue,
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (!std.mem.endsWith(u8, import_path, ".zig")) continue;
            const resolved = try std.Io.Dir.path.resolveAlloc(temporary, &.{ directory, import_path });
            if (reached.contains(resolved) or reached.count() == max_reachable_files) continue;
            const owned = try arena.dupe(u8, resolved);
            try reached.put(arena, owned, {});
            try queue.append(arena, owned);
        }
    }
}

fn hashModule(hasher: *std.hash.Wyhash, unit: *const Unit, index: usize, visited: []bool) void {
    if (visited[index]) return;
    visited[index] = true;
    const module = &unit.modules[index];
    hasher.update(module.source.path() orelse "");
    std.hash.autoHash(hasher, std.meta.activeTag(module.source));
    if (module.target) |target| {
        hasher.update(target.triple);
        hasher.update(target.cpu);
    }
    std.hash.autoHash(hasher, module.optimize);
    std.hash.autoHash(hasher, module.link_libc);
    for (module.imports) |import| {
        hasher.update(import.name);
        hashModule(hasher, unit, import.module, visited);
    }
}

/// Lowers `unit` to compiler arguments the way `zig build` does: the root
/// module first, then every module it reaches, each with its own target,
/// optimization mode and `--dep` imports. A module without a usable source is
/// left out, so importing it is a compile error in the editor rather than a
/// silent absence. The arguments are copies owned by `arena`.
pub fn lower(arena: std.mem.Allocator, unit: *const Unit) !Launch {
    var arguments: std.ArrayList([]const u8) = .empty;
    var links_libc = false;
    if (unit.kind.isTest()) try arguments.append(arena, "--test-no-exec");
    for (unit.modules) |module| {
        const path = module.source.path() orelse continue;
        links_libc = links_libc or module.link_libc;
        if (module.target) |target| {
            try arguments.appendSlice(arena, &.{ "-target", try arena.dupe(u8, target.triple), "-mcpu", try arena.dupe(u8, target.cpu) });
        }
        if (module.optimize) |mode| try arguments.append(arena, switch (mode) {
            .debug => "-Odebug",
            .safe => "-Osafe",
            .fast => "-Ofast",
            .small => "-Osmall",
        });
        for (module.imports) |import| {
            const imported = unit.modules[import.module];
            if (imported.source.path() == null) continue;
            try arguments.append(arena, "--dep");
            try arguments.append(arena, if (std.mem.eql(u8, import.name, imported.name))
                try arena.dupe(u8, imported.name)
            else
                try arena.print("{s}={s}", .{ import.name, imported.name }));
        }
        try arguments.append(arena, try arena.print("-M{s}={s}", .{ module.name, path }));
    }
    if (links_libc) try arguments.append(arena, "-lc");
    return .{
        .command = if (unit.kind.isTest()) "test-obj" else "build-obj",
        .arguments = arguments.items,
    };
}

test "lowering names modules and dependencies like the build runner" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const modules = [_]Module{
        .{
            .name = "root",
            .source = .{ .file = "/p/src/main.zig" },
            .imports = &.{ .{ .name = "lsp", .module = 1 }, .{ .name = "gen", .module = 2 } },
            .optimize = .safe,
            .target = .{ .triple = "x86_64-linux-gnu", .cpu = "baseline" },
        },
        .{ .name = "lsp", .source = .{ .file = "/dep/lsp.zig" }, .imports = &.{} },
        .{ .name = "gen", .source = .{ .unavailable = .{ .step = "run gen", .reason = "runs a program" } }, .imports = &.{} },
    };
    const unit: Unit = .{ .name = "compile exe app", .kind = .exe, .modules = &modules };
    const launch = try lower(arena, &unit);
    try std.testing.expectEqualStrings("build-obj", launch.command);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{
            "-target", "x86_64-linux-gnu", "-mcpu",                  "baseline",           "-Osafe",
            "--dep",   "lsp",              "-Mroot=/p/src/main.zig", "-Mlsp=/dep/lsp.zig",
        }),
        launch.arguments,
    );
}

test "a unit lists the unavailable modules it imports once per name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const modules = [_]Module{
        .{ .name = "root", .source = .{ .file = "/p/main.zig" }, .imports = &.{ .{ .name = "gen", .module = 1 }, .{ .name = "ok", .module = 2 } } },
        .{ .name = "gen", .source = .{ .unavailable = .{ .step = "run gen", .reason = "runs a program" } }, .imports = &.{} },
        .{ .name = "ok", .source = .{ .file = "/p/ok.zig" }, .imports = &.{.{ .name = "gen", .module = 1 }} },
    };
    const unit: Unit = .{ .name = "compile exe app", .kind = .exe, .modules = &modules };
    const imports = try unit.unavailableImports(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("gen", imports[0].import_name);
    try std.testing.expectEqualStrings("run gen", imports[0].step);
}

test "units analyze a file identically when its modules are configured identically" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "shared.zig", .data = "pub const value = 1;\n" });
    const directory = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const shared_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ directory, "shared.zig" });
    defer std.testing.allocator.free(shared_path);

    const debug = [_]Module{.{ .name = "root", .source = .{ .file = shared_path }, .imports = &.{}, .optimize = .debug }};
    const same_debug = [_]Module{.{ .name = "other", .source = .{ .file = shared_path }, .imports = &.{}, .optimize = .debug }};
    const fast = [_]Module{.{ .name = "root", .source = .{ .file = shared_path }, .imports = &.{}, .optimize = .fast }};
    const units = [_]Unit{
        .{ .name = "a", .kind = .exe, .modules = &debug },
        .{ .name = "b", .kind = .lib, .modules = &same_debug },
        .{ .name = "c", .kind = .exe, .modules = &fast },
        .{ .name = "d", .kind = .@"test", .modules = &debug },
    };
    const graph = try testGraph(&units);
    defer graph.release();
    var keys: [4]u64 = undefined;
    for (&units, &keys) |*unit, *key| key.* = try graph.analysisKey(io, std.testing.allocator, unit, shared_path);
    try std.testing.expectEqual(keys[0], keys[1]);
    try std.testing.expect(keys[0] != keys[2]);
    try std.testing.expect(keys[0] != keys[3]);
}

test "a unit lists every file it reaches" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "root.zig", .data = "const real = @import(\"real.zig\");\ncomptime { _ = real; }\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "real.zig", .data = "pub const value = 1;\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "unrelated.zig", .data = "pub const value = 2;\n" });
    const directory = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const root_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ directory, "root.zig" });
    defer std.testing.allocator.free(root_path);
    const modules = [_]Module{.{ .name = "root", .source = .{ .file = root_path }, .imports = &.{} }};
    const unit: Unit = .{ .name = "unit", .kind = .exe, .modules = &modules };
    const graph = try testGraph(&.{unit});
    defer graph.release();
    const files = try graph.unitFiles(io, std.testing.allocator, &unit);
    defer {
        for (files) |file| std.testing.allocator.free(file);
        std.testing.allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 2), files.len);
    for (files) |file| try std.testing.expect(std.mem.endsWith(u8, file, "root.zig") or std.mem.endsWith(u8, file, "real.zig"));
}

test "test units are analyzed with test-obj" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const modules = [_]Module{.{ .name = "root", .source = .{ .file = "/p/t.zig" }, .imports = &.{} }};
    const launch = try lower(arena_state.allocator(), &.{ .name = "compile test", .kind = .@"test", .modules = &modules });
    try std.testing.expectEqualStrings("test-obj", launch.command);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "--test-no-exec", "-Mroot=/p/t.zig" }), launch.arguments);
}

fn testGraph(units: []const Unit) !*BuildGraph {
    const graph = try BuildGraph.create(std.testing.allocator);
    graph.units = units;
    return graph;
}

test "containment follows real imports and ignores comments and strings" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "root.zig",
        .data =
        \\const real = @import ("real.zig");
        \\// const commented = @import("unrelated.zig");
        \\const text = "@import(\"unrelated.zig\")";
        \\comptime { _ = real; _ = text; }
        ,
    });
    try temporary.dir.writeFile(io, .{ .sub_path = "real.zig", .data = "pub const value = 1;\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "unrelated.zig", .data = "pub const value = 2;\n" });
    const directory = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const root_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ directory, "root.zig" });
    defer std.testing.allocator.free(root_path);
    const real_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ directory, "real.zig" });
    defer std.testing.allocator.free(real_path);
    const unrelated_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ directory, "unrelated.zig" });
    defer std.testing.allocator.free(unrelated_path);

    const modules = [_]Module{.{ .name = "root", .source = .{ .file = root_path }, .imports = &.{} }};
    const graph = try testGraph(&.{.{ .name = "unit", .kind = .exe, .modules = &modules }});
    defer graph.release();
    try std.testing.expect(try graph.unitFor(io, real_path) != null);
    try std.testing.expect(try graph.unitFor(io, unrelated_path) == null);
}

test "a file is analyzed through its own unit, then a non-test unit, then a test unit" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const shared = @import(\"shared.zig\");\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "tests.zig", .data = "const shared = @import(\"shared.zig\");\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "shared.zig", .data = "pub const value = 1;\n" });
    const directory = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const main_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ directory, "main.zig" });
    defer std.testing.allocator.free(main_path);
    const tests_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ directory, "tests.zig" });
    defer std.testing.allocator.free(tests_path);
    const shared_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ directory, "shared.zig" });
    defer std.testing.allocator.free(shared_path);

    const test_modules = [_]Module{.{ .name = "root", .source = .{ .file = tests_path }, .imports = &.{} }};
    const exe_modules = [_]Module{.{ .name = "root", .source = .{ .file = main_path }, .imports = &.{} }};
    const graph = try testGraph(&.{
        .{ .name = "tests", .kind = .@"test", .modules = &test_modules },
        .{ .name = "app", .kind = .exe, .modules = &exe_modules },
    });
    defer graph.release();
    try std.testing.expectEqualStrings("tests", (try graph.unitFor(io, tests_path)).?.name);
    try std.testing.expectEqualStrings("app", (try graph.unitFor(io, main_path)).?.name);
    try std.testing.expectEqualStrings("app", (try graph.unitFor(io, shared_path)).?.name);
    const containing = try graph.unitsContaining(io, std.testing.allocator, shared_path);
    defer std.testing.allocator.free(containing);
    try std.testing.expectEqual(@as(usize, 2), containing.len);
    try std.testing.expectEqualStrings("tests", containing[0].name);
}

test "build problems are reported to the first caller only" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const graph = try BuildGraph.create(std.testing.allocator);
    defer graph.release();
    graph.build_root = "/project";
    graph.failure = "boom";
    graph.notices = &.{.{ .level = .information, .text = "module 'gen' is unavailable" }};
    const first = try graph.takeNotices(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expect(std.mem.find(u8, first[0].text, "boom") != null);
    try std.testing.expectEqual(.warning, first[0].level);
    try std.testing.expectEqual(.information, first[1].level);
    try std.testing.expectEqual(@as(usize, 0), (try graph.takeNotices(arena_state.allocator())).len);
}

test "named modules survive a round trip and a failed build script stores as empty" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const api = @import(\"api\");\n" });
    const directory = try temporary.dir.realPathFileAlloc(io, ".", arena);
    const main_path = try std.Io.Dir.path.join(arena, &.{ directory, "main.zig" });
    const api_path = try std.Io.Dir.path.join(arena, &.{ directory, "api.zig" });

    const modules = [_]Module{
        .{ .name = "root", .source = .{ .file = main_path }, .imports = &.{.{ .name = "api", .module = 1 }} },
        .{ .name = "api", .source = .{ .file = api_path }, .imports = &.{} },
    };
    const graph = try testGraph(&.{.{ .name = "app", .kind = .exe, .modules = &modules }});
    defer graph.release();
    const table = (try graph.namedModules(arena)).?;

    const restored = (try BuildGraph.restore(std.testing.allocator, directory, table)).?;
    defer restored.release();
    try std.testing.expectEqualStrings(api_path, (try restored.importedModuleSource(io, main_path, "api")).?);
    try std.testing.expect(try restored.importedModuleSource(io, main_path, "other") == null);
    try std.testing.expect(try restored.namedModules(arena) == null);

    const dangling = [_][]const NamedModule{&.{.{ .root = main_path, .imports = &.{.{ .name = "api", .module = 4 }} }}};
    try std.testing.expect(try BuildGraph.restore(std.testing.allocator, directory, .{ .units = &dangling }) == null);

    const failed = try testGraph(&.{});
    defer failed.release();
    failed.failure = "build.zig:3:5: error: expected token";
    try std.testing.expectEqual(@as(usize, 0), (try failed.namedModules(arena)).?.units.len);
    failed.failure = "running 'zig build' failed: Timeout";
    try std.testing.expect(try failed.namedModules(arena) == null);
}
