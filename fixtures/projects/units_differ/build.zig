const std = @import("std");

/// One source file built twice with different build options: the declaration
/// `Backend.start` resolves to a different function in each configuration.
pub fn build(b: *std.Build) void {
    const check = b.step("check", "Check both configurations");
    const target = b.standardTargetOptions(.{});
    inline for (.{ .{ "threaded", true }, .{ "single", false } }) |configuration| {
        const options = b.addOptions();
        options.addOption(bool, "threaded", configuration[1]);
        const executable = b.addExecutable(.{
            .name = configuration[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
            }),
        });
        check.dependOn(&executable.step);
    }
}
