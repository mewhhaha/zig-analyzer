//! Where a source file's lint configuration and per-project state come from.
//! The CLI and the language server resolve a file the same way: walk up from
//! the file to the nearest `zig-analyzer.json`, apply the per-path relaxations
//! in `configurationForPath`, and root caches at the directory that owns the
//! configuration (else the workspace root, else the file's directory).
const std = @import("std");
const analysis = @import("../analysis.zig");

pub const file_name = "zig-analyzer.json";
const max_configuration_size = 1024 * 1024;

pub const Resolved = struct {
    /// Parsed `zig-analyzer.json`, or the defaults when there is none.
    configuration: analysis.Configuration,
    /// Directory that owns the project's analyzer state: the one holding
    /// `zig-analyzer.json`, else the containing workspace root, else the
    /// starting directory.
    root: []const u8,
    /// Set only on the first resolution of each version of the configuration
    /// file, so a broken file is reported once rather than on every request.
    /// Same text as `configuration.warning`.
    new_warning: ?[]const u8,
};

/// Resolved configurations, cached per starting directory. A cached result is
/// refreshed when the nearest configuration file changes, appears, or vanishes, and everything is
/// dropped by `invalidate`. Results stay valid until `deinit`, even after the
/// file changes, so callers may keep using one across a refresh. Safe to share
/// between threads.
pub const Store = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    workspace_roots: std.ArrayList([]u8) = .empty,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Arenas of superseded entries, kept alive for outstanding results.
    retired: std.ArrayList(std.heap.ArenaAllocator) = .empty,

    const Entry = struct {
        arena: std.heap.ArenaAllocator,
        /// Absolute path of the configuration file; null when none exists.
        config_path: ?[]const u8,
        stamp: Stamp,
        configuration: analysis.Configuration,
        root: []const u8,
        reported: bool = false,

        fn resolved(entry: *Entry) Resolved {
            const new_warning = if (entry.reported) null else entry.configuration.warning;
            entry.reported = true;
            return .{ .configuration = entry.configuration, .root = entry.root, .new_warning = new_warning };
        }
    };

    const Stamp = struct {
        modified: i96 = 0,
        size: u64 = 0,
    };

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Store {
        return .{ .io = io, .allocator = allocator };
    }

    pub fn deinit(store: *Store) void {
        for (store.workspace_roots.items) |root| store.allocator.free(root);
        store.workspace_roots.deinit(store.allocator);
        var entries = store.entries.iterator();
        while (entries.next()) |entry| {
            store.allocator.free(entry.key_ptr.*);
            entry.value_ptr.arena.deinit();
        }
        store.entries.deinit(store.allocator);
        for (store.retired.items) |*arena| arena.deinit();
        store.retired.deinit(store.allocator);
        store.* = undefined;
    }

    /// Records a workspace folder. Re-adding a known folder is a no-op.
    pub fn addWorkspaceRoot(store: *Store, path: []const u8) !void {
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        for (store.workspace_roots.items) |root| if (std.mem.eql(u8, root, path)) return;
        const owned = try store.allocator.dupe(u8, path);
        errdefer store.allocator.free(owned);
        try store.workspace_roots.append(store.allocator, owned);
        store.dropEntries();
    }

    pub fn removeWorkspaceRoot(store: *Store, path: []const u8) void {
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        for (store.workspace_roots.items, 0..) |root, index| {
            if (!std.mem.eql(u8, root, path)) continue;
            store.allocator.free(store.workspace_roots.swapRemove(index));
            store.dropEntries();
            return;
        }
    }

    /// Forgets every cached lookup; call when a `zig-analyzer.json` changed.
    pub fn invalidate(store: *Store) void {
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        store.dropEntries();
    }

    /// Configuration and project root for the source file at `file_path`
    /// (absolute), with `configurationForPath` relaxations for that file.
    pub fn forFile(store: *Store, file_path: []const u8) !Resolved {
        var resolved = try store.forDirectory(std.Io.Dir.path.dirname(file_path) orelse file_path);
        resolved.configuration = configurationForPath(resolved.configuration, file_path);
        return resolved;
    }

    /// Configuration and project root for the directory `directory` (absolute).
    pub fn forDirectory(store: *Store, directory: []const u8) !Resolved {
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        if (store.entries.getPtr(directory)) |entry| {
            if (store.isFresh(entry.*, directory)) return entry.resolved();
            const removed = store.entries.fetchRemove(directory).?;
            store.allocator.free(removed.key);
            try store.retired.append(store.allocator, removed.value.arena);
        }
        const key = try store.allocator.dupe(u8, directory);
        errdefer store.allocator.free(key);
        var entry = try store.load(directory);
        errdefer entry.arena.deinit();
        try store.entries.put(store.allocator, key, entry);
        return store.entries.getPtr(key).?.resolved();
    }

    fn dropEntries(store: *Store) void {
        var entries = store.entries.iterator();
        while (entries.next()) |entry| {
            store.allocator.free(entry.key_ptr.*);
            // Outstanding results may still point into this arena.
            store.retired.append(store.allocator, entry.value_ptr.arena) catch entry.value_ptr.arena.deinit();
        }
        store.entries.clearRetainingCapacity();
    }

    /// Whether `entry` still describes `directory`: the nearest configuration
    /// file is the same one and has not been modified.
    fn isFresh(store: *const Store, entry: Entry, directory: []const u8) bool {
        var buffer: [4 * std.Io.Dir.max_path_bytes]u8 = undefined;
        var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
        const found = store.findConfiguration(scratch.allocator(), directory) catch return false;
        const cached_path = entry.config_path orelse return found == null;
        if (found == null or !std.mem.eql(u8, found.?, cached_path)) return false;
        const stamp = store.stampOf(cached_path) orelse return false;
        return stamp.modified == entry.stamp.modified and stamp.size == entry.stamp.size;
    }

    fn load(store: *Store, directory: []const u8) !Entry {
        var arena: std.heap.ArenaAllocator = .init(store.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const config_path = try store.findConfiguration(allocator, directory);
        var entry: Entry = .{
            .arena = undefined,
            .config_path = config_path,
            .stamp = .{},
            .configuration = analysis.Configuration.defaults(),
            .root = undefined,
        };
        if (config_path) |path| {
            entry.root = std.Io.Dir.path.dirname(path) orelse directory;
            entry.stamp = store.stampOf(path) orelse .{};
            if (std.Io.Dir.cwd().readFileAlloc(store.io, path, allocator, .limited(max_configuration_size))) |source| {
                entry.configuration = try analysis.parseConfiguration(allocator, source);
            } else |err| switch (err) {
                error.OutOfMemory, error.Canceled => return err,
                else => entry.configuration.warning = try allocator.print("could not read {s}: {t}", .{ path, err }),
            }
        } else {
            entry.root = try allocator.dupe(u8, store.workspaceRootContaining(directory) orelse directory);
        }
        entry.arena = arena;
        return entry;
    }

    /// Absolute path of the nearest configuration file at or above `directory`.
    fn findConfiguration(store: *const Store, allocator: std.mem.Allocator, directory: []const u8) !?[]const u8 {
        var current = directory;
        while (true) {
            const candidate = try std.Io.Dir.path.join(allocator, &.{ current, file_name });
            if (store.stampOf(candidate) != null) return candidate;
            allocator.free(candidate);
            const parent = std.Io.Dir.path.dirname(current) orelse return null;
            if (std.mem.eql(u8, parent, current)) return null;
            current = parent;
        }
    }

    fn stampOf(store: *const Store, path: []const u8) ?Stamp {
        const stat = std.Io.Dir.cwd().statFile(store.io, path, .{}) catch return null;
        return .{ .modified = stat.mtime.nanoseconds, .size = stat.size };
    }

    /// The longest workspace folder that contains `directory`.
    fn workspaceRootContaining(store: *const Store, directory: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        for (store.workspace_roots.items) |root| {
            if (!isWithin(directory, root)) continue;
            if (best == null or root.len > best.?.len) best = root;
        }
        return best;
    }
};

fn isWithin(path: []const u8, directory: []const u8) bool {
    if (!std.mem.startsWith(u8, path, directory)) return false;
    if (path.len == directory.len) return true;
    if (directory.len != 0 and std.Io.Dir.path.isSep(directory[directory.len - 1])) return true;
    return std.Io.Dir.path.isSep(path[directory.len]);
}

/// Per-path relaxations of a project's configuration: debug printing is
/// legitimate in tests and build scripts.
pub fn configurationForPath(configuration: analysis.Configuration, path: []const u8) analysis.Configuration {
    var file_configuration = configuration;
    if (isTestOnlyPath(path) or std.mem.eql(u8, std.Io.Dir.path.basename(path), "build.zig")) {
        file_configuration.levels[@backingInt(analysis.Rule.prefer_log_over_print)] = .off;
    }
    return file_configuration;
}

fn isTestOnlyPath(path: []const u8) bool {
    const basename = std.Io.Dir.path.basename(path);
    if (std.mem.endsWith(u8, basename, "_test.zig") or std.mem.endsWith(u8, basename, "_tests.zig")) return true;
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "test") or std.mem.eql(u8, component, "tests") or
            std.mem.eql(u8, component, "testing")) return true;
    }
    return false;
}

test "test and build paths keep debug printing out of production logging guidance" {
    var configuration = analysis.Configuration.defaults();
    configuration.levels[@backingInt(analysis.Rule.prefer_log_over_print)] = .information;
    try std.testing.expectEqual(analysis.Level.off, configurationForPath(configuration, "build.zig").level(.prefer_log_over_print));
    try std.testing.expectEqual(analysis.Level.off, configurationForPath(configuration, "src/testing/snapshot.zig").level(.prefer_log_over_print));
    try std.testing.expectEqual(analysis.Level.off, configurationForPath(configuration, "src/parser_tests.zig").level(.prefer_log_over_print));
    try std.testing.expectEqual(analysis.Level.information, configurationForPath(configuration, "src/main.zig").level(.prefer_log_over_print));
}

test "configuration is found by walking up from the file and applies test relaxations" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "src/deep");
    try temporary.dir.writeFile(io, .{
        .sub_path = file_name,
        .data = "{\"lints\":{\"rules\":{\"prefer-log-over-print\":\"warning\",\"redundant-boolean-if\":\"warning\"}}}\n",
    });
    const root = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const production = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "src/deep/main.zig" });
    defer std.testing.allocator.free(production);
    const test_file = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "src/deep/main_test.zig" });
    defer std.testing.allocator.free(test_file);

    var store = Store.init(io, std.testing.allocator);
    defer store.deinit();
    const first = try store.forFile(production);
    try std.testing.expectEqualStrings(root, first.root);
    try std.testing.expectEqual(analysis.Level.warning, first.configuration.level(.redundant_boolean_if));
    try std.testing.expectEqual(analysis.Level.warning, first.configuration.level(.prefer_log_over_print));
    try std.testing.expect(first.new_warning == null);

    const relaxed = try store.forFile(test_file);
    try std.testing.expectEqual(analysis.Level.off, relaxed.configuration.level(.prefer_log_over_print));
    try std.testing.expectEqual(analysis.Level.warning, relaxed.configuration.level(.redundant_boolean_if));
}

test "a changed configuration file is picked up and its error is reported once" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = file_name, .data = "{\"lints\":{\"rules\":{\"redundant-boolean-if\":\"warning\"}}}\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var store = Store.init(io, std.testing.allocator);
    defer store.deinit();
    const before = try store.forDirectory(root);
    try std.testing.expectEqual(analysis.Level.warning, before.configuration.level(.redundant_boolean_if));

    try temporary.dir.writeFile(io, .{ .sub_path = file_name, .data = "{ not json, and a longer file than before" });
    const broken = try store.forDirectory(root);
    try std.testing.expect(broken.new_warning != null);
    try std.testing.expectEqual(analysis.Level.off, broken.configuration.level(.redundant_boolean_if));
    // The superseded result stays readable.
    try std.testing.expectEqual(analysis.Level.warning, before.configuration.level(.redundant_boolean_if));

    const again = try store.forDirectory(root);
    try std.testing.expect(again.new_warning == null);
    try std.testing.expect(again.configuration.warning != null);

    try temporary.dir.writeFile(io, .{ .sub_path = file_name, .data = "{}\n" });
    store.invalidate();
    const fixed = try store.forDirectory(root);
    try std.testing.expect(fixed.configuration.warning == null);
}

test "the project root is the configuration directory, else the containing workspace folder" {
    var store = Store.init(std.testing.io, std.testing.allocator);
    defer store.deinit();
    try store.addWorkspaceRoot("/work/app");
    try store.addWorkspaceRoot("/work/app/vendor/lib");
    try store.addWorkspaceRoot("/work/other");
    try std.testing.expectEqualStrings("/work/app", store.workspaceRootContaining("/work/app/src").?);
    try std.testing.expectEqualStrings("/work/app/vendor/lib", store.workspaceRootContaining("/work/app/vendor/lib/src").?);
    try std.testing.expectEqualStrings("/work/app", store.workspaceRootContaining("/work/app").?);
    try std.testing.expect(store.workspaceRootContaining("/work/application") == null);
    try std.testing.expect(store.workspaceRootContaining("/elsewhere") == null);
    store.removeWorkspaceRoot("/work/app");
    try std.testing.expect(store.workspaceRootContaining("/work/app/src") == null);
}

test "a configuration file appearing later is noticed without invalidation" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "app/src");
    const root = try temporary.dir.realPathFileAlloc(io, "app", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source_directory = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "src" });
    defer std.testing.allocator.free(source_directory);

    var store = Store.init(io, std.testing.allocator);
    defer store.deinit();
    const before = try store.forDirectory(source_directory);
    try std.testing.expect(!std.mem.eql(u8, before.root, root));

    try temporary.dir.writeFile(io, .{ .sub_path = "app/zig-analyzer.json", .data = "{}\n" });
    const after = try store.forDirectory(source_directory);
    try std.testing.expectEqualStrings(root, after.root);
}
