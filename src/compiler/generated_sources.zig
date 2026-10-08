//! Generation steps the analyzer carries out itself so a module whose root
//! source is generated can still be analyzed. Only steps whose output is a
//! pure function of the serialized build configuration run here: `Options`
//! (the `build_options` module) and `WriteFile`. Nothing is ever executed, so
//! steps that run a program (`Run`), translate C, or need a compiled artifact
//! are reported as unavailable instead.
//!
//! Outputs are content-addressed files below `generated_root`, so repeated
//! discovery reuses them and concurrent analyzers write identical bytes.
const std = @import("std");

const Configuration = std.Build.Configuration;

/// Largest single file mirrored into a generated directory.
const max_file_bytes = 16 * 1024 * 1024;
/// Most files one `WriteFile` step may mirror.
const max_files = 4096;

pub const Generated = struct {
    path: []const u8,
    /// Name of the step that produced `path`.
    step: []const u8,
};

pub const Unavailable = struct {
    /// Name of the step the analyzer did not (or could not) run.
    step: []const u8,
    reason: []const u8,
};

/// What a lazy path or a generation step resolves to.
pub const Resolved = union(enum) {
    /// A file in the source tree or in a dependency package.
    file: []const u8,
    /// A file the analyzer produced from a generation step.
    generated: Generated,
    unavailable: Unavailable,

    pub fn unavailableBecause(step: []const u8, reason: []const u8) Resolved {
        return .{ .unavailable = .{ .step = step, .reason = reason } };
    }
};

/// Materializes an `Options` step as `<generated_root>/<digest>/options.zig`.
/// `resolver.resolve(lazy_path)` resolves the paths the options mention.
pub fn options(
    io: std.Io,
    arena: std.mem.Allocator,
    conf: *const Configuration,
    step_index: Configuration.Step.Index,
    generated_root: []const u8,
    resolver: anytype,
) error{OutOfMemory}!Resolved {
    const step = step_index.ptr(conf);
    const step_name = step.name.slice(conf);
    const conf_options = step.extended.get(conf.extra).options;

    var declarations: std.ArrayList([]const u8) = .empty;
    inline for (.{ conf_options.files.slice, conf_options.directories.slice, conf_options.untracked_paths.slice }) |named_paths| {
        for (named_paths) |named| {
            const path = switch (try resolver.resolve(named.path)) {
                .file => |file| file,
                .generated => |generated| generated.path,
                .unavailable => |unavailable| return .{ .unavailable = unavailable },
            };
            try declarations.append(arena, try arena.print("pub const {f}: []const u8 = \"{f}\";\n", .{
                std.zig.fmtId(named.name.slice(conf)), std.zig.fmtString(path),
            }));
        }
    }

    const contents = conf_options.contents.slice(conf);
    const path_declarations = try std.mem.concat(arena, u8, declarations.items);
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    hasher.update("options\x00");
    hasher.update(contents);
    hasher.update("\x00");
    hasher.update(path_declarations);
    const directory = try digestDirectory(arena, generated_root, hasher.finalResult());
    const path = try std.Io.Dir.path.join(arena, &.{ directory, "options.zig" });

    const bytes = try std.mem.concat(arena, u8, &.{ contents, path_declarations });
    writeAtomically(arena, io, path, bytes) catch |err| return .unavailableBecause(step_name, try arena.print("could not write {s}: {t}", .{ path, err }));
    return .{ .generated = .{ .path = path, .step = step_name } };
}

/// Materializes a `WriteFile` step as the directory
/// `<generated_root>/<digest>`. A step that mutates the source tree in place
/// is unavailable.
pub fn writeFile(
    io: std.Io,
    arena: std.mem.Allocator,
    conf: *const Configuration,
    step_index: Configuration.Step.Index,
    generated_root: []const u8,
    resolver: anytype,
) error{OutOfMemory}!Resolved {
    const step = step_index.ptr(conf);
    const step_name = step.name.slice(conf);
    const write_file = step.extended.get(conf.extra).write_file;
    if (write_file.flags.mode == .mutate) {
        return .unavailableBecause(step_name, "it rewrites files in the source tree in place");
    }

    var entries: std.ArrayList(Entry) = .empty;
    for (write_file.embeds.slice) |embed| {
        try entries.append(arena, .{ .sub_path = embed.sub_path.slice(conf), .bytes = embed.contents.slice(conf) });
    }
    for (write_file.copies.slice) |copy| {
        const source_path = switch (try resolver.resolve(copy.src_file)) {
            .file => |file| file,
            .generated => |generated| generated.path,
            .unavailable => |unavailable| return .{ .unavailable = unavailable },
        };
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, source_path, arena, .limited(max_file_bytes)) catch |err| {
            return .unavailableBecause(step_name, try arena.print("could not read {s}: {t}", .{ source_path, err }));
        };
        try entries.append(arena, .{ .sub_path = copy.sub_path.slice(conf), .bytes = bytes });
    }
    for (write_file.directories.slice) |directory| {
        const source_path = switch (try resolver.resolve(directory.src_path)) {
            .file => |file| file,
            .generated => |generated| generated.path,
            .unavailable => |unavailable| return .{ .unavailable = unavailable },
        };
        const copied = copyDirectory(io, arena, conf, source_path, directory, &entries) catch |err| {
            return .unavailableBecause(step_name, try arena.print("could not read directory {s}: {t}", .{ source_path, err }));
        };
        if (!copied) return .unavailableBecause(step_name, "it copies more files than the analyzer mirrors");
    }

    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    hasher.update("write-file\x00");
    for (entries.items) |entry| {
        hasher.update(entry.sub_path);
        hasher.update("\x00");
        hasher.update(std.mem.asBytes(&entry.bytes.len));
        hasher.update(entry.bytes);
    }
    const directory = try digestDirectory(arena, generated_root, hasher.finalResult());
    const marker = try std.Io.Dir.path.join(arena, &.{ directory, ".complete" });
    var complete = true;
    std.Io.Dir.cwd().access(io, marker, .{}) catch |err| switch (err) {
        error.FileNotFound => complete = false,
        else => return .unavailableBecause(step_name, try arena.print("could not inspect {s}: {t}", .{ directory, err })),
    };
    if (!complete) {
        for (entries.items) |entry| {
            const path = try std.Io.Dir.path.join(arena, &.{ directory, entry.sub_path });
            writeAtomically(arena, io, path, entry.bytes) catch |err| {
                return .unavailableBecause(step_name, try arena.print("could not write {s}: {t}", .{ path, err }));
            };
        }
        writeAtomically(arena, io, marker, "") catch |err| {
            return .unavailableBecause(step_name, try arena.print("could not write {s}: {t}", .{ marker, err }));
        };
    }
    return .{ .generated = .{ .path = directory, .step = step_name } };
}

const Entry = struct {
    /// Path inside the generated directory.
    sub_path: []const u8,
    bytes: []const u8,
};

/// Appends every file of `directory_path` that the step's extension filters
/// admit. False when the directory holds too many files to mirror.
fn copyDirectory(
    io: std.Io,
    arena: std.mem.Allocator,
    conf: *const Configuration,
    directory_path: []const u8,
    directory: Configuration.Step.WriteFile.Directory,
    entries: *std.ArrayList(Entry),
) !bool {
    const exclude_extensions = directory.exclude_extensions.slice(conf) orelse &.{};
    const include_extensions = directory.include_extensions.slice(conf);
    var source = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer source.close(io);
    var walker = try source.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !pathIncluded(conf, exclude_extensions, include_extensions, entry.path)) continue;
        if (entries.items.len == max_files) return false;
        const bytes = try entry.dir.readFileAlloc(io, entry.basename, arena, .limited(max_file_bytes));
        try entries.append(arena, .{
            .sub_path = try std.Io.Dir.path.join(arena, &.{ directory.sub_path.slice(conf), entry.path }),
            .bytes = bytes,
        });
    }
    return true;
}

/// The step's extension filters, as `std.Build.Step.WriteFile` applies them.
fn pathIncluded(
    conf: *const Configuration,
    exclude_extensions: []const Configuration.String,
    include_extensions: ?[]const Configuration.String,
    path: []const u8,
) bool {
    for (exclude_extensions) |extension| {
        if (std.mem.endsWith(u8, path, extension.slice(conf))) return false;
    }
    const includes = include_extensions orelse return true;
    for (includes) |extension| {
        if (std.mem.endsWith(u8, path, extension.slice(conf))) return true;
    }
    return false;
}

fn digestDirectory(arena: std.mem.Allocator, generated_root: []const u8, digest: [32]u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return std.Io.Dir.path.join(arena, &.{ generated_root, &hex });
}

/// Writes `bytes` to `path` through a temporary file so a concurrent reader
/// never sees a partial file. Content-addressed callers may race harmlessly.
fn writeAtomically(arena: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const directory = std.Io.Dir.path.dirname(path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(io, directory);
    var random: u64 = undefined;
    io.random(std.mem.asBytes(&random));
    const temporary = try arena.print("{s}.{x}.tmp", .{ path, random });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = bytes });
    try std.Io.Dir.rename(std.Io.Dir.cwd(), temporary, std.Io.Dir.cwd(), path, io);
}
