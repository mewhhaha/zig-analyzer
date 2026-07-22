const std = @import("std");

pub fn libDirectory(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "zig", "env" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |exit_code| exit_code == 0,
        else => false,
    };
    if (!succeeded) {
        std.log.err("'zig env' failed: {s}", .{result.stderr});
        return error.ZigEnvironmentUnavailable;
    }
    return parseLibDirectory(allocator, result.stdout);
}

fn parseLibDirectory(allocator: std.mem.Allocator, environment: []const u8) ![]u8 {
    const prefix = ".lib_dir = \"";
    const start = std.mem.indexOf(u8, environment, prefix) orelse return error.ZigEnvironmentMalformed;
    const value_start = start + prefix.len;
    const value_end = std.mem.indexOfScalarPos(u8, environment, value_start, '"') orelse {
        return error.ZigEnvironmentMalformed;
    };
    return allocator.dupe(u8, environment[value_start..value_end]);
}

test "lib directory is parsed from zig environment output" {
    const directory = try parseLibDirectory(
        std.testing.allocator,
        ".{\n    .zig_exe = \"/opt/zig/zig\",\n    .lib_dir = \"/opt/zig/lib\",\n}\n",
    );
    defer std.testing.allocator.free(directory);

    try std.testing.expectEqualStrings("/opt/zig/lib", directory);
}

test "missing lib directory is rejected" {
    try std.testing.expectError(
        error.ZigEnvironmentMalformed,
        parseLibDirectory(std.testing.allocator, ".{ .zig_exe = \"/opt/zig/zig\" }"),
    );
}
