const Implementations = struct {
    const compact = struct {
        fn pack(value: u32) u32 {
            return value;
        }
    };

    const checked = struct {
        fn verify(value: u32) bool {
            return value == 42;
        }
    };
};

fn Implementation(comptime name: []const u8) type {
    return @field(Implementations, name);
}

const ActiveImplementation = Implementation("checked");

fn result() bool {
    return ActiveImplementation.verify(42);
}

test "comptime field lookup selects a type" {
    try @import("std").testing.expect(result());
}
