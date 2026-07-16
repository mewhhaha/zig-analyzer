const std = @import("std");

pub fn returningDeinitializedView(allocator: std.mem.Allocator) []u8 {
    var values = std.ArrayList(u8).empty;
    defer values.deinit(allocator);
    return values.items;
}

pub fn returningArenaAllocation(parent: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    return try arena.allocator().dupe(u8, "temporary");
}

pub fn invalidatedElementPointer(allocator: std.mem.Allocator) !void {
    var values = std.ArrayList(u8).empty;
    defer values.deinit(allocator);
    try values.append(allocator, 1);
    const first = &values.items[0];
    try values.append(allocator, 2);
    _ = first.*;
}

pub fn reassignedDeferredBinding(allocator: std.mem.Allocator) !void {
    var bytes = try allocator.alloc(u8, 1);
    defer allocator.free(bytes);
    bytes = try allocator.alloc(u8, 2);
}

pub fn errorOnlyResourceCleanup(dir: anytype) !void {
    const file = try dir.openFile("input", .{});
    errdefer file.close();
}

pub fn uncheckedAllocationSize(allocator: std.mem.Allocator, count: usize) !void {
    const bytes = try allocator.alloc(u8, count * 4);
    defer allocator.free(bytes);
}

pub fn invalidatedMapIterator(allocator: std.mem.Allocator) !void {
    var values = std.AutoHashMap(u8, u8).init(allocator);
    defer values.deinit();
    var iterator = values.iterator();
    while (iterator.next()) |_| {
        try values.put(1, 2);
    }
}

test "diagnostic examples remain valid Zig" {
    _ = returningDeinitializedView;
    _ = returningArenaAllocation;
    _ = invalidatedElementPointer;
    _ = reassignedDeferredBinding;
    _ = errorOnlyResourceCleanup;
    _ = uncheckedAllocationSize;
    _ = invalidatedMapIterator;
}
