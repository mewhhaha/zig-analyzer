const std = @import("std");

pub fn build(b: *std.Build) void {
    const options = b.addOptions();
    options.addOption(u32, "answer", 40);
    options.addOption([]const u8, "label", "generated");

    const files = b.addWriteFiles();
    const table = files.add("table.zig", "pub const bonus: u32 = 2;\n");

    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "table", .module = b.createModule(.{ .root_source_file = table }) },
            },
        }),
    });
    b.installArtifact(app);
}
