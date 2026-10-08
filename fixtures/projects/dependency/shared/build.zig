const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("shared", .{ .root_source_file = b.path("shared.zig") });
}
