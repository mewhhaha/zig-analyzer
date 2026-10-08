//! Which compile unit analyzes a file. The units come from the project's real
//! build graph (see `build_configuration.zig`): compile steps under the
//! `check` step, else under `install`. A document is analyzed through the unit
//! whose module graph contains it, with that graph's modules passed to the
//! patched compiler, so `build_options`, dependencies and named modules
//! resolve. Files no unit contains, projects without a build script, and
//! build scripts that fail to configure fall back to analyzing the file alone.
//!
//! Discovered graphs are cached per build root for the life of the process and
//! rediscovered when `build.zig` or `build.zig.zon` change on disk or
//! `forgetBuildGraph` is called (the language server does after a save).
const std = @import("std");

const build_configuration = @import("build_configuration.zig");
const build_graph = @import("build_graph.zig");

pub const BuildGraph = build_graph.BuildGraph;
pub const Launch = build_graph.Launch;
pub const Unit = build_graph.Unit;
pub const lower = build_graph.lower;

/// Whether looking a build graph up may run the build script.
pub const Mode = enum {
    /// Only graphs already discovered; never spawns a process. For request
    /// handlers that must not wait.
    cached,
    /// Discovers the graph when it is missing or stale.
    discover,
};

/// The analysis a document gets.
pub const Selected = struct {
    launch: Launch,
    /// Absolute path of the file the compiler is rooted at.
    root_source: []const u8,
    /// The compile step's name, or null when the file is analyzed alone.
    unit: ?[]const u8,
    /// Build problems not yet reported for this project; show each once.
    notices: []const build_graph.Notice,
    /// Imports of the selected unit that name modules the analyzer cannot
    /// provide. Compiler errors that say they do not resolve are expected.
    unavailable: []const build_graph.UnavailableImport = &.{},
};

/// Chooses how to analyze `document_path`. Everything returned lives in `arena`.
pub fn select(io: std.Io, arena: std.mem.Allocator, document_path: []const u8, mode: Mode) !Selected {
    const absolute = try absolutePath(io, arena, document_path);
    var selected: Selected = .{
        .launch = try Launch.standalone(arena, absolute),
        .root_source = absolute,
        .unit = null,
        .notices = &.{},
    };
    const build_root = (try nearestBuildRoot(io, arena, absolute)) orelse return selected;
    const graph = (try buildGraph(io, build_root, mode)) orelse return selected;
    defer graph.release();
    selected.notices = try graph.takeNotices(arena);
    const unit = (try graph.unitFor(io, absolute)) orelse return selected;
    selected.launch = try build_graph.lower(arena, unit);
    selected.unavailable = try unit.unavailableImports(arena);
    selected.root_source = try arena.dupe(u8, unit.root().source.path().?);
    selected.unit = try arena.dupe(u8, unit.name);
    return selected;
}

/// The root source of the module `import_name` names when written in the file
/// at `file_path`, or null. The result belongs to `allocator`.
pub fn namedModuleSource(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    import_name: []const u8,
    mode: Mode,
) !?[]const u8 {
    var scratch: std.heap.ArenaAllocator = .init(allocator);
    defer scratch.deinit();
    const absolute = try absolutePath(io, scratch.allocator(), file_path);
    const build_root = (try nearestBuildRoot(io, scratch.allocator(), absolute)) orelse return null;
    const graph = (try buildGraph(io, build_root, mode)) orelse return null;
    defer graph.release();
    const source = (try graph.importedModuleSource(io, absolute, import_name)) orelse return null;
    return try allocator.dupe(u8, source);
}

/// The build graph of the build in `build_root`, which the caller releases.
/// Null in `.cached` mode when none was discovered yet.
pub fn buildGraph(io: std.Io, build_root: []const u8, mode: Mode) !?*BuildGraph {
    const stamp = try Stamp.of(io, build_root);
    {
        store.mutex.lockUncancelable(io);
        defer store.mutex.unlock(io);
        if (store.entries.get(build_root)) |entry| {
            if (mode == .cached or entry.stamp.eql(stamp)) return entry.graph.retain();
        } else if (mode == .cached) return null;
    }
    // Configuring can take seconds; do it without holding the store.
    const discovered = try build_configuration.discover(io, std.heap.page_allocator, build_root);
    errdefer discovered.release();
    store.mutex.lockUncancelable(io);
    defer store.mutex.unlock(io);
    const entry = try store.entries.getOrPut(std.heap.page_allocator, build_root);
    if (entry.found_existing) {
        entry.value_ptr.graph.release();
    } else {
        entry.key_ptr.* = try std.heap.page_allocator.dupe(u8, build_root);
    }
    entry.value_ptr.* = .{ .graph = discovered, .stamp = stamp };
    return discovered.retain();
}

/// Drops the cached graph of the build that contains `document_path`, so the
/// next `.discover` lookup runs the build script again.
pub fn forgetBuildGraph(io: std.Io, document_path: []const u8) !void {
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const absolute = try absolutePath(io, scratch.allocator(), document_path);
    const build_root = (try nearestBuildRoot(io, scratch.allocator(), absolute)) orelse return;
    store.mutex.lockUncancelable(io);
    defer store.mutex.unlock(io);
    if (store.entries.fetchRemove(build_root)) |removed| {
        removed.value.graph.release();
        std.heap.page_allocator.free(removed.key);
    }
}

/// The directory of the nearest `build.zig` at or above `path`.
pub fn nearestBuildRoot(io: std.Io, arena: std.mem.Allocator, path: []const u8) !?[]const u8 {
    var directory = std.Io.Dir.path.dirname(path) orelse return null;
    while (true) {
        const candidate = try std.Io.Dir.path.join(arena, &.{ directory, "build.zig" });
        std.Io.Dir.cwd().access(io, candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = std.Io.Dir.path.dirname(directory) orelse return null;
                if (std.mem.eql(u8, parent, directory)) return null;
                directory = parent;
                continue;
            },
            else => return err,
        };
        return directory;
    }
}

/// `path` made absolute against the working directory and normalized, without
/// following symbolic links.
pub fn absolutePath(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.Io.Dir.path.isAbsolute(path)) return std.Io.Dir.path.resolveAlloc(arena, &.{path});
    const working = try std.process.currentPathAlloc(io, arena);
    return std.Io.Dir.path.resolveAlloc(arena, &.{ working, path });
}

/// Modification times and sizes of the files whose edits change the graph.
const Stamp = struct {
    build: ?File = null,
    manifest: ?File = null,

    const File = struct { modified: i96, size: u64 };

    fn of(io: std.Io, build_root: []const u8) !Stamp {
        return .{
            .build = try fileStamp(io, build_root, "build.zig"),
            .manifest = try fileStamp(io, build_root, "build.zig.zon"),
        };
    }

    fn fileStamp(io: std.Io, build_root: []const u8, name: []const u8) !?File {
        var directory = std.Io.Dir.cwd().openDir(io, build_root, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        defer directory.close(io);
        const stat = directory.statFile(io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return .{ .modified = stat.mtime.nanoseconds, .size = stat.size };
    }

    fn eql(stamp: Stamp, other: Stamp) bool {
        return std.meta.eql(stamp, other);
    }
};

const Entry = struct {
    graph: *BuildGraph,
    stamp: Stamp,
};

/// Process-wide, like the host compiler environment: the language server's
/// foreground and worker threads and the CLI all consult one cache.
var store: struct {
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
} = .{};
