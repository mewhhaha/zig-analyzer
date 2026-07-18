const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const owned_call = @import("owned_call.zig");
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.missing_errdefer);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        if (!startsStatement(context, declaration_index)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const acquisition = owningAcquisition(context, declaration_index, declaration_end) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        const receiver = context.source[context.tokens[acquisition.release_owner_start].loc.start..context.tokens[acquisition.release_owner_end].loc.end];
        const callable = context.source[context.tokens[acquisition.callable_start].loc.start..context.tokens[acquisition.method_index].loc.end];
        const method = context.tokenText(acquisition.method_index);
        if (acquisition.kind == .allocation and std.ascii.indexOfIgnoreCase(receiver, "arena") != null) continue;
        if (acquisition.kind == .allocation and std.mem.eql(u8, method, "create") and std.ascii.indexOfIgnoreCase(receiver, "pool") != null) continue;
        if (acquisition.kind == .allocation and declarationLooksArenaBacked(context, context.tokenText(acquisition.release_owner_start))) continue;
        if (scopeReleasesBinding(context, scope_opening, scope_end, binding_name)) continue;
        // 'defer pool.deinit(...)' reclaims everything the pool handed out,
        // error path included.
        if (acquisition.kind == .allocation and scopeDeinitializesReceiver(context, scope_opening, scope_end, context.tokenText(acquisition.release_owner_end))) continue;
        const fallible_index = fallibleBeforeBindingUse(
            context,
            declaration_end + 1,
            scope_end,
            binding_name,
            acquisition.kind == .network_stream,
        ) orelse continue;

        const release: []const u8 = if (std.mem.eql(u8, method, "create")) "destroy" else "free";
        const release_statement = switch (acquisition.kind) {
            .allocation => try std.fmt.allocPrint(context.allocator, "{s}.{s}({s})", .{ receiver, release, binding_name }),
            .network_stream => try std.fmt.allocPrint(
                context.allocator,
                "{s}.close({s})",
                .{
                    binding_name,
                    context.source[context.tokens[acquisition.close_argument.?.start].loc.start..context.tokens[acquisition.close_argument.?.end - 1].loc.end],
                },
            ),
        };
        const indent = lineIndent(context.source, context.tokens[declaration_index].loc.start);
        const semicolon_end = context.tokens[declaration_end].loc.end;
        const edits = try context.allocator.alloc(types.Edit, 1);
        if (std.mem.indexOfScalarPos(u8, context.source, semicolon_end, '\n')) |line_break| {
            edits[0] = .{
                .span = .{ .start = line_break + 1, .end = line_break + 1 },
                .replacement = try std.fmt.allocPrint(context.allocator, "{s}errdefer {s};\n", .{ indent, release_statement }),
            };
        } else {
            edits[0] = .{
                .span = .{ .start = semicolon_end, .end = semicolon_end },
                .replacement = try std.fmt.allocPrint(context.allocator, "\n{s}errdefer {s};", .{ indent, release_statement }),
            };
        }
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Add an errdefer release after the acquisition",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
        };
        const related = try context.allocator.alloc(types.RelatedSpan, 1);
        related[0] = .{
            .span = context.tokens[fallible_index].loc,
            .message = try context.allocator.dupe(u8, "this fallible operation leaks the owning value when it fails"),
        };
        try context.emit(.{
            .rule = .missing_errdefer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "owning value '{s}' from '{s}' has no errdefer release before the next fallible operation, so the error path leaks it",
                .{ binding_name, callable },
            ),
            .related = related,
            .fixes = fixes,
        });
    }
}

// `const` also appears inside pointer and slice types ("[]const u8"), where the
// following identifier is the pointee type, not a binding.
fn startsStatement(context: RuleRun, index: usize) bool {
    if (index == 0) return true;
    return switch (context.tokens[index - 1].tag) {
        .semicolon, .l_brace, .r_brace, .keyword_pub, .keyword_comptime, .keyword_export => true,
        else => false,
    };
}

const Acquisition = struct {
    kind: enum { allocation, network_stream } = .allocation,
    callable_start: usize,
    release_owner_start: usize,
    release_owner_end: usize,
    method_index: usize,
    close_argument: ?TokenRange = null,
};

fn owningAcquisition(context: RuleRun, declaration_index: usize, declaration_end: usize) ?Acquisition {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var equal_index: ?usize = null;
    var index = declaration_index + 2;
    while (index < declaration_end) : (index += 1) {
        switch (context.tokens[index].tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .equal => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                equal_index = index;
            },
            else => {},
        }
        if (equal_index != null) break;
    }
    const equal = equal_index orelse return null;
    if (equal + 4 >= declaration_end or context.tokens[equal + 1].tag != .keyword_try or
        context.tokens[equal + 2].tag != .identifier) return null;
    var path_end = equal + 2;
    while (path_end + 2 < declaration_end and context.tokens[path_end + 1].tag == .period and
        context.tokens[path_end + 2].tag == .identifier) path_end += 2;
    if (path_end == equal + 2 or path_end + 1 >= declaration_end or
        context.tokens[path_end + 1].tag != .l_paren) return null;
    const call_close = context.matchingToken(path_end + 1, .l_paren, .r_paren) orelse return null;
    if (call_close + 1 != declaration_end) return null;
    const callable = context.source[context.tokens[equal + 2].loc.start..context.tokens[path_end].loc.end];
    if (std.mem.eql(u8, callable, "std.Io.net.IpAddress.connect")) {
        const io_argument = callArgument(context, path_end + 2, call_close, 1) orelse return null;
        return .{
            .kind = .network_stream,
            .callable_start = equal + 2,
            .release_owner_start = equal + 2,
            .release_owner_end = path_end - 2,
            .method_index = path_end,
            .close_argument = io_argument,
        };
    }
    const standard_allocator_argument = owned_call.standardAllocatorArgument(callable);
    if (!isAllocatingMethod(context.tokenText(path_end)) and standard_allocator_argument == null) return null;
    if (argumentsReferenceArena(context, path_end + 2, call_close)) return null;
    if (standard_allocator_argument) |argument_index| {
        const argument = callArgument(context, path_end + 2, call_close, argument_index) orelse return null;
        if (argument.start + 1 != argument.end or context.tokens[argument.start].tag != .identifier) return null;
        return .{
            .callable_start = equal + 2,
            .release_owner_start = argument.start,
            .release_owner_end = argument.start,
            .method_index = path_end,
        };
    }
    if ((context.tokenIs(path_end, "dupe") or context.tokenIs(path_end, "dupeZ")) and
        !receiverLooksLikeAllocator(context, equal + 2, path_end - 2)) return null;
    return .{
        .callable_start = equal + 2,
        .release_owner_start = equal + 2,
        .release_owner_end = path_end - 2,
        .method_index = path_end,
    };
}

const TokenRange = struct { start: usize, end: usize };

fn callArgument(context: RuleRun, start: usize, end: usize, expected_index: usize) ?TokenRange {
    var argument_index: usize = 0;
    var argument_start = start;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .comma => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                if (argument_index == expected_index) return .{ .start = argument_start, .end = index };
                argument_index += 1;
                argument_start = index + 1;
            },
            else => {},
        }
    }
    if (argument_index != expected_index or argument_start >= end) return null;
    return .{ .start = argument_start, .end = end };
}

fn argumentsReferenceArena(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and std.ascii.indexOfIgnoreCase(context.tokenText(index), "arena") != null) return true;
    }
    return false;
}

fn receiverLooksLikeAllocator(context: RuleRun, receiver_start: usize, receiver_end: usize) bool {
    const receiver_name = context.tokenText(receiver_end);
    if (std.ascii.indexOfIgnoreCase(receiver_name, "alloc") != null or
        std.ascii.indexOfIgnoreCase(receiver_name, "arena") != null or
        std.mem.eql(u8, receiver_name, "gpa")) return true;
    if (receiver_start != receiver_end) return false;
    for (context.tokens, 0..) |token, identifier_index| {
        if (token.tag != .identifier or !context.tokenIs(identifier_index, receiver_name) or
            identifier_index + 2 >= context.tokens.len or context.tokens[identifier_index + 1].tag != .colon) continue;
        var type_index = identifier_index + 2;
        while (type_index < context.tokens.len) : (type_index += 1) {
            switch (context.tokens[type_index].tag) {
                .comma, .r_paren, .equal, .semicolon, .l_brace => break,
                .identifier => if (context.tokenIs(type_index, "Allocator")) return true,
                else => {},
            }
        }
    }
    return false;
}

fn isAllocatingMethod(name: []const u8) bool {
    return owned_call.releaseForMethod(name) != null and !std.mem.eql(u8, name, "realloc");
}

fn declarationLooksArenaBacked(context: RuleRun, root_name: []const u8) bool {
    for (context.tokens, 0..) |token, index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            index + 1 >= context.tokens.len or
            !context.tokenIs(index + 1, root_name)) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[token.loc.start..context.tokens[end].loc.end];
        if (std.mem.indexOf(u8, declaration, "ArenaAllocator") != null or
            std.mem.indexOf(u8, declaration, "FixedBufferAllocator") != null or
            std.mem.indexOf(u8, declaration, ".allocator()") != null) return true;
    }
    return false;
}

fn scopeReleasesBinding(context: RuleRun, scope_opening: usize, scope_end: usize, binding: []const u8) bool {
    var index = scope_opening + 1;
    while (index < scope_end) : (index += 1) {
        const tag = context.tokens[index].tag;
        if (tag != .keyword_defer and tag != .keyword_errdefer) continue;
        var body_start = index + 1;
        if (body_start < scope_end and context.tokens[body_start].tag == .pipe) {
            body_start += 1;
            while (body_start < scope_end and context.tokens[body_start].tag != .pipe) body_start += 1;
            body_start += 1;
        }
        if (body_start >= scope_end) return true;
        const body_end = if (context.tokens[body_start].tag == .l_brace)
            context.matchingToken(body_start, .l_brace, .r_brace) orelse return true
        else
            context.statementEnd(body_start) orelse return true;
        for (context.tokens[body_start..@min(body_end + 1, scope_end)], body_start..) |body_token, body_index| {
            if (body_token.tag == .identifier and context.tokenIs(body_index, binding)) return true;
        }
        index = body_end;
    }
    return false;
}

fn scopeDeinitializesReceiver(context: RuleRun, scope_opening: usize, scope_end: usize, receiver_segment: []const u8) bool {
    var index = scope_opening + 1;
    while (index + 3 < scope_end) : (index += 1) {
        const tag = context.tokens[index].tag;
        if (tag != .keyword_defer and tag != .keyword_errdefer) continue;
        const body_end = if (context.tokens[index + 1].tag == .l_brace)
            context.matchingToken(index + 1, .l_brace, .r_brace) orelse scope_end
        else
            context.statementEnd(index + 1) orelse scope_end;
        var body_index = index + 1;
        while (body_index + 2 < @min(body_end, scope_end)) : (body_index += 1) {
            if (context.tokens[body_index].tag == .identifier and
                context.tokenIs(body_index, receiver_segment) and
                context.tokens[body_index + 1].tag == .period and
                context.tokenIs(body_index + 2, "deinit")) return true;
        }
        index = @min(body_end, scope_end - 1);
    }
    return false;
}

fn fallibleBeforeBindingUse(
    context: RuleRun,
    start: usize,
    scope_end: usize,
    binding: []const u8,
    allow_writer_view: bool,
) ?usize {
    var cursor = start;
    while (cursor < scope_end) {
        const end = context.statementEnd(cursor) orelse return null;
        if (end >= scope_end) return null;
        var fallible_index: ?usize = null;
        for (context.tokens[cursor .. end + 1], cursor..) |chunk_token, chunk_index| {
            switch (chunk_token.tag) {
                .keyword_return => return null,
                // A nested function declaration's body does not execute here, so a
                // 'try' inside it is not a fallible operation on this path.
                .keyword_fn => return null,
                .keyword_try => if (fallible_index == null) {
                    fallible_index = chunk_index;
                },
                .identifier => if (context.tokenIs(chunk_index, binding)) {
                    if (fallible_index != null and callsBorrowingWriterMethod(context, cursor, end)) return fallible_index;
                    if (allow_writer_view and callsMethod(context, cursor, end, "writer")) continue;
                    return null;
                },
                else => {},
            }
        }
        if (fallible_index) |found| return found;
        cursor = end + 1;
    }
    return null;
}

fn callsMethod(context: RuleRun, start: usize, end: usize, expected: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, expected) and
            index + 1 < end and context.tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

fn callsBorrowingWriterMethod(context: RuleRun, start: usize, end: usize) bool {
    const borrowing_methods = [_][]const u8{ "write", "writeAll", "print" };
    for (borrowing_methods) |method| if (callsMethod(context, start, end, method)) return true;
    return false;
}

fn lineIndent(source: []const u8, offset: usize) []const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |newline| newline + 1 else 0;
    var end = line_start;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    return source[line_start..end];
}

test "allocation followed by another fallible operation without errdefer leaks on the error path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    const node = try allocator.create(u32);\n" ++
        "    try fill(buffer, node);\n" ++
        "}\n" ++
        "fn init(allocator: std.mem.Allocator) !void {\n" ++
        "    const node = try allocator.create(u32);\n" ++
        "    const extra = try allocator.alloc(u8, 2);\n" ++
        "    use(node, extra);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'buffer'") != null);
    try std.testing.expectEqualStrings("    errdefer allocator.free(buffer);\n", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "'node'") != null);
    try std.testing.expectEqualStrings("    errdefer allocator.destroy(node);\n", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expect(!findings[0].fixes[0].fix_all);
}

test "released transferred arena-backed and final allocations stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn released(allocator: std.mem.Allocator) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    errdefer allocator.free(buffer);\n" ++
        "    const extra = try allocator.alloc(u8, 4);\n" ++
        "    defer allocator.free(extra);\n" ++
        "    try flush(buffer, extra);\n" ++
        "}\n" ++
        "fn stored(gpa: std.mem.Allocator, sink: *Sink) !void {\n" ++
        "    const owned = try gpa.dupe(u8, \"name\");\n" ++
        "    sink.value = owned;\n" ++
        "    try sink.commit();\n" ++
        "}\n" ++
        "fn scratch(gpa: std.mem.Allocator) !void {\n" ++
        "    var arena_state = std.heap.ArenaAllocator.init(gpa);\n" ++
        "    defer arena_state.deinit();\n" ++
        "    const scratch_allocator = arena_state.allocator();\n" ++
        "    const scratch_bytes = try scratch_allocator.alloc(u8, 4);\n" ++
        "    const more = try scratch_allocator.alloc(u8, 4);\n" ++
        "    try consume(scratch_bytes, more);\n" ++
        "}\n" ++
        "fn last(allocator: std.mem.Allocator) ![]u8 {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    return buffer;\n" ++
        "}\n" ++
        "fn block(allocator: std.mem.Allocator) !void {\n" ++
        "    const pair = try allocator.alloc(u8, 2);\n" ++
        "    defer {\n" ++
        "        allocator.free(pair);\n" ++
        "    }\n" ++
        "    try flush(pair, pair);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "allocations reclaimed by a deferred pool deinit stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: std.mem.Allocator) !void {\n" ++
        "    var pool: MemoryPool = .empty;\n" ++
        "    defer pool.deinit(a);\n" ++
        "    const first = try pool.create(a);\n" ++
        "    const second = try pool.create(a);\n" ++
        "    use(first, second);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "pool-owned allocations do not require individual error cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn start(self: anytype) !void {\n" ++
        "    const completion = try self.completion_pool.create(self.allocator);\n" ++
        "    try self.socket.bind();\n" ++
        "    use(completion);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a try inside a nested function declaration is not a fallible operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    const Helper = struct {\n" ++
        "        fn fill() !void { try refill(); }\n" ++
        "    };\n" ++
        "    Helper.fill() catch {};\n" ++
        "    allocator.free(buffer);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a multiline typed acquisition with errdefer on the next line stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(gpa: std.mem.Allocator, options: Options) !void {\n" ++
        "    const exe_path: []const u8 = try gpa.dupe(\n" ++
        "        u8,\n" ++
        "        options.prebuilt orelse fallback.?,\n" ++
        "    );\n" ++
        "    errdefer gpa.free(exe_path);\n" ++
        "    try shell.exec(exe_path);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "standard allocation helpers require error-path cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator, parts: []const []const u8) !void {\n" ++
        "    const joined = try std.mem.concat(allocator, u8, parts);\n" ++
        "    _ = try writer.write(joined);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("    errdefer allocator.free(joined);\n", findings[0].fixes[0].edits[0].replacement);
}

test "returned network streams require error-path cleanup before fallible writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn connect(io: std.Io, address: std.Io.net.IpAddress) !std.Io.net.Stream {\n" ++
        "    const stream = try std.Io.net.IpAddress.connect(&address, io, .{});\n" ++
        "    var stream_writer = stream.writer(io, &.{});\n" ++
        "    try stream_writer.interface.writeAll(\"request\");\n" ++
        "    return stream;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("    errdefer stream.close(io);\n", findings[0].fixes[0].edits[0].replacement);
}

test "dupe on a non-allocator receiver does not invent allocator provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn complete(tuple_info: anytype, arena_allocator: std.mem.Allocator, ip: anytype) !void {\n" ++
        "    const tuple_types = try tuple_info.types.dupe(arena_allocator, ip);\n" ++
        "    try render(tuple_types);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "constructors passed an arena do not require individual error cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(context: anytype) !void {\n" ++
        "    const node = try ZigTag.node.create(context.state.arena, .{});\n" ++
        "    try render(node);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "missing errdefer diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator) !void {\n" ++
        "    // zig-analyzer: disable-next-line missing-errdefer\n" ++
        "    const buffer = try allocator.alloc(u8, 4);\n" ++
        "    const node = try allocator.create(u32);\n" ++
        "    try fill(buffer, node);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
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
