const std = @import("std");

pub fn joinedPair(first: u8, second: u8) []u8 {
    var pair = [_]u8{ first, second };
    return pair[0..];
}

pub fn copiedPair(allocator: std.mem.Allocator, first: u8, second: u8) ![]u8 {
    const pair = [_]u8{ first, second };
    return allocator.dupe(u8, pair[0..]);
}
