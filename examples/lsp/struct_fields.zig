const std = @import("std");

const Profile = struct {
    display_name: []const u8,
    login_count: u32,
};

fn displayName(profile: Profile) []const u8 {
    return profile.display_name;
}

test "ordinary struct fields remain available" {
    const profile: Profile = .{ .display_name = "ziggy", .login_count = 7 };
    try std.testing.expectEqualStrings("ziggy", displayName(profile));
}
