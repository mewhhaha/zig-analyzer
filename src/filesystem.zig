//! Small filesystem predicates shared by the CLI, the language server, and
//! backend bootstrap.
const std = @import("std");

/// True when `path` (absolute, or relative to the process working directory)
/// exists. A missing path is not an error.
pub fn pathExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "pathExists distinguishes missing paths from present ones" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "present.zig", .data = "" });
    const present = try temporary.dir.realPathFileAlloc(std.testing.io, "present.zig", std.testing.allocator);
    defer std.testing.allocator.free(present);
    try std.testing.expect(try pathExists(std.testing.io, present));
    try std.testing.expect(!try pathExists(std.testing.io, "definitely/missing/path.zig"));
}
