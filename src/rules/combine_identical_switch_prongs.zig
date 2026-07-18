const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

const Prong = struct {
    body: []const u8,
    body_span: std.zig.Token.Loc,
    has_capture: bool,
    has_comment: bool,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.combine_identical_switch_prongs);
    if (level == .off) return;

    for (context.tokens, 0..) |token, switch_index| {
        if (token.tag != .keyword_switch or switch_index + 2 >= context.tokens.len or
            context.tokens[switch_index + 1].tag != .l_paren) continue;
        const operand_end = context.matchingToken(switch_index + 1, .l_paren, .r_paren) orelse continue;
        const opening = operand_end + 1;
        if (opening >= context.tokens.len or context.tokens[opening].tag != .l_brace) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;

        var previous: ?Prong = null;
        var cursor = opening + 1;
        while (cursor < closing) {
            const arrow = topLevelArrow(context.tokens, cursor, closing) orelse break;
            const body_start = arrow + 1;
            const body_end = prongBodyEnd(context, body_start, closing) orelse break;
            const body = std.mem.trim(
                u8,
                context.source[context.tokens[body_start].loc.start..context.tokens[body_end].loc.end],
                " \t\r\n",
            );
            const current: Prong = .{
                .body = body,
                .body_span = .{ .start = context.tokens[body_start].loc.start, .end = context.tokens[body_end].loc.end },
                .has_capture = body_start < closing and context.tokens[body_start].tag == .pipe,
                .has_comment = containsComment(
                    context.source[context.tokens[cursor].loc.start..context.tokens[body_end].loc.end],
                ),
            };
            if (previous) |prior| {
                if (!prior.has_capture and !current.has_capture and std.mem.eql(u8, prior.body, current.body) and
                    !prior.has_comment and !current.has_comment)
                {
                    try context.emit(.{
                        .rule = .combine_identical_switch_prongs,
                        .level = level,
                        .span = current.body_span,
                        .message = "adjacent switch prongs have identical uncaptured bodies; combine their case values",
                    });
                    previous = null;
                } else {
                    previous = current;
                }
            } else {
                previous = current;
            }
            cursor = body_end + 1;
            if (cursor < closing and context.tokens[cursor].tag == .comma) cursor += 1;
        }
    }
}

fn topLevelArrow(tokens: []const std.zig.Token, start: usize, end: usize) ?usize {
    var depth: usize = 0;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .equal_angle_bracket_right => if (depth == 0) return index,
        else => {},
    };
    return null;
}

fn prongBodyEnd(context: RuleRun, start: usize, switch_end: usize) ?usize {
    if (start >= switch_end) return null;
    if (context.tokens[start].tag == .pipe) return null;
    if (context.tokens[start].tag == .l_brace) return context.matchingToken(start, .l_brace, .r_brace);
    var depth: usize = 0;
    for (context.tokens[start..switch_end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) return if (index == start) null else index - 1,
        else => {},
    };
    return switch_end - 1;
}

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

test "adjacent identical switch bodies prefer one combined prong" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "switch (mode) {\n" ++
        "    .fast => run(),\n" ++
        "    .turbo => run(),\n" ++
        "    .safe => recover(),\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "captured and different switch bodies stay separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "switch (value) { .left => |payload| use(payload), .right => |payload| use(payload) }\n" ++
        "switch (mode) { .fast => run(), .safe => recover() }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "identical switch prong preference respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line combine-identical-switch-prongs\n" ++
        "switch (mode) { .fast => run(), .turbo => run() }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "nested switches report their identical prongs once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "switch (outer) {\n" ++
        "    .active => switch (inner) {\n" ++
        "        .first => run(),\n" ++
        "        .second => run(),\n" ++
        "    },\n" ++
        "    .inactive => stop(),\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.combine_identical_switch_prongs)] = .information;
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
