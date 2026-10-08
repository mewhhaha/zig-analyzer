const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Only installed: the check step below does not reach it.
    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(app);

    const checked = b.addExecutable(.{
        .name = "checked",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/checked.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("check", "Check the checked executable").dependOn(&checked.step);
}
