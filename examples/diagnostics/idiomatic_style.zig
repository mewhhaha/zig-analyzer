const std = @import("std");

const json = struct {
    pub const JsonValue = union(enum) {
        number: f64,
        boolean: bool,
    };
};

const Mode = enum { fast, safe };
const Options = struct { count: u32 };

fn load() !u32 {
    return 42;
}

fn inspect(optional: ?u32, actual: u32, pointer: *u32) !void {
    if (optional != null) {
        _ = optional.?;
    }

    const loaded = load() catch |err| return err;
    try std.testing.expect(actual == 42);

    const mode: Mode = Mode.fast;
    const options: Options = Options{ .count = pointer.* };
    _ = loaded;
    _ = mode;
    _ = options;
}

fn localBytes() []u8 {
    var bytes = [_]u8{ 1, 2, 3 };
    return bytes[0..];
}

fn inspectCapture(optional: ?u32) void {
    _ = optional orelse unreachable;
    if (optional) |value| {
        _ = optional.?;
        _ = value;
    }
}

fn openAfterFallibleWork(dir: std.fs.Dir) !void {
    const file = try dir.openFile("input", .{});
    _ = try load();
    defer file.close();
}

fn collapsedError() ?u32 {
    return load() catch null;
}

fn optionalPresence(optional: ?u32) bool {
    return if (optional) |_| true else false;
}

fn manuallyTerminated(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, input.len + 1);
    @memcpy(result[0..input.len], input);
    result[input.len] = 0;
    return result;
}

fn expectedFailure() !void {
    return error.NotFound;
}

test "idiomatic style actions preserve behavior" {
    var count: u32 = 42;
    try inspect(42, 42, &count);
    inspectCapture(42);
    try std.testing.expect(std.mem.eql(u8, "zig", "zig"));
    try std.testing.expect(std.mem.eql(u32, &.{ 1, 2 }, &.{ 1, 2 }));
    const actual_float: f64 = 1.0;
    const expected_float: f64 = 1.001;
    const tolerance: f64 = 0.01;
    try std.testing.expect(@abs(actual_float - expected_float) <= tolerance);
    try std.testing.expect(optionalPresence(42));
    try std.testing.expectEqual(@as(?u32, 42), collapsedError());
    _ = manuallyTerminated;
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(json.JsonValue).@"union".fields.len);
}

test "manual error expectation" {
    expectedFailure() catch |err| {
        try std.testing.expectEqual(error.NotFound, err);
        return;
    };
    return error.TestExpectedError;
}
