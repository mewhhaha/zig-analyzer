const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.inclusive_index_bound);
    if (level == .off) return;

    for (context.tokens, 0..) |operator, operator_index| {
        if (operator.tag != .angle_bracket_left_equal) continue;
        const opening = enclosingAssertOpening(context, operator_index) orelse continue;
        const closing = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        if (operator_index + 3 >= closing or context.tokens[closing - 2].tag != .period or
            !context.tokenIs(closing - 1, "len")) continue;
        const index_path = Path{ .start = opening + 1, .end = operator_index };
        const sequence_path = Path{ .start = operator_index + 1, .end = closing - 2 };
        if (!validPath(context, index_path) or !validPath(context, sequence_path)) continue;
        const assertion_end = context.statementEnd(opening - 1) orelse continue;
        if (assertion_end != closing + 1 or assertion_end + 1 >= context.tokens.len) continue;
        const next_statement_end = context.statementEnd(assertion_end + 1) orelse continue;
        if (context.enclosingOpeningBrace(operator_index) != context.enclosingOpeningBrace(assertion_end + 1) or
            !statementIndexes(context, sequence_path, index_path, assertion_end + 1, next_statement_end)) continue;

        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{ .span = operator.loc, .replacement = "<" };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = "Make the index assertion strict",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
        };
        try context.emit(.{
            .rule = .inclusive_index_bound,
            .level = level,
            .span = operator.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "inclusive assertion for index '{s}' does not itself establish the strict bound required by the following '{s}' indexing operation",
                .{ pathText(context, index_path), pathText(context, sequence_path) },
            ),
            .fixes = fixes,
        });
    }
}

const Path = struct { start: usize, end: usize };

fn enclosingAssertOpening(context: RuleRun, operator_index: usize) ?usize {
    var cursor = operator_index;
    while (cursor > 0) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .l_paren) {
            if (cursor > 0 and context.tokenIs(cursor - 1, "assert")) return cursor;
            return null;
        }
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) return null;
    }
    return null;
}

fn validPath(context: RuleRun, path: Path) bool {
    if (path.start >= path.end) return false;
    for (context.tokens[path.start..path.end], 0..) |token, offset| {
        if (offset % 2 == 0 and token.tag != .identifier) return false;
        if (offset % 2 == 1 and token.tag != .period) return false;
    }
    return (path.end - path.start) % 2 == 1;
}

fn statementIndexes(context: RuleRun, sequence: Path, index: Path, start: usize, end: usize) bool {
    const sequence_length = sequence.end - sequence.start;
    const index_length = index.end - index.start;
    var cursor = start;
    while (cursor + sequence_length + index_length + 2 <= end) : (cursor += 1) {
        if (!pathsEqual(context, sequence, .{ .start = cursor, .end = cursor + sequence_length })) continue;
        const bracket = cursor + sequence_length;
        if (context.tokens[bracket].tag != .l_bracket) continue;
        const candidate_index = Path{ .start = bracket + 1, .end = bracket + 1 + index_length };
        if (!pathsEqual(context, index, candidate_index) or context.tokens[candidate_index.end].tag != .r_bracket) continue;
        return true;
    }
    return false;
}

fn pathsEqual(context: RuleRun, left: Path, right: Path) bool {
    if (left.end - left.start != right.end - right.start) return false;
    for (context.tokens[left.start..left.end], context.tokens[right.start..right.end]) |left_token, right_token| {
        if (left_token.tag != right_token.tag or
            !std.mem.eql(
                u8,
                context.source[left_token.loc.start..left_token.loc.end],
                context.source[right_token.loc.start..right_token.loc.end],
            )) return false;
    }
    return true;
}

fn pathText(context: RuleRun, path: Path) []const u8 {
    return context.source[context.tokens[path.start].loc.start..context.tokens[path.end - 1].loc.end];
}

test "inclusive bounds immediately followed by indexing warn and offer a fix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn read(values: []u8, index: usize) u8 { std.debug.assert(index <= values.len); return values[index]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.inclusive_index_bound)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqualStrings("<", findings.items[0].fixes[0].edits[0].replacement);
    try std.testing.expect(!findings.items[0].fixes[0].fix_all);
}

test "slice bounds and already strict index guards remain valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn prefix(values: []u8, end: usize) []u8 { std.debug.assert(end <= values.len); return values[0..end]; }\n" ++
        "fn read(values: []u8, index: usize) u8 { std.debug.assert(index < values.len); return values[index]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.inclusive_index_bound)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "inclusive bound diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn read(values: []u8, index: usize) u8 {\n" ++
        "// zig-analyzer: disable-next-line inclusive-index-bound\n" ++
        "std.debug.assert(index <= values.len); return values[index]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.inclusive_index_bound)] = .information;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = configuration, .findings = &findings });
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
