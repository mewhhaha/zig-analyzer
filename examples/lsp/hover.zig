const std = @import("std");

/// Maximum number of attempts made by the example.
const retry_limit: u8 = 3;

/// Adds an incoming sample to an accumulated value.
fn addSample(accumulated: u32, incoming: u32) u32 {
    return accumulated + incoming;
}

fn compute(incoming: u32) u32 {
    const doubled: u32 = incoming * 2;
    return addSample(doubled, incoming) + retry_limit;
}

test "hover example produces the expected value" {
    try std.testing.expectEqual(@as(u32, 15), compute(4));
}
