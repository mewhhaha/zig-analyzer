const std = @import("std");

pub fn readAfterRelease(allocator: std.mem.Allocator) !u8 {
    const line = try allocator.alloc(u8, 32);
    allocator.free(line);
    return line[0];
}

pub fn releasedTwice(allocator: std.mem.Allocator) !void {
    const line = try allocator.alloc(u8, 32);
    defer allocator.free(line);
    allocator.free(line);
}

pub fn releasedOnce(allocator: std.mem.Allocator) !u8 {
    const line = try allocator.alloc(u8, 32);
    defer allocator.free(line);
    @memset(line, ' ');
    return line[0];
}
