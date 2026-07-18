const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_expression_initializer);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const initializer = undefinedInitializer(context, declaration_index + 2, declaration_end) orelse continue;
        if (initializer + 2 != declaration_end or !context.tokenIs(initializer + 1, "undefined")) continue;
        const expression_index = declaration_end + 1;
        if (expression_index >= context.tokens.len) continue;
        const name = context.tokenText(declaration_index + 1);
        const expression_name = switch (context.tokens[expression_index].tag) {
            .keyword_if => if (ifAssignsEveryBranch(context, expression_index, name)) "if" else continue,
            .keyword_switch => if (switchAssignsEveryProng(context, expression_index, name)) "switch" else continue,
            else => continue,
        };

        try context.emit(.{
            .rule = .prefer_expression_initializer,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "'{s}' starts undefined and every {s} branch assigns it; initialize a const from the {s} expression",
                .{ name, expression_name, expression_name },
            ),
        });
    }
}

fn undefinedInitializer(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| if (token.tag == .equal) return index;
    return null;
}

fn ifAssignsEveryBranch(context: RuleRun, if_index: usize, name: []const u8) bool {
    if (if_index + 2 >= context.tokens.len or context.tokens[if_index + 1].tag != .l_paren) return false;
    const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse return false;
    if (bindingReferenced(context, if_index + 2, condition_end, name)) return false;
    const then_start = condition_end + 1;
    if (then_start >= context.tokens.len or context.tokens[then_start].tag != .l_brace) return false;
    const then_end = context.matchingToken(then_start, .l_brace, .r_brace) orelse return false;
    if (!blockOnlyAssigns(context, then_start, then_end, name)) return false;
    if (then_end + 2 >= context.tokens.len or context.tokens[then_end + 1].tag != .keyword_else or
        context.tokens[then_end + 2].tag != .l_brace) return false;
    const else_end = context.matchingToken(then_end + 2, .l_brace, .r_brace) orelse return false;
    return blockOnlyAssigns(context, then_end + 2, else_end, name);
}

fn switchAssignsEveryProng(context: RuleRun, switch_index: usize, name: []const u8) bool {
    if (switch_index + 2 >= context.tokens.len or context.tokens[switch_index + 1].tag != .l_paren) return false;
    const operand_end = context.matchingToken(switch_index + 1, .l_paren, .r_paren) orelse return false;
    if (bindingReferenced(context, switch_index + 2, operand_end, name)) return false;
    const opening = operand_end + 1;
    if (opening >= context.tokens.len or context.tokens[opening].tag != .l_brace) return false;
    const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse return false;

    var cursor = opening + 1;
    var prong_count: usize = 0;
    while (cursor < closing) {
        const arrow = topLevelArrow(context.tokens, cursor, closing) orelse return false;
        if (bindingReferenced(context, cursor, arrow, name)) return false;
        const body_start = arrow + 1;
        if (body_start >= closing or context.tokens[body_start].tag != .l_brace) return false;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse return false;
        if (!blockOnlyAssigns(context, body_start, body_end, name)) return false;
        prong_count += 1;
        cursor = body_end + 1;
        if (cursor < closing) {
            if (context.tokens[cursor].tag != .comma) return false;
            cursor += 1;
        }
    }
    return prong_count >= 2;
}

fn bindingReferenced(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.refersToBinding(index, name)) return true;
    }
    return false;
}

fn blockOnlyAssigns(context: RuleRun, opening: usize, closing: usize, name: []const u8) bool {
    if (opening + 4 > closing or context.tokens[opening + 1].tag != .identifier or
        !context.tokenIs(opening + 1, name) or context.tokens[opening + 2].tag != .equal or
        context.tokens[closing - 1].tag != .semicolon) return false;
    for (context.tokens[opening + 3 .. closing - 1], opening + 3..) |token, index| {
        if (token.tag == .semicolon or context.refersToBinding(index, name)) return false;
    }
    return true;
}

fn topLevelArrow(tokens: []const std.zig.Token, start: usize, end: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren => parenthesis_depth += 1,
        .r_paren => parenthesis_depth -|= 1,
        .l_bracket => bracket_depth += 1,
        .r_bracket => bracket_depth -|= 1,
        .l_brace => brace_depth += 1,
        .r_brace => brace_depth -|= 1,
        .equal_angle_bracket_right => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index,
        else => {},
    };
    return null;
}

test "undefined locals assigned by every if branch prefer expression initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var value: u8 = undefined;\n" ++
        "if (ready) { value = 1; } else { value = 2; }\n" ++
        "use(value);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "const") != null);
}

test "undefined locals assigned by every switch prong prefer expression initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var value: u8 = undefined;\n" ++
        "switch (mode) { .fast => { value = 1; }, .safe => { value = 2; } }\n" ++
        "use(value);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "switch") != null);
}

test "partial and multi-statement assignments stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var partial: u8 = undefined; if (ready) { partial = 1; }\n" ++
        "var prepared: u8 = undefined; if (ready) { prepare(); prepared = 1; } else { prepared = 2; }\n" ++
        "var self_read: u8 = undefined; if (self_read == 0) { self_read = 1; } else { self_read = 2; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "expression initializer preference respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line prefer-expression-initializer\n" ++
        "var value: u8 = undefined;\n" ++
        "if (ready) { value = 1; } else { value = 2; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_expression_initializer)] = .information;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
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
