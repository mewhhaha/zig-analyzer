//! The one table of resource acquire/release knowledge: which calls hand out a
//! resource, which call gives it back, and how the declared `contracts.resources`
//! pairs join the built-in ones. Rules that reason about cleanup (missing,
//! discarded, error-only, late) ask here instead of keeping their own list.
const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const Syntax = @import("context.zig").Syntax;
const tokens_util = @import("../syntax/tokens.zig");
const types = @import("types.zig");

pub const Kind = enum {
    /// File or directory handle opened through `std.Io.Dir`.
    io_handle,
    /// `std.Thread.spawn`, joined or detached.
    thread,
    /// Container or allocator whose `init` owns memory until `deinit`.
    managed,
    /// A pair declared in `contracts.resources`.
    contract,
};

pub const Pair = struct {
    /// Method or function name of the acquiring call.
    acquisition: []const u8,
    /// Method name that releases the resource.
    release: []const u8,
    alternative_release: ?[]const u8 = null,
    /// Text before the acquiring call's final `.` that a contract requires; built-in pairs accept any receiver.
    receiver: ?[]const u8 = null,
    kind: Kind,
};

const io_handles = [_][]const u8{
    "openFile",
    "createFile",
    "openFileAbsolute",
    "createFileAbsolute",
    "openDir",
    "openDirAbsolute",
};

const builtin = blk: {
    var pairs: [io_handles.len + 3]Pair = undefined;
    for (io_handles, 0..) |name, index| pairs[index] = .{ .acquisition = name, .release = "close", .kind = .io_handle };
    pairs[io_handles.len] = .{ .acquisition = "spawn", .release = "join", .alternative_release = "detach", .kind = .thread };
    pairs[io_handles.len + 1] = .{ .acquisition = "init", .release = "deinit", .kind = .managed };
    pairs[io_handles.len + 2] = .{ .acquisition = "initCapacity", .release = "deinit", .kind = .managed };
    break :blk pairs;
};

/// Type names that make an `init` call an owning resource.
pub const managed_types = [_][]const u8{
    "ArrayList",
    "ArrayHashMap",
    "AutoHashMap",
    "StringHashMap",
    "ArenaAllocator",
    "GeneralPurposeAllocator",
};

/// Calls that return a raw OS handle which must be closed.
pub const os_handle_acquisitions = [_][]const u8{
    "open",
    "openat",
    "socket",
    "dup",
    "dup2",
    "eventfd",
    "inotify_init1",
};

/// Method names whose call ends the life of the value they act on.
pub const release_methods = [_][]const u8{ "free", "destroy", "close", "deinit", "join", "detach", "unlock" };

/// Allocator methods whose result is released with `free` or `destroy`.
/// `print` and `printSentinel` are shared with writers; `uniqueAllocationRelease`
/// leaves them out.
const allocation_methods = [_]struct { method: []const u8, release: []const u8, shared_name: bool = false }{
    .{ .method = "alloc", .release = "free" },
    .{ .method = "allocSentinel", .release = "free" },
    .{ .method = "alignedAlloc", .release = "free" },
    .{ .method = "dupe", .release = "free" },
    .{ .method = "dupeZ", .release = "free" },
    .{ .method = "dupeSentinel", .release = "free" },
    .{ .method = "print", .release = "free", .shared_name = true },
    .{ .method = "printSentinel", .release = "free", .shared_name = true },
    .{ .method = "realloc", .release = "free" },
    .{ .method = "create", .release = "destroy" },
};

/// Allocator methods that take an element count, with the argument position
/// counted from the end of the call.
pub const SizedAllocation = struct { method: []const u8, length_from_end: usize = 1 };

pub const sized_allocations = [_]SizedAllocation{
    .{ .method = "alloc" },
    .{ .method = "allocSentinel", .length_from_end = 2 },
    .{ .method = "alignedAlloc" },
    .{ .method = "realloc" },
};

/// The release for an allocator method, or null when the method does not allocate.
pub fn allocationRelease(method: []const u8) ?[]const u8 {
    for (allocation_methods) |entry| if (std.mem.eql(u8, method, entry.method)) return entry.release;
    return null;
}

/// `allocationRelease` for rules that cannot prove the receiver is an allocator:
/// skips the names that writers share (`print`).
pub fn uniqueAllocationRelease(method: []const u8) ?[]const u8 {
    for (allocation_methods) |entry| {
        if (!entry.shared_name and std.mem.eql(u8, method, entry.method)) return entry.release;
    }
    return null;
}

pub fn isReleaseMethod(name: []const u8) bool {
    for (release_methods) |method| if (std.mem.eql(u8, name, method)) return true;
    return false;
}

/// The pair acquired by calling `name` on `receiver` (the text before the call's
/// final `.`, null for a bare call). Declared contracts win over built-in pairs.
pub fn lookup(configuration: types.Configuration, name: []const u8, receiver: ?[]const u8) ?Pair {
    if (contract(configuration, name, receiver)) |pair| return pair;
    for (builtin) |pair| if (std.mem.eql(u8, pair.acquisition, name)) return pair;
    return null;
}

/// The declared `contracts.resources` pair acquired by this call, if any. A
/// qualified contract (`Db.open`) needs the same receiver; a bare one (`open`) a bare call.
pub fn contract(configuration: types.Configuration, name: []const u8, receiver: ?[]const u8) ?Pair {
    for (configuration.resource_contracts) |declared| {
        const separator = std.mem.findScalarLast(u8, declared.acquire, '.');
        const acquired_name = if (separator) |position| declared.acquire[position + 1 ..] else declared.acquire;
        if (!std.mem.eql(u8, acquired_name, name)) continue;
        if (separator) |position| {
            const actual = receiver orelse continue;
            if (!std.mem.eql(u8, declared.acquire[0..position], actual)) continue;
        } else if (receiver != null) continue;
        const release_separator = std.mem.findScalarLast(u8, declared.release, '.');
        return .{
            .acquisition = acquired_name,
            .release = if (release_separator) |position| declared.release[position + 1 ..] else declared.release,
            .receiver = if (separator) |position| declared.acquire[0..position] else null,
            .kind = .contract,
        };
    }
    return null;
}

/// Source text of the dotted path before the call at `call_index`, e.g. `Db` for `Db.open(`.
pub fn callReceiver(source: []const u8, tokens: []const std.zig.Token, call_index: usize) ?[]const u8 {
    if (call_index < 2 or tokens[call_index - 1].tag != .period or tokens[call_index - 2].tag != .identifier) return null;
    var start = call_index - 2;
    while (start >= 2 and tokens[start - 1].tag == .period and tokens[start - 2].tag == .identifier) start -= 2;
    return source[tokens[start].loc.start..tokens[call_index - 2].loc.end];
}

/// Whether the call at `call_index` really acquires `pair`: `init` only owns
/// memory next to a managed type, `spawn` only on a thread; `start` bounds the
/// initializer that is searched for those hints.
pub fn acquires(pair: Pair, source: []const u8, tokens: []const std.zig.Token, start: usize, call_index: usize) bool {
    switch (pair.kind) {
        .thread => return namesAny(source, tokens, start, call_index, &.{"Thread"}),
        .managed => return namesAny(source, tokens, start, call_index, &managed_types),
        .io_handle, .contract => return true,
    }
}

fn namesAny(source: []const u8, tokens: []const std.zig.Token, start: usize, end: usize, names: []const []const u8) bool {
    for (tokens[start..end]) |token| {
        if (token.tag != .identifier) continue;
        for (names) |name| if (tokens_util.tokenIs(source, token, name)) return true;
    }
    return false;
}

/// The first resource acquired by a call inside `tokens[start..end]`.
pub fn acquiredIn(context: RuleRun, start: usize, end: usize) ?Pair {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const pair = lookup(context.configuration, context.tokenText(index), callReceiver(context.source, context.tokens, index)) orelse continue;
        if (acquires(pair, context.source, context.tokens, start, index)) return pair;
    }
    return null;
}

test "built-in pairs cover io handles threads and managed containers" {
    const defaults = types.Configuration.defaults();
    try std.testing.expectEqualStrings("close", lookup(defaults, "openDirAbsolute", null).?.release);
    try std.testing.expectEqualStrings("detach", lookup(defaults, "spawn", "std.Thread").?.alternative_release.?);
    try std.testing.expectEqual(Kind.managed, lookup(defaults, "initCapacity", "std.ArrayList").?.kind);
    try std.testing.expect(lookup(defaults, "openIterableDir", null) == null);
}

test "declared contracts win and respect their receiver" {
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{
        .{ .acquire = "Db.open", .release = "Db.close" },
        .{ .acquire = "connect", .release = "disconnect" },
    };
    const qualified = lookup(configuration, "open", "Db").?;
    try std.testing.expectEqualStrings("close", qualified.release);
    try std.testing.expectEqual(Kind.contract, qualified.kind);
    try std.testing.expect(lookup(configuration, "open", "Other") == null);
    try std.testing.expect(lookup(configuration, "open", null) == null);
    try std.testing.expectEqualStrings("disconnect", lookup(configuration, "connect", null).?.release);
    try std.testing.expect(lookup(configuration, "connect", "Db") == null);
}

test "allocation releases distinguish shared writer names" {
    try std.testing.expectEqualStrings("destroy", allocationRelease("create").?);
    try std.testing.expect(uniqueAllocationRelease("print") == null);
    try std.testing.expectEqualStrings("free", allocationRelease("print").?);
    try std.testing.expect(allocationRelease("append") == null);
}

test "acquiredIn applies declared pairs inside an initializer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const source: [:0]const u8 = "const connection = try Db.open();";
    const tokens = try tokens_util.tokenize(arena.allocator(), source);
    var syntax = try Syntax.init(arena.allocator(), source, tokens);
    var found: std.ArrayList(types.Finding) = .empty;
    const context = syntax.ruleRun(arena.allocator(), configuration, &found);
    try std.testing.expectEqualStrings("Db", callReceiver(source, tokens, 6).?);
    try std.testing.expectEqualStrings("close", acquiredIn(context, 3, 9).?.release);
    try std.testing.expect(acquiredIn(context, 3, 4) == null);
}
