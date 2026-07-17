const std = @import("std");

const flag_names = [_][:0]const u8{ "verbose", "cache", "trace" };

const CliFlags = @Struct(.auto, null, &flag_names, &@splat(bool), &@splat(.{}));

fn shouldLog(flags: CliFlags) bool {
    return flags.verbose;
}

test "reified flags expose one field per name" {
    const flags: CliFlags = .{ .verbose = true, .cache = false, .trace = true };
    try std.testing.expect(shouldLog(flags));
    try std.testing.expect(!flags.cache);
    try std.testing.expect(flags.trace);
}
