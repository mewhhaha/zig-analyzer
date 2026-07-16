const package = @import("package");
const std = @import("std");

const Mode = enum { fast, safe, checked };
const unused_private = 1;

const Options = struct {
    attempts: u8,
    verbose: bool,
};

fn analyze(mode: Mode, enabled: bool, err: anyerror) void {
    var attempts = 3;
    _ = attempts;

    _ = Options{};
    _ = switch (mode) {
        .fast => 1,
    };

    _ = enabled == true;
    _ = attempts + 1 << 2;
    _ = err == error.Failed;
    _ = missingFunction(attempts);
}

fn fallible() error{ Missing, Invalid }!u8 {
    return error.Missing;
}

fn optional() ?u8 {
    return null;
}

fn recoverValues() !void {
    _ = fallible();
    _ = optional();
}

fn returnOwnedStorage(allocator: std.mem.Allocator) ![]u8 {
    var values = std.ArrayList(u8).empty;
    defer values.deinit(allocator);
    return values.items;
}

fn transferOwnership(allocator: std.mem.Allocator) ![]u8 {
    const value = try allocator.alloc(u8, 1);
    defer allocator.free(value);
    return value;
}

fn readAfterInclusiveBound(values: []const u8, index: usize) u8 {
    std.debug.assert(index <= values.len);
    return values[index];
}

fn reverseWithUnsignedIndex(values: []const u8) void {
    if (values.len == 0) return;
    var index: usize = values.len - 1;
    while (index >= 0) : (index -= 1) {
        _ = values[index];
    }
}

const Payload = union(enum) {
    number: u8,
    code: u8,
};

fn mutatePayload(value: ?u8) void {
    var current = value;
    if (current) |payload| payload += 1;
}

fn inspectPayload(value: Payload) void {
    if (value == .number) {
        _ = value.number;
    }
}

fn formattingAndOverflow(allocator: std.mem.Allocator, count: usize) !void {
    std.debug.print("name {}", .{"zig"});
    _ = try allocator.alloc(u8, count * 4);
}

fn pointerCasts(source: *const u8) void {
    const target: *align(8) u16 = source;
    _ = target;
}

fn reflectedDispatch(value: Payload) u8 {
    inline for (@typeInfo(Payload).@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, @tagName(value))) return @field(value, field.name);
    }
    unreachable;
}

const Generated = @TypeOf(Payload{ .number = 1 });

comptime {
    _ = @hasDecl(Generated, "parse");
}

// This file is intentionally not compiled by `zig build examples`. Open it in
// an editor to exercise diagnostics and code actions on incomplete code.
