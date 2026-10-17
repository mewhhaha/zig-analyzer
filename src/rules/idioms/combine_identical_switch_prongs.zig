const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const containsComment = @import("../../syntax/tokens.zig").containsComment;

const Prong = struct {
    body: []const u8,
    body_span: std.zig.Token.Loc,
    /// The case items, from the first token to the last before `=>`.
    items: std.zig.Token.Loc,
    has_capture: bool,
    /// A comment above the prong, inside it, or after it on its last line.
    has_comment: bool,
    is_else: bool,
    /// Items that can be joined into another prong's list as written: one
    /// line, no trailing comma, no `inline`.
    mergeable: bool,
    /// A row of a table that maps a C status enum (errno, NTSTATUS, Win32
    /// error codes) to outcomes: every item is a SCREAMING_CASE enum literal
    /// and the body is `unreachable`, an error value or a `return`.
    status_row: bool,
};

/// Adjacent prongs with one body, reported once at the second prong and
/// merged into the first prong's item list.
const Run = struct {
    report: std.zig.Token.Loc,
    first: Prong,
    last: Prong,
    mergeable: bool,
    /// The items of every prong after the first, each preceded by ", ".
    joined: std.ArrayList(u8),
};

pub const rules = [_]types.Rule{
    .combine_identical_switch_prongs,
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
        var current_run: ?Run = null;
        var cursor = opening + 1;
        while (cursor < closing) {
            const arrow = topLevelArrow(context.tokens, cursor, closing) orelse break;
            const body_start = arrow + 1;
            const body_end = prongBodyEnd(context, body_start, closing) orelse break;
            const current = prong(context, cursor, arrow, body_end, closing);
            const combinable = if (previous) |prior|
                !prior.has_capture and !current.has_capture and !prior.is_else and !current.is_else and
                    std.mem.eql(u8, prior.body, current.body) and
                    !prior.has_comment and !current.has_comment and
                    // Each status keeps its own row so the table can be read
                    // against the platform's documentation.
                    !(prior.status_row and current.status_row)
            else
                false;
            if (combinable) {
                if (current_run) |*joining| {
                    joining.last = current;
                    joining.mergeable = joining.mergeable and current.mergeable;
                } else current_run = .{
                    .report = current.body_span,
                    .first = previous.?,
                    .last = current,
                    .mergeable = previous.?.mergeable and current.mergeable,
                    .joined = .empty,
                };
                try current_run.?.joined.print(context.allocator, ", {s}", .{context.source[current.items.start..current.items.end]});
            } else if (current_run) |finished| {
                try report(context, level, finished);
                current_run = null;
            }
            previous = current;
            cursor = body_end + 1;
            if (cursor < closing and context.tokens[cursor].tag == .comma) cursor += 1;
        }
        if (current_run) |finished| try report(context, level, finished);
    }
}

fn prong(context: RuleRun, cursor: usize, arrow: usize, body_end: usize, closing: usize) Prong {
    const tokens = context.tokens;
    const source = context.source;
    const body_start = arrow + 1;
    const items: std.zig.Token.Loc = .{ .start = tokens[cursor].loc.start, .end = tokens[arrow - 1].loc.end };
    // From the line after the previous prong, whose trailing comment is its
    // own, to the end of this prong's last line.
    const separator_end = tokens[cursor - 1].loc.end;
    const comment_start = if (std.mem.findScalar(u8, source[separator_end..items.start], '\n')) |newline|
        separator_end + newline
    else
        separator_end;
    const line_end = std.mem.findScalarPos(u8, source, tokens[body_end].loc.end, '\n') orelse source.len;
    return .{
        .body = std.mem.trim(u8, source[tokens[body_start].loc.start..tokens[body_end].loc.end], " \t\r\n"),
        .body_span = .{ .start = tokens[body_start].loc.start, .end = tokens[body_end].loc.end },
        .items = items,
        .has_capture = body_start < closing and tokens[body_start].tag == .pipe,
        .has_comment = containsComment(source[comment_start..line_end]),
        .is_else = isElseCase(tokens, cursor, arrow),
        .mergeable = tokens[cursor].tag != .keyword_inline and tokens[arrow - 1].tag != .comma and
            std.mem.findScalar(u8, source[items.start..items.end], '\n') == null,
        .status_row = statusItems(context, cursor, arrow) and switch (tokens[body_start].tag) {
            .keyword_return => true,
            .keyword_unreachable => body_end == body_start,
            .keyword_error => body_end == body_start + 2,
            else => false,
        },
    };
}

fn report(context: RuleRun, level: types.Level, finished: Run) !void {
    const fixes: []const types.Fix = if (finished.mergeable) try context.singleFix(.{
        .title = "Combine the identical prongs",
        .span = .{ .start = finished.first.items.end, .end = finished.last.items.end },
        .replacement = finished.joined.items,
        .preferred = true,
    }) else &.{};
    try context.emit(.{
        .rule = .combine_identical_switch_prongs,
        .level = level,
        .span = finished.report,
        .message = "adjacent switch prongs have identical uncaptured bodies; combine their case values",
        .fixes = fixes,
    });
}

/// Whether every case item in `[start, arrow)` is a SCREAMING_CASE enum
/// literal such as `.NOENT`.
fn statusItems(context: RuleRun, start: usize, arrow: usize) bool {
    var cursor = start;
    while (cursor < arrow) : (cursor += 1) {
        if (context.tokens[cursor].tag != .period or cursor + 1 >= arrow or
            context.tokens[cursor + 1].tag != .identifier) return false;
        var upper = false;
        for (context.tokenText(cursor + 1)) |character| {
            if (std.ascii.isLower(character)) return false;
            upper = upper or std.ascii.isUpper(character);
        }
        if (!upper) return false;
        cursor += 2;
        if (cursor < arrow and context.tokens[cursor].tag != .comma) return false;
    }
    return true;
}

fn isElseCase(tokens: []const std.zig.Token, start: usize, arrow: usize) bool {
    for (tokens[start..arrow]) |token| {
        if (token.tag == .keyword_else) return true;
    }
    return false;
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
    var body_expr = start;
    if (context.tokens[body_expr].tag == .pipe) {
        body_expr += 1;
        while (body_expr < switch_end and context.tokens[body_expr].tag != .pipe) : (body_expr += 1) {}
        if (body_expr >= switch_end) return null;
        body_expr += 1;
    }
    if (body_expr >= switch_end) return null;
    if (context.tokens[body_expr].tag == .l_brace) return context.matchingToken(body_expr, .l_brace, .r_brace);
    var depth: usize = 0;
    for (context.tokens[body_expr..switch_end], body_expr..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) return if (index == body_expr) null else index - 1,
        else => {},
    };
    return switch_end - 1;
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
    try std.testing.expectEqualStrings(
        "switch (mode) {\n" ++
            "    .fast, .turbo => run(),\n" ++
            "    .safe => recover(),\n" ++
            "}",
        try applied(arena.allocator(), source, findings[0].fixes[0]),
    );
    try std.testing.expect(!findings[0].fixes[0].fix_all);
}

test "captured and different switch bodies stay separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "switch (value) { .left => |payload| use(payload), .right => |payload| use(payload) }\n" ++
        "switch (mode) { .fast => run(), else => run() }\n" ++
        "switch (mode) { .fast => run(), .safe => recover() }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "captured prong does not abort scanning subsequent identical prongs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "switch (value) {\n" ++
        "    .left => |payload| use(payload),\n" ++
        "    .fast => run(),\n" ++
        "    .turbo => run(),\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "a run of identical prongs is reported once and merged whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "switch (op) {\n" ++
        "    .load => 1,\n" ++
        "    .store => unreachable,\n" ++
        "    .splat => unreachable,\n" ++
        "    .add, .sub => unreachable,\n" ++
        "    .mul => 2,\n" ++
        "    .div => 2,\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqual(std.mem.find(u8, source, "unreachable,\n    .add").?, findings[0].span.start);
    try std.testing.expectEqualStrings(
        "switch (op) {\n" ++
            "    .load => 1,\n" ++
            "    .store, .splat, .add, .sub => unreachable,\n" ++
            "    .mul => 2,\n" ++
            "    .div => 2,\n" ++
            "}",
        try applied(arena.allocator(), source, findings[0].fixes[0]),
    );
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

test "a comment above or after a prong keeps the prongs apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "switch (os) {\n" ++
        "    .linux => 255,\n" ++
        "    // WASI hosts may be Windows.\n" ++
        "    .wasi => 255,\n" ++
        "}\n" ++
        "switch (result) {\n" ++
        "    0 => {}, // ok\n" ++
        "    1 => {},\n" ++
        "}\n" ++
        "switch (state) {\n" ++
        "    .none => unreachable, // never parked\n" ++
        "    .parked => unreachable,\n" ++
        "    .blocked => unreachable,\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    // Only the last pair: a trailing comment belongs to its own prong.
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(std.mem.find(u8, source, "unreachable,\n    .blocked").? + "unreachable,\n    .blocked => ".len, findings[0].span.start);
}

test "status tables keep one row per status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "switch (errno(rc)) {\n" ++
        "    .SUCCESS => {},\n" ++
        "    .BADF => unreachable,\n" ++
        "    .FAULT => unreachable,\n" ++
        "    .ACCES => return error.AccessDenied,\n" ++
        "    .PERM => return error.AccessDenied,\n" ++
        "    .NOENT => error.FileNotFound,\n" ++
        "    .NOTDIR => error.FileNotFound,\n" ++
        "    .AGAIN => retry(),\n" ++
        "    .INTR => retry(),\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(std.mem.find(u8, source, "retry(),\n}").?, findings[0].span.start);
}

test "inline and multi-line prongs are reported without a merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "switch (shape) {\n" ++
        "    inline .square => run(),\n" ++
        "    inline .circle => run(),\n" ++
        "}\n" ++
        "switch (shape) {\n" ++
        "    .square,\n" ++
        "    .triangle,\n" ++
        "    => run(),\n" ++
        "    .circle => run(),\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
}

fn applied(allocator: std.mem.Allocator, source: []const u8, fix: types.Fix) ![]const u8 {
    const edit = fix.edits[0];
    return std.mem.concat(allocator, u8, &.{ source[0..edit.span.start], edit.replacement, source[edit.span.end..] });
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.combine_identical_switch_prongs}, .information));
}
