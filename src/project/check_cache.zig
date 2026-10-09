const std = @import("std");
const analysis = @import("../analysis.zig");
const build_graph = @import("../compiler/build_graph.zig");

/// Bump when the stored records change meaning. It names the cache directory,
/// seeds every key, and is stored in each record, so entries of another
/// version are never read.
const format_version: u8 = 1;
const cache_path = std.fmt.comptimePrint(".zig-cache/zig-analyzer/check-v{d}", .{format_version});
const cache_file_limit = 16 * 1024 * 1024;

pub const Record = struct {
    rule: analysis.Rule,
    level: analysis.Level,
    start: usize,
    end: usize,
    message: []const u8,
};

pub const ProjectSource = struct {
    path: []const u8,
    source: []const u8,
};

pub const ProjectRecord = struct {
    file_index: usize,
    rule: analysis.Rule,
    level: analysis.Level,
    start: usize,
    end: usize,
    message: []const u8,
};

const StoredFile = struct {
    version: u8,
    findings: []const Record,
};

const StoredProject = struct {
    version: u8,
    findings: []const ProjectRecord,
};

/// A file or build root a cross-file result was computed from. The result is
/// valid while every dependency still hashes the same.
pub const DependencyKind = enum { file, build_root };

pub const Dependency = struct {
    kind: DependencyKind,
    path: []const u8,
    /// Null for a file that did not exist.
    hash: ?u64,
};

/// What the cross-file passes found for one file: findings that depend on the
/// files it imports, so the entry also names them.
pub const CrossEntry = struct {
    version: u8 = format_version,
    imports: []const Record,
    members: []const Record,
    dependencies: []const Dependency,
};

const StoredModules = struct {
    version: u8,
    units: []const []const build_graph.NamedModule,
};

pub const Cache = struct {
    dir: ?std.Io.Dir = null,
    identity: [std.crypto.hash.Blake3.digest_length]u8 = @splat(0),

    pub fn init(
        io: std.Io,
        root_dir: std.Io.Dir,
        configuration: analysis.Configuration,
    ) Cache {
        var executable_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const executable_path_length = std.process.executablePath(io, &executable_path_buffer) catch |err| {
            std.log.warn("check cache disabled: could not locate the executable: {t}", .{err});
            return .{};
        };
        const executable_stat = std.Io.Dir.cwd().statFile(io, executable_path_buffer[0..executable_path_length], .{}) catch |err| {
            std.log.warn("check cache disabled: could not inspect the executable: {t}", .{err});
            return .{};
        };

        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(std.fmt.comptimePrint("zig-analyzer-check-cache-v{d}", .{format_version}));
        hasher.update(std.mem.asBytes(&executable_stat.inode));
        hasher.update(std.mem.asBytes(&executable_stat.size));
        hasher.update(std.mem.asBytes(&executable_stat.mtime.nanoseconds));
        hasher.update(std.mem.asBytes(&executable_stat.ctime.nanoseconds));
        hasher.update(std.mem.asBytes(&configuration.levels));
        hasher.update(std.mem.asBytes(&configuration.lint_profile));
        hasher.update(std.mem.asBytes(&configuration.function_length_limit));
        hasher.update(std.mem.asBytes(&configuration.line_length_limit));
        hasher.update(std.mem.asBytes(&configuration.line_length_allow_unsplittable));
        for (configuration.todo_markers) |marker| {
            hasher.update(std.mem.asBytes(&marker.len));
            hasher.update(marker);
        }
        for (configuration.banned) |banned| {
            hasher.update(std.mem.asBytes(&banned.path.len));
            hasher.update(banned.path);
            if (banned.hint) |hint| {
                hasher.update(&.{1});
                hasher.update(std.mem.asBytes(&hint.len));
                hasher.update(hint);
            } else {
                hasher.update(&.{0});
            }
        }
        hasher.update(std.mem.asBytes(&configuration.import_boundaries.len));
        for (configuration.import_boundaries) |boundary| {
            hasher.update(std.mem.asBytes(&boundary.from.len));
            hasher.update(boundary.from);
            hasher.update(std.mem.asBytes(&boundary.denied.len));
            for (boundary.denied) |denied| {
                hasher.update(std.mem.asBytes(&denied.len));
                hasher.update(denied);
            }
        }
        hasher.update(std.mem.asBytes(&configuration.resource_contracts.len));
        for (configuration.resource_contracts) |contract| {
            hasher.update(std.mem.asBytes(&contract.acquire.len));
            hasher.update(contract.acquire);
            hasher.update(std.mem.asBytes(&contract.release.len));
            hasher.update(contract.release);
        }
        hasher.update(std.mem.asBytes(&configuration.arena_allocator_contracts.len));
        for (configuration.arena_allocator_contracts) |contract| {
            hasher.update(std.mem.asBytes(&contract.len));
            hasher.update(contract);
        }
        hasher.update(std.mem.asBytes(&configuration.must_use_contracts.len));
        for (configuration.must_use_contracts) |contract| {
            hasher.update(std.mem.asBytes(&contract.len));
            hasher.update(contract);
        }
        for (configuration.check_excludes) |excluded_path| {
            hasher.update(std.mem.asBytes(&excluded_path.len));
            hasher.update(excluded_path);
        }
        var identity: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
        hasher.final(&identity);

        root_dir.createDirPath(io, cache_path) catch |err| {
            std.log.warn("check cache disabled: could not create {s}: {t}", .{ cache_path, err });
            return .{};
        };
        const dir = root_dir.openDir(io, cache_path, .{}) catch |err| {
            std.log.warn("check cache disabled: could not open {s}: {t}", .{ cache_path, err });
            return .{};
        };
        return .{ .dir = dir, .identity = identity };
    }

    pub fn deinit(cache: *Cache, io: std.Io) void {
        if (cache.dir) |*dir| dir.close(io);
        cache.dir = null;
    }

    pub fn load(
        cache: Cache,
        io: std.Io,
        allocator: std.mem.Allocator,
        relative_path: []const u8,
        source: []const u8,
    ) !?[]const Record {
        const dir = cache.dir orelse return null;
        var file_name_buffer: [std.crypto.hash.Blake3.digest_length * 2 + ".json".len]u8 = undefined;
        const file_name = cache.fileName(relative_path, source, &file_name_buffer);
        const bytes = try readEntry(io, dir, file_name, allocator) orelse return null;
        const parsed = std.json.parseFromSlice(StoredFile, allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // A truncated or foreign entry is just a miss; it is rewritten.
            else => return null,
        };
        if (parsed.value.version != format_version) return null;
        for (parsed.value.findings) |finding| {
            if (finding.start > finding.end or finding.end > source.len) return null;
        }
        return parsed.value.findings;
    }

    pub fn store(
        cache: Cache,
        io: std.Io,
        allocator: std.mem.Allocator,
        relative_path: []const u8,
        source: []const u8,
        findings: []const Record,
    ) !void {
        const dir = cache.dir orelse return;
        var encoded: std.Io.Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        std.json.Stringify.value(
            StoredFile{ .version = format_version, .findings = findings },
            .{},
            &encoded.writer,
        ) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory, // an allocating writer fails only on allocation
        };
        const bytes = try encoded.toOwnedSlice();
        defer allocator.free(bytes);

        var file_name_buffer: [std.crypto.hash.Blake3.digest_length * 2 + ".json".len]u8 = undefined;
        const file_name = cache.fileName(relative_path, source, &file_name_buffer);
        try writeEntry(io, dir, file_name, bytes);
    }

    pub fn loadProject(
        cache: Cache,
        io: std.Io,
        allocator: std.mem.Allocator,
        sources: []const ProjectSource,
    ) !?[]const ProjectRecord {
        const dir = cache.dir orelse return null;
        var file_name_buffer: ["project-".len + std.crypto.hash.Blake3.digest_length * 2 + ".json".len]u8 = undefined;
        const file_name = cache.projectFileName(sources, &file_name_buffer);
        const bytes = try readEntry(io, dir, file_name, allocator) orelse return null;
        const parsed = std.json.parseFromSlice(StoredProject, allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        if (parsed.value.version != format_version) return null;
        for (parsed.value.findings) |finding| {
            if (finding.file_index >= sources.len or finding.start > finding.end or
                finding.end > sources[finding.file_index].source.len) return null;
        }
        return parsed.value.findings;
    }

    pub fn storeProject(
        cache: Cache,
        io: std.Io,
        allocator: std.mem.Allocator,
        sources: []const ProjectSource,
        findings: []const ProjectRecord,
    ) !void {
        const dir = cache.dir orelse return;
        var encoded: std.Io.Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        std.json.Stringify.value(
            StoredProject{ .version = format_version, .findings = findings },
            .{},
            &encoded.writer,
        ) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory, // an allocating writer fails only on allocation
        };
        const bytes = try encoded.toOwnedSlice();
        defer allocator.free(bytes);

        var file_name_buffer: ["project-".len + std.crypto.hash.Blake3.digest_length * 2 + ".json".len]u8 = undefined;
        const file_name = cache.projectFileName(sources, &file_name_buffer);
        try writeEntry(io, dir, file_name, bytes);
    }

    pub fn loadCross(
        cache: Cache,
        io: std.Io,
        allocator: std.mem.Allocator,
        relative_path: []const u8,
        source: []const u8,
    ) !?CrossEntry {
        const dir = cache.dir orelse return null;
        var file_name_buffer: [cross_name_length]u8 = undefined;
        const file_name = cache.crossFileName(relative_path, source, &file_name_buffer);
        const bytes = try readEntry(io, dir, file_name, allocator) orelse return null;
        const parsed = std.json.parseFromSliceLeaky(CrossEntry, allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        if (parsed.version != format_version) return null;
        for ([_][]const Record{ parsed.imports, parsed.members }) |records| {
            for (records) |record| if (record.start > record.end or record.end > source.len) return null;
        }
        return parsed;
    }

    pub fn storeCross(
        cache: Cache,
        io: std.Io,
        allocator: std.mem.Allocator,
        relative_path: []const u8,
        source: []const u8,
        entry: CrossEntry,
    ) !void {
        const dir = cache.dir orelse return;
        var encoded: std.Io.Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        std.json.Stringify.value(entry, .{}, &encoded.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory, // an allocating writer fails only on allocation
        };
        const bytes = try encoded.toOwnedSlice();
        defer allocator.free(bytes);
        var file_name_buffer: [cross_name_length]u8 = undefined;
        const file_name = cache.crossFileName(relative_path, source, &file_name_buffer);
        try writeEntry(io, dir, file_name, bytes);
    }

    const cross_name_length = "cross-".len + std.crypto.hash.Blake3.digest_length * 2 + ".json".len;

    fn crossFileName(
        cache: Cache,
        relative_path: []const u8,
        source: []const u8,
        buffer: *[cross_name_length]u8,
    ) []const u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&cache.identity);
        hasher.update("cross");
        hasher.update(std.mem.asBytes(&relative_path.len));
        hasher.update(relative_path);
        hasher.update(source);
        var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
        hasher.final(&digest);
        const hexadecimal = std.fmt.bytesToHex(digest, .lower);
        @memcpy(buffer[0.."cross-".len], "cross-");
        @memcpy(buffer["cross-".len..][0..hexadecimal.len], &hexadecimal);
        @memcpy(buffer["cross-".len + hexadecimal.len ..], ".json");
        return buffer;
    }

    /// The named-module table stored for the build in `build_root` when the
    /// build inputs hashed to `digest` (see `compile_units.buildDigest`).
    pub fn loadBuildModules(
        cache: Cache,
        io: std.Io,
        allocator: std.mem.Allocator,
        build_root: []const u8,
        digest: [std.crypto.hash.Blake3.digest_length]u8,
    ) !?build_graph.NamedModules {
        const dir = cache.dir orelse return null;
        var file_name_buffer: [build_modules_name_length]u8 = undefined;
        const file_name = cache.buildModulesFileName(build_root, digest, &file_name_buffer);
        const bytes = try readEntry(io, dir, file_name, allocator) orelse return null;
        const parsed = std.json.parseFromSliceLeaky(StoredModules, allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        if (parsed.version != format_version) return null;
        return .{ .units = parsed.units };
    }

    pub fn storeBuildModules(
        cache: Cache,
        io: std.Io,
        allocator: std.mem.Allocator,
        build_root: []const u8,
        digest: [std.crypto.hash.Blake3.digest_length]u8,
        table: build_graph.NamedModules,
    ) !void {
        const dir = cache.dir orelse return;
        var encoded: std.Io.Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        std.json.Stringify.value(
            StoredModules{ .version = format_version, .units = table.units },
            .{},
            &encoded.writer,
        ) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory, // an allocating writer fails only on allocation
        };
        const bytes = try encoded.toOwnedSlice();
        defer allocator.free(bytes);
        var file_name_buffer: [build_modules_name_length]u8 = undefined;
        const file_name = cache.buildModulesFileName(build_root, digest, &file_name_buffer);
        try writeEntry(io, dir, file_name, bytes);
    }

    const build_modules_name_length = "build-".len + std.crypto.hash.Blake3.digest_length * 2 + ".json".len;

    fn buildModulesFileName(
        cache: Cache,
        build_root: []const u8,
        digest: [std.crypto.hash.Blake3.digest_length]u8,
        buffer: *[build_modules_name_length]u8,
    ) []const u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&cache.identity);
        hasher.update("build-modules");
        hasher.update(std.mem.asBytes(&build_root.len));
        hasher.update(build_root);
        hasher.update(&digest);
        var name_digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
        hasher.final(&name_digest);
        const hexadecimal = std.fmt.bytesToHex(name_digest, .lower);
        @memcpy(buffer[0.."build-".len], "build-");
        @memcpy(buffer["build-".len..][0..hexadecimal.len], &hexadecimal);
        @memcpy(buffer["build-".len + hexadecimal.len ..], ".json");
        return buffer;
    }

    /// The entry's bytes, or null when it was never stored.
    fn readEntry(io: std.Io, dir: std.Io.Dir, file_name: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        return dir.readFileAlloc(io, file_name, allocator, .limited(cache_file_limit)) catch |err| switch (err) {
            error.FileNotFound => null,
            // Over the size limit: not something this cache wrote.
            error.StreamTooLong => null,
            else => err,
        };
    }

    fn writeEntry(io: std.Io, dir: std.Io.Dir, file_name: []const u8, bytes: []const u8) !void {
        var atomic_file = try dir.createFileAtomic(io, file_name, .{ .replace = true });
        defer atomic_file.deinit(io);
        try atomic_file.file.writeStreamingAll(io, bytes);
        try atomic_file.replace(io);
    }

    fn fileName(
        cache: Cache,
        relative_path: []const u8,
        source: []const u8,
        buffer: *[std.crypto.hash.Blake3.digest_length * 2 + ".json".len]u8,
    ) []const u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&cache.identity);
        hasher.update(std.mem.asBytes(&relative_path.len));
        hasher.update(relative_path);
        hasher.update(source);
        var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
        hasher.final(&digest);
        const hexadecimal = std.fmt.bytesToHex(digest, .lower);
        @memcpy(buffer[0..hexadecimal.len], &hexadecimal);
        @memcpy(buffer[hexadecimal.len..], ".json");
        return buffer;
    }

    fn projectFileName(
        cache: Cache,
        sources: []const ProjectSource,
        buffer: *["project-".len + std.crypto.hash.Blake3.digest_length * 2 + ".json".len]u8,
    ) []const u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&cache.identity);
        hasher.update("project");
        for (sources) |source| {
            hasher.update(std.mem.asBytes(&source.path.len));
            hasher.update(source.path);
            hasher.update(std.mem.asBytes(&source.source.len));
            hasher.update(source.source);
        }
        var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
        hasher.final(&digest);
        const hexadecimal = std.fmt.bytesToHex(digest, .lower);
        @memcpy(buffer[0.."project-".len], "project-");
        @memcpy(buffer["project-".len..][0..hexadecimal.len], &hexadecimal);
        @memcpy(buffer["project-".len + hexadecimal.len ..], ".json");
        return buffer;
    }
};

test "cache invalidates source path and configuration changes" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var configuration = analysis.Configuration.defaults();
    var cache = Cache.init(io, temporary.dir, configuration);
    defer cache.deinit(io);
    try std.testing.expect(cache.dir != null);
    const records = [_]Record{.{
        .rule = .unresolved_call,
        .level = .@"error",
        .start = 3,
        .end = 10,
        .message = "call to unresolved function 'missing'",
    }};
    try cache.store(io, allocator, "src/main.zig", "fn missing", &records);

    const loaded = try cache.load(io, allocator, "src/main.zig", "fn missing");
    try std.testing.expect(loaded != null);
    try std.testing.expectEqualStrings(records[0].message, loaded.?[0].message);
    try std.testing.expect(try cache.load(io, allocator, "src/main.zig", "fn changed") == null);
    try std.testing.expect(try cache.load(io, allocator, "src/other.zig", "fn missing") == null);

    configuration.levels[@backingInt(analysis.Rule.discarded_error)] = .information;
    var changed_cache = Cache.init(io, temporary.dir, configuration);
    defer changed_cache.deinit(io);
    try std.testing.expect(try changed_cache.load(io, allocator, "src/main.zig", "fn missing") == null);

    var settings_configuration = analysis.Configuration.defaults();
    settings_configuration.line_length_limit = 120;
    var settings_cache = Cache.init(io, temporary.dir, settings_configuration);
    defer settings_cache.deinit(io);
    try std.testing.expect(try settings_cache.load(io, allocator, "src/main.zig", "fn missing") == null);

    var contract_configuration = analysis.Configuration.defaults();
    contract_configuration.must_use_contracts = &.{"Builder.finish"};
    var contract_cache = Cache.init(io, temporary.dir, contract_configuration);
    defer contract_cache.deinit(io);
    try std.testing.expect(try contract_cache.load(io, allocator, "src/main.zig", "fn missing") == null);
}

test "project cache invalidates when any source changes" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var cache = Cache.init(io, temporary.dir, analysis.Configuration.defaults());
    defer cache.deinit(io);
    const sources = [_]ProjectSource{
        .{ .path = "src/main.zig", .source = "const support = @import(\"support.zig\");" },
        .{ .path = "src/support.zig", .source = "pub const value = 1;" },
    };
    const records = [_]ProjectRecord{.{
        .file_index = 0,
        .rule = .duplicate_module_import,
        .level = .warning,
        .start = 6,
        .end = 13,
        .message = "duplicate import",
    }};
    try cache.storeProject(io, allocator, &sources, &records);

    const loaded = (try cache.loadProject(io, allocator, &sources)).?;
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings(records[0].message, loaded[0].message);

    const changed_sources = [_]ProjectSource{
        sources[0],
        .{ .path = "src/support.zig", .source = "pub const value = 2;" },
    };
    try std.testing.expect(try cache.loadProject(io, allocator, &changed_sources) == null);
}

test "named module tables are keyed by build root and build inputs" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var cache = Cache.init(io, temporary.dir, analysis.Configuration.defaults());
    defer cache.deinit(io);
    const table: build_graph.NamedModules = .{ .units = &.{&.{
        .{ .root = "/p/main.zig", .imports = &.{.{ .name = "api", .module = 1 }} },
        .{ .root = "/p/api.zig", .imports = &.{} },
    }} };
    const digest: [std.crypto.hash.Blake3.digest_length]u8 = @splat(7);
    try cache.storeBuildModules(io, allocator, "/p", digest, table);
    const loaded = (try cache.loadBuildModules(io, allocator, "/p", digest)).?;
    try std.testing.expectEqualStrings("api", loaded.units[0][0].imports[0].name);
    try std.testing.expectEqualStrings("/p/api.zig", loaded.units[0][1].root.?);
    const changed: [std.crypto.hash.Blake3.digest_length]u8 = @splat(8);
    try std.testing.expect(try cache.loadBuildModules(io, allocator, "/p", changed) == null);
    try std.testing.expect(try cache.loadBuildModules(io, allocator, "/q", digest) == null);
}
