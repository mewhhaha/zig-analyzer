const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findOptionalPresenceTests(context);
    try findUnusedElseCaptures(context);
    try findManualSentinels(context);
}

fn findOptionalPresenceTests(context: RuleRun) !void {
    const level = context.level(.prefer_optional_presence_test);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .keyword_if or index + 9 >= context.tokens.len or
            context.tokens[index + 1].tag != .l_paren or context.tokens[index + 2].tag != .identifier or
            context.tokens[index + 3].tag != .r_paren or context.tokens[index + 4].tag != .pipe or
            !context.tokenIs(index + 5, "_") or context.tokens[index + 6].tag != .pipe or
            context.tokens[index + 7].tag != .identifier or context.tokens[index + 8].tag != .keyword_else or
            context.tokens[index + 9].tag != .identifier) continue;
        if (index + 10 < context.tokens.len and !endsExpression(context.tokens[index + 10].tag)) continue;
        if (containsComment(context.source[token.loc.start..context.tokens[index + 9].loc.end])) continue;
        const when_present = context.tokenText(index + 7);
        const when_absent = context.tokenText(index + 9);
        const operator = if (std.mem.eql(u8, when_present, "true") and std.mem.eql(u8, when_absent, "false"))
            "!="
        else if (std.mem.eql(u8, when_present, "false") and std.mem.eql(u8, when_absent, "true"))
            "=="
        else
            continue;
        const optional_name = context.tokenText(index + 2);
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = token.loc.start, .end = context.tokens[index + 9].loc.end },
            .replacement = try std.fmt.allocPrint(context.allocator, "{s} {s} null", .{ optional_name, operator }),
        };
        const fixes = try oneFix(context, "Use an optional presence comparison", edits);
        try context.emit(.{
            .rule = .prefer_optional_presence_test,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "optional capture is used only to test whether '{s}' is null",
                .{optional_name},
            ),
            .fixes = fixes,
        });
    }
}

fn endsExpression(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .semicolon, .comma, .r_paren, .r_bracket, .r_brace => true,
        else => false,
    };
}

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

fn findUnusedElseCaptures(context: RuleRun) !void {
    const level = context.level(.needless_switch_else_capture);
    if (level == .off) return;
    for (context.tokens, 0..) |token, else_index| {
        if (token.tag != .keyword_else or else_index + 4 >= context.tokens.len or
            context.tokens[else_index + 1].tag != .equal_angle_bracket_right or
            context.tokens[else_index + 2].tag != .pipe or context.tokens[else_index + 3].tag != .identifier or
            context.tokens[else_index + 4].tag != .pipe or context.tokenIs(else_index + 3, "_")) continue;
        const capture_name = context.tokenText(else_index + 3);
        const body_start = else_index + 5;
        if (body_start >= context.tokens.len) continue;
        const body_end = if (context.tokens[body_start].tag == .l_brace)
            context.matchingToken(body_start, .l_brace, .r_brace) orelse continue
        else
            prongEnd(context.tokens, body_start);
        var used = false;
        for (context.tokens[body_start..body_end], body_start..) |body_token, index| {
            if (body_token.tag == .identifier and context.tokenIs(index, capture_name)) {
                used = true;
                break;
            }
        }
        if (used) continue;
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = context.tokens[else_index + 2].loc.start, .end = context.tokens[else_index + 4].loc.end },
            .replacement = "",
        };
        const fixes = try oneFix(context, "Remove the unused else capture", edits);
        try context.emit(.{
            .rule = .needless_switch_else_capture,
            .level = level,
            .span = context.tokens[else_index + 3].loc,
            .message = try std.fmt.allocPrint(context.allocator, "switch else capture '{s}' is never used", .{capture_name}),
            .fixes = fixes,
        });
    }
}

fn findManualSentinels(context: RuleRun) !void {
    const level = context.level(.prefer_sentinel_termination);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const allocation = allocationLengthBeforePlusOne(context, declaration_index + 3, declaration_end) orelse continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        const write = zeroTerminatorWrite(context, binding_name, allocation.length_text, declaration_end + 1, scope_end) orelse continue;
        const fixes: []const types.Fix = if (allocation.rewritable and write.exact_index and write.whole_statement) fixes: {
            var delete_start = context.tokens[write.use_index].loc.start;
            while (delete_start > 0 and (context.source[delete_start - 1] == ' ' or context.source[delete_start - 1] == '\t')) delete_start -= 1;
            if (delete_start > 0 and context.source[delete_start - 1] == '\n') delete_start -= 1;
            const edits = try context.allocator.alloc(types.Edit, 3);
            edits[0] = .{ .span = context.tokens[allocation.alloc_index].loc, .replacement = "allocSentinel" };
            edits[1] = .{
                .span = .{
                    .start = context.tokens[allocation.length_end].loc.end,
                    .end = context.tokens[allocation.one_index].loc.end,
                },
                .replacement = ", 0",
            };
            edits[2] = .{
                .span = .{ .start = delete_start, .end = context.tokens[write.semicolon_index].loc.end },
                .replacement = "",
            };
            const allocated = try context.allocator.alloc(types.Fix, 1);
            allocated[0] = .{
                .title = "Rewrite with allocSentinel and drop the manual terminator",
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
            };
            break :fixes allocated;
        } else &.{};
        try context.emit(.{
            .rule = .prefer_sentinel_termination,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "buffer '{s}' manually allocates one extra element and writes a zero terminator; allocSentinel or dupeZ expresses the sentinel contract",
                .{binding_name},
            ),
            .fixes = fixes,
        });
    }
}

const SentinelAllocation = struct {
    length_text: []const u8,
    alloc_index: usize,
    length_end: usize,
    one_index: usize,
    rewritable: bool,
};

fn allocationLengthBeforePlusOne(context: RuleRun, start: usize, end: usize) ?SentinelAllocation {
    var alloc_index: ?usize = null;
    var alloc_close: ?usize = null;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "alloc") and
            index + 1 < end and context.tokens[index + 1].tag == .l_paren)
        {
            alloc_index = index;
            alloc_close = context.matchingToken(index + 1, .l_paren, .r_paren);
        }
    }
    var allocation: ?SentinelAllocation = null;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .plus or index + 1 >= end or context.tokens[index + 1].tag != .number_literal or
            !context.tokenIs(index + 1, "1")) continue;
        var length_start = index;
        while (length_start > start) : (length_start -= 1) {
            switch (context.tokens[length_start - 1].tag) {
                .identifier, .period, .number_literal => {},
                else => break,
            }
        }
        if (length_start < index) {
            allocation = .{
                .length_text = context.source[context.tokens[length_start].loc.start..context.tokens[index - 1].loc.end],
                .alloc_index = alloc_index orelse return null,
                .length_end = index - 1,
                .one_index = index + 1,
                .rewritable = alloc_close != null and index + 2 == alloc_close.?,
            };
        }
    }
    if (alloc_index == null) return null;
    return allocation;
}

const TerminatorWrite = struct {
    use_index: usize,
    semicolon_index: usize,
    exact_index: bool,
    whole_statement: bool,
};

fn zeroTerminatorWrite(
    context: RuleRun,
    name: []const u8,
    length: []const u8,
    start: usize,
    end: usize,
) ?TerminatorWrite {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index + 5 >= end or
            context.tokens[index + 1].tag != .l_bracket) continue;
        const bracket_end = context.matchingToken(index + 1, .l_bracket, .r_bracket) orelse continue;
        if (bracket_end + 2 >= end or bracket_end == index + 2 or context.tokens[bracket_end + 1].tag != .equal or
            context.tokens[bracket_end + 2].tag != .number_literal or !context.tokenIs(bracket_end + 2, "0")) continue;
        const index_text = context.source[context.tokens[index + 2].loc.start..context.tokens[bracket_end - 1].loc.end];
        const exact_index = std.mem.eql(u8, index_text, length);
        if (!exact_index and !std.mem.endsWith(u8, index_text, ".len")) continue;
        const starts_statement = index == 0 or switch (context.tokens[index - 1].tag) {
            .semicolon, .l_brace, .r_brace => true,
            else => false,
        };
        const has_semicolon = bracket_end + 3 < end and context.tokens[bracket_end + 3].tag == .semicolon;
        return .{
            .use_index = index,
            .semicolon_index = bracket_end + 3,
            .exact_index = exact_index,
            .whole_statement = starts_statement and has_semicolon,
        };
    }
    return null;
}

fn oneFix(context: RuleRun, title: []const u8, edits: []const types.Edit) ![]const types.Fix {
    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{ .title = title, .kind = .quickfix, .edits = edits, .preferred = true, .fix_all = true };
    return fixes;
}

fn prongEnd(tokens: []const std.zig.Token, start: usize) usize {
    var depth: usize = 0;
    for (tokens[start..], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => {
            if (depth == 0) return index;
            depth -= 1;
        },
        .comma => if (depth == 0) return index,
        else => {},
    };
    return tokens.len;
}

test "optional presence and sentinel idioms are recognized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() !void {\n" ++
        "    const present = if (optional) |_| true else false;\n" ++
        "    const result = try allocator.alloc(u8, input.len + 1); result[input.len] = 0;\n" ++
        "    _ = present;\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_optional_presence_test)] = .information;
    configuration.levels[@intFromEnum(types.Rule.prefer_sentinel_termination)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 2), findings.items.len);
}

test "a compared presence test keeps its capture form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const compared = if (optional) |_| false else true == other;";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_optional_presence_test)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "writing a value at an unrelated index is not a manual sentinel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() !void { const grid = try allocator.alloc(u8, w * h + 1); grid[0] = 0; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_sentinel_termination)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "manual sentinel rewrite fixes alloc and removes the terminator write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() !void {\n" ++
        "    const result = try allocator.alloc(u8, input.len + 1);\n" ++
        "    result[input.len] = 0;\n" ++
        "}\n";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_sentinel_termination)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    const fixes = findings.items[0].fixes;
    try std.testing.expectEqual(@as(usize, 1), fixes.len);
    try std.testing.expect(!fixes[0].fix_all);
    try std.testing.expectEqual(@as(usize, 3), fixes[0].edits.len);
    var rewritten: std.ArrayList(u8) = .empty;
    try rewritten.appendSlice(arena.allocator(), source);
    var edit_index = fixes[0].edits.len;
    while (edit_index > 0) {
        edit_index -= 1;
        const edit = fixes[0].edits[edit_index];
        try rewritten.replaceRange(arena.allocator(), edit.span.start, edit.span.end - edit.span.start, edit.replacement);
    }
    try std.testing.expectEqualStrings(
        "fn run() !void {\n" ++
            "    const result = try allocator.allocSentinel(u8, input.len, 0);\n" ++
            "}\n",
        rewritten.items,
    );
}

test "sentinel writes that cannot be rewritten mechanically keep the diagnostic only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() !void {\n" ++
        "    const result = try allocator.alloc(u8, count + 1);\n" ++
        "    result[other.len] = 0;\n" ++
        "}\n";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_sentinel_termination)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(@as(usize, 0), findings.items[0].fixes.len);
}

test "unused switch else captures are removable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const result = switch (value) { else => |payload| 1 };";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.needless_switch_else_capture)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
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
