const std = @import("std");

const json = struct {
    // expect: redundant-qualified-name
    pub const JsonValue = union(enum) {
        number: f64,
        boolean: bool,
    };
};

const Mode = enum { fast, safe };
const Options = struct { count: u32 };
const Resource = struct {
    fn close(_: Resource) void {}
};

fn load() !u32 {
    return 42;
}

// expect: mutable-pointer-parameter
fn inspect(optional: ?u32, actual: u32, pointer: *u32) !void {
    // expect: prefer-optional-capture
    if (optional != null) {
        _ = optional.?;
    }

    // expect: prefer-try
    const loaded = load() catch |err| return err;
    // expect: prefer-testing-expect-equal
    try std.testing.expect(actual == 42);

    // expect: redundant-type-qualification
    const mode: Mode = Mode.fast;
    // expect: prefer-anonymous-initializer
    const options: Options = Options{ .count = pointer.* };
    _ = loaded;
    _ = mode;
    _ = options;
}

fn localBytes() []u8 {
    var bytes = [_]u8{ 1, 2, 3 };
    // expect: returning-local-slice
    return bytes[0..];
}

fn inspectCapture(optional: ?u32) void {
    // expect: unsafe-orelse-unreachable
    _ = optional orelse unreachable;
    // expect: redundant-optional-unwrap
    if (optional) |value| {
        _ = optional.?;
        _ = value;
    }
}

fn openAfterFallibleWork(dir: std.fs.Dir) !void {
    // expect: cleanup-after-fallible-operation
    const file = try dir.openFile("input", .{});
    _ = try load();
    defer file.close();
}

fn collapsedError() ?u32 {
    // expect: error-collapsed-to-absence
    return load() catch null;
}

fn directBoolean(value: u32) bool {
    // expect: redundant-boolean-if
    return if (value != 0) true else false;
}

fn closeResource(resource: Resource) void {
    // expect: needless-defer-block
    defer {
        resource.close();
    }
}

fn runWhenEnabled(enabled: bool) void {
    if (enabled) {
        closeResource(.{});
        // expect: needless-empty-else
    } else {}
}

fn optionalPresence(optional: ?u32) bool {
    // expect: prefer-optional-presence-test
    return if (optional) |_| true else false;
}

fn manuallyTerminated(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // expect: prefer-sentinel-termination
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
    // expect: prefer-testing-expect-equal-strings
    try std.testing.expect(std.mem.eql(u8, "zig", "zig"));
    // expect: prefer-testing-expect-equal-slices
    try std.testing.expect(std.mem.eql(u32, &.{ 1, 2 }, &.{ 1, 2 }));
    const actual_float: f64 = 1.0;
    const expected_float: f64 = 1.001;
    const tolerance: f64 = 0.01;
    // expect: prefer-testing-expect-approx
    try std.testing.expect(@abs(actual_float - expected_float) <= tolerance);
    try std.testing.expect(optionalPresence(42));
    try std.testing.expectEqual(@as(?u32, 42), collapsedError());
    try std.testing.expect(directBoolean(1));
    closeResource(.{});
    runWhenEnabled(true);
    _ = manuallyTerminated;
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(json.JsonValue).@"union".field_names.len);
}

test "manual error expectation" {
    // expect: prefer-testing-expect-error
    expectedFailure() catch |err| {
        try std.testing.expectEqual(error.NotFound, err);
        return;
    };
    return error.TestExpectedError;
}
