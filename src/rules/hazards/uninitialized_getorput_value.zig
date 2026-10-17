//! Reads of the value a `getOrPut` call may have just inserted. When the key
//! is new, `found_existing` is false and `value_ptr` points at an undefined
//! slot, so reading it, updating it in place (`+= 1`) or calling a method on
//! it before assigning it uses undefined memory. `getOrPutValue` initializes
//! the slot and is not reported.

const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");

pub const rules = [_]types.Rule{.uninitialized_getorput_value};

/// The `std` hash map methods whose result leaves a new value undefined.
const inserting_methods = [_][]const u8{
    "getOrPut",
    "getOrPutAdapted",
    "getOrPutContext",
    "getOrPutContextAdapted",
    "getOrPutAssumeCapacity",
    "getOrPutAssumeCapacityAdapted",
    "getOrPutAssumeCapacityContext",
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.uninitialized_getorput_value);
    if (level == .off) return;
    const tokens = context.tokens;
    for (tokens, 0..) |token, method| {
        if (token.tag != .identifier or method < 2 or tokens[method - 1].tag != .period or
            tokens[method + 1].tag != .l_paren or !isInsertingMethod(context.tokenText(method))) continue;
        const closing = context.matchingToken(method + 1, .l_paren, .r_paren) orelse continue;
        if (directValueUse(context, method, closing)) |value| {
            try report(context, level, method, value);
            continue;
        }
        const name = resultBinding(context, method, closing) orelse continue;
        const statement_end = context.statementEnd(name - 1) orelse continue;
        const scope_end = context.enclosingScopeEnd(name) orelse continue;
        if (firstUncheckedRead(context, name, statement_end + 1, scope_end)) |value| {
            try report(context, level, method, value);
        }
    }
}

fn isInsertingMethod(name: []const u8) bool {
    for (inserting_methods) |method| if (std.mem.eql(u8, name, method)) return true;
    return false;
}

fn report(context: RuleRun, level: types.Level, method: usize, value: usize) !void {
    const related = try context.allocator.alloc(types.RelatedSpan, 1);
    related[0] = .{
        .span = context.tokens[method].loc,
        .message = "a new key leaves the value undefined until it is assigned",
    };
    try context.emit(.{
        .rule = .uninitialized_getorput_value,
        .level = level,
        .span = context.tokens[value].loc,
        .message = try context.allocator.print(
            "'value_ptr' is read before it is assigned, but '{s}' leaves it undefined when the key is new; assign it when 'found_existing' is false",
            .{context.tokenText(method)},
        ),
        .related = related,
    });
}

/// `map.getOrPutAssumeCapacity(key).value_ptr.* += 1` and
/// `(try map.getOrPut(key)).value_ptr.append(..)`: the `value_ptr` token of a
/// result read without ever checking `found_existing`.
fn directValueUse(context: RuleRun, method: usize, closing: usize) ?usize {
    const tokens = context.tokens;
    var end = closing;
    const receiver = tokens_util.pathBefore(tokens, method - 1) orelse return null;
    if (receiver.start >= 2 and tokens[receiver.start - 1].tag == .keyword_try and
        tokens[receiver.start - 2].tag == .l_paren and tokens[end + 1].tag == .r_paren and
        context.scopes.matchingToken(end + 1) == receiver.start - 2) end += 1;
    if (tokens[end + 1].tag != .period or !context.tokenIs(end + 2, "value_ptr")) return null;
    return if (valueUse(context, end + 2) == .read) end + 2 else null;
}

/// The name of `const gop = [try] map.getOrPut(..) [catch ..];`.
fn resultBinding(context: RuleRun, method: usize, closing: usize) ?usize {
    const tokens = context.tokens;
    const receiver = tokens_util.pathBefore(tokens, method - 1) orelse return null;
    var value = receiver.start;
    if (tokens[value - 1].tag == .keyword_try) value -= 1;
    if (value < 3 or tokens[value - 1].tag != .equal or tokens[value - 2].tag != .identifier) return null;
    const keyword = tokens[value - 3].tag;
    if (keyword != .keyword_const and keyword != .keyword_var) return null;
    if (tokens[closing + 1].tag != .semicolon and tokens[closing + 1].tag != .keyword_catch) return null;
    if (!context.scopes.insideFunctionOrTestBody(value - 2)) return null;
    return value - 2;
}

/// The `value_ptr` token of the first read of the result named at `name`
/// that no `found_existing` check or assignment precedes.
fn firstUncheckedRead(context: RuleRun, name: usize, start: usize, end: usize) ?usize {
    const tokens = context.tokens;
    const text = context.tokenText(name);
    for (start..end) |index| {
        if (tokens[index].tag != .identifier or tokens[index - 1].tag == .period or !context.tokenIs(index, text)) continue;
        if (context.scopes.resolve(index)) |binding| if (binding.token_index != name) continue;
        if (tokens[index + 1].tag != .period) return null;
        const field = index + 2;
        if (context.tokenIs(field, "key_ptr") or context.tokenIs(field, "index")) continue;
        if (!context.tokenIs(field, "value_ptr")) return null;
        switch (valueUse(context, field)) {
            .read => return field,
            .other => return null,
        }
    }
    return null;
}

const ValueUse = enum { read, other };

/// Whether the `value_ptr` at `field` reads the value it points to: a load
/// of `.*`, an in-place update, a method call or a field read. Assigning it,
/// taking its address or handing the pointer on is `other`.
fn valueUse(context: RuleRun, field: usize) ValueUse {
    const tokens = context.tokens;
    var cursor = field + 1;
    if (field >= 3 and tokens[field - 3].tag == .ampersand) return .other;
    if (tokens[cursor].tag == .period_asterisk) {
        cursor += 1;
        switch (tokens[cursor].tag) {
            .equal => return .other,
            .period => {},
            else => return if (tokens_util.isAssignment(tokens[cursor].tag) or loadsValue(tokens[cursor].tag)) .read else .other,
        }
    }
    if (tokens[cursor].tag != .period or tokens[cursor + 1].tag != .identifier) return .other;
    const member = cursor + 1;
    const after = tokens[member + 1].tag;
    if (after == .l_paren) return if (std.mem.startsWith(u8, context.tokenText(member), "init")) .other else .read;
    // Assigning one field may be how the value is built up.
    if (after == .equal) return .other;
    return .read;
}

/// Whether the token after `value_ptr.*` uses the loaded value in an
/// expression rather than passing the place on.
fn loadsValue(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .semicolon, .comma, .r_paren, .r_bracket, .r_brace => true,
        .plus, .minus, .asterisk, .slash, .percent, .ampersand, .pipe, .caret => true,
        .plus_percent, .minus_percent, .asterisk_percent, .plus_pipe, .minus_pipe, .asterisk_pipe => true,
        .angle_bracket_left, .angle_bracket_right, .angle_bracket_left_equal, .angle_bracket_right_equal => true,
        .equal_equal, .bang_equal, .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_right => true,
        .keyword_and, .keyword_or, .keyword_orelse, .keyword_catch => true,
        else => false,
    };
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.uninitialized_getorput_value}, .warning));
}

test "reads of an unchecked getOrPut value report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn count(gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u32, u32), key: u32) !void {
        \\    const gop = try map.getOrPut(gpa, key);
        \\    gop.value_ptr.* += 1;
        \\}
        \\fn append(gpa: std.mem.Allocator, map: anytype, key: u32) !void {
        \\    const entry = map.getOrPutAssumeCapacity(key);
        \\    try entry.value_ptr.append(gpa, key);
        \\}
        \\fn load(map: anytype, key: u32) u32 {
        \\    const gop = map.getOrPut(key) catch unreachable;
        \\    _ = gop.key_ptr;
        \\    return gop.value_ptr.*;
        \\}
        \\fn field(map: anytype, key: u32) !usize {
        \\    var gop = try map.getOrPutAdapted(key, Context{});
        \\    return gop.value_ptr.items.len;
        \\}
        \\fn direct(map: anytype, key: u32) !void {
        \\    (try map.getOrPut(key)).value_ptr.* *= 2;
        \\    map.getOrPutAssumeCapacity(key).value_ptr.count += 1;
        \\}
        \\const Context = struct {};
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "value_ptr", "value_ptr", "value_ptr", "value_ptr", "value_ptr", "value_ptr" });
    try std.testing.expect(std.mem.find(u8, found[0].message, "'getOrPut'") != null);
    try std.testing.expectEqualStrings("getOrPut", source[found[0].related[0].span.start..found[0].related[0].span.end]);
}

test "checked, assigned, initializing and escaping uses stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn checked(map: anytype, key: u32) !void {
        \\    const gop = try map.getOrPut(key);
        \\    if (!gop.found_existing) gop.value_ptr.* = 0;
        \\    gop.value_ptr.* += 1;
        \\}
        \\fn existing(map: anytype, key: u32) !void {
        \\    const gop = try map.getOrPut(key);
        \\    if (gop.found_existing) {
        \\        try gop.value_ptr.append(key);
        \\    } else {
        \\        gop.value_ptr.* = .empty;
        \\    }
        \\}
        \\fn assigned(map: anytype, key: u32) !u32 {
        \\    const gop = try map.getOrPut(key);
        \\    gop.value_ptr.* = 1;
        \\    return gop.value_ptr.*;
        \\}
        \\fn built(map: anytype, key: u32) !void {
        \\    const gop = try map.getOrPut(key);
        \\    gop.value_ptr.count = 0;
        \\    gop.value_ptr.init();
        \\}
        \\fn escaped(map: anytype, key: u32) !void {
        \\    const gop = try map.getOrPut(key);
        \\    fill(gop.value_ptr);
        \\    fill(&gop.value_ptr.*);
        \\}
        \\fn defaulted(map: anytype, key: u32) !void {
        \\    const gop = try map.getOrPutValue(key, 0);
        \\    gop.value_ptr.* += 1;
        \\}
        \\fn direct(map: anytype, key: u32) !void {
        \\    (try map.getOrPut(key)).value_ptr.* = 1;
        \\    map.getOrPutAssumeCapacity(key).value_ptr.* = 2;
        \\}
        \\fn handed(map: anytype, key: u32) !void {
        \\    const gop = try map.getOrPut(key);
        \\    initialize(gop);
        \\    gop.value_ptr.* += 1;
        \\}
        \\fn fill(_: anytype) void {}
        \\fn initialize(_: anytype) void {}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}
