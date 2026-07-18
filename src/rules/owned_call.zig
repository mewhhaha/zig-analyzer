const std = @import("std");

pub fn releaseForMethod(method: []const u8) ?[]const u8 {
    const free_methods = [_][]const u8{
        "alloc",
        "allocSentinel",
        "alignedAlloc",
        "dupe",
        "dupeZ",
        "realloc",
    };
    for (free_methods) |candidate| {
        if (std.mem.eql(u8, method, candidate)) return "free";
    }
    if (std.mem.eql(u8, method, "create")) return "destroy";
    return null;
}

pub fn standardAllocatorArgument(callable: []const u8) ?usize {
    const callables = [_][]const u8{
        "std.mem.concat",
        "std.mem.concatWithSentinel",
        "std.mem.join",
        "std.mem.joinZ",
        "std.fmt.allocPrint",
        "std.fmt.allocPrintSentinel",
        "std.fs.path.join",
        "std.fs.path.joinZ",
        "std.fs.path.resolve",
    };
    for (callables) |candidate| {
        if (std.mem.eql(u8, callable, candidate)) return 0;
    }
    return null;
}

pub fn releaseForCallable(callable: []const u8) ?[]const u8 {
    if (standardAllocatorArgument(callable) != null) return "free";
    const separator = std.mem.lastIndexOfScalar(u8, callable, '.');
    const method = if (separator) |position| callable[position + 1 ..] else callable;
    const release = releaseForMethod(method) orelse return null;
    if (!std.mem.eql(u8, method, "create")) return release;
    const position = separator orelse return null;
    const receiver = callable[0..position];
    const receiver_name = if (std.mem.lastIndexOfScalar(u8, receiver, '.')) |receiver_separator|
        receiver[receiver_separator + 1 ..]
    else
        receiver;
    return if (std.ascii.indexOfIgnoreCase(receiver_name, "alloc") != null or
        std.ascii.indexOfIgnoreCase(receiver_name, "pool") != null or
        std.mem.eql(u8, receiver_name, "gpa")) release else null;
}

test "standard allocator functions return memory released with free" {
    try std.testing.expectEqual(@as(?usize, 0), standardAllocatorArgument("std.mem.concat"));
    try std.testing.expectEqualStrings("free", releaseForCallable("std.fs.path.resolve").?);
    try std.testing.expect(standardAllocatorArgument("project.mem.concat") == null);
}
