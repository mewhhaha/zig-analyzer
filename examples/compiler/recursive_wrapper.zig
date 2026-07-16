const Leaf = struct {
    value: u32,
};

fn Wrapped(comptime depth: u8, comptime Inner: type) type {
    if (depth == 0) return Inner;
    return struct {
        inner: Wrapped(depth - 1, Inner),

        const Self = @This();

        fn unwrap(self: Self) Leaf {
            if (depth == 1) return self.inner;
            return self.inner.unwrap();
        }
    };
}

const TripleWrapped = Wrapped(3, Leaf);

fn result() u32 {
    const wrapped: TripleWrapped = .{ .inner = .{ .inner = .{ .inner = .{ .value = 42 } } } };
    return wrapped.unwrap().value;
}

test "recursive type construction exposes the wrapper API" {
    try @import("std").testing.expectEqual(@as(u32, 42), result());
}
