const builtin = @import("builtin");
const std = @import("std");

const build_options = @import("build_options");

const filesystem = @import("../filesystem.zig");
const protocol = @import("protocol.zig");

const pathExists = filesystem.pathExists;

/// Everything the analyzer keeps per project lives under this directory.
pub const state_directory = ".zig-analyzer";
pub const source_directory = state_directory ++ "/zig-0.17.0";
pub const build_cache_directory = state_directory ++ "/compiler-cache";
pub const global_cache_directory = state_directory ++ "/compiler-global-cache";
pub const analysis_cache_directory = state_directory ++ "/analysis-cache";
/// Module sources the analyzer generates from build steps (see
/// `generated_sources.zig`), below the build root.
pub const generated_directory = state_directory ++ "/generated";
pub const backend_directory = "zig-out/backend";
pub const backend_binary = backend_directory ++ "/bin/zig";
pub const manifest_path = backend_directory ++ "/zig-analyzer-backend.json";
pub const patch_path = "compiler/zig-0.17.0-analysis.patch";
pub const protocol_source_path = "src/compiler/protocol.zig";
/// Where the shared protocol file lands inside the compiler checkout; the
/// patch imports it by this name.
const installed_protocol_path = source_directory ++ "/src/AnalysisProtocol.zig";

const upstream_url = "https://codeberg.org/ziglang/zig";

pub const Manifest = struct {
    analyzer_version: []const u8,
    zig_version: []const u8,
    zig_commit: []const u8,
    /// Digest of everything the backend is built from: the patch and the
    /// protocol source. See `inputsSha256`.
    backend_sha256: []const u8,
    compiler_protocol_version: u16,
};

pub const Backend = struct {
    binary_path: []u8,
    manifest_path: []u8,

    pub fn deinit(backend: *Backend, allocator: std.mem.Allocator) void {
        allocator.free(backend.binary_path);
        allocator.free(backend.manifest_path);
        backend.* = undefined;
    }
};

pub fn findBackend(io: std.Io, allocator: std.mem.Allocator) !?Backend {
    const executable_directory = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_directory);
    const installed_directory = try installedBackendDirectory(allocator, executable_directory);
    defer allocator.free(installed_directory);
    if (try findBackendInDirectories(io, allocator, installed_directory, installed_directory)) |backend| return backend;

    const source_install_directory = try std.Io.Dir.path.resolveAlloc(allocator, &.{ executable_directory, "../backend" });
    defer allocator.free(source_install_directory);
    const source_install_binary_directory = try std.Io.Dir.path.join(allocator, &.{ source_install_directory, "bin" });
    defer allocator.free(source_install_binary_directory);
    if (try findBackendInDirectories(io, allocator, source_install_binary_directory, source_install_directory)) |backend| return backend;

    return findBackendInDirectories(io, allocator, backend_directory ++ "/bin", backend_directory);
}

fn findBackendInDirectories(
    io: std.Io,
    allocator: std.mem.Allocator,
    binary_directory: []const u8,
    manifest_directory: []const u8,
) !?Backend {
    const binary_path = try std.Io.Dir.path.join(allocator, &.{ binary_directory, backendExecutableName() });
    errdefer allocator.free(binary_path);
    const backend_manifest_path = try std.Io.Dir.path.join(allocator, &.{ manifest_directory, "zig-analyzer-backend.json" });
    errdefer allocator.free(backend_manifest_path);
    if (try pathExists(io, binary_path) and try pathExists(io, backend_manifest_path)) {
        return .{
            .binary_path = binary_path,
            .manifest_path = backend_manifest_path,
        };
    }
    allocator.free(binary_path);
    allocator.free(backend_manifest_path);
    return null;
}

fn installedBackendDirectory(allocator: std.mem.Allocator, executable_directory: []const u8) ![]u8 {
    return std.Io.Dir.path.resolveAlloc(allocator, &.{ executable_directory, "../libexec/zig-analyzer" });
}

fn backendExecutableName() []const u8 {
    return if (builtin.target.os.tag == .windows) "zig.exe" else "zig";
}

pub fn bootstrap(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ) !void {
    try verifyBootstrapCompiler(io, allocator);
    try std.Io.Dir.cwd().createDirPath(io, state_directory);

    const current_inputs_sha256 = try inputsSha256(io, allocator);
    defer allocator.free(current_inputs_sha256);
    if (!try manifestMatches(io, allocator, current_inputs_sha256) and
        try pathExists(io, source_directory ++ "/.git"))
    {
        // A tree built from other inputs may carry an older patch or stray
        // edits; return it to the pristine upstream commit instead of
        // downloading a fresh checkout.
        try runChecked(io, allocator, source_directory, &.{ "git", "reset", "--hard", "HEAD" });
        try runChecked(io, allocator, source_directory, &.{ "git", "clean", "-fd" });
    }

    if (!try pathExists(io, source_directory ++ "/.git")) {
        try runChecked(io, allocator, null, &.{
            "git",
            "clone",
            "--depth",
            "1",
            "--branch",
            build_options.zig_version,
            upstream_url,
            source_directory,
        });
    }

    const actual_commit = try commandOutput(io, allocator, source_directory, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(actual_commit);
    if (!std.mem.eql(u8, actual_commit, build_options.zig_commit)) {
        return printFailure(io, "compiler source {s} is at commit {s}; expected {s}\n", .{
            source_directory,
            actual_commit,
            build_options.zig_commit,
        });
    }

    const patch_state = try detectPatchState(io, allocator);
    switch (patch_state) {
        .not_applied => try runChecked(io, allocator, source_directory, &.{ "git", "apply", "../../" ++ patch_path }),
        .applied => {},
        .conflicted => return printFailure(io, "compiler patch does not apply cleanly in {s}\n", .{source_directory}),
    }
    try installProtocolSource(io, allocator);

    try std.Io.Dir.cwd().createDirPath(io, backend_directory);
    try std.Io.Dir.cwd().createDirPath(io, build_cache_directory);
    try std.Io.Dir.cwd().createDirPath(io, global_cache_directory);

    const project_root = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(project_root);
    const absolute_backend_directory = try std.Io.Dir.path.join(allocator, &.{ project_root, backend_directory });
    defer allocator.free(absolute_backend_directory);
    const absolute_local_cache = try std.Io.Dir.path.join(allocator, &.{ project_root, build_cache_directory });
    defer allocator.free(absolute_local_cache);
    const absolute_global_cache = try std.Io.Dir.path.join(allocator, &.{ project_root, global_cache_directory });
    defer allocator.free(absolute_global_cache);

    var build_environment = try environ.createMap(allocator);
    defer build_environment.deinit();
    try build_environment.put("ZIG_GLOBAL_CACHE_DIR", absolute_global_cache);
    try build_environment.put("ZIG_LOCAL_CACHE_DIR", absolute_local_cache);

    try runCheckedWithEnvironment(io, allocator, source_directory, &.{
        "zig",
        "build",
        "-Dno-lib",
        "-Denable-llvm=false",
        "-Ddebug-extensions=true",
        "-Doptimize=safe",
        "-Dstrip=true",
        "-Dversion-string=0.17.0+zig-analyzer.1",
        "--cache-dir",
        absolute_local_cache,
        "--prefix",
        absolute_backend_directory,
    }, &build_environment);

    if (!try pathExists(io, backend_binary)) {
        return printFailure(io, "compiler build completed without producing {s}\n", .{backend_binary});
    }

    try writeManifest(io, allocator, current_inputs_sha256);

    var buffer: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    try file_writer.interface.print("zig-analyzer backend: built {s}\n", .{backend_binary});
    try file_writer.interface.flush();
}

pub fn readManifest(io: std.Io, allocator: std.mem.Allocator) !std.json.Parsed(Manifest) {
    return readManifestAt(io, allocator, manifest_path);
}

pub fn readManifestAt(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Manifest) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(Manifest, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// The digest this executable was built to expect, computed by build.zig from
/// the same two files `inputsSha256` reads.
pub const expected_inputs_sha256 = build_options.backend_sha256;

/// True when the installed manifest records the current inputs for this Zig
/// version. A missing manifest never matches; an unreadable one is reported
/// and treated as not matching so a corrupt file cannot wedge bootstrap.
fn manifestMatches(io: std.Io, allocator: std.mem.Allocator, inputs_sha256: []const u8) !bool {
    var manifest = readManifest(io, allocator) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => {
            var warning_buffer: [4096]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &warning_buffer);
            try stderr_writer.interface.print(
                "backend manifest {s} is unreadable ({t}); rebuilding the backend from scratch\n",
                .{ manifest_path, err },
            );
            try stderr_writer.interface.flush();
            return false;
        },
    };
    defer manifest.deinit();
    return std.mem.eql(u8, manifest.value.zig_version, build_options.zig_version) and
        std.mem.eql(u8, manifest.value.backend_sha256, inputs_sha256);
}

/// Installs the analyzer's protocol source into the compiler checkout so the
/// patched backend and the analyzer compile one definition of the wire format.
fn installProtocolSource(io: std.Io, allocator: std.mem.Allocator) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, protocol_source_path, allocator, .limited(1024 * 1024));
    defer allocator.free(source);
    if (std.Io.Dir.cwd().readFileAlloc(io, installed_protocol_path, allocator, .limited(1024 * 1024))) |installed| {
        defer allocator.free(installed);
        if (std.mem.eql(u8, installed, source)) return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = installed_protocol_path, .data = source });
}

fn verifyBootstrapCompiler(io: std.Io, allocator: std.mem.Allocator) !void {
    const actual_version = try commandOutput(io, allocator, null, &.{ "zig", "version" });
    defer allocator.free(actual_version);
    if (!std.mem.eql(u8, actual_version, build_options.zig_version)) {
        return printFailure(io, "backend bootstrap requires Zig {s}; found {s}\n", .{
            build_options.zig_version,
            actual_version,
        });
    }
}

const PatchState = enum { not_applied, applied, conflicted };

fn detectPatchState(io: std.Io, allocator: std.mem.Allocator) !PatchState {
    if (try commandSucceeds(io, allocator, source_directory, &.{ "git", "apply", "--check", "../../" ++ patch_path })) {
        return .not_applied;
    }
    if (try commandSucceeds(io, allocator, source_directory, &.{ "git", "apply", "--reverse", "--check", "../../" ++ patch_path })) {
        return .applied;
    }
    return .conflicted;
}

fn writeManifest(io: std.Io, allocator: std.mem.Allocator, inputs_sha256: []const u8) !void {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
    try std.json.Stringify.value(Manifest{
        .analyzer_version = build_options.version_string,
        .zig_version = build_options.zig_version,
        .zig_commit = build_options.zig_commit,
        .backend_sha256 = inputs_sha256,
        .compiler_protocol_version = protocol.version,
    }, .{ .whitespace = .indent_2 }, &allocating.writer);
    try allocating.writer.writeByte('\n');
    const bytes = try allocating.toOwnedSlice();
    defer allocator.free(bytes);
    // Write-temp-rename so a crash mid-write cannot leave a truncated
    // manifest next to a complete backend.
    var atomic_manifest = try std.Io.Dir.cwd().createFileAtomic(io, manifest_path, .{ .replace = true });
    defer atomic_manifest.deinit(io);
    try atomic_manifest.file.writeStreamingAll(io, bytes);
    try atomic_manifest.replace(io);
}

/// Digest of the compiler patch followed by the protocol source: the two
/// files the backend binary is built from besides upstream Zig.
pub fn inputsSha256(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    for ([_][]const u8{ patch_path, protocol_source_path }) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(bytes);
        hasher.update(bytes);
    }
    return try allocator.dupe(u8, &std.fmt.bytesToHex(hasher.finalResult(), .lower));
}

fn commandOutput(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    arguments: []const []const u8,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = arguments,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!exitedSuccessfully(result.term)) {
        return printFailure(io, "command '{s}' failed: {s}\n", .{ arguments[0], result.stderr });
    }
    return try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn runChecked(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    arguments: []const []const u8,
) !void {
    return runCheckedWithEnvironment(io, allocator, cwd, arguments, null);
}

fn runCheckedWithEnvironment(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    arguments: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = arguments,
        .environ_map = environ_map,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(32 * 1024 * 1024),
        .stderr_limit = .limited(32 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitedSuccessfully(result.term)) return;
    return printFailure(io, "command '{s}' failed:\n{s}\n{s}\n", .{ arguments[0], result.stdout, result.stderr });
}

fn commandSucceeds(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    arguments: []const []const u8,
) !bool {
    const result = try std.process.run(allocator, io, .{
        .argv = arguments,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return exitedSuccessfully(result.term);
}

fn exitedSuccessfully(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |exit_code| exit_code == 0,
        else => false,
    };
}

fn printFailure(io: std.Io, comptime format: []const u8, arguments: anytype) anyerror {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stderr().writer(io, &buffer);
    try file_writer.interface.print(format, arguments);
    try file_writer.interface.flush();
    return error.BootstrapFailed;
}

test "manifest captures the compatibility boundary" {
    const manifest = Manifest{
        .analyzer_version = "0.1.0-dev",
        .zig_version = "0.17.0",
        .zig_commit = build_options.zig_commit,
        .backend_sha256 = "abc",
        .compiler_protocol_version = 1,
    };
    try std.testing.expectEqualStrings("0.17.0", manifest.zig_version);
    try std.testing.expectEqual(@as(u16, 1), manifest.compiler_protocol_version);
}

test "installed backend lives beside the installation prefix" {
    const directory = try installedBackendDirectory(std.testing.allocator, "/opt/zig-analyzer/bin");
    defer std.testing.allocator.free(directory);
    try std.testing.expectEqualStrings("/opt/zig-analyzer/libexec/zig-analyzer", directory);
}

test "configured backend digest matches the patch and protocol sources" {
    const actual_digest = try inputsSha256(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actual_digest);
    try std.testing.expectEqualStrings(expected_inputs_sha256, actual_digest);
}
