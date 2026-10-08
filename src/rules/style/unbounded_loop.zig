//! `while` loops whose condition and body state no iteration bound or exhaustion.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;

pub const rules = [_]types.Rule{.unbounded_loop};

pub fn run(context: RuleRun) !void {
    const level = context.level(.unbounded_loop);
    if (level == .off) return;
    for (context.tokens, 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 2 >= context.tokens.len or context.tokens[while_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        const condition = context.source[context.tokens[while_index + 2].loc.start..context.tokens[condition_end - 1].loc.end];
        const body_open = context.whileBodyOpening(condition_end) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (std.mem.findAny(u8, condition, "<>") != null or
            conditionStatesExhaustion(context, while_index + 2, condition_end, body_open, body_end) or
            optionalCaptureStatesExhaustion(context, while_index + 2, condition_end, body_open, body_end) or
            equalityConditionHasUpdate(context, while_index + 2, condition_end, body_open, body_end) or
            callConditionHasUpdate(context, while_index + 2, condition_end, body_open, body_end) or
            bodyHasExhaustionExit(context, body_open + 1, body_end) or
            bodyHasBoundAssertion(context, while_index + 2, condition_end, body_open + 1, body_end) or
            bodyHasExhaustionPredicate(context, body_open + 1, body_end) or
            bodyDrainsCollection(context, body_open + 1, body_end) or
            bodyRetriesInterruptedCall(context, body_open + 1, body_end)) continue;
        if (eventLoopHasBlockingDispatch(context, body_open + 1, body_end)) continue;
        if (bodyHasCounterGuard(context, body_open + 1, body_end) or
            bodyHasDerivedCounterGuard(context, body_open + 1, body_end)) continue;
        try context.emit(.{
            .rule = .unbounded_loop,
            .level = level,
            .span = token.loc,
            .message = "loop has no statically visible iteration bound; state a maximum and handle exhaustion explicitly",
        });
    }
}

fn bodyDrainsCollection(context: RuleRun, start: usize, end: usize) bool {
    if (!rangeCanExitLoop(context.tokens, start, end)) return false;
    var continues = false;
    for (context.tokens[start..end]) |token| if (token.tag == .keyword_continue) {
        continues = true;
        break;
    };
    if (!continues) return false;
    return bodyCalls(context, start, end, "swapRemove") or bodyCalls(context, start, end, "orderedRemove");
}

fn bodyHasBoundAssertion(context: RuleRun, condition_start: usize, condition_end: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren or
            (!context.tokenIs(index, "assert") and !context.tokenIs(index, "expect"))) continue;
        const call_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end > end) continue;
        if (hasOrderingComparison(context.tokens[index + 2 .. call_end])) return true;
        if (hasEqualityComparison(context.tokens[index + 2 .. call_end]) and
            rangesShareConditionVariable(context, condition_start, condition_end, index + 2, call_end)) return true;
    }
    return false;
}

fn bodyHasCounterGuard(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_if or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end >= end or !hasBoundComparison(context.tokens[index + 2 .. condition_end])) continue;
        var branch_start = condition_end + 1;
        if (context.tokens[branch_start].tag == .pipe) {
            branch_start = nextTagBefore(context.tokens, branch_start + 1, .pipe, .semicolon) orelse continue;
            branch_start += 1;
        }
        const branch_end = if (context.tokens[branch_start].tag == .l_brace)
            context.matchingToken(branch_start, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(branch_start) orelse continue;
        if (rangeCanExitLoop(context.tokens, branch_start, branch_end)) return true;
    }
    return false;
}

fn bodyHasDerivedCounterGuard(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, declaration| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration + 3 >= end or
            context.tokens[declaration + 1].tag != .identifier or context.tokens[declaration + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration) orelse continue;
        if (declaration_end >= end or !hasBoundComparison(context.tokens[declaration + 3 .. declaration_end])) continue;
        const name = context.tokenText(declaration + 1);
        for (context.tokens[declaration_end + 1 .. end], declaration_end + 1..) |candidate, if_index| {
            if (candidate.tag != .keyword_if or if_index + 3 >= end or context.tokens[if_index + 1].tag != .l_paren or
                !context.tokenIs(if_index + 2, name) or context.tokens[if_index + 3].tag != .r_paren) continue;
            const branch_start = if_index + 4;
            if (branch_start >= end) continue;
            const branch_end = if (context.tokens[branch_start].tag == .l_brace)
                context.matchingToken(branch_start, .l_brace, .r_brace) orelse continue
            else
                context.statementEnd(branch_start) orelse continue;
            if (branch_end <= end and rangeCanExitLoop(context.tokens, branch_start, branch_end)) return true;
        }
    }
    return false;
}

fn bodyHasExhaustionExit(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_orelse) continue;
        var branch_start = index + 1;
        if (branch_start >= end) continue;
        if (context.tokens[branch_start].tag == .pipe) {
            branch_start = nextTagBefore(context.tokens, branch_start + 1, .pipe, .semicolon) orelse continue;
            branch_start += 1;
        }
        if (branch_start >= end) continue;
        if (context.tokens[branch_start].tag == .keyword_break or context.tokens[branch_start].tag == .keyword_return) return true;
        const branch_end = if (context.tokens[branch_start].tag == .l_brace)
            context.matchingToken(branch_start, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(branch_start) orelse continue;
        if (branch_end <= end and rangeCanExitLoop(context.tokens, branch_start + 1, branch_end)) return true;
    }
    return false;
}

fn bodyHasExhaustionPredicate(context: RuleRun, start: usize, end: usize) bool {
    if (!rangeCanExitLoop(context.tokens, start, end)) return false;
    return bodyCalls(context, start, end, "eof") or
        bodyCalls(context, start, end, "takeDelimiterExclusive") or
        bodyCalls(context, start, end, "streamDelimiterEnding");
}

fn bodyRetriesInterruptedCall(context: RuleRun, start: usize, end: usize) bool {
    if (!bodyCalls(context, start, end, "errno")) return false;
    var saw_interrupted = false;
    var saw_retry = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "INTR")) saw_interrupted = true;
        if (token.tag == .keyword_continue) saw_retry = true;
    }
    return saw_interrupted and saw_retry;
}

fn callConditionHasUpdate(
    context: RuleRun,
    condition_start: usize,
    condition_end: usize,
    body_open: usize,
    body_end: usize,
) bool {
    var has_call = false;
    for (context.tokens[condition_start..condition_end], condition_start..) |token, index| {
        if ((token.tag == .identifier or token.tag == .builtin) and index + 1 < condition_end and
            context.tokens[index + 1].tag == .l_paren)
        {
            has_call = true;
            break;
        }
    }
    return has_call and conditionVariableUpdated(context, condition_start, condition_end, body_open + 1, body_end);
}

fn conditionStatesExhaustion(context: RuleRun, start: usize, end: usize, body_open: usize, body_end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const name = context.tokenText(index);
        if (std.mem.eql(u8, name, "next") or std.mem.endsWith(u8, name, "_next") or
            consumingNextCall(name) or std.mem.eql(u8, name, "iteration")) return true;
        if (std.mem.eql(u8, name, "isClosed") or std.mem.eql(u8, name, "isRunning") or
            std.mem.eql(u8, name, "shouldStop") or std.mem.eql(u8, name, "isShutdown")) return true;
        if (std.mem.eql(u8, name, "eof") and bodyCalls(context, body_open + 1, body_end, "advance")) return true;
    }
    return false;
}

fn equalityConditionHasUpdate(
    context: RuleRun,
    condition_start: usize,
    condition_end: usize,
    body_open: usize,
    body_end: usize,
) bool {
    var has_equality = false;
    for (context.tokens[condition_start..condition_end]) |token| {
        if (token.tag == .equal_equal or token.tag == .bang_equal) {
            has_equality = true;
            break;
        }
    }
    if (!has_equality) return false;
    if (condition_end + 2 < body_open and context.tokens[condition_end + 1].tag == .colon and
        conditionVariableUpdated(context, condition_start, condition_end, condition_end + 2, body_open)) return true;
    return conditionVariableUpdated(context, condition_start, condition_end, body_open + 1, body_end);
}

fn eventLoopHasBlockingDispatch(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        if (context.tokenIs(index, "wait") or context.tokenIs(index, "run") or context.tokenIs(index, "dispatch") or
            context.tokenIs(index, "accept") or context.tokenIs(index, "pollEvent")) return true;
    }
    return false;
}

fn optionalCaptureStatesExhaustion(
    context: RuleRun,
    condition_start: usize,
    condition_end: usize,
    body_open: usize,
    body_end: usize,
) bool {
    if (condition_end + 2 >= body_open or context.tokens[condition_end + 1].tag != .pipe) return false;
    const capture_end = nextTagBefore(context.tokens, condition_end + 2, .pipe, .semicolon) orelse return false;
    if (capture_end >= body_open) return false;

    for (context.tokens[condition_start..condition_end], condition_start..) |token, index| {
        if ((token.tag == .identifier or token.tag == .builtin) and index + 1 < condition_end and
            context.tokens[index + 1].tag == .l_paren) return true;
    }

    return conditionVariableUpdated(context, condition_start, condition_end, capture_end + 1, body_open) or
        conditionVariableUpdated(context, condition_start, condition_end, body_open + 1, body_end);
}

fn bodyCalls(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index + 1 < end and
            context.tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

fn rangeCanExitLoop(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| if (token.tag == .keyword_break or token.tag == .keyword_return) return true;
    return false;
}

fn hasEqualityComparison(tokens: []const std.zig.Token) bool {
    for (tokens) |token| if (token.tag == .equal_equal or token.tag == .bang_equal) return true;
    return false;
}

fn hasOrderingComparison(tokens: []const std.zig.Token) bool {
    for (tokens) |token| switch (token.tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        => return true,
        else => {},
    };
    return false;
}

fn rangesShareConditionVariable(context: RuleRun, left_start: usize, left_end: usize, right_start: usize, right_end: usize) bool {
    for (context.tokens[left_start..left_end], left_start..) |left, left_index| {
        if (left.tag != .identifier or context.tokenIs(left_index, "true") or context.tokenIs(left_index, "false")) continue;
        for (context.tokens[right_start..right_end], right_start..) |right, right_index| {
            if (right.tag == .identifier and context.tokenIs(right_index, context.tokenText(left_index))) return true;
        }
    }
    return false;
}

fn hasBoundComparison(tokens: []const std.zig.Token) bool {
    for (tokens) |token| switch (token.tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .equal_equal,
        => return true,
        else => {},
    };
    return false;
}

fn conditionVariableUpdated(context: RuleRun, condition_start: usize, condition_end: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, operator_index| {
        if (!isAssignmentOperator(token.tag) or operator_index == start or context.tokens[operator_index - 1].tag != .identifier) continue;
        const assigned_path_start = context.pathStartBefore(operator_index) orelse continue;
        if (dottedPathOccurs(context, assigned_path_start, operator_index, condition_start, condition_end)) return true;
        if (assigned_path_start != operator_index - 1) continue;
        for (context.tokens[condition_start..condition_end], condition_start..) |condition_token, condition_index| {
            if (condition_token.tag == .identifier and
                (condition_index == condition_start or context.tokens[condition_index - 1].tag != .period) and
                context.tokenIs(condition_index, context.tokenText(operator_index - 1))) return true;
        }
    }
    return false;
}

fn consumingNextCall(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, "Next")) return false;
    const verbs = [_][]const u8{ "consume", "parse", "poll", "process", "read", "remove", "run", "take" };
    for (verbs) |verb| if (std.mem.startsWith(u8, name, verb)) return true;
    return false;
}

fn dottedPathOccurs(context: RuleRun, path_start: usize, path_end: usize, start: usize, end: usize) bool {
    const path_length = path_end - path_start;
    if (path_length == 0 or path_length > end - start) return false;
    var candidate = start;
    while (candidate + path_length <= end) : (candidate += 1) {
        if (context.dottedPathsEqual(path_start, path_end, candidate, candidate + path_length)) return true;
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
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_right_equal,
        .ampersand_equal,
        .caret_equal,
        .pipe_equal,
        => true,
        else => false,
    };
}

test "a queue pop loop states exhaustion through its optional capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn drain(mailbox: *Mailbox) void {\n" ++
        "while (mailbox.pop()) |message| {\n" ++
        "consume(message);\n" ++
        "}\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "optional-producing calls state exhaustion through their captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn decode(iterator: *Iterator) !void {\n" ++
        "while (iterator.nextCodepoint()) |codepoint| consume(codepoint);\n" ++
        "while (try parseOneItem(iterator)) |value| consume(value);\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "boolean next calls and orelse exits state iterator exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn visit(iterator: *Iterator) !void {\n" ++
        "while (iterator.next()) { consume(iterator.value()); }\n" ++
        "while (placement_iterator_next(iterator)) { consume(iterator.value()); }\n" ++
        "while (true) { const value = (try iterator.nextValue()) orelse break; consume(value); }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "consuming camel case next calls state exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn drain(scheduler: *Scheduler, cursor: *Cursor) void {\n" ++
        "while (scheduler.runNext()) {}\n" ++
        "while (cursor.hasNext()) {}\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "optional traversal must visibly advance its condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn visit(first: ?*Node, state: *State) void {\n" ++
        "var node = first;\n" ++
        "while (node) |value| : (node = value.next) { consume(value); }\n" ++
        "while (state.row) |row| { state.row = row.next; }\n" ++
        "while (first) |value| { consume(value); }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "equality loop updates state used by its condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn scan(bytes: []const u8, end: usize) void {\n" ++
        "var offset: usize = 0;\n" ++
        "while (offset != end) : (offset += 1) { consume(bytes[offset]); }\n" ++
        "while (bytes.len == end) { consume(bytes); }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "body guards and blocking waits state loop termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn consumeAll(input: []const u8, pipeline: *Pipeline) void {\n" ++
        "var index: usize = 0;\n" ++
        "while (true) { if (index >= input.len) break; consume(input[index]); index += 1; }\n" ++
        "while (pipeline.count == 0) { pipeline.ready.wait(&pipeline.mutex); }\n" ++
        "while (glib.MainContext.iteration(null, 0) != 0) {}\n" ++
        "while (!pipeline.done) { pipeline.loop.pollEvent(); }\n" ++
        "while (!pipeline.isClosed()) { pipeline.handleOne(); }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "input exhaustion and compound sentinel updates state loop termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(parser: *Parser, state: *State, input: []const u8) !void {\n" ++
        "while (!parser.eof()) { parser.advance(); }\n" ++
        "while (state.current != state.active and state.current != state.last) { state.current = state.current.next.?; }\n" ++
        "while (state.current.isUsed()) { state.current = state.current.next.?; }\n" ++
        "var index: usize = 0;\n" ++
        "while (true) { try testing.expect(index < input.len); index += 1; if (input[index] == 0) return; }\n" ++
        "while (true) { parser.advance(); if (parser.eof()) break; }\n" ++
        "drain: while (true) { if (state.expired()) { _ = state.entries.swapRemove(0); continue :drain; } break :drain; }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "unbraced while expressions do not borrow nested braces as their body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(reader: *Reader) void {\n" ++
        "while (true) switch (reader.readByte() catch ',') { ',' => break, else => {}, };\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an unrelated equality assertion does not bound a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn generate(value: usize) void {\n" ++
        "while (true) { assert(value == value); consume(value); }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "derived bounds readers and interrupted calls state loop termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(reader: *Reader, duration: usize) !void {\n" ++
        "while (true) { const finished = elapsed() >= duration; if (finished) return; step(); }\n" ++
        "while (reader.seek != reader.end) { _ = reader.streamDelimiterEnding('\\n') catch return; if (reader.empty()) break; }\n" ++
        "while (true) { switch (posix.errno(retry())) { .SUCCESS => break, .INTR => continue, else => return error.Failed, } }\n" ++
        "}\n";
    const configuration = support.only(&.{.unbounded_loop}, .information);

    const found = try support.findings(arena.allocator(), run, source, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a loop on an unchanged flag reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn spin(flag: bool) void { while (flag) {} }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.unbounded_loop}, .information));
    try support.expectRules(found, &.{.unbounded_loop});
}
