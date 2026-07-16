const std = @import("std");

fn Client(comptime specification: []const u8) type {
    const separator = std.mem.indexOfScalar(u8, specification, ':').?;
    const retry_budget = std.fmt.parseInt(u8, specification[separator + 1 ..], 10) catch unreachable;

    return if (retry_budget >= 3) struct {
        fn retryBudget() u8 {
            return retry_budget;
        }
    } else struct {
        fn singleAttempt() void {}
    };
}

const ResilientClient = Client("retries:3");

fn result() u8 {
    return ResilientClient.retryBudget();
}

test "comptime parsing selects the resilient client" {
    try std.testing.expectEqual(@as(u8, 3), result());
}
