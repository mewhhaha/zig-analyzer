const std = @import("std");

const Reading = struct {
    sequence: u32,
    temperature: i16,
    humidity: u8,
};

fn Strategy(comptime Model: type) type {
    const fields = @typeInfo(Model).@"struct".fields;
    return if (fields.len >= 3 and fields[0].type == u32) struct {
        fn encode(model: Model) u32 {
            return model.sequence;
        }
    } else struct {
        fn unsupported() void {}
    };
}

const ReadingStrategy = Strategy(Reading);

fn result() u32 {
    return ReadingStrategy.encode(.{
        .sequence = 42,
        .temperature = 19,
        .humidity = 60,
    });
}

test "reflection selects the matching strategy" {
    try std.testing.expectEqual(@as(u32, 42), result());
}
