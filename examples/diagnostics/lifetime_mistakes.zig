const std = @import("std");

pub fn returningDeinitializedView(allocator: std.mem.Allocator) []u8 {
    var values = std.ArrayList(u8).empty;
    defer values.deinit(allocator);
    // expect: returning-deinitialized-view
    return values.items;
}

pub fn returningArenaAllocation(parent: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(parent);
    defer arena.deinit();
    // expect: returning-arena-allocation
    return try arena.allocator().dupe(u8, "temporary");
}

pub fn invalidatedElementPointer(allocator: std.mem.Allocator) !void {
    var values = std.ArrayList(u8).empty;
    defer values.deinit(allocator);
    try values.append(allocator, 1);
    // expect: invalidated-element-pointer
    const first = &values.items[0];
    try values.append(allocator, 2);
    _ = first.*;
}

pub fn reassignedDeferredBinding(allocator: std.mem.Allocator) !void {
    var bytes = try allocator.alloc(u8, 1);
    defer allocator.free(bytes);
    // expect: defer-uses-reassigned-binding
    bytes = try allocator.alloc(u8, 2);
}

pub fn errorOnlyResourceCleanup(dir: anytype) !void {
    // expect: resource-cleanup-on-error-only
    const file = try dir.openFile("input", .{});
    errdefer file.close();
}

pub fn uncheckedAllocationSize(allocator: std.mem.Allocator, count: usize) !void {
    // expect: allocation-size-overflow
    const bytes = try allocator.alloc(u8, count * 4);
    defer allocator.free(bytes);
}

pub fn invalidatedMapIterator(allocator: std.mem.Allocator) !void {
    var values = std.AutoHashMap(u8, u8).init(allocator);
    defer values.deinit();
    var iterator = values.iterator();
    while (iterator.next()) |_| {
        // expect: iterator-invalidated-during-loop
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
