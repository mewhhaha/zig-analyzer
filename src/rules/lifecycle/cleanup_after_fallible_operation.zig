const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const resources = @import("../resources.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.cleanup_after_fallible_operation);
    if (level == .off) return;
    // The scans below visit a binding's uses through the identifier table.
    _ = try context.scopes.identifiers();

    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const resource = resources.acquiredIn(context, declaration_index + 3, declaration_end) orelse continue;
        if (managedMemoryInTest(context, resource, declaration_index)) continue;
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
        if (!context.fallibleOperationBetween(declaration_end + 1, cleanup_index, scope_opening)) continue;
        if (bindingAddressEscapesBeforeFallible(context, binding_name, declaration_end + 1, cleanup_index)) continue;
        try context.emit(.{
            .rule = .cleanup_after_fallible_operation,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try context.allocator.print(
                "cleanup for resource '{s}' is registered after a fallible operation; an earlier error can skip {s}",
                .{ binding_name, resource.release },
            ),
        });
    }

    try findLateDirectCleanup(context, level);
    try findExpiredInsertionRollback(context, level);
}

fn findExpiredInsertionRollback(context: RuleRun, level: types.Level) !void {
    var bodies: ?FunctionBodies = null;
    defer if (bodies) |*built| built.deinit(context.allocator);
    for (context.tokens, 0..) |token, errdefer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const rollback_scope = context.enclosingOpeningBrace(errdefer_index) orelse continue;
        const rollback_scope_end = context.matchingToken(rollback_scope, .l_brace, .r_brace) orelse continue;
        if (bodies == null) bodies = try .init(context);
        const function = bodies.?.containing(errdefer_index) orelse continue;
        if (rollback_scope == function.body_start) continue;
        const rollback = removalCall(context, errdefer_index + 1, rollback_scope_end) orelse continue;
        if (!matchingFallibleInsertion(context, rollback_scope + 1, errdefer_index, rollback)) continue;
        const later_fallible = firstFallibleOperation(context, rollback_scope_end + 1, function.body_end) orelse continue;
        if (activeRollback(context, function.body_start + 1, later_fallible, rollback)) continue;
        try context.emit(.{
            .rule = .cleanup_after_fallible_operation,
            .level = level,
            .span = context.tokens[errdefer_index].loc,
            .message = try context.allocator.print(
                "rollback for insertion into '{s}' expires at the end of this block before a later fallible operation",
                .{rollback.path},
            ),
        });
    }
}

const FunctionBody = struct {
    body_start: usize,
    body_end: usize,
};

const Removal = struct {
    path: []const u8,
    key: []const u8,
};

/// The body of the nearest `fn` before a token that holds it, where a
/// body is the first `{` after the `fn` when no `;` comes first. The braces
/// nest, so the innermost one around the token is that body; it is found by
/// a binary search and a walk out instead of a scan back over every `fn`.
const FunctionBodies = struct {
    /// Distinct bodies by their `{`, each with the body around it.
    bodies: []const Body,

    const Body = struct { start: u32, end: u32, parent: u32 };
    const none = std.math.maxInt(u32);

    fn init(context: RuleRun) !FunctionBodies {
        const allocator = context.allocator;
        var bodies: std.ArrayList(Body) = .empty;
        errdefer bodies.deinit(allocator);
        // Bodies still open at the current one, innermost last.
        var open: std.ArrayList(u32) = .empty;
        defer open.deinit(allocator);
        const tokens = context.tokens;
        for (tokens, 0..) |token, function_index| {
            if (token.tag != .keyword_fn or tokens.len > none) continue;
            var body_start = function_index + 1;
            while (body_start < tokens.len and tokens[body_start].tag != .l_brace and
                tokens[body_start].tag != .semicolon) : (body_start += 1)
            {}
            if (body_start >= tokens.len or tokens[body_start].tag != .l_brace) continue;
            const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
            // A `fn` type before the body shares its brace with the declaration.
            if (bodies.last()) |previous| if (previous.start == body_start) continue;
            while (open.last()) |innermost| {
                if (bodies.items[innermost].end > body_start) break;
                _ = open.pop();
            }
            try bodies.append(allocator, .{ .start = @intCast(body_start), .end = @intCast(body_end), .parent = open.last() orelse none });
            try open.append(allocator, @intCast(bodies.items.len - 1));
        }
        return .{ .bodies = try bodies.toOwnedSlice(allocator) };
    }

    fn deinit(function_bodies: *FunctionBodies, allocator: std.mem.Allocator) void {
        allocator.free(function_bodies.bodies);
    }

    fn containing(function_bodies: *const FunctionBodies, index: usize) ?FunctionBody {
        const bodies = function_bodies.bodies;
        var low: usize = 0;
        var high = bodies.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (bodies[middle].start < index) low = middle + 1 else high = middle;
        }
        if (low == 0) return null;
        var candidate: u32 = @intCast(low - 1);
        while (candidate != none) : (candidate = bodies[candidate].parent) {
            if (index < bodies[candidate].end) return .{ .body_start = bodies[candidate].start, .body_end = bodies[candidate].end };
        }
        return null;
    }
};

fn removalCall(context: RuleRun, start: usize, end: usize) ?Removal {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, "remove") or
            method_index == 0 or context.tokens[method_index - 1].tag != .period or
            method_index + 2 >= end or context.tokens[method_index + 1].tag != .l_paren or
            context.tokens[method_index + 2].tag != .identifier) continue;
        const path_start = receiverPathStart(context.tokens, method_index) orelse continue;
        return .{
            .path = context.source[context.tokens[path_start].loc.start..context.tokens[method_index - 1].loc.start],
            .key = context.tokenText(method_index + 2),
        };
    }
    return null;
}

fn receiverPathStart(tokens: []const std.zig.Token, method_index: usize) ?usize {
    if (method_index < 2 or tokens[method_index - 1].tag != .period or
        tokens[method_index - 2].tag != .identifier) return null;
    var start = method_index - 2;
    while (start >= 2 and tokens[start - 1].tag == .period and tokens[start - 2].tag == .identifier) start -= 2;
    return start;
}

fn matchingFallibleInsertion(context: RuleRun, start: usize, end: usize, rollback: Removal) bool {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, "put") or
            method_index + 1 >= end or context.tokens[method_index + 1].tag != .l_paren) continue;
        const path_start = receiverPathStart(context.tokens, method_index) orelse continue;
        const path = context.source[context.tokens[path_start].loc.start..context.tokens[method_index - 1].loc.start];
        if (!std.mem.eql(u8, path, rollback.path)) continue;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end >= end or !rangeNamesBinding(context, method_index + 2, call_end, rollback.key)) continue;
        var statement_start = method_index;
        while (statement_start > start and context.tokens[statement_start - 1].tag != .semicolon and
            context.tokens[statement_start - 1].tag != .l_brace) : (statement_start -= 1)
        {}
        for (context.tokens[statement_start..method_index]) |candidate| if (candidate.tag == .keyword_try) return true;
    }
    return false;
}

fn rangeNamesBinding(context: RuleRun, start: usize, end: usize, binding: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.refersToBinding(index, binding)) return true;
    }
    return false;
}

fn firstFallibleOperation(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_try or
            (token.tag == .keyword_return and index + 1 < end and context.tokens[index + 1].tag == .keyword_error)) return index;
    }
    return null;
}

fn activeRollback(context: RuleRun, start: usize, before: usize, rollback: Removal) bool {
    for (context.tokens[start..before], start..) |token, errdefer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const scope = context.enclosingOpeningBrace(errdefer_index) orelse continue;
        const scope_end = context.matchingToken(scope, .l_brace, .r_brace) orelse continue;
        if (scope_end < before) continue;
        const active = removalCall(context, errdefer_index + 1, scope_end) orelse continue;
        if (std.mem.eql(u8, active.path, rollback.path) and std.mem.eql(u8, active.key, rollback.key)) return true;
    }
    return false;
}

fn findLateDirectCleanup(context: RuleRun, level: types.Level) !void {
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const resource = resources.acquiredIn(context, declaration_index + 3, declaration_end) orelse continue;
        if (managedMemoryInTest(context, resource, declaration_index)) continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        const cleanup_index = directCleanup(context, binding_name, resource.release, declaration_end + 1, scope_end) orelse continue;
        if (!context.fallibleOperationBetween(declaration_end + 1, cleanup_index, scope_opening)) continue;
        try context.emit(.{
            .rule = .cleanup_after_fallible_operation,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try context.allocator.print(
                "resource '{s}' is closed only after a fallible operation; an earlier error can skip {s}",
                .{ binding_name, resource.release },
            ),
        });
    }
}

/// Memory a test leaks on an error path is reported by `std.testing.allocator`
/// itself; files, threads and other handles still need their cleanup proven.
fn managedMemoryInTest(context: RuleRun, resource: resources.Pair, declaration_index: usize) bool {
    return resource.kind == .managed and context.scopes.insideTestBlock(declaration_index);
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

fn deferredCleanup(
    context: RuleRun,
    binding_name: []const u8,
    release: []const u8,
    start: usize,
    end: usize,
    scope_opening: usize,
) ?usize {
    // A matching `defer` comes before a later use of the binding it releases.
    var last_use: usize = start;
    var uses = context.scopes.identifiersNamed(binding_name, start, end);
    while (uses.next()) |use| last_use = use;
    for (context.tokens[start..last_use], start..) |token, defer_index| {
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

fn directCleanup(context: RuleRun, binding_name: []const u8, release: []const u8, start: usize, end: usize) ?usize {
    var uses = context.scopes.identifiersNamed(binding_name, start, end);
    while (uses.next()) |index| {
        if (index + 3 >= end) break;
        if (context.tokens[index + 1].tag != .period or
            !context.tokenIs(index + 2, release) or context.tokens[index + 3].tag != .l_paren) continue;
        const statement_start = index -| 4;
        for (context.tokens[statement_start..index]) |token| if (token.tag == .keyword_defer) return null;
        return index;
    }
    return null;
}

test "resource cleanup registered after try can be skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(dir: std.fs.Dir) !void {\n" ++
        "    var file = try dir.openFile(\"input\", .{});\n" ++
        "    try validate();\n" ++
        "    defer file.close();\n" ++
        "}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "a fallible operation one block deep can still skip the cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(dir: std.fs.Dir, flag: bool) !void {\n" ++
        "    var file = try dir.openFile(\"input\", .{});\n" ++
        "    if (flag) { try validate(); }\n" ++
        "    defer file.close();\n" ++
        "}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "resource cleanup immediately after acquisition is safe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(dir: std.fs.Dir) !void {\n" ++
        "    var file = try dir.openFile(\"input\", .{});\n" ++
        "    defer file.close();\n" ++
        "    try validate();\n" ++
        "}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "resource transferred by pointer before a fallible operation stays opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(allocator: std.mem.Allocator) !void {\n" ++
        "    var buffer = try std.ArrayList(u8).initCapacity(allocator, 16);\n" ++
        "    var writer = Writer.fromArrayList(allocator, &buffer);\n" ++
        "    errdefer writer.deinit();\n" ++
        "    try writer.writeAll(\"value\");\n" ++
        "    buffer = writer.toArrayList();\n" ++
        "    defer buffer.deinit(allocator);\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "direct directory close after a fallible operation can be skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn scan(path: []const u8) !void { var dir = try std.fs.openDirAbsolute(path, .{}); try inspect(dir); dir.close(); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "direct cleanup after an explicit error path can be skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn scan(dir: std.fs.Dir, fail: bool) !void { var child = try dir.openDir(\".\", .{});" ++
        "if (fail) return error.Failed; child.close(); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "nested insertion rollback remains active through later fallible operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn spawn(world: *World, entity: Entity, velocity: ?Velocity) !void {\n" ++
        "    if (velocity) |value| {\n" ++
        "        try world.velocities.put(world.allocator, entity, value);\n" ++
        "        errdefer _ = world.velocities.remove(entity);\n" ++
        "    }\n" ++
        "    try world.names.put(world.allocator, entity, \"luna\");\n" ++
        "}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "function scoped insertion rollback covers later fallible operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn spawn(world: *World, entity: Entity, velocity: Velocity) !void {\n" ++
        "    try world.velocities.put(world.allocator, entity, velocity);\n" ++
        "    errdefer _ = world.velocities.remove(entity);\n" ++
        "    try world.names.put(world.allocator, entity, \"luna\");\n" ++
        "}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a declared resource pair reports cleanup registered after a fallible operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const source: [:0]const u8 =
        "fn load() !void {\n" ++
        "    const connection = try Db.open();\n" ++
        "    try validate();\n" ++
        "    defer connection.close();\n" ++
        "}";
    const declared = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), declared.len);
    const builtin = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), builtin.len);
}
