//! Loops that read with `std.Io.Reader.takeDelimiterExclusive` without
//! consuming the delimiter. The call advances up to, not past, the delimiter,
//! so every later call in the loop returns an empty slice and a `while` loop
//! never reaches the end of the stream.

const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const Range = tokens_util.Range;

pub const rules = [_]types.Rule{.unconsumed_delimiter};

pub fn run(context: RuleRun) !void {
    const level = context.level(.unconsumed_delimiter);
    if (level == .off) return;
    const tokens = context.tokens;
    for (tokens, 0..) |token, method| {
        if (token.tag != .identifier or method < 2 or tokens[method - 1].tag != .period or
            tokens[method + 1].tag != .l_paren or !context.tokenIs(method, "takeDelimiterExclusive")) continue;
        const receiver = tokens_util.pathBefore(tokens, method - 1) orelse continue;
        if (receiver.start > 0 and tokens[receiver.start - 1].tag == .period) continue;
        const loop = enclosingLoop(context, method) orelse continue;
        if (readerTouched(context, receiver, loop)) continue;
        try context.emit(.{
            .rule = .unconsumed_delimiter,
            .level = level,
            .span = token.loc,
            .message = "takeDelimiterExclusive stops before the delimiter, so later iterations of this loop read an empty slice; consume the delimiter with toss(1) or use takeDelimiter",
        });
    }
}

/// The innermost loop around `index` in its function, from its keyword to
/// the end of its body.
fn enclosingLoop(context: RuleRun, index: usize) ?Range {
    const tokens = context.tokens;
    const function = context.scopes.enclosingFunctionBody(index) orelse return null;
    // A call in the condition: `while (reader.takeDelimiterExclusive('\n')) |line| {`.
    var head = tokens_util.statementStart(tokens, index);
    if (tokens[head].tag == .identifier and tokens[head + 1].tag == .colon) head += 2;
    if (tokens[head].tag == .keyword_inline) head += 1;
    if (tokens[head].tag == .keyword_while and tokens[head + 1].tag == .l_paren) {
        const condition_end = context.matchingToken(head + 1, .l_paren, .r_paren) orelse return null;
        if (index < condition_end) {
            const body = context.whileBodyOpening(condition_end) orelse return null;
            return .{ .start = head, .end = context.matchingToken(body, .l_brace, .r_brace) orelse return null };
        }
    }
    var brace = context.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening == function) return null;
        const keyword = context.loopKeyword(opening) orelse continue;
        return .{ .start = keyword, .end = context.matchingToken(opening, .l_brace, .r_brace) orelse return null };
    }
    return null;
}

/// Whether the loop does anything else with the reader at `receiver` that
/// might consume the delimiter: any other method call on it or on an object
/// holding it, passing it on, or assigning it.
fn readerTouched(context: RuleRun, receiver: Range, loop: Range) bool {
    const tokens = context.tokens;
    const receiver_segments = (receiver.end - receiver.start + 1) / 2;
    for (loop.start..loop.end) |index| {
        if (index == receiver.start or tokens[index].tag != .identifier or tokens[index - 1].tag == .period or
            !context.tokenIs(index, context.tokenText(receiver.start))) continue;
        const path = tokens_util.pathAfter(tokens, index) orelse continue;
        const segments = (path.end - path.start + 1) / 2;
        var common: usize = 0;
        while (common < @min(segments, receiver_segments) and
            context.tokenIs(path.start + 2 * common, context.tokenText(receiver.start + 2 * common))) common += 1;
        const call = tokens[path.end].tag == .l_paren;
        if (call and segments == receiver_segments + 1 and common == receiver_segments and
            context.tokenIs(path.end - 1, "takeDelimiterExclusive")) continue;
        if (common == @min(segments, receiver_segments)) return true;
        if (call and common + 1 >= segments) return true;
    }
    return false;
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.unconsumed_delimiter}, .warning));
}

test "a line loop that never consumes the delimiter reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn lines(reader: *std.Io.Reader) !usize {
        \\    var count: usize = 0;
        \\    while (true) {
        \\        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
        \\            error.EndOfStream => break,
        \\            else => |e| return e,
        \\        };
        \\        count += line.len;
        \\    }
        \\    return count;
        \\}
        \\fn condition(self: *Parser) usize {
        \\    var count: usize = 0;
        \\    while (self.input.takeDelimiterExclusive('\n')) |line| : (count += 1) {
        \\        self.total += line.len;
        \\    } else |_| {}
        \\    return count;
        \\}
        \\const Parser = struct { input: *std.Io.Reader, total: usize };
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "takeDelimiterExclusive", "takeDelimiterExclusive" });
}

test "loops that consume the delimiter or hand the reader on stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn tossed(reader: *std.Io.Reader) !void {
        \\    while (true) {
        \\        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
        \\            error.StreamTooLong => {
        \\                _ = try reader.discardDelimiterInclusive('\n');
        \\                continue;
        \\            },
        \\            else => break,
        \\        };
        \\        reader.toss(@min(1, reader.bufferedLen()));
        \\        _ = line;
        \\    }
        \\}
        \\fn helper(self: *Parser) !void {
        \\    while (true) {
        \\        _ = try self.input.takeDelimiterExclusive('\n');
        \\        try self.skipNewline();
        \\    }
        \\}
        \\fn once(reader: *std.Io.Reader) ![]u8 {
        \\    return reader.takeDelimiterExclusive('\n');
        \\}
        \\fn fresh(lines: []const []const u8) !void {
        \\    for (lines) |line| {
        \\        var reader: std.Io.Reader = .fixed(line);
        \\        _ = try reader.takeDelimiterExclusive(' ');
        \\    }
        \\}
        \\const Parser = struct {
        \\    input: *std.Io.Reader,
        \\    fn skipNewline(self: *Parser) !void {
        \\        self.input.toss(1);
        \\    }
        \\};
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}
