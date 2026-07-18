const std = @import("std");

fn increment(value: u32) u32 {
    return value + 1;
}

fn describe(value: []const u8) []const u8 {
    return value;
}

test "same spelling in separate scopes keeps separate identities" {
    try std.testing.expectEqual(@as(u32, 42), increment(41));
    try std.testing.expectEqualStrings("zig", describe("zig"));
}
