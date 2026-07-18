const std = @import("std");

test "compiler patch uses the analyzer protocol and Zig versions" {
    const patch = @embedFile("zig-0.16.0-analysis.patch");
    const build_options = @import("build_options");

    var protocol_buffer: [64]u8 = undefined;
    const protocol_declaration = try std.fmt.bufPrint(
        &protocol_buffer,
        "pub const version: u16 = {d};",
        .{build_options.compiler_protocol_version},
    );
    try std.testing.expect(std.mem.indexOf(u8, patch, protocol_declaration) != null);

    var zig_version_buffer: [64]u8 = undefined;
    const zig_version_check = try std.fmt.bufPrint(
        &zig_version_buffer,
        "std.mem.eql(u8, zig_version, \"{s}\")",
        .{build_options.zig_version},
    );
    try std.testing.expect(std.mem.indexOf(u8, patch, zig_version_check) != null);
}
