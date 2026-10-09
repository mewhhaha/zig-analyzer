//! The CLI's cross-file passes: deprecations a file reaches through its
//! imports, and members it reads from the modules it imports. Both depend on
//! files other than the one reported, so they cannot ride the per-file cache.
//! Each file's result is cached together with the hashes of every file and
//! build root it was computed from, and reused while those still match.
//! Files are independent, so misses are computed by a few workers at once.
const std = @import("std");

const analysis = @import("../analysis.zig");
const compile_units = @import("../compiler/compile_units.zig");
const project_rules = @import("../rules/project.zig");
const build_roots = @import("build_roots.zig");
const check_cache = @import("check_cache.zig");
const project_config = @import("config.zig");
const imported_deprecations = @import("imported_deprecations.zig");
const module_sites = @import("module_sites.zig");

const Record = check_cache.Record;

/// Workers computing results at once.
const max_workers = 4;

/// The findings of one file, in output order.
pub const FileResult = struct {
    imports: []const Record = &.{},
    members: []const Record = &.{},
};

pub const Input = struct {
    io: std.Io,
    /// Must be safe to use from several threads.
    allocator: std.mem.Allocator,
    /// Absolute path the files' paths are relative to.
    root_path: []const u8,
    files: []const project_rules.SourceFile,
    configuration: analysis.Configuration,
    cache: check_cache.Cache,
};

pub const Results = struct {
    allocator: std.mem.Allocator,
    /// Hold the records of `files`.
    arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    files: []FileResult = &.{},
    failure: ?anyerror = null,

    pub fn deinit(results: *Results) void {
        for (results.arenas.items) |arena| {
            arena.deinit();
            results.allocator.destroy(arena);
        }
        results.arenas.deinit(results.allocator);
        results.allocator.free(results.files);
        results.* = undefined;
    }
};

/// Computes the cross-file findings of `input.files`; `files[i]` of the result
/// belongs to `input.files[i]`.
pub fn run(input: Input) !Results {
    var results: Results = .{ .allocator = input.allocator };
    errdefer results.deinit();
    results.files = try input.allocator.alloc(FileResult, input.files.len);
    @memset(results.files, .{});
    var shared_arena: std.heap.ArenaAllocator = .init(input.allocator);
    defer shared_arena.deinit();
    const arena = shared_arena.allocator();
    const check_imports = input.configuration.level(.deprecated_declaration) != .off;
    const check_members = input.configuration.level(.unresolved_member) != .off;
    if (!check_imports and !check_members or input.files.len == 0) return results;

    const absolute_paths = try arena.alloc([]const u8, input.files.len);
    for (input.files, absolute_paths) |file, *path| {
        path.* = try std.Io.Dir.path.resolveAlloc(arena, &.{ input.root_path, file.path });
    }
    var shared: Shared = .{
        .input = input,
        .check_imports = check_imports,
        .check_members = check_members,
        .absolute_paths = absolute_paths,
        .results = results.files,
        .kept = &results.arenas,
    };
    try shared.index(arena);
    if (check_members) {
        const candidates = try arena.alloc(build_roots.File, input.files.len);
        for (input.files, shared.absolute_paths, candidates) |file, path, *candidate| candidate.* = .{
            .path = path,
            .source = file.source,
            .tokens = file.tokens.?,
        };
        try build_roots.prepare(input.io, input.cache, try build_roots.neededRoots(input.io, arena, candidates));
    }

    var group: std.Io.Group = .init;
    defer group.cancel(input.io);
    const workers = @max(1, @min(max_workers, input.files.len / 8));
    for (1..workers) |_| group.concurrent(input.io, work, .{&shared}) catch break;
    work(&shared);
    try group.await(input.io);
    results.failure = shared.failure;
    return results;
}

const Shared = struct {
    input: Input,
    check_imports: bool,
    check_members: bool,
    absolute_paths: []const []const u8,
    results: []FileResult,
    /// Arenas of finished workers; their records are what `results` points to.
    kept: *std.ArrayList(*std.heap.ArenaAllocator),
    next: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,
    /// Guards `failure`, `results` allocation and `hashes`.
    mutex: std.Io.Mutex = .init,
    /// The scanned files by absolute path, as the passes read them.
    sources: std.StringHashMapUnmanaged(imported_deprecations.Source) = .empty,
    module_files: std.StringHashMapUnmanaged(module_sites.File) = .empty,
    /// Content hash of every file that was looked at: scanned files up front,
    /// others when first needed. Null for a file that does not exist.
    hashes: std.StringHashMapUnmanaged(?u64) = .empty,
    build_hashes: std.StringHashMapUnmanaged(?u64) = .empty,

    fn index(shared: *Shared, arena: std.mem.Allocator) !void {
        const count: u32 = @intCast(shared.input.files.len);
        try shared.sources.ensureTotalCapacity(arena, count);
        try shared.module_files.ensureTotalCapacity(arena, count);
        try shared.hashes.ensureTotalCapacity(arena, count);
        for (shared.input.files, shared.absolute_paths) |file, path| {
            shared.sources.putAssumeCapacity(path, .{ .path = path, .source = file.source, .tokens = file.tokens });
            shared.module_files.putAssumeCapacity(path, .{ .path = path, .source = file.source, .tokens = file.tokens.? });
            shared.hashes.putAssumeCapacity(path, std.hash.Wyhash.hash(0, file.source));
        }
    }

    fn fail(shared: *Shared, err: anyerror) void {
        shared.mutex.lockUncancelable(shared.input.io);
        defer shared.mutex.unlock(shared.input.io);
        if (shared.failure == null) shared.failure = err;
        shared.next.store(shared.input.files.len, .monotonic);
    }

    /// The content hash of the file at `path`, read once.
    fn fileHash(shared: *Shared, path: []const u8) !?u64 {
        const io = shared.input.io;
        try shared.mutex.lock(io);
        defer shared.mutex.unlock(io);
        if (shared.hashes.get(path)) |known| return known;
        const stable = try shared.input.allocator.dupe(u8, path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, stable, shared.input.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => null,
        };
        defer if (bytes) |present| shared.input.allocator.free(present);
        const hash: ?u64 = if (bytes) |present| std.hash.Wyhash.hash(0, present) else null;
        try shared.hashes.put(shared.input.allocator, stable, hash);
        return hash;
    }

    fn buildRootHash(shared: *Shared, root: []const u8) !?u64 {
        const io = shared.input.io;
        try shared.mutex.lock(io);
        defer shared.mutex.unlock(io);
        if (shared.build_hashes.get(root)) |known| return known;
        const digest = try compile_units.buildDigest(io, shared.input.allocator, root);
        const hash = std.mem.readInt(u64, digest[0..8], .little);
        try shared.build_hashes.put(shared.input.allocator, try shared.input.allocator.dupe(u8, root), hash);
        return hash;
    }

    fn matches(shared: *Shared, dependency: check_cache.Dependency) !bool {
        const current = switch (dependency.kind) {
            .file => try shared.fileHash(dependency.path),
            .build_root => try shared.buildRootHash(dependency.path),
        };
        return std.meta.eql(current, dependency.hash);
    }
};

fn work(shared: *Shared) void {
    var worker: Worker = .init(shared);
    defer worker.deinit();
    while (true) {
        const position = shared.next.fetchAdd(1, .monotonic);
        if (position >= shared.input.files.len) return;
        worker.file(position) catch |err| switch (err) {
            error.Canceled => return,
            else => return shared.fail(err),
        };
    }
}

const Worker = struct {
    shared: *Shared,
    /// Scratch for everything this worker computes; freed when it is done.
    scratch: std.heap.ArenaAllocator,
    imported: ?*imported_deprecations.ImportedDeprecations = null,
    modules: module_sites.Cache,
    /// Owns the records this worker hands back; given to the results at the end.
    kept: ?*std.heap.ArenaAllocator = null,

    fn init(shared: *Shared) Worker {
        var worker: Worker = .{
            .shared = shared,
            .scratch = .init(shared.input.allocator),
            .modules = .init(shared.input.allocator),
        };
        worker.modules.known = &shared.module_files;
        worker.modules.tracing = true;
        return worker;
    }

    fn deinit(worker: *Worker) void {
        if (worker.imported) |imported| {
            imported.deinit();
            worker.shared.input.allocator.destroy(imported);
        }
        worker.modules.deinit();
        worker.scratch.deinit();
        const kept = worker.kept orelse return;
        const shared = worker.shared;
        shared.mutex.lockUncancelable(shared.input.io);
        defer shared.mutex.unlock(shared.input.io);
        shared.kept.append(shared.input.allocator, kept) catch {
            kept.deinit();
            shared.input.allocator.destroy(kept);
            shared.failure = error.OutOfMemory;
        };
    }

    fn file(worker: *Worker, position: usize) !void {
        const shared = worker.shared;
        const input = shared.input;
        const source_file = input.files[position];
        if (analysis.isTranslateCOutput(source_file.source)) return;
        var arena_state: std.heap.ArenaAllocator = .init(input.allocator);
        defer arena_state.deinit();
        const temporary = arena_state.allocator();

        if (try input.cache.loadCross(input.io, temporary, source_file.path, source_file.source)) |entry| {
            if (try worker.current(entry.dependencies)) {
                try worker.keep(position, entry.imports, entry.members);
                return;
            }
        }

        var dependencies: std.array_hash_map.String(check_cache.DependencyKind) = .empty;
        var imports: []const Record = &.{};
        var members: []const Record = &.{};
        const absolute_path = shared.absolute_paths[position];
        if (shared.check_imports) {
            const imported = try worker.importedDeprecations();
            var found: std.ArrayList(analysis.Finding) = .empty;
            try imported.check(.{
                .path = absolute_path,
                .source = source_file.source,
                .tokens = source_file.tokens.?,
            }, input.configuration, &found);
            imports = try records(temporary, found.items);
            for (try imported.dependencyPaths(temporary)) |path| try dependencies.put(temporary, path, .file);
        }
        if (shared.check_members) {
            worker.modules.forgetTouched();
            const resolver: module_sites.Resolver = .{ .io = input.io, .cache = &worker.modules, .discover_build = true };
            const modules = try resolver.fileModules(temporary, .{
                .path = absolute_path,
                .source = source_file.source,
                .tokens = source_file.tokens.?,
            });
            const found = try analysis.moduleMemberFindings(
                temporary,
                source_file.source,
                source_file.tokens.?,
                project_config.configurationForPath(input.configuration, source_file.path),
                modules,
            );
            members = try records(temporary, found);
            var files = worker.modules.touched_files.keyIterator();
            while (files.next()) |path| try dependencies.put(temporary, path.*, .file);
            var roots = worker.modules.touched_roots.keyIterator();
            while (roots.next()) |root| try dependencies.put(temporary, root.*, .build_root);
        }
        try worker.keep(position, imports, members);
        if (input.cache.dir == null) return;

        const stored = try temporary.alloc(check_cache.Dependency, dependencies.count());
        for (dependencies.keys(), dependencies.values(), stored) |path, kind, *dependency| dependency.* = .{
            .kind = kind,
            .path = path,
            .hash = switch (kind) {
                .file => try shared.fileHash(path),
                .build_root => try shared.buildRootHash(path),
            },
        };
        // Sorted so equal inputs store equal entries.
        std.mem.sort(check_cache.Dependency, stored, {}, struct {
            fn lessThan(_: void, left: check_cache.Dependency, right: check_cache.Dependency) bool {
                return std.mem.lessThan(u8, left.path, right.path);
            }
        }.lessThan);
        try input.cache.storeCross(input.io, temporary, source_file.path, source_file.source, .{
            .imports = imports,
            .members = members,
            .dependencies = stored,
        });
    }

    fn current(worker: *Worker, dependencies: []const check_cache.Dependency) !bool {
        for (dependencies) |dependency| if (!try worker.shared.matches(dependency)) return false;
        return true;
    }

    fn importedDeprecations(worker: *Worker) !*imported_deprecations.ImportedDeprecations {
        if (worker.imported) |imported| return imported;
        const imported = try worker.shared.input.allocator.create(imported_deprecations.ImportedDeprecations);
        errdefer worker.shared.input.allocator.destroy(imported);
        imported.init(worker.shared.input.io, worker.scratch.allocator());
        imported.useKnownSources(&worker.shared.sources);
        worker.imported = imported;
        return imported;
    }

    /// Stores the records of file `position` where the caller reads them.
    fn keep(worker: *Worker, position: usize, imports: []const Record, members: []const Record) !void {
        const shared = worker.shared;
        if (worker.kept == null) {
            const arena = try shared.input.allocator.create(std.heap.ArenaAllocator);
            arena.* = .init(shared.input.allocator);
            worker.kept = arena;
        }
        const arena = worker.kept.?.allocator();
        shared.results[position] = .{ .imports = try duplicate(arena, imports), .members = try duplicate(arena, members) };
    }
};

fn records(allocator: std.mem.Allocator, found: []const analysis.Finding) ![]const Record {
    const stored = try allocator.alloc(Record, found.len);
    for (found, stored) |finding, *record| record.* = .{
        .rule = finding.rule,
        .level = finding.level,
        .start = finding.span.start,
        .end = finding.span.end,
        .message = finding.message,
    };
    return stored;
}

fn duplicate(arena: std.mem.Allocator, found: []const Record) ![]const Record {
    const copy = try arena.dupe(Record, found);
    for (copy) |*record| record.message = try arena.dupe(u8, record.message);
    return copy;
}
