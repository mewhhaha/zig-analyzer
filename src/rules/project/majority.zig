//! The corpus-majority proof behind the project convention rules: a spelling
//! is only called a convention when the project has enough samples and one
//! choice covers nine in ten of them.
const std = @import("std");

/// Samples required before any convention is enforced.
pub const min_samples: usize = 20;

/// Whether `dominant` of `total` samples is a strong enough majority.
pub fn strong(dominant: usize, total: usize) bool {
    return total >= min_samples and dominant * 10 >= total * 9;
}

/// Counts how often each value occurs within each group and remembers the
/// most frequent value of every group. Allocations belong to the scratch
/// arena of the project run; nothing here is freed individually.
pub const Tally = struct {
    groups: std.StringHashMapUnmanaged(Group) = .empty,
    counts: std.StringHashMapUnmanaged(usize) = .empty,

    pub const Group = struct {
        total: usize = 0,
        dominant: ?[]const u8 = null,
        dominant_count: usize = 0,

        /// Whether `value` departs from a strong majority of the group.
        pub fn isMinority(counts: Group, value: []const u8) bool {
            const dominant = counts.dominant orelse return false;
            return strong(counts.dominant_count, counts.total) and !std.mem.eql(u8, value, dominant);
        }
    };

    pub fn add(tally: *Tally, allocator: std.mem.Allocator, group_name: []const u8, value: []const u8) !void {
        const entry = try tally.groups.getOrPut(allocator, group_name);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.total += 1;
        const count = try tally.counts.getOrPut(allocator, try allocator.print("{s}\x00{s}", .{ group_name, value }));
        if (!count.found_existing) count.value_ptr.* = 0;
        count.value_ptr.* += 1;
        if (count.value_ptr.* > entry.value_ptr.dominant_count) {
            entry.value_ptr.dominant = value;
            entry.value_ptr.dominant_count = count.value_ptr.*;
        }
    }

    /// The tally of a group that `add` has seen.
    pub fn lookup(tally: Tally, group_name: []const u8) Group {
        return tally.groups.get(group_name).?;
    }
};

test "a convention needs enough samples and a strong majority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tally: Tally = .{};
    for (0..19) |_| try tally.add(arena.allocator(), "pkg", "db");
    try tally.add(arena.allocator(), "pkg", "store");
    try std.testing.expect(tally.lookup("pkg").isMinority("store"));
    try std.testing.expect(!tally.lookup("pkg").isMinority("db"));

    var sparse: Tally = .{};
    for (0..5) |_| try sparse.add(arena.allocator(), "pkg", "db");
    try sparse.add(arena.allocator(), "pkg", "store");
    try std.testing.expect(!sparse.lookup("pkg").isMinority("store"));
}
