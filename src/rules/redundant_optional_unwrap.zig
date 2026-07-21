const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.redundant_optional_unwrap);
    if (level == .off) return;

    for (context.tokens, 0..) |token, condition_index| {
        if ((token.tag != .keyword_if and token.tag != .keyword_while) or condition_index + 7 >= context.tokens.len or
            context.tokens[condition_index + 1].tag != .l_paren or
            context.tokens[condition_index + 2].tag != .identifier or
            context.tokens[condition_index + 3].tag != .r_paren or
            context.tokens[condition_index + 4].tag != .pipe or
            context.tokens[condition_index + 5].tag != .identifier or
            context.tokens[condition_index + 6].tag != .pipe or
            context.tokens[condition_index + 7].tag != .l_brace) continue;
        const body_end = context.matchingToken(condition_index + 7, .l_brace, .r_brace) orelse continue;
        const optional_name = context.tokenText(condition_index + 2);
        const capture_name = context.tokenText(condition_index + 5);
        if (bindingChangesOrIsShadowed(context, optional_name, condition_index + 8, body_end)) continue;
        if (bindingIsMutatedThroughUnwrap(context, optional_name, condition_index + 8, body_end)) continue;

        var edits: std.ArrayList(types.Edit) = .empty;
        errdefer edits.deinit(context.allocator);
        for (context.tokens[condition_index + 8 .. body_end], condition_index + 8..) |body_token, index| {
            if (body_token.tag != .identifier or !context.refersToBinding(index, optional_name) or index + 2 >= body_end or
                context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .question_mark) continue;
            try edits.append(context.allocator, .{
                .span = .{ .start = body_token.loc.start, .end = context.tokens[index + 2].loc.end },
                .replacement = capture_name,
            });
        }
        if (edits.items.len == 0) continue;
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Use the optional capture",
            .kind = .quickfix,
            .edits = try edits.toOwnedSlice(context.allocator),
            .preferred = true,
            .fix_all = true,
        };
        try context.emit(.{
            .rule = .redundant_optional_unwrap,
            .level = level,
            .span = context.tokens[condition_index + 2].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "optional '{s}' is already available as capture '{s}'; forcing it again obscures the proven non-null value",
                .{ optional_name, capture_name },
            ),
            .fixes = fixes,
        });
    }
}

fn bindingChangesOrIsShadowed(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > start and (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var)) return true;
        if (index + 1 < end and context.tokens[index + 1].tag == .equal) return true;
    }
    return false;
}

fn bindingIsMutatedThroughUnwrap(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.refersToBinding(index, name)) continue;
        if (index > start and context.tokens[index - 1].tag == .ampersand) return true;
        if (index + 3 < end and context.tokens[index + 1].tag == .period and
            context.tokens[index + 2].tag == .question_mark and
            isAssignmentOperator(context.tokens[index + 3].tag)) return true;
    }
    return false;
}

fn isAssignmentOperator(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal,
        .plus_equal,
        .minus_equal,
        .asterisk_equal,
        .slash_equal,
        .percent_equal,
        .ampersand_equal,
        .pipe_equal,
        .caret_equal,
        .plus_percent_equal,
        .minus_percent_equal,
        .asterisk_percent_equal,
        .plus_pipe_equal,
        .minus_pipe_equal,
        .asterisk_pipe_equal,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left_pipe_equal,
        .angle_bracket_angle_bracket_right_equal,
        => true,
        else => false,
    };
}

test "optional captures replace repeated force unwraps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (optional) |value| { consume(optional.?); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.redundant_optional_unwrap)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqualStrings("value", findings.items[0].fixes[0].edits[0].replacement);
}

test "reassigned optionals do not produce capture rewrites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (optional) |value| { optional = other; consume(optional.?); _ = value; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.redundant_optional_unwrap)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a field named like the optional binding is not the binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (optional) |value| { consume(config.optional.?); _ = value; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.redundant_optional_unwrap)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "assigning through the forced unwrap disqualifies the capture rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "if (optional) |value| { optional.? = compute(value); consume(optional.?); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.redundant_optional_unwrap)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
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
