const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findLongFunctions(context);
    try findUncheckedIndexing(context);
    try findUnboundedLoops(context);
    try findLongLines(context);
    try findParameterOrder(context);
    try findTaskMarkers(context);
    try findAssertionFreeTests(context);
}

fn findLongFunctions(context: RuleRun) !void {
    const level = context.level(.function_length);
    if (level == .off) return;
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or insideKeywordBlock(context, fn_index, .keyword_test) or
            insideKeywordBlock(context, fn_index, .keyword_comptime)) continue;
        const body_open = nextTagBefore(context.tokens, fn_index + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        const lines = lineNumber(context.source, context.tokens[body_end].loc.end) - lineNumber(context.source, token.loc.start) + 1;
        if (lines <= context.configuration.function_length_limit) continue;
        const name = if (fn_index + 1 < context.tokens.len and context.tokens[fn_index + 1].tag == .identifier) context.tokenText(fn_index + 1) else "function";
        try context.emit(.{
            .rule = .function_length,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(context.allocator, "function '{s}' spans {d} lines, exceeding the configured limit of {d}", .{ name, lines, context.configuration.function_length_limit }),
        });
    }
}

fn findUncheckedIndexing(context: RuleRun) !void {
    const level = context.level(.assertion_free_branching);
    if (level == .off) return;
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn) continue;
        const body_open = nextTagBefore(context.tokens, fn_index + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (lineNumber(context.source, context.tokens[body_end].loc.end) - lineNumber(context.source, token.loc.start) < 8) continue;
        if (hasInvariantCheck(context, body_open + 1, body_end)) continue;
        const bracket = computedBracket(context, body_open + 1, body_end) orelse continue;
        try context.emit(.{
            .rule = .assertion_free_branching,
            .level = level,
            .span = context.tokens[bracket].loc,
            .message = "computed indexing has no visible assertion, unreachable arm, or early-return validation stating its bounds",
        });
    }
}

fn findUnboundedLoops(context: RuleRun) !void {
    const level = context.level(.unbounded_loop);
    if (level == .off) return;
    for (context.tokens, 0..) |token, while_index| {
        if (token.tag != .keyword_while or while_index + 2 >= context.tokens.len or context.tokens[while_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(while_index + 1, .l_paren, .r_paren) orelse continue;
        const condition = context.source[context.tokens[while_index + 2].loc.start..context.tokens[condition_end - 1].loc.end];
        if (std.mem.indexOfAny(u8, condition, "<>") != null or std.mem.indexOf(u8, condition, ".next(") != null) continue;
        const body_open = nextTagBefore(context.tokens, condition_end + 1, .l_brace, .semicolon) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (conditionIsTrue(context, while_index + 2, condition_end) and eventLoopHasBlockingDispatch(context, body_open + 1, body_end)) continue;
        if (bodyHasCounterGuard(context, body_open + 1, body_end)) continue;
        try context.emit(.{
            .rule = .unbounded_loop,
            .level = level,
            .span = token.loc,
            .message = "loop has no statically visible iteration bound; state a maximum and handle exhaustion explicitly",
        });
    }
}

fn findLongLines(context: RuleRun) !void {
    const level = context.level(.line_length);
    if (level == .off) return;
    var start: usize = 0;
    while (start < context.source.len) {
        const relative_end = std.mem.indexOfScalar(u8, context.source[start..], '\n') orelse context.source.len - start;
        const end = start + relative_end;
        const line = context.source[start..end];
        const columns = displayColumns(line);
        if (columns > context.configuration.line_length_limit and
            (!context.configuration.line_length_allow_unsplittable or !singleUnsplittableToken(line)))
        {
            try context.emit(.{
                .rule = .line_length,
                .level = level,
                .span = .{ .start = start, .end = end },
                .message = try std.fmt.allocPrint(context.allocator, "line is {d} display columns, exceeding the configured limit of {d}", .{ columns, context.configuration.line_length_limit }),
            });
        }
        if (end == context.source.len) break;
        start = end + 1;
    }
}

fn findParameterOrder(context: RuleRun) !void {
    const allocator_level = context.level(.allocator_first_parameter);
    const comptime_level = context.level(.comptime_parameter_order);
    if (allocator_level == .off and comptime_level == .off) return;
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or externallyConstrained(context, fn_index)) continue;
        const opening = nextTagBefore(context.tokens, fn_index + 1, .l_paren, .semicolon) orelse continue;
        const closing = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        if (nextTagBefore(context.tokens, closing + 1, .l_brace, .semicolon) == null) continue;
        var parameter_start = opening + 1;
        var position: usize = 0;
        var saw_runtime = false;
        while (parameter_start < closing) {
            const comma = topLevelComma(context.tokens, parameter_start, closing) orelse closing;
            if (parameter_start < comma) {
                const is_self = position == 0 and context.tokens[parameter_start].tag == .identifier and context.tokenIs(parameter_start, "self");
                const is_comptime = context.tokens[parameter_start].tag == .keyword_comptime;
                if (is_comptime and saw_runtime and comptime_level != .off) try context.emit(.{
                    .rule = .comptime_parameter_order,
                    .level = comptime_level,
                    .span = context.tokens[parameter_start].loc,
                    .message = "comptime parameters configure the function and should precede runtime parameters",
                });
                if (!is_comptime and !is_self) saw_runtime = true;
                const allocator_type = findAllocatorType(context, parameter_start, comma);
                const expected_position: usize = if (firstParameterIsSelf(context, opening + 1, closing)) 1 else 0;
                if (allocator_type != null and position != expected_position and allocator_level != .off) try context.emit(.{
                    .rule = .allocator_first_parameter,
                    .level = allocator_level,
                    .span = context.tokens[allocator_type.?].loc,
                    .message = "std.mem.Allocator should be the first parameter after an optional self parameter",
                });
                position += 1;
            }
            if (comma == closing) break;
            parameter_start = comma + 1;
        }
    }
}

fn findTaskMarkers(context: RuleRun) !void {
    const level = context.level(.todo_comment);
    if (level == .off) return;
    var line_start: usize = 0;
    while (line_start < context.source.len) {
        const relative_end = std.mem.indexOfScalar(u8, context.source[line_start..], '\n') orelse context.source.len - line_start;
        const line_end = line_start + relative_end;
        const line = context.source[line_start..line_end];
        if (commentStart(line)) |comment_start| {
            const comment = line[comment_start + 2 ..];
            for (context.configuration.todo_markers) |marker| {
                const marker_offset = std.mem.indexOf(u8, comment, marker) orelse continue;
                const absolute = line_start + comment_start + 2 + marker_offset;
                try context.emit(.{
                    .rule = .todo_comment,
                    .level = level,
                    .span = .{ .start = absolute, .end = absolute + marker.len },
                    .message = try std.fmt.allocPrint(context.allocator, "comment contains task marker '{s}'; track or resolve the promise before it becomes invisible debt", .{marker}),
                });
                break;
            }
        }
        if (line_end == context.source.len) break;
        line_start = line_end + 1;
    }
}

fn findAssertionFreeTests(context: RuleRun) !void {
    const level = context.level(.assertion_free_test);
    if (level == .off) return;
    for (context.tokens, 0..) |token, test_index| {
        if (token.tag != .keyword_test) continue;
        const opening = nextTagBefore(context.tokens, test_index + 1, .l_brace, .semicolon) orelse continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        if (testHasAssertion(context, opening + 1, closing)) continue;
        try context.emit(.{
            .rule = .assertion_free_test,
            .level = level,
            .span = token.loc,
            .message = "test block contains no expectation, propagated fallible call, catch, or debug assertion",
        });
    }
}

fn testHasAssertion(context: RuleRun, start: usize, end: usize) bool {
    if (testIsCompileSmoke(context, start, end)) return true;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .keyword_try, .keyword_catch => return true,
        .identifier, .builtin => if (index + 1 < end and context.tokens[index + 1].tag == .l_paren) return true,
        else => {},
    };
    return false;
}

fn testIsCompileSmoke(context: RuleRun, start: usize, end: usize) bool {
    var statement_start = start;
    var statements: usize = 0;
    while (statement_start < end) {
        if (statement_start + 2 >= end or context.tokens[statement_start].tag != .identifier or
            !context.tokenIs(statement_start, "_") or context.tokens[statement_start + 1].tag != .equal) return false;
        const statement_end = context.statementEnd(statement_start) orelse return false;
        if (statement_end >= end) return false;
        statements += 1;
        statement_start = statement_end + 1;
    }
    return statements != 0;
}

fn hasInvariantCheck(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_unreachable) return true;
        if (token.tag == .identifier and context.tokenIs(index, "assert") and index + 1 < end and context.tokens[index + 1].tag == .l_paren) return true;
        if (token.tag == .keyword_if and index + 1 < end) {
            const limited_end = @min(end, index + 20);
            for (context.tokens[index + 1 .. limited_end]) |guard_token| if (guard_token.tag == .keyword_return) return true;
        }
    }
    return false;
}

fn computedBracket(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .l_bracket or index + 2 >= end) continue;
        if (context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .r_bracket) return index;
        if (context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .ellipsis2) return index;
    }
    return null;
}

fn bodyHasCounterGuard(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_if) continue;
        const limit = @min(end, index + 20);
        var comparison = false;
        var exits = false;
        for (context.tokens[index + 1 .. limit]) |candidate| switch (candidate.tag) {
            .angle_bracket_left, .angle_bracket_right, .equal_equal => comparison = true,
            .keyword_break, .keyword_return => exits = true,
            else => {},
        };
        if (comparison and exits) return true;
    }
    return false;
}

fn eventLoopHasBlockingDispatch(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        if (context.tokenIs(index, "wait") or context.tokenIs(index, "run") or context.tokenIs(index, "dispatch") or context.tokenIs(index, "accept")) return true;
    }
    return false;
}

fn conditionIsTrue(context: RuleRun, start: usize, end: usize) bool {
    return end == start + 1 and context.tokens[start].tag == .identifier and context.tokenIs(start, "true");
}

fn firstParameterIsSelf(context: RuleRun, start: usize, end: usize) bool {
    const comma = topLevelComma(context.tokens, start, end) orelse end;
    return start < comma and context.tokens[start].tag == .identifier and context.tokenIs(start, "self");
}

fn findAllocatorType(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "Allocator") and index >= start + 4 and
            context.tokenIs(index - 4, "std") and context.tokenIs(index - 2, "mem")) return index;
    }
    return null;
}

fn externallyConstrained(context: RuleRun, fn_index: usize) bool {
    var cursor = fn_index;
    while (cursor > 0 and fn_index - cursor < 5) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .keyword_extern or context.tokens[cursor].tag == .keyword_export) return true;
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) break;
    }
    return false;
}

fn insideKeywordBlock(context: RuleRun, index: usize, keyword: std.zig.Token.Tag) bool {
    var keyword_scopes: [256]bool = @splat(false);
    var depth: usize = 0;
    for (context.tokens[0..index], 0..) |token, token_index| switch (token.tag) {
        .l_brace => {
            if (depth == keyword_scopes.len) return false;
            const inherited = depth != 0 and keyword_scopes[depth - 1];
            var belongs = false;
            var cursor = token_index;
            while (cursor > 0 and token_index - cursor < 16) {
                cursor -= 1;
                if (context.tokens[cursor].tag == keyword) {
                    belongs = true;
                    break;
                }
                if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .r_brace) break;
            }
            keyword_scopes[depth] = inherited or belongs;
            depth += 1;
        },
        .r_brace => depth -|= 1,
        else => {},
    };
    return depth != 0 and keyword_scopes[depth - 1];
}

fn displayColumns(line: []const u8) usize {
    var columns: usize = 0;
    var view = std.unicode.Utf8View.init(line) catch return line.len;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == '\t') {
            columns += 8 - (columns % 8);
        } else {
            columns += 1;
        }
    }
    return columns;
}

fn singleUnsplittableToken(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (std.mem.indexOf(u8, trimmed, "http://") != null or std.mem.indexOf(u8, trimmed, "https://") != null) return true;
    return std.mem.indexOfAny(u8, trimmed, " \t") == null;
}

fn commentStart(line: []const u8) ?usize {
    var quote: ?u8 = null;
    var escaped = false;
    var index: usize = 0;
    while (index + 1 < line.len) : (index += 1) {
        const byte = line[index];
        if (quote) |delimiter| {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == delimiter) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '/' and line[index + 1] == '/') return index;
    }
    return null;
}

fn lineNumber(source: []const u8, offset: usize) usize {
    return std.mem.count(u8, source[0..@min(offset, source.len)], "\n") + 1;
}

fn nextTagBefore(tokens: []const std.zig.Token, start: usize, wanted: std.zig.Token.Tag, stop: std.zig.Token.Tag) ?usize {
    for (tokens[start..], start..) |token, index| {
        if (token.tag == stop) return null;
        if (token.tag == wanted) return index;
    }
    return null;
}

fn topLevelComma(tokens: []const std.zig.Token, start: usize, end: usize) ?usize {
    var depth: usize = 0;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) return index,
        else => {},
    };
    return null;
}

test "disciplined and policy rules report their bounded local shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_writer: std.Io.Writer.Allocating = .init(arena.allocator());
    try source_writer.writer.writeAll(
        "fn inspect(buffer: []u8, index: usize) u8 {\n" ++
            "const one = 1;\nconst two = 2;\nconst three = 3;\nconst four = 4;\n" ++
            "const five = 5;\nconst six = 6;\nconst seven = 7;\n_ = one + two + three + four + five + six + seven;\n" ++
            "return buffer[index];\n}\n" ++
            "fn spin(flag: bool) void { while (flag) {} }\n" ++
            "fn configure(value: u8, comptime T: type, other: u8, allocator: std.mem.Allocator) void { _ = T; _ = value; _ = other; _ = allocator; }\n" ++
            "// TODO replace this marker\n" ++
            "test \"empty assertion\" { const value = 1; _ = value; }\n" ++
            "const long = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\";\n" ++
            "fn longFunction() void {\n",
    );
    for (0..70) |_| try source_writer.writer.writeAll("_ = 1;\n");
    try source_writer.writer.writeAll("}\n");
    const bytes = try source_writer.toOwnedSlice();
    const source = try arena.allocator().dupeZ(u8, bytes);
    var configuration = types.Configuration.defaults();
    const expected_rules = [_]types.Rule{
        .function_length,
        .assertion_free_branching,
        .unbounded_loop,
        .line_length,
        .allocator_first_parameter,
        .comptime_parameter_order,
        .todo_comment,
        .assertion_free_test,
    };
    for (expected_rules) |rule| configuration.levels[@intFromEnum(rule)] = .information;
    const found = try findingsFor(arena.allocator(), source, configuration);
    for (expected_rules) |rule| {
        var seen = false;
        for (found) |finding| if (finding.rule == rule) {
            seen = true;
            break;
        };
        if (!seen) std.debug.print("missing discipline test finding {s}\n", .{rule.code()});
        try std.testing.expect(seen);
    }
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8, configuration: types.Configuration) ![]const types.Finding {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    var found: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = allocator, .source = source, .tokens = tokens.items, .configuration = configuration, .findings = &found });
    return try found.toOwnedSlice(allocator);
}
