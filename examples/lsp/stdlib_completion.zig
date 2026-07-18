const std = @import("std");

fn namesMatch(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "standard library declarations resolve" {
    try std.testing.expect(namesMatch("zig", "zig"));
}
