//! Copies of the build projects under `fixtures/projects`, placed in a
//! temporary directory so configuring them never writes into the checkout.
const std = @import("std");

pub const Project = struct {
    tmp: std.testing.TmpDir,
    /// Absolute path of the copy; owned by the allocator given to `copy`.
    root: [:0]u8,

    pub fn deinit(project: *Project, allocator: std.mem.Allocator) void {
        allocator.free(project.root);
        project.tmp.cleanup();
        project.* = undefined;
    }

    /// `sub_path` below the project root, owned by `allocator`.
    pub fn path(project: Project, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        return std.Io.Dir.path.join(allocator, &.{ project.root, sub_path });
    }

    /// Replaces the file at `sub_path`.
    pub fn write(project: Project, sub_path: []const u8, data: []const u8) !void {
        try project.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    }

    pub fn exists(project: Project, sub_path: []const u8) !bool {
        project.tmp.dir.access(std.testing.io, sub_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
};

/// Copies `fixtures/projects/<name>` into a fresh temporary directory.
pub fn copy(allocator: std.mem.Allocator, name: []const u8) !Project {
    const io = std.testing.io;
    var project: Project = .{ .tmp = std.testing.tmpDir(.{}), .root = undefined };
    errdefer project.tmp.cleanup();
    const source_path = try std.Io.Dir.path.join(allocator, &.{ "fixtures/projects", name });
    defer allocator.free(source_path);
    var source = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source.close(io);
    var walker = try source.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try project.tmp.dir.createDirPath(io, entry.path),
        .file => try std.Io.Dir.copyFile(entry.dir, entry.basename, project.tmp.dir, entry.path, io, .{ .make_path = true }),
        else => {},
    };
    project.root = try project.tmp.dir.realPathFileAlloc(io, ".", allocator);
    return project;
}
