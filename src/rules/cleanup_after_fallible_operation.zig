const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;

const Resource = struct {
    acquisition: []const u8,
    release: []const u8,
};

const resources = [_]Resource{
    .{ .acquisition = "openFile", .release = "close" },
    .{ .acquisition = "createFile", .release = "close" },
    .{ .acquisition = "openDir", .release = "close" },
    .{ .acquisition = "openIterableDir", .release = "close" },
    .{ .acquisition = "spawn", .release = "join" },
    .{ .acquisition = "init", .release = "deinit" },
    .{ .acquisition = "initCapacity", .release = "deinit" },
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.cleanup_after_fallible_operation);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const resource = acquiredResource(context, declaration_index + 3, declaration_end) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        const cleanup_index = deferredCleanup(
            context,
            binding_name,
            resource.release,
            declaration_end + 1,
            scope_end,
            scope_opening,
        ) orelse continue;
        if (!fallibleOperationBetween(context, declaration_end + 1, cleanup_index, scope_opening)) continue;
        if (bindingAddressEscapesBeforeFallible(context, binding_name, declaration_end + 1, cleanup_index)) continue;
        try context.emit(.{
            .rule = .cleanup_after_fallible_operation,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "cleanup for resource '{s}' is registered after a fallible operation; an earlier error can skip {s}",
                .{ binding_name, resource.release },
            ),
        });
    }
}

fn bindingAddressEscapesBeforeFallible(context: RuleRun, binding_name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_try) return false;
        if (token.tag != .identifier or !context.tokenIs(index, binding_name) or index == start or
            context.tokens[index - 1].tag != .ampersand) continue;
        return true;
    }
    return false;
}

fn acquiredResource(context: RuleRun, start: usize, end: usize) ?Resource {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        for (resources) |resource| {
            if (!context.tokenIs(index, resource.acquisition)) continue;
            if (std.mem.eql(u8, resource.acquisition, "spawn") and !containsName(context, start, index, "Thread")) continue;
            if ((std.mem.eql(u8, resource.acquisition, "init") or std.mem.eql(u8, resource.acquisition, "initCapacity")) and
                !namesManagedType(context, start, index)) continue;
            return resource;
        }
    }
    return null;
}

fn namesManagedType(context: RuleRun, start: usize, end: usize) bool {
    const managed_types = [_][]const u8{
        "ArrayList",
        "ArrayHashMap",
        "AutoHashMap",
        "StringHashMap",
        "ArenaAllocator",
        "GeneralPurposeAllocator",
    };
    for (managed_types) |type_name| if (containsName(context, start, end, type_name)) return true;
    return false;
}

fn containsName(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

fn deferredCleanup(
    context: RuleRun,
    binding_name: []const u8,
    release: []const u8,
    start: usize,
    end: usize,
    scope_opening: usize,
) ?usize {
    for (context.tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_defer or context.enclosingOpeningBrace(defer_index) != scope_opening) continue;
        const statement_end = context.statementEnd(defer_index) orelse continue;
        if (statement_end >= end) continue;
        var index = defer_index + 1;
        while (index + 3 < statement_end) : (index += 1) {
            if (context.tokenIs(index, binding_name) and context.tokens[index + 1].tag == .period and
                context.tokenIs(index + 2, release) and context.tokens[index + 3].tag == .l_paren) return defer_index;
        }
    }
    return null;
}

fn fallibleOperationBetween(context: RuleRun, start: usize, end: usize, scope_opening: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_try) continue;
        const enclosing = context.enclosingOpeningBrace(index) orelse continue;
        if (enclosing == scope_opening) return true;
        if (context.enclosingOpeningBrace(enclosing) == scope_opening) return true;
    }
    return false;
}

test "resource cleanup registered after try can be skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn load(dir: std.fs.Dir) !void {\n" ++
        "    var file = try dir.openFile(\"input\", .{});\n" ++
        "    try validate();\n" ++
        "    defer file.close();\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
}

test "a fallible operation one block deep can still skip the cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn load(dir: std.fs.Dir, flag: bool) !void {\n" ++
        "    var file = try dir.openFile(\"input\", .{});\n" ++
        "    if (flag) { try validate(); }\n" ++
        "    defer file.close();\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
}

test "resource cleanup immediately after acquisition is safe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn load(dir: std.fs.Dir) !void {\n" ++
        "    var file = try dir.openFile(\"input\", .{});\n" ++
        "    defer file.close();\n" ++
        "    try validate();\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "resource transferred by pointer before a fallible operation stays opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn load(allocator: std.mem.Allocator) !void {\n" ++
        "    var buffer = try std.ArrayList(u8).initCapacity(allocator, 16);\n" ++
        "    var writer = Writer.fromArrayList(allocator, &buffer);\n" ++
        "    errdefer writer.deinit();\n" ++
        "    try writer.writeAll(\"value\");\n" ++
        "    buffer = writer.toArrayList();\n" ++
        "    defer buffer.deinit(allocator);\n" ++
        "}\n";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
