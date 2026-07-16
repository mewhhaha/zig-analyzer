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
        const length = allocationLengthBeforePlusOne(context, declaration_index + 3, declaration_end) orelse continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        if (!writesZeroTerminator(context, binding_name, length, declaration_end + 1, scope_end)) continue;
        try context.emit(.{
            .rule = .prefer_sentinel_termination,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "buffer '{s}' manually allocates one extra element and writes a zero terminator; allocSentinel or dupeZ expresses the sentinel contract",
                .{binding_name},
            ),
        });
    }
}

fn allocationLengthBeforePlusOne(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    var calls_alloc = false;
    var length: ?[]const u8 = null;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "alloc")) calls_alloc = true;
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
            length = context.source[context.tokens[length_start].loc.start..context.tokens[index - 1].loc.end];
        }
    }
    if (!calls_alloc) return null;
    return length;
}

fn writesZeroTerminator(context: RuleRun, name: []const u8, length: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index + 5 >= end or
            context.tokens[index + 1].tag != .l_bracket) continue;
        const bracket_end = context.matchingToken(index + 1, .l_bracket, .r_bracket) orelse continue;
        if (bracket_end + 2 >= end or bracket_end == index + 2 or context.tokens[bracket_end + 1].tag != .equal or
            context.tokens[bracket_end + 2].tag != .number_literal or !context.tokenIs(bracket_end + 2, "0")) continue;
        const index_text = context.source[context.tokens[index + 2].loc.start..context.tokens[bracket_end - 1].loc.end];
        if (!std.mem.eql(u8, index_text, length) and !std.mem.endsWith(u8, index_text, ".len")) continue;
        return true;
    }
    return false;
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
