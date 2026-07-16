const std = @import("std");

pub fn forgottenRelease(allocator: std.mem.Allocator) !void {
    const buffer = try allocator.alloc(u8, 128);
    @memset(buffer, 0);
}

pub fn errorPathOnly(allocator: std.mem.Allocator) !void {
    const buffer = try allocator.alloc(u8, 128);
    errdefer allocator.free(buffer);
    @memset(buffer, 0);
}

pub fn releasedCorrectly(allocator: std.mem.Allocator) !void {
    const buffer = try allocator.alloc(u8, 128);
    defer allocator.free(buffer);
    @memset(buffer, 0);
}

pub fn cleanupRegisteredTooLate(allocator: std.mem.Allocator) !void {
    const first = try allocator.alloc(u8, 128);
    const second = try allocator.alloc(u8, 128);
    defer allocator.free(first);
    defer allocator.free(second);
}
