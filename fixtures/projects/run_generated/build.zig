const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const generator = b.addExecutable(.{
        .name = "generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generator.zig"),
            .target = target,
        }),
    });
    // The generator writes `marker.txt` when it runs: analysis must not run it.
    const run = b.addRunArtifact(generator);
    const output = run.addOutputFileArg2("generated.zig", .{});
    run.addArg("marker.txt");
    run.setCwd(b.path("."));

    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "generated", .module = b.createModule(.{ .root_source_file = output }) },
            },
        }),
    });
    b.installArtifact(app);
}
