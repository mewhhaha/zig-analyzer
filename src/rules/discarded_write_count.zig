const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.discarded_write_count);
    if (level == .off) return;

    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or
            context.tokens[equal_index - 1].tag != .identifier or !context.tokenIs(equal_index - 1, "_")) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        for (context.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or !context.tokenIs(method_index, "write") or
                method_index < 2 or method_index + 1 >= statement_end or
                context.tokens[method_index - 1].tag != .period or
                context.tokens[method_index + 1].tag != .l_paren) continue;
            if (context.tokens[method_index - 2].tag != .identifier or
                !ioReceiver(context.tokenText(method_index - 2)) or
                receiverIsAllocatingWriter(context, context.tokenText(method_index - 2), method_index)) continue;
            try context.emit(.{
                .rule = .discarded_write_count,
                .level = level,
                .span = candidate.loc,
                .message = try context.allocator.dupe(
                    u8,
                    "discarding write's byte count can silently accept a partial write; use writeAll when the entire buffer must be written",
                ),
            });
            break;
        }
    }
}

fn receiverIsAllocatingWriter(context: RuleRun, receiver: []const u8, before: usize) bool {
    var candidate = before;
    while (candidate > 0) {
        candidate -= 1;
        if (!context.tokenIs(candidate, receiver) or candidate == 0 or
            (context.tokens[candidate - 1].tag != .keyword_const and context.tokens[candidate - 1].tag != .keyword_var)) continue;
        const declaration_end = context.statementEnd(candidate - 1) orelse continue;
        if (declaration_end >= before) continue;
        const scope_end = context.enclosingScopeEnd(candidate - 1) orelse continue;
        if (scope_end < before) continue;
        const declaration = context.source[context.tokens[candidate - 1].loc.start..context.tokens[declaration_end].loc.end];
        if (std.mem.indexOf(u8, declaration, "Writer.Allocating") != null) return true;

        var equal_index = candidate + 1;
        while (equal_index < declaration_end and context.tokens[equal_index].tag != .equal) : (equal_index += 1) {}
        if (equal_index + 4 >= declaration_end or context.tokens[equal_index + 1].tag != .ampersand or
            context.tokens[equal_index + 2].tag != .identifier or context.tokens[equal_index + 3].tag != .period or
            !context.tokenIs(equal_index + 4, "writer")) return false;
        return receiverIsAllocatingWriter(context, context.tokenText(equal_index + 2), candidate - 1);
    }
    return false;
}

fn ioReceiver(name: []const u8) bool {
    const fragments = [_][]const u8{ "writer", "file", "stream", "socket" };
    for (fragments) |fragment| if (hasRoleName(name, fragment)) return true;
    return std.mem.eql(u8, name, "posix") or std.mem.eql(u8, name, "linux");
}

fn hasRoleName(name: []const u8, role: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, role) or name.len <= role.len) return std.ascii.eqlIgnoreCase(name, role);
    const suffix = name[name.len - role.len ..];
    if (!std.ascii.eqlIgnoreCase(suffix, role)) return false;
    return name[name.len - role.len - 1] == '_' or std.ascii.isUpper(suffix[0]);
}

test "discarding a partial write count reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn send(writer: anytype, bytes: []const u8) !void { _ = try writer.write(bytes); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "writeAll and used write counts stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn send(writer: anytype, bytes: []const u8) !void {\n" ++
        "    try writer.writeAll(bytes);\n" ++
        "    const written = try writer.write(bytes);\n" ++
        "    consume(written);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "custom write methods do not imply partial byte output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn update(registry: *Registry, value: Value) !void { _ = try registry.write(value); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "profile writes do not look like file output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn update(profile: *Profile, value: Value) !void { _ = try profile.write(value); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "allocating writers cannot return partial writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn render(allocator: std.mem.Allocator, bytes: []const u8) !void {" ++
        "var output: std.Io.Writer.Allocating = .init(allocator); defer output.deinit();" ++
        "const writer = &output.writer; _ = try writer.write(bytes); }";
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
