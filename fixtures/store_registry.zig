pub const Store = @import("store/backing.zig").Store;

pub fn Queue(comptime T: type) type {
    return struct {
        /// Pending entries in arrival order.
        entries: []const T,

        pub const empty: @This() = .{ .entries = &.{} };

        /// Appends one entry to the queue tail.
        pub fn push(self: *@This(), entry: T) void {
            _ = self;
            _ = entry;
        }
    };
}
