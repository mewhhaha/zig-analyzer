//! `if (x != null)` followed by `x.?` rewritten as an optional capture.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
const statementEnd = @import("../../syntax/tokens.zig").statementEnd;
const isAssignment = @import("../../syntax/tokens.zig").isAssignment;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Edit = types.Edit;
const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .prefer_optional_capture,
};

pub fn run(context: RuleRun) !void {
    try findOptionalCaptureIdioms(context);
}

fn findOptionalCaptureIdioms(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.prefer_optional_capture);
    if (level == .off) return;
    for (tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 6 >= tokens.len or tokens[if_index + 1].tag != .l_paren) continue;
        var optional_name: []const u8 = undefined;
        if (tokens[if_index + 2].tag == .identifier and !tokenIs(source, tokens[if_index + 2], "null") and
            tokens[if_index + 3].tag == .bang_equal and
            tokenIs(source, tokens[if_index + 4], "null") and
            tokens[if_index + 5].tag == .r_paren)
        {
            optional_name = tokenText(source, tokens[if_index + 2]);
        } else if (tokenIs(source, tokens[if_index + 2], "null") and
            tokens[if_index + 3].tag == .bang_equal and
            tokens[if_index + 4].tag == .identifier and !tokenIs(source, tokens[if_index + 4], "null") and
            tokens[if_index + 5].tag == .r_paren)
        {
            optional_name = tokenText(source, tokens[if_index + 4]);
        } else continue;
        const body_start = if_index + 6;
        const body_close = if (tokens[body_start].tag == .l_brace)
            matchingToken(tokens, body_start, .l_brace, .r_brace) orelse continue
        else
            statementEnd(tokens, body_start) orelse continue;
        var unwraps: std.ArrayList(std.zig.Token.Loc) = .empty;
        var unsafe = false;
        for (tokens[body_start..body_close], body_start..) |body_token, body_index| {
            if (body_token.tag != .identifier or !tokenIs(source, body_token, optional_name)) continue;
            // A preceding period means this is a same-named field of another value.
            if (body_index > 0 and tokens[body_index - 1].tag == .period) continue;
            if (body_index + 1 < body_close and isAssignment(tokens[body_index + 1].tag)) {
                unsafe = true;
                break;
            }
            if (body_index + 2 < body_close and tokens[body_index + 1].tag == .period and
                tokenIs(source, tokens[body_index + 2], "?"))
            {
                if (body_index + 3 < body_close and isAssignment(tokens[body_index + 3].tag)) {
                    unsafe = true;
                    break;
                }
                try unwraps.append(context.allocator, .{ .start = body_token.loc.start, .end = tokens[body_index + 2].loc.end });
            }
        }
        if (unsafe or unwraps.items.len == 0) continue;
        const capture_name = try collisionFreeCaptureName(context.allocator, source, optional_name);
        errdefer context.allocator.free(capture_name);
        const edits = try context.allocator.alloc(Edit, unwraps.items.len + 1);
        edits[0] = .{
            .span = .{ .start = tokens[if_index + 2].loc.start, .end = tokens[if_index + 5].loc.end },
            .replacement = try context.allocator.print("{s}) |{s}|", .{ optional_name, capture_name }),
        };
        for (unwraps.items, edits[1..]) |span, *edit| edit.* = .{ .span = span, .replacement = capture_name };
        const fixes = try context.allocator.alloc(Fix, 1);
        fixes[0] = .{ .title = "Use an optional capture", .kind = .refactor_rewrite, .edits = edits };
        try context.emit(.{
            .rule = .prefer_optional_capture,
            .level = level,
            .span = tokens[if_index + 3].loc,
            .message = try context.allocator.print(
                "optional '{s}' is checked and then force-unwrapped; capture the payload in the if condition",
                .{optional_name},
            ),
            .fixes = fixes,
        });
    }
}

fn collisionFreeCaptureName(allocator: std.mem.Allocator, source: []const u8, optional_name: []const u8) ![]const u8 {
    if (!identifierAppears(source, "value")) return try allocator.dupe(u8, "value");
    const candidate = try allocator.print("{s}_value", .{optional_name});
    if (!identifierAppears(source, candidate)) return candidate;
    allocator.free(candidate);
    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const numbered = try allocator.print("{s}_value_{d}", .{ optional_name, suffix });
        if (!identifierAppears(source, numbered)) return numbered;
        allocator.free(numbered);
    }
}

fn identifierAppears(source: []const u8, name: []const u8) bool {
    var start: usize = 0;
    while (std.mem.findPos(u8, source, start, name)) |offset| {
        const before_is_identifier = offset > 0 and isIdentifierCharacter(source[offset - 1]);
        const end = offset + name.len;
        const after_is_identifier = end < source.len and isIdentifierCharacter(source[end]);
        if (!before_is_identifier and !after_is_identifier) return true;
        start = end;
    }
    return false;
}

fn isIdentifierCharacter(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '_';
}

test "optional capture skips foreign fields and assigned unwraps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn read(y: ?u32, box: anytype) u32 {\n" ++
        "    if (y != null) { return y.? + box.y.?; }\n" ++
        "    return 0;\n" ++
        "}\n" ++
        "fn bump(count: ?u32) void {\n" ++
        "    var y = count;\n" ++
        "    if (y != null) { y.? += 1; }\n" ++
        "    _ = y;\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_optional_capture}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var capture_count: usize = 0;
    for (found) |finding| if (finding.rule == .prefer_optional_capture) {
        capture_count += 1;
        try std.testing.expectEqual(@as(usize, 2), finding.fixes[0].edits.len);
        try std.testing.expectEqual(std.mem.find(u8, source, "y.? + box").?, finding.fixes[0].edits[1].span.start);
    };
    try std.testing.expectEqual(@as(usize, 1), capture_count);
}

test "optional capture supports null != opt operand order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn read(y: ?u32) u32 {\n" ++
        "    if (null != y) { return y.?; }\n" ++
        "    return 0;\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_optional_capture}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var capture_count: usize = 0;
    for (found) |finding| if (finding.rule == .prefer_optional_capture) {
        capture_count += 1;
        try std.testing.expectEqualStrings("y) |value|", finding.fixes[0].edits[0].replacement);
        try std.testing.expectEqualStrings("value", finding.fixes[0].edits[1].replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), capture_count);
}
