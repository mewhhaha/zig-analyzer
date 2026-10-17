//! Calls whose result the caller must free, as the ownership summaries the
//! lifecycle rules use decide it, for editor hints. A call is listed only
//! when the summaries resolve it to one function of the same file (or a
//! configured resource contract) that returns memory the caller releases with
//! the allocator's `free` or `destroy`. The summaries match a method call by
//! its name alone, so `receiver.name(...)` is also required to name the
//! function's container: `Type.name(...)`, or a receiver declared as `Type`,
//! `*Type` or `?*const Type`; otherwise `allocator.dupe(...)` would be taken
//! for a `dupe` method the file declares. The memory must also come from an
//! allocator passed in as an argument, not a field of one, that is not an
//! arena by its spelling, its parameter's documentation, or the project's
//! `arena-allocators` contracts: what an arena hands out the caller does not
//! free.
const std = @import("std");

const syntax_scope = @import("../syntax/scope.zig");
const tokens_util = @import("../syntax/tokens.zig");
const summaries = @import("summaries.zig");
const types = @import("types.zig");

pub const OwnedResult = struct {
    /// Just past the call's closing parenthesis.
    end: usize,
    /// `free` or `destroy`.
    release: []const u8,
};

/// Every call of `source` returning memory its caller owns, in source order
/// of the callee name. Plain `name(...)` and `receiver.name(...)` calls only;
/// longer receiver paths are not resolved by the summaries.
pub fn calls(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    scopes: *const syntax_scope.Index,
    configuration: types.Configuration,
) ![]OwnedResult {
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source, .tokens = tokens }};
    var index = try summaries.build(allocator, &sources, configuration);
    defer index.deinit(allocator);
    var file_types: std.ArrayList([]const u8) = .empty;
    defer file_types.deinit(allocator);
    for (tokens, 0..) |token, const_index| {
        if (token.tag != .keyword_const or const_index + 6 >= tokens.len or tokens[const_index + 1].tag != .identifier or
            tokens[const_index + 2].tag != .equal or !tokens_util.tokenIs(source, tokens[const_index + 3], "@This") or
            tokens[const_index + 4].tag != .l_paren or tokens[const_index + 5].tag != .r_paren or
            tokens[const_index + 6].tag != .semicolon or scopes.enclosingOpeningBrace(const_index) != null) continue;
        try file_types.append(allocator, tokens_util.tokenText(source, tokens[const_index + 1]));
    }
    var found: std.ArrayList(OwnedResult) = .empty;
    errdefer found.deinit(allocator);
    for (tokens, 0..) |token, name_index| {
        if (token.tag != .identifier or name_index + 1 >= tokens.len or tokens[name_index + 1].tag != .l_paren) continue;
        const receiver: ?[]const u8 = if (name_index > 0) switch (tokens[name_index - 1].tag) {
            .keyword_fn => continue,
            .period => receiver: {
                if (name_index < 2 or tokens[name_index - 2].tag != .identifier) continue;
                if (name_index >= 3 and tokens[name_index - 3].tag == .period) continue;
                break :receiver tokens_util.tokenText(source, tokens[name_index - 2]);
            },
            else => null,
        } else null;
        const name = tokens_util.tokenText(source, token);
        const owned = index.ownedReturnCall(source, receiver, name) orelse continue;
        if (!std.mem.eql(u8, owned.release, "free") and !std.mem.eql(u8, owned.release, "destroy")) continue;
        const function = index.calledFunction(source, receiver, name) orelse continue;
        if (receiver != null and !namesContainer(source, tokens, scopes, name_index - 2, function.container_name, file_types.items)) continue;
        const allocator_argument = owned.allocator_parameter orelse continue;
        if (owned.allocator_parameter_member != null or arenaParameter(function, configuration)) continue;
        const closing = scopes.matchingToken(name_index + 1) orelse continue;
        const argument = callArgument(tokens, name_index + 1, closing, allocator_argument) orelse continue;
        if (std.ascii.findIgnoreCase(tokens_util.rangeSource(source, tokens, argument), "arena") != null) continue;
        try found.append(allocator, .{ .end = tokens[closing].loc.end, .release = owned.release });
    }
    return try found.toOwnedSlice(allocator);
}

/// Whether a parameter of `function` is documented or configured to be an
/// arena.
fn arenaParameter(function: summaries.FunctionSummary, configuration: types.Configuration) bool {
    for (function.parameter_names) |parameter| {
        if (summaries.parameterDocumentsArena(function, parameter)) return true;
        for (configuration.arena_allocator_contracts) |contract| {
            if (contract.len == function.name.len + 1 + parameter.len and std.mem.startsWith(u8, contract, function.name) and
                contract[function.name.len] == '.' and std.mem.endsWith(u8, contract, parameter)) return true;
        }
    }
    return false;
}

/// Token range of the argument at `position` between the call parentheses
/// at `opening` and `closing`.
fn callArgument(tokens: []const std.zig.Token, opening: usize, closing: usize, position: usize) ?tokens_util.Range {
    var start = opening + 1;
    for (0..position) |_| start = (tokens_util.topLevelComma(tokens, start, closing) orelse return null) + 1;
    const end = tokens_util.topLevelComma(tokens, start, closing) orelse closing;
    return if (end > start) .{ .start = start, .end = end } else null;
}

/// Whether the receiver at `receiver_index` is the container of a function
/// declared in `container` (null for the file's own struct, which the
/// top-level `@This()` aliases in `file_types` name).
fn namesContainer(
    source: []const u8,
    tokens: []const std.zig.Token,
    scopes: *const syntax_scope.Index,
    receiver_index: usize,
    container: ?[]const u8,
    file_types: []const []const u8,
) bool {
    if (isContainerName(tokens_util.tokenText(source, tokens[receiver_index]), container, file_types)) return true;
    const binding = scopes.findBinding(receiver_index) orelse return false;
    var cursor = binding.token_index + 1;
    if (cursor >= tokens.len or tokens[cursor].tag != .colon) return false;
    cursor += 1;
    while (cursor < tokens.len) : (cursor += 1) switch (tokens[cursor].tag) {
        .asterisk, .question_mark, .keyword_const => {},
        else => break,
    };
    if (cursor + 1 >= tokens.len or tokens[cursor].tag != .identifier or tokens[cursor + 1].tag == .period) return false;
    return isContainerName(tokens_util.tokenText(source, tokens[cursor]), container, file_types);
}

fn isContainerName(name: []const u8, container: ?[]const u8, file_types: []const []const u8) bool {
    if (container) |container_name| return std.mem.eql(u8, name, container_name);
    for (file_types) |file_type| if (std.mem.eql(u8, name, file_type)) return true;
    return false;
}

test "calls of functions returning allocated memory are listed" {
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn duplicate(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        \\    return allocator.dupe(u8, bytes);
        \\}
        \\fn length(bytes: []const u8) usize {
        \\    return bytes.len;
        \\}
        \\fn run(allocator: std.mem.Allocator) !void {
        \\    const copy = try duplicate(allocator, "text");
        \\    defer allocator.free(copy);
        \\    _ = length(copy);
        \\}
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokens_util.tokenize(arena.allocator(), source);
    var scopes = try syntax_scope.Index.init(arena.allocator(), source, tokens);
    defer scopes.deinit();
    const found = try calls(arena.allocator(), source, tokens, &scopes, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), found.len);
    const call_end = std.mem.find(u8, source, "\"text\")").? + "\"text\")".len;
    try std.testing.expectEqual(call_end, found[0].end);
    try std.testing.expectEqualStrings("free", found[0].release);
}

test "memory from an arena argument is not the caller's to free" {
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn label(allocator: std.mem.Allocator, id: u32) ![]u8 {
        \\    return std.fmt.allocPrint(allocator, "item {d}", .{id});
        \\}
        \\/// The allocator should be an arena.
        \\fn scratch(allocator: std.mem.Allocator) ![]u8 {
        \\    return allocator.alloc(u8, 4);
        \\}
        \\fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
        \\    _ = try label(arena, 1);
        \\    _ = try scratch(gpa);
        \\    gpa.free(try label(gpa, 2));
        \\}
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokens_util.tokenize(arena.allocator(), source);
    var scopes = try syntax_scope.Index.init(arena.allocator(), source, tokens);
    defer scopes.deinit();
    const found = try calls(arena.allocator(), source, tokens, &scopes, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), found.len);
    const call_end = std.mem.find(u8, source, "label(gpa, 2)").? + "label(gpa, 2)".len;
    try std.testing.expectEqual(call_end, found[0].end);
}

test "a method call counts only on a receiver of the method's container" {
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Name = struct {
        \\    raw: []const u8,
        \\    fn dupe(name: Name, allocator: std.mem.Allocator) ![]u8 {
        \\        return allocator.dupe(u8, name.raw);
        \\    }
        \\};
        \\fn run(allocator: std.mem.Allocator, name: *const Name, other: anytype) !void {
        \\    const copy = try name.dupe(allocator);
        \\    defer allocator.free(copy);
        \\    const bytes = try allocator.dupe(u8, copy);
        \\    defer allocator.free(bytes);
        \\    const unknown = try other.dupe(allocator);
        \\    defer allocator.free(unknown);
        \\}
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try tokens_util.tokenize(arena.allocator(), source);
    var scopes = try syntax_scope.Index.init(arena.allocator(), source, tokens);
    defer scopes.deinit();
    const found = try calls(arena.allocator(), source, tokens, &scopes, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), found.len);
    const call_end = std.mem.find(u8, source, "name.dupe(allocator)").? + "name.dupe(allocator)".len;
    try std.testing.expectEqual(call_end, found[0].end);
}
