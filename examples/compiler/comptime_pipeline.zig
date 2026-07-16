const Stage = enum { buffered, traced };

const Source = struct {
    value: u32,
};

fn Buffered(comptime Inner: type) type {
    return struct {
        inner: Inner,

        const Self = @This();

        fn flush(self: Self) u32 {
            return self.inner.value;
        }
    };
}

fn Traced(comptime Inner: type) type {
    return struct {
        inner: Inner,

        const Self = @This();

        fn trace(self: Self) u32 {
            return self.inner.flush();
        }
    };
}

fn Pipeline(comptime stages: []const Stage) type {
    comptime var current = Source;
    inline for (stages) |stage| {
        current = switch (stage) {
            .buffered => Buffered(current),
            .traced => Traced(current),
        };
    }
    return current;
}

const ActivePipeline = Pipeline(&.{ .buffered, .traced });

fn result() u32 {
    const pipeline: ActivePipeline = .{ .inner = .{ .inner = .{ .value = 42 } } };
    return pipeline.trace();
}

test "comptime pipeline exposes the final stage" {
    try @import("std").testing.expectEqual(@as(u32, 42), result());
}
