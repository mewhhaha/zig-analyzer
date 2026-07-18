const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.directory_iteration_not_enabled);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const open_call = openDirectoryCall(context, declaration_index + 2, declaration_end) orelse continue;
        if (!open_call.options_literal or open_call.iteration_enabled or
            !callHasDirectoryProvenance(context, open_call.method_index)) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        const iterate_index = iterationCall(context, binding, declaration_end + 1, scope_end) orelse continue;

        try context.emit(.{
            .rule = .directory_iteration_not_enabled,
            .level = level,
            .span = context.tokens[iterate_index].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "directory '{s}' is iterated after being opened without '.iterate = true'",
                .{binding},
            ),
        });
    }
}

const OpenDirectoryCall = struct {
    method_index: usize,
    options_literal: bool,
    iteration_enabled: bool,
};

fn openDirectoryCall(context: RuleRun, start: usize, end: usize) ?OpenDirectoryCall {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or
            (!context.tokenIs(method_index, "openDir") and !context.tokenIs(method_index, "openDirAbsolute")) or
            method_index == 0 or context.tokens[method_index - 1].tag != .period or
            method_index + 1 >= end or context.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end > end) continue;
        const options_start = lastArgumentStart(context, method_index + 1, call_end);
        const options_literal = options_start + 1 < call_end and
            context.tokens[options_start].tag == .period and context.tokens[options_start + 1].tag == .l_brace;
        return .{
            .method_index = method_index,
            .options_literal = options_literal,
            .iteration_enabled = options_literal and optionEnablesIteration(context, options_start, call_end),
        };
    }
    return null;
}

fn lastArgumentStart(context: RuleRun, opening: usize, closing: usize) usize {
    var start = opening + 1;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .comma => {
                if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) start = index + 1;
            },
            else => {},
        }
    }
    return start;
}

fn optionEnablesIteration(context: RuleRun, start: usize, end: usize) bool {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (context.tokens[index].tag == .period and context.tokenIs(index + 1, "iterate") and
            context.tokens[index + 2].tag == .equal and context.tokenIs(index + 3, "true")) return true;
    }
    return false;
}

fn callHasDirectoryProvenance(context: RuleRun, method_index: usize) bool {
    const statement_start = statementStart(context, method_index);
    for (context.tokens[statement_start..method_index], statement_start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "std")) return true;
    }
    if (method_index < 2 or context.tokens[method_index - 2].tag != .identifier) return false;
    return bindingHasDirectoryType(context, context.tokenText(method_index - 2), method_index);
}

fn bindingHasDirectoryType(context: RuleRun, binding: []const u8, before: usize) bool {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, binding) or index + 1 >= before or context.tokens[index + 1].tag != .colon) continue;
        const type_end = @min(before, index + 10);
        var saw_std = false;
        for (context.tokens[index + 2 .. type_end], index + 2..) |token, type_index| {
            if (token.tag == .comma or token.tag == .r_paren or token.tag == .equal) break;
            if (context.tokenIs(type_index, "std")) saw_std = true;
            if (saw_std and context.tokenIs(type_index, "Dir")) return true;
        }
    }
    return false;
}

fn iterationCall(context: RuleRun, binding: []const u8, start: usize, end: usize) ?usize {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (!context.refersToBinding(index, binding)) continue;
        if (index > 0 and (context.tokens[index - 1].tag == .keyword_const or
            context.tokens[index - 1].tag == .keyword_var)) return null;
        if (context.tokens[index + 1].tag == .equal) return null;
        if (context.tokens[index + 1].tag == .period and context.tokenIs(index + 2, "iterate") and
            context.tokens[index + 3].tag == .l_paren) return index + 2;
    }
    return null;
}

fn statementStart(context: RuleRun, index: usize) usize {
    var cursor = index;
    while (cursor > 0) {
        const previous = context.tokens[cursor - 1].tag;
        if (previous == .semicolon or previous == .l_brace or previous == .r_brace) break;
        cursor -= 1;
    }
    return cursor;
}

test "iterating a directory opened with default options reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn walk(io: std.Io, path: []const u8) !void {\n" ++
        "    var directory = try std.Io.Dir.cwd().openDir(io, path, .{});\n" ++
        "    var iterator = directory.iterate();\n" ++
        "    _ = &iterator;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "explicitly disabled iteration reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn walk(directory: std.Io.Dir, io: std.Io, path: []const u8) !void {\n" ++
        "    var child = try directory.openDir(io, path, .{ .iterate = false });\n" ++
        "    var iterator = child.iterate();\n" ++
        "    _ = &iterator;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "legacy standard directory API reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn walk(path: []const u8) !void {\n" ++
        "    var directory = try std.fs.openDirAbsolute(path, .{});\n" ++
        "    var iterator = directory.iterate();\n" ++
        "    _ = &iterator;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "enabled iteration and opaque options stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn walk(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !void {\n" ++
        "    var enabled = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });\n" ++
        "    var unknown = try std.Io.Dir.cwd().openDir(io, path, options);\n" ++
        "    var enabled_iterator = enabled.iterate();\n" ++
        "    var unknown_iterator = unknown.iterate();\n" ++
        "    _ = &enabled_iterator;\n" ++
        "    _ = &unknown_iterator;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "custom openDir method stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn walk(tree: anytype, path: []const u8) !void {\n" ++
        "    var directory = try tree.openDir(path, .{});\n" ++
        "    var iterator = directory.iterate();\n" ++
        "    _ = &iterator;\n" ++
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

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
