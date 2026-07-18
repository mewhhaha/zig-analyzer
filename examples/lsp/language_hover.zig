const enabled: bool = true;

fn enabledSize() usize {
    return if (enabled) @sizeOf(u8) else 0;
}

test "language hover example remains valid Zig" {
    try @import("std").testing.expectEqual(@as(usize, 1), enabledSize());
}
