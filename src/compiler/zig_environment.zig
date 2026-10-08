const std = @import("std");

pub const Error = error{ ZigEnvironmentUnavailable, ZigEnvironmentMalformed, OutOfMemory };

/// The host compiler as `zig env` reports it.
pub const Environment = struct {
    lib_dir: []const u8,
    zig_exe: []const u8,
};

/// The Zig standard library directory reported by `zig env`. Discovered once
/// per process: a failure is remembered too, so a missing `zig` is not
/// re-spawned on every request. The returned path lives for the process.
pub fn libDirectory(io: std.Io) Error![]const u8 {
    return (try environment(io)).lib_dir;
}

/// The host `zig` executable, which runs the project's build script.
pub fn executable(io: std.Io) Error![]const u8 {
    return (try environment(io)).zig_exe;
}

fn environment(io: std.Io) Error!Environment {
    cache.mutex.lockUncancelable(io);
    defer cache.mutex.unlock(io);
    if (cache.outcome) |outcome| return outcome;
    cache.outcome = discover(io);
    return cache.outcome.?;
}

var cache: struct {
    mutex: std.Io.Mutex = .init,
    outcome: ?Error!Environment = null,
} = .{};

fn discover(io: std.Io) Error!Environment {
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "env" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| {
        std.log.err("could not run 'zig env': {t}", .{err});
        return error.ZigEnvironmentUnavailable;
    };
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
    const lib_dir = try parseField(allocator, result.stdout, ".lib_dir");
    errdefer allocator.free(lib_dir);
    return .{ .lib_dir = lib_dir, .zig_exe = try parseField(allocator, result.stdout, ".zig_exe") };
}

fn parseField(allocator: std.mem.Allocator, environment_text: []const u8, field: []const u8) error{ ZigEnvironmentMalformed, OutOfMemory }![]const u8 {
    const prefix = try allocator.print("{s} = \"", .{field});
    defer allocator.free(prefix);
    const start = std.mem.find(u8, environment_text, prefix) orelse return error.ZigEnvironmentMalformed;
    const value_start = start + prefix.len;
    const value_end = std.mem.findScalarPos(u8, environment_text, value_start, '"') orelse {
        return error.ZigEnvironmentMalformed;
    };
    return allocator.dupe(u8, environment_text[value_start..value_end]);
}

test "lib directory and executable are parsed from zig environment output" {
    const text = ".{\n    .zig_exe = \"/opt/zig/zig\",\n    .lib_dir = \"/opt/zig/lib\",\n}\n";
    const directory = try parseField(std.testing.allocator, text, ".lib_dir");
    defer std.testing.allocator.free(directory);
    const zig_exe = try parseField(std.testing.allocator, text, ".zig_exe");
    defer std.testing.allocator.free(zig_exe);

    try std.testing.expectEqualStrings("/opt/zig/lib", directory);
    try std.testing.expectEqualStrings("/opt/zig/zig", zig_exe);
}

test "missing lib directory is rejected" {
    try std.testing.expectError(
        error.ZigEnvironmentMalformed,
        parseField(std.testing.allocator, ".{ .zig_exe = \"/opt/zig/zig\" }", ".lib_dir"),
    );
}

test "discovery is remembered for the process" {
    const first = try libDirectory(std.testing.io);
    const second = try libDirectory(std.testing.io);
    try std.testing.expectEqual(first.ptr, second.ptr);
}
