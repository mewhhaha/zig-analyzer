//! One model of standard-container identity for the rules that track lifetimes.
//!
//! A local declaration is a container when its type annotation names one
//! (`var l: std.ArrayList(u8) = .empty`, `= try .initCapacity(gpa, n)`) or, with
//! no annotation, when its initializer names one (`std.ArrayList(u8).empty`).
//! Every rule that classifies containers goes through here, so none disagrees.

const std = @import("std");
const tokens_util = @import("../syntax/tokens.zig");

pub const Kind = enum {
    list,
    hash_map,
    array_hash_map,
    multi_array_list,
    segmented_list,
    priority_queue,

    /// Containers with an `.items` slice that appends can reallocate.
    pub fn hasItems(kind: Kind) bool {
        return kind == .list;
    }

    /// Hash maps of either flavour.
    pub fn isMap(kind: Kind) bool {
        return kind == .hash_map or kind == .array_hash_map;
    }

    /// Containers whose element or view pointers a mutation can invalidate.
    pub fn invalidatesViews(kind: Kind) bool {
        return kind == .list or kind.isMap();
    }
};

const named = [_]struct { name: []const u8, kind: Kind }{
    .{ .name = "ArrayList", .kind = .list },
    .{ .name = "ArrayListUnmanaged", .kind = .list },
    .{ .name = "ArrayListAligned", .kind = .list },
    .{ .name = "ArrayListAlignedUnmanaged", .kind = .list },
    .{ .name = "HashMap", .kind = .hash_map },
    .{ .name = "HashMapUnmanaged", .kind = .hash_map },
    .{ .name = "AutoHashMap", .kind = .hash_map },
    .{ .name = "AutoHashMapUnmanaged", .kind = .hash_map },
    .{ .name = "StringHashMap", .kind = .hash_map },
    .{ .name = "StringHashMapUnmanaged", .kind = .hash_map },
    .{ .name = "ArrayHashMap", .kind = .array_hash_map },
    .{ .name = "ArrayHashMapUnmanaged", .kind = .array_hash_map },
    .{ .name = "AutoArrayHashMap", .kind = .array_hash_map },
    .{ .name = "AutoArrayHashMapUnmanaged", .kind = .array_hash_map },
    .{ .name = "StringArrayHashMap", .kind = .array_hash_map },
    .{ .name = "StringArrayHashMapUnmanaged", .kind = .array_hash_map },
    .{ .name = "MultiArrayList", .kind = .multi_array_list },
    .{ .name = "SegmentedList", .kind = .segmented_list },
    .{ .name = "PriorityQueue", .kind = .priority_queue },
    .{ .name = "PriorityDequeue", .kind = .priority_queue },
};

/// List methods that may reallocate the storage behind `items`.
pub const list_growth = [_][]const u8{
    "append",
    "appendNTimes",
    "appendSlice",
    "insert",
    "insertSlice",
    "replaceRange",
    "resize",
    "ensureTotalCapacity",
    "ensureUnusedCapacity",
    "addOne",
    "addManyAsArray",
    "addManyAsSlice",
    "addManyAt",
    "clearAndFree",
};

/// List methods that shift or drop elements without reallocating.
pub const list_removal = [_][]const u8{ "orderedRemove", "swapRemove", "clearRetainingCapacity" };

/// Map methods that may rehash or reallocate the entry storage.
pub const map_growth = [_][]const u8{
    "put",
    "putNoClobber",
    "fetchPut",
    "getOrPut",
    "getOrPutValue",
    "clearAndFree",
    "ensureTotalCapacity",
    "ensureUnusedCapacity",
    "rehash",
};

/// Map methods that remove entries or move the remaining ones.
pub const map_removal = [_][]const u8{
    "remove",
    "fetchRemove",
    "swapRemove",
    "orderedRemove",
    "swapRemoveAt",
    "orderedRemoveAt",
    "fetchSwapRemove",
    "fetchOrderedRemove",
    "clearRetainingCapacity",
};

pub fn isOneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

/// The container a type-constructor name denotes, or null.
pub fn kindOfName(name: []const u8) ?Kind {
    for (named) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.kind;
    return null;
}

/// The container an identifier token denotes, including the module-qualified
/// constructors `array_hash_map.Auto|String|Custom` and `array_list.Aligned|Managed`.
pub fn kindOfToken(source: []const u8, tokens: []const std.zig.Token, index: usize) ?Kind {
    if (tokens[index].tag != .identifier) return null;
    const name = tokens_util.tokenText(source, tokens[index]);
    if (kindOfName(name)) |kind| return kind;
    if (index < 2 or tokens[index - 1].tag != .period or tokens[index - 2].tag != .identifier) return null;
    const module = tokens_util.tokenText(source, tokens[index - 2]);
    if (std.mem.eql(u8, module, "array_hash_map") and
        (std.mem.eql(u8, name, "Auto") or std.mem.eql(u8, name, "String") or std.mem.eql(u8, name, "Custom"))) return .array_hash_map;
    if (std.mem.eql(u8, module, "array_list") and
        (std.mem.eql(u8, name, "Aligned") or std.mem.eql(u8, name, "Managed") or std.mem.eql(u8, name, "AlignedManaged"))) return .list;
    return null;
}

/// First container named anywhere in `[start, end)`.
pub fn firstKindIn(source: []const u8, tokens: []const std.zig.Token, start: usize, end: usize) ?Kind {
    for (start..end) |index| if (kindOfToken(source, tokens, index)) |kind| return kind;
    return null;
}

/// The container a type expression denotes when it starts with one, looking
/// through `*`, `const` and a `std.`-style path: `*std.ArrayList(u8)`.
pub fn kindOfTypeStart(source: []const u8, tokens: []const std.zig.Token, start: usize, end: usize) ?Kind {
    var index = start;
    while (index < end and (tokens[index].tag == .asterisk or tokens[index].tag == .keyword_const)) index += 1;
    while (index + 1 < end and tokens[index].tag == .identifier and tokens[index + 1].tag == .period) index += 2;
    if (index >= end) return null;
    return kindOfToken(source, tokens, index);
}

/// The container a `const|var name [: Type] = init;` declaration holds. The
/// annotation decides when present; otherwise the initializer must name one.
pub fn declaredKind(source: []const u8, tokens: []const std.zig.Token, declaration: usize, declaration_end: usize) ?Kind {
    if (declaration + 2 >= declaration_end or tokens[declaration + 1].tag != .identifier) return null;
    switch (tokens[declaration + 2].tag) {
        .equal => return firstKindIn(source, tokens, declaration + 3, declaration_end),
        .colon => {
            var equal = declaration + 3;
            while (equal < declaration_end and tokens[equal].tag != .equal) : (equal += 1) {}
            if (equal >= declaration_end) return null;
            return kindOfTypeStart(source, tokens, declaration + 3, equal);
        },
        else => return null,
    }
}

/// The index of the first initializer token of a declaration, after `=`.
pub fn initializerStart(tokens: []const std.zig.Token, declaration: usize, declaration_end: usize) ?usize {
    var index = declaration + 2;
    while (index < declaration_end) : (index += 1) {
        if (tokens[index].tag == .equal) return index + 1;
    }
    return null;
}

test "kindOfName covers lists maps and queues" {
    try std.testing.expectEqual(Kind.list, kindOfName("ArrayList").?);
    try std.testing.expectEqual(Kind.array_hash_map, kindOfName("AutoArrayHashMapUnmanaged").?);
    try std.testing.expect(kindOfName("Foo") == null);
}
