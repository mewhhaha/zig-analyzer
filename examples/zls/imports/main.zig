const std = @import("std");
const catalog = @import("catalog.zig");

fn result() u32 {
    return catalog.clampToLimit(100);
}

test "imported declarations resolve across files" {
    try std.testing.expectEqual(catalog.default_limit, result());
}
