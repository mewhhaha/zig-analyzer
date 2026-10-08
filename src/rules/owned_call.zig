const std = @import("std");
const syntax_scope = @import("../syntax/scope.zig");
const resources = @import("resources.zig");

pub fn printReceiverIsAllocator(source: []const u8, tokens: []const std.zig.Token, receiver_end: usize) bool {
    if (receiver_end >= tokens.len or tokens[receiver_end].tag != .identifier) return false;
    if (receiver_end == 0 or tokens[receiver_end - 1].tag != .period) {
        const binding = syntax_scope.findBinding(source, tokens, receiver_end) orelse return false;
        const name_index = binding.token_index;
        if (name_index + 2 < tokens.len and tokens[name_index + 1].tag == .colon) {
            var index = name_index + 2;
            while (index < tokens.len) : (index += 1) switch (tokens[index].tag) {
                .comma, .equal, .r_paren, .semicolon, .l_brace => return false,
                .keyword_anytype => break,
                .identifier => if (allocatorTypeAt(source, tokens, index)) return true,
                else => {},
            };
        }
    }
    const name = source[tokens[receiver_end].loc.start..tokens[receiver_end].loc.end];
    return std.mem.eql(u8, name, "allocator") or std.mem.eql(u8, name, "alloc") or
        std.mem.eql(u8, name, "gpa") or std.mem.eql(u8, name, "arena");
}

fn allocatorTypeAt(source: []const u8, tokens: []const std.zig.Token, index: usize) bool {
    if (index >= 4 and tokens[index - 1].tag == .period and tokens[index - 3].tag == .period and
        std.mem.eql(u8, source[tokens[index - 4].loc.start..tokens[index - 4].loc.end], "std") and
        std.mem.eql(u8, source[tokens[index - 2].loc.start..tokens[index - 2].loc.end], "mem") and
        std.mem.eql(u8, source[tokens[index].loc.start..tokens[index].loc.end], "Allocator")) return true;
    const binding = syntax_scope.findBinding(source, tokens, index) orelse return false;
    const name_index = binding.token_index;
    if (name_index + 6 >= tokens.len or tokens[name_index + 1].tag != .equal or
        tokens[name_index + 3].tag != .period or tokens[name_index + 5].tag != .period) return false;
    return std.mem.eql(u8, source[tokens[name_index + 2].loc.start..tokens[name_index + 2].loc.end], "std") and
        std.mem.eql(u8, source[tokens[name_index + 4].loc.start..tokens[name_index + 4].loc.end], "mem") and
        std.mem.eql(u8, source[tokens[name_index + 6].loc.start..tokens[name_index + 6].loc.end], "Allocator");
}

pub fn standardAllocatorArgument(callable: []const u8) ?usize {
    const callables = [_][]const u8{
        "std.mem.concat",
        "std.mem.concatWithSentinel",
        "std.mem.join",
        "std.mem.joinZ",
        "std.fmt.allocPrint",
        "std.fmt.allocPrintSentinel",
    };
    for (callables) |candidate| {
        if (std.mem.eql(u8, callable, candidate)) return 0;
    }
    const path_prefixes = [_][]const u8{ "std.fs.path.", "std.Io.Dir.path." };
    const allocating_paths = [_][]const u8{
        "join",          "joinZ",               "resolve",              "resolveWindows",     "resolvePosix",
        "resolveAlloc",  "resolveAllocWindows", "resolveAllocPosix",    "relative",           "relativeWindows",
        "relativePosix", "relativeAlloc",       "relativeAllocWindows", "relativeAllocPosix",
    };
    for (path_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, callable, prefix)) continue;
        for (allocating_paths) |method| {
            if (std.mem.eql(u8, callable[prefix.len..], method)) return 0;
        }
    }
    const separator = std.mem.findScalarLast(u8, callable, '.');
    const method = if (separator) |position| callable[position + 1 ..] else callable;
    if (std.mem.eql(u8, method, "allocRemaining") or std.mem.eql(u8, method, "toOwnedSlice")) return 0;
    return null;
}

pub fn releaseForCallable(callable: []const u8) ?[]const u8 {
    if (standardAllocatorArgument(callable) != null) return "free";
    const separator = std.mem.findScalarLast(u8, callable, '.');
    const method = if (separator) |position| callable[position + 1 ..] else callable;
    const release = resources.allocationRelease(method) orelse return null;
    if (!std.mem.eql(u8, method, "create")) return release;
    const position = separator orelse return null;
    const receiver = callable[0..position];
    const receiver_name = if (std.mem.findScalarLast(u8, receiver, '.')) |receiver_separator|
        receiver[receiver_separator + 1 ..]
    else
        receiver;
    return if (std.ascii.findIgnoreCase(receiver_name, "alloc") != null or
        std.ascii.findIgnoreCase(receiver_name, "pool") != null or
        std.mem.eql(u8, receiver_name, "gpa")) release else null;
}

test "standard allocator functions return memory released with free" {
    try std.testing.expectEqual(@as(?usize, 0), standardAllocatorArgument("std.mem.concat"));
    try std.testing.expectEqual(@as(?usize, 0), standardAllocatorArgument("reader.interface.allocRemaining"));
    try std.testing.expectEqual(@as(?usize, 0), standardAllocatorArgument("items.toOwnedSlice"));
    try std.testing.expectEqualStrings("free", releaseForCallable("std.fs.path.resolve").?);
    try std.testing.expect(standardAllocatorArgument("project.mem.concat") == null);
    try std.testing.expectEqualStrings("free", resources.allocationRelease("dupeSentinel").?);
    try std.testing.expectEqualStrings("free", resources.allocationRelease("print").?);
    try std.testing.expectEqualStrings("free", resources.allocationRelease("printSentinel").?);
    try std.testing.expectEqual(@as(?usize, 0), standardAllocatorArgument("std.Io.Dir.path.resolveAlloc"));
    try std.testing.expectEqual(@as(?usize, 0), standardAllocatorArgument("std.Io.Dir.path.relativeAllocPosix"));
    try std.testing.expect(standardAllocatorArgument("std.Io.Dir.path.resolveAppend") == null);
}
