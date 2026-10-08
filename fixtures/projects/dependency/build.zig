const std = @import("std");

pub fn build(b: *std.Build) void {
    const shared = b.dependency("shared", .{}).module("shared");
    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .imports = &.{.{ .name = "shared", .module = shared }},
        }),
    });
    b.installArtifact(app);
}
