const std = @import("std");
const syntax_scope = @import("../syntax/scope.zig");
const resources = @import("resources.zig");

/// Whether the receiver ending at `receiver_end` of a `.print(...)` call is
/// an allocator: a binding declared with an allocator type, or one of the
/// conventional allocator names. Bindings resolve by scanning the file; rules
/// with a scope index use `printReceiverIsAllocatorIndexed`.
pub fn printReceiverIsAllocator(source: []const u8, tokens: []const std.zig.Token, receiver_end: usize) bool {
    return receiverIsAllocator(FileScan{ .source = source, .tokens = tokens }, source, tokens, receiver_end);
}

/// `printReceiverIsAllocator` with bindings resolved through `scopes`.
pub fn printReceiverIsAllocatorIndexed(scopes: *const syntax_scope.Index, receiver_end: usize) bool {
    return receiverIsAllocator(scopes, scopes.source, scopes.tokens, receiver_end);
}

const FileScan = struct {
    source: []const u8,
    tokens: []const std.zig.Token,

    fn findBinding(scan: FileScan, use_index: usize) ?syntax_scope.Binding {
        return syntax_scope.findBinding(scan.source, scan.tokens, use_index);
    }
};

fn receiverIsAllocator(bindings: anytype, source: []const u8, tokens: []const std.zig.Token, receiver_end: usize) bool {
    if (receiver_end >= tokens.len or tokens[receiver_end].tag != .identifier) return false;
    if (receiver_end == 0 or tokens[receiver_end - 1].tag != .period) {
        const binding = bindings.findBinding(receiver_end) orelse return false;
        const name_index = binding.token_index;
        if (name_index + 2 < tokens.len and tokens[name_index + 1].tag == .colon) {
            var index = name_index + 2;
            while (index < tokens.len) : (index += 1) switch (tokens[index].tag) {
                .comma, .equal, .r_paren, .semicolon, .l_brace => return false,
                .keyword_anytype => break,
                .identifier => if (allocatorTypeAt(bindings, source, tokens, index)) return true,
                else => {},
            };
        }
    }
    const name = source[tokens[receiver_end].loc.start..tokens[receiver_end].loc.end];
    return std.mem.eql(u8, name, "allocator") or std.mem.eql(u8, name, "alloc") or
        std.mem.eql(u8, name, "gpa") or std.mem.eql(u8, name, "arena");
}

fn allocatorTypeAt(bindings: anytype, source: []const u8, tokens: []const std.zig.Token, index: usize) bool {
    if (index >= 4 and tokens[index - 1].tag == .period and tokens[index - 3].tag == .period and
        std.mem.eql(u8, source[tokens[index - 4].loc.start..tokens[index - 4].loc.end], "std") and
        std.mem.eql(u8, source[tokens[index - 2].loc.start..tokens[index - 2].loc.end], "mem") and
        std.mem.eql(u8, source[tokens[index].loc.start..tokens[index].loc.end], "Allocator")) return true;
    const binding = bindings.findBinding(index) orelse return false;
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

test "print receivers resolve the same through the scope index" {
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\fn run(gpa: Allocator, other: std.mem.Allocator, writer: anytype, list: List) !void {
        \\    const text = try gpa.print("{d}", .{1});
        \\    _ = try other.print("{d}", .{2});
        \\    try writer.print("{s}", .{text});
        \\    { const other = list; _ = try other.print("", .{}); }
        \\    _ = try allocator.print("", .{});
        \\}
        \\
    ;
    const tokens = try @import("../syntax/tokens.zig").tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var scopes = try syntax_scope.Index.init(std.testing.allocator, source, tokens);
    defer scopes.deinit();
    var allocators: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier) continue;
        const scanned = printReceiverIsAllocator(source, tokens, index);
        try std.testing.expectEqual(scanned, printReceiverIsAllocatorIndexed(&scopes, index));
        if (scanned and index + 2 < tokens.len and std.mem.eql(u8, source[tokens[index + 2].loc.start..tokens[index + 2].loc.end], "print")) {
            allocators += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), allocators);
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
