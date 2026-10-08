//! Formats Zig source by running `zig fmt --stdin`, preferring the patched
//! compiler the analyzer installed so formatting matches its Zig version.
const std = @import("std");
const bootstrap = @import("bootstrap.zig");

/// The formatted `source`; the caller owns the result.
pub fn format(io: std.Io, allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var backend = try bootstrap.findBackend(io, allocator);
    defer if (backend) |*installed| installed.deinit(allocator);
    const zig_binary = if (backend) |installed| installed.binary_path else "zig";
    var child = try std.process.spawn(io, .{
        .argv = &.{ zig_binary, "fmt", "--stdin" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    try child.stdin.?.writeStreamingAll(io, source);
    child.stdin.?.close(io);
    child.stdin = null;

    var stdout_reader = child.stdout.?.readerStreaming(io, &.{});
    const formatted = try stdout_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
    errdefer allocator.free(formatted);
    var stderr_reader = child.stderr.?.readerStreaming(io, &.{});
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(stderr);

    const term = try child.wait(io);
    const succeeded = switch (term) {
        .exited => |exit_code| exit_code == 0,
        else => false,
    };
    if (!succeeded) {
        std.log.err("Zig formatter failed: {s}", .{stderr});
        return error.FormattingFailed;
    }
    return formatted;
}

test "formatting returns the Zig formatter result" {
    const formatted = try format(std.testing.io, std.testing.allocator, "const answer=42;\n");
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("const answer = 42;\n", formatted);
}
