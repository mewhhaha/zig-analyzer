const std = @import("std");

pub fn isTranslateCOutput(source: []const u8) bool {
    const prefix = source[0..@min(source.len, 32 * 1024)];
    if (std.mem.indexOf(u8, prefix, "pub const __builtin_") == null or
        std.mem.indexOf(u8, prefix, ".zig.c_builtins.") == null) return false;
    return std.mem.count(u8, prefix, "pub const __builtin_") >= 3;
}

test "translate-c preambles are recognized without treating ordinary bindings as generated" {
    try std.testing.expect(isTranslateCOutput(
        "pub const __builtin_bswap16 = @import(\"std\").zig.c_builtins.__builtin_bswap16;\n" ++
            "pub const __builtin_bswap32 = @import(\"std\").zig.c_builtins.__builtin_bswap32;\n" ++
            "pub const __builtin_bswap64 = @import(\"std\").zig.c_builtins.__builtin_bswap64;\n",
    ));
    try std.testing.expect(!isTranslateCOutput("pub const __builtin_value = 1;\n"));
}
