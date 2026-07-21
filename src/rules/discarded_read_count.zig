const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.discarded_read_count);
    if (level == .off) return;

    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or
            context.tokens[equal_index - 1].tag != .identifier or !context.tokenIs(equal_index - 1, "_")) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        for (context.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or method_index == 0 or method_index + 1 >= statement_end or
                context.tokens[method_index - 1].tag != .period or context.tokens[method_index + 1].tag != .l_paren) continue;
            const method = context.tokenText(method_index);
            const partial_read = partialRead(method) orelse continue;
            if (method_index < 2 or context.tokens[method_index - 2].tag != .identifier or
                !ioReceiver(context.tokenText(method_index - 2))) continue;
            const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
            if (readDestination(context, method_index + 2, call_end)) |destination| {
                const scope_end = context.enclosingScopeEnd(equal_index) orelse continue;
                if (!bindingUsedAfter(context, destination, statement_end + 1, scope_end)) continue;
            }
            try context.emit(.{
                .rule = .discarded_read_count,
                .level = level,
                .span = candidate.loc,
                .message = if (partial_read.complete_method) |complete_method|
                    try std.fmt.allocPrint(
                        context.allocator,
                        "discarding {s}'s byte count loses how much of the destination was initialized; use {s} when the destination must be filled",
                        .{ method, complete_method },
                    )
                else
                    try std.fmt.allocPrint(
                        context.allocator,
                        "discarding {s}'s byte count loses how much of the destination was initialized",
                        .{method},
                    ),
            });
            break;
        }
    }
}

fn readDestination(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    var depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) return null,
        .identifier => if (depth <= 1 and (index == start or context.tokens[index - 1].tag != .period)) {
            return context.tokenText(index);
        },
        else => {},
    };
    return null;
}

fn bindingUsedAfter(context: RuleRun, binding: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, binding) and
            (index == 0 or context.tokens[index - 1].tag != .period)) return true;
    }
    return false;
}

fn ioReceiver(name: []const u8) bool {
    const fragments = [_][]const u8{ "reader", "file", "stream", "socket" };
    for (fragments) |fragment| if (hasRoleName(name, fragment)) return true;
    return std.mem.eql(u8, name, "posix") or std.mem.eql(u8, name, "linux");
}

fn hasRoleName(name: []const u8, role: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, role) or name.len <= role.len) return std.ascii.eqlIgnoreCase(name, role);
    const suffix = name[name.len - role.len ..];
    if (!std.ascii.eqlIgnoreCase(suffix, role)) return false;
    return name[name.len - role.len - 1] == '_' or std.ascii.isUpper(suffix[0]);
}

const PartialRead = struct {
    complete_method: ?[]const u8,
};

fn partialRead(method: []const u8) ?PartialRead {
    if (std.mem.eql(u8, method, "readVec")) return .{ .complete_method = "readVecAll" };
    if (std.mem.eql(u8, method, "readSliceShort")) return .{ .complete_method = "readSliceAll" };
    const partial_methods = [_][]const u8{ "read", "pread", "readv", "preadv" };
    for (partial_methods) |candidate| {
        if (std.mem.eql(u8, method, candidate)) return .{ .complete_method = null };
    }
    return null;
}

test "discarded partial read counts report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn receive(reader: anytype, buffers: [][]u8, bytes: []u8) !void {\n" ++
        "    _ = try reader.readVec(buffers);\n" ++
        "    _ = try reader.readSliceShort(bytes);\n" ++
        "    _ = try reader.read(bytes);\n" ++
        "    consume(buffers, bytes);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "readVecAll") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "readSliceAll") != null);
}

test "discarded reads used only for their side effect stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn consumeEvent(fd: anytype) void { var bytes: [8]u8 = undefined; _ = std.posix.read(fd, &bytes) catch {}; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "discarded reads track a sliced destination instead of its bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn receive(reader: anytype, limit: usize) !void { var bytes: [8]u8 = undefined; " ++
        "_ = try reader.read(bytes[0..limit]); consume(bytes); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "complete reads and handled counts stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn receive(reader: anytype, buffers: [][]u8, bytes: []u8) !void {\n" ++
        "    try reader.readVecAll(buffers);\n" ++
        "    try reader.readSliceAll(bytes);\n" ++
        "    const count = try reader.readVec(buffers);\n" ++
        "    consume(count);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "custom read methods do not imply partial byte input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn query(registry: *Registry, key: Key) !void { _ = try registry.read(key); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "profile reads do not look like file input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn query(profile: *Profile, key: Key) !void { _ = try profile.read(key); }";
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

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
