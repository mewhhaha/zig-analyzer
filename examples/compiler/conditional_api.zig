const std = @import("std");

fn Api(comptime features: []const []const u8) type {
    comptime var metrics_enabled = false;
    inline for (features) |feature| {
        if (std.mem.eql(u8, feature, "metrics")) metrics_enabled = true;
    }

    return if (metrics_enabled) struct {
        fn recordMetric(value: u32) u32 {
            return value + 1;
        }
    } else struct {
        fn disabled() void {}
    };
}

const ActiveApi = Api(&.{ "logging", "metrics" });

fn result() u32 {
    return ActiveApi.recordMetric(41);
}

test "comptime string selection exposes the enabled API" {
    try std.testing.expectEqual(@as(u32, 42), result());
}
