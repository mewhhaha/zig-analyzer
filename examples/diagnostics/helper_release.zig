const std = @import("std");

fn recycleLine(allocator: std.mem.Allocator, line: []u8) void {
    allocator.free(line);
}

pub fn recycled(allocator: std.mem.Allocator) !void {
    const line = try allocator.alloc(u8, 80);
    line[0] = '>';
    recycleLine(allocator, line);
}

pub fn forgotten(allocator: std.mem.Allocator) !void {
    const line = try allocator.alloc(u8, 80);
    line[0] = '>';
}
