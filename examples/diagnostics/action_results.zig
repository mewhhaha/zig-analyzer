const std = @import("std");

const Payload = union(enum) {
    number: u8,
    code: u8,
};

const ResolvedPayload = union(enum) {
    number: @TypeOf(@field(@as(Payload, undefined), "number")),
    code: @TypeOf(@field(@as(Payload, undefined), "code")),
};

fn fallible() error{ Missing, Invalid }!u8 {
    return error.Missing;
}

fn propagateError() !u8 {
    return try fallible();
}

fn handleEveryError() u8 {
    return fallible() catch |err| switch (err) {
        error.Missing => @panic("TODO"),
        error.Invalid => @panic("TODO"),
    };
}

fn unwrapOptional(value: ?u8) u8 {
    return value orelse unreachable;
}

fn returnOwnedStorage(allocator: std.mem.Allocator) ![]u8 {
    var values = std.ArrayList(u8).empty;
    defer values.deinit(allocator);
    return try values.toOwnedSlice(allocator);
}

fn transferOwnership(allocator: std.mem.Allocator) ![]u8 {
    const value = try allocator.alloc(u8, 1);
    errdefer allocator.free(value);
    return value;
}

fn mutatePayload(value: ?u8) void {
    var current = value;
    if (current) |*payload| payload.* += 1;
}

fn inspectPayload(value: Payload) void {
    switch (value) {
        .number => |payload| {
            _ = payload;
        },
        else => {},
    }
}

fn inlineDispatch(value: Payload) u8 {
    return switch (value) {
        inline else => |payload| payload,
    };
}

fn checkedAllocation(allocator: std.mem.Allocator, count: usize) !void {
    const length = std.math.mul(usize, count, 4) catch @panic("allocation size overflow");
    const value = try allocator.alloc(u8, length);
    defer allocator.free(value);
}

fn pointerCasts(source: *const u8) *align(8) u16 {
    return @ptrCast(@alignCast(@constCast(source)));
}

fn repairedFormat() void {
    std.debug.print("name {s}", .{"zig"});
}

test "generated action forms compile" {
    _ = ResolvedPayload;
    _ = propagateError;
    _ = handleEveryError;
    _ = unwrapOptional;
    _ = returnOwnedStorage;
    _ = transferOwnership;
    _ = mutatePayload;
    _ = inspectPayload;
    _ = inlineDispatch;
    _ = checkedAllocation;
    _ = pointerCasts;
    _ = repairedFormat;
}
