//! `catch` expressions that discard, lose or assert away the error.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
const matchingOpeningToken = @import("../../syntax/tokens.zig").matchingOpeningToken;
const callExpressionStart = @import("../../syntax/tokens.zig").callExpressionStart;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .discarded_error,
    .unsafe_catch_unreachable,
    .lost_error_context,
};

pub fn run(context: RuleRun) !void {
    try findDiscardedErrors(context);
    try findCatchDiagnostics(context);
}

fn findDiscardedErrors(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.discarded_error);
    if (level == .off) return;
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_catch) continue;
        const opening = catchBodyStart(tokens, index) orelse continue;
        if (opening + 1 >= tokens.len or tokens[opening].tag != .l_brace or tokens[opening + 1].tag != .r_brace) continue;
        const body = source[tokens[opening].loc.end..tokens[opening + 1].loc.start];
        if (std.mem.trim(u8, body, &std.ascii.whitespace).len != 0) continue;
        try context.emit(.{
            .rule = .discarded_error,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(u8, "empty catch body discards the error without handling it"),
        });
    }
}

fn findCatchDiagnostics(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const unreachable_level = context.level(.unsafe_catch_unreachable);
    const context_level = context.level(.lost_error_context);
    if (unreachable_level == .off and context_level == .off) return;

    for (tokens, 0..) |token, catch_index| {
        if (token.tag != .keyword_catch) continue;
        const body_start = catchBodyStart(tokens, catch_index) orelse continue;
        if (unreachable_level != .off and tokens[body_start].tag == .keyword_unreachable and
            catchExpressionIsKnownFallible(source, tokens, catch_index))
        {
            const fixes: []const Fix = fixes: {
                if (!enclosingFunctionReturnsErrorUnion(tokens, catch_index)) break :fixes &.{};
                const call_open = matchingOpeningToken(tokens, catch_index - 1, .l_paren, .r_paren) orelse break :fixes &.{};
                const expression_start = callExpressionStart(tokens, call_open) orelse break :fixes &.{};
                const expression = std.mem.trim(u8, source[tokens[expression_start].loc.start..token.loc.start], " \t\r\n");
                const allocated = try Fix.single(context.allocator, .{
                    .title = "Propagate the error with try",
                    .span = .{ .start = tokens[expression_start].loc.start, .end = tokens[body_start].loc.end },
                    .replacement = try context.allocator.print("try {s}", .{expression}),
                });
                break :fixes allocated;
            };
            try context.emit(.{
                .rule = .unsafe_catch_unreachable,
                .level = unreachable_level,
                .span = tokens[body_start].loc,
                .message = try context.allocator.dupe(u8, "catch unreachable asserts that a proven fallible operation cannot fail"),
                .fixes = fixes,
            });
        }
        if (context_level == .off) continue;
        const remapped_error = remappedErrorToken(source, tokens, body_start) orelse continue;
        // A body that stores or logs the captured error keeps its identity.
        if (catchCaptureIsUsed(source, tokens, catch_index, body_start)) continue;
        try context.emit(.{
            .rule = .lost_error_context,
            .level = context_level,
            .span = token.loc,
            .message = try context.allocator.print(
                "catch maps every failure to '{s}' and loses the original error identity",
                .{tokenText(source, remapped_error)},
            ),
        });
    }
}

fn catchCaptureIsUsed(
    source: []const u8,
    tokens: []const std.zig.Token,
    catch_index: usize,
    body_start: usize,
) bool {
    if (catch_index + 2 >= tokens.len or tokens[catch_index + 1].tag != .pipe or
        tokens[catch_index + 2].tag != .identifier) return false;
    const capture_name = tokenText(source, tokens[catch_index + 2]);
    if (std.mem.eql(u8, capture_name, "_")) return false;
    var limit = @min(tokens.len, body_start + 16);
    if (tokens[body_start].tag == .l_brace) {
        limit = matchingToken(tokens, body_start, .l_brace, .r_brace) orelse return false;
    }
    for (tokens[body_start..limit], body_start..) |token, index| {
        if (token.tag == .semicolon and tokens[body_start].tag != .l_brace) break;
        if (token.tag != .identifier or !tokenIs(source, token, capture_name)) continue;
        if (index > 0 and tokens[index - 1].tag == .period) continue;
        return true;
    }
    return false;
}

fn catchBodyStart(tokens: []const std.zig.Token, catch_index: usize) ?usize {
    var index = catch_index + 1;
    if (index >= tokens.len) return null;
    if (tokens[index].tag == .pipe) {
        index += 1;
        while (index < tokens.len and tokens[index].tag != .pipe) : (index += 1) {}
        if (index >= tokens.len) return null;
        index += 1;
    }
    return if (index < tokens.len) index else null;
}

fn enclosingFunctionReturnsErrorUnion(tokens: []const std.zig.Token, index: usize) bool {
    var nested_closing_braces: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => nested_closing_braces += 1,
            .l_brace => {
                if (nested_closing_braces != 0) {
                    nested_closing_braces -= 1;
                    continue;
                }
                var signature_cursor = cursor;
                while (signature_cursor > 0) {
                    signature_cursor -= 1;
                    switch (tokens[signature_cursor].tag) {
                        .keyword_fn => {
                            var parameters_open = signature_cursor + 1;
                            while (parameters_open < cursor and tokens[parameters_open].tag != .l_paren) : (parameters_open += 1) {}
                            if (parameters_open >= cursor) return false;
                            const parameters_end = matchingToken(tokens, parameters_open, .l_paren, .r_paren) orelse return false;
                            for (tokens[parameters_end + 1 .. cursor]) |return_token| {
                                if (return_token.tag == .bang) return true;
                            }
                            return false;
                        },
                        .semicolon, .l_brace, .r_brace => break,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

fn catchExpressionIsKnownFallible(source: []const u8, tokens: []const std.zig.Token, catch_index: usize) bool {
    if (catch_index == 0 or tokens[catch_index - 1].tag != .r_paren) return false;
    const opening = matchingOpeningToken(tokens, catch_index - 1, .l_paren, .r_paren) orelse return false;
    if (opening == 0 or tokens[opening - 1].tag != .identifier) return false;
    const callee_name = tokenText(source, tokens[opening - 1]);
    const known_fallible = [_][]const u8{
        "alloc",    "allocSentinel", "alignedAlloc", "dupe",            "dupeZ", "realloc", "create",
        "openFile", "createFile",    "openDir",      "openIterableDir", "read",  "write",   "parse",
    };
    for (known_fallible) |name| if (std.mem.eql(u8, callee_name, name)) return true;

    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_fn or index + 2 >= tokens.len or
            !tokenIs(source, tokens[index + 1], callee_name) or tokens[index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, index + 2, .l_paren, .r_paren) orelse continue;
        var return_index = parameters_end + 1;
        const return_limit = @min(tokens.len, parameters_end + 32);
        while (return_index < return_limit and tokens[return_index].tag != .semicolon and
            tokens[return_index].tag != .keyword_return) : (return_index += 1)
        {
            if (tokenIs(source, tokens[return_index], "!")) return true;
            if (tokens[return_index].tag != .l_brace) continue;
            if (return_index > parameters_end + 1 and tokenIs(source, tokens[return_index - 1], "error")) {
                return_index = matchingToken(tokens, return_index, .l_brace, .r_brace) orelse return false;
                continue;
            }
            return false;
        }
    }
    return false;
}

fn remappedErrorToken(
    source: []const u8,
    tokens: []const std.zig.Token,
    body_start: usize,
) ?std.zig.Token {
    var index = body_start;
    var limit = @min(tokens.len, body_start + 16);
    const braced = tokens[body_start].tag == .l_brace;
    if (braced) {
        const closing = matchingToken(tokens, body_start, .l_brace, .r_brace) orelse return null;
        limit = closing;
        index += 1;
    }
    var remapped: ?std.zig.Token = null;
    while (index < limit) : (index += 1) {
        switch (tokens[index].tag) {
            // Branching means only some failures are remapped, not every one.
            .keyword_if, .keyword_switch => return null,
            .keyword_return => {
                if (remapped != null) return null;
                if (index + 3 >= limit or !tokenIs(source, tokens[index + 1], "error") or
                    tokens[index + 2].tag != .period or tokens[index + 3].tag != .identifier) return null;
                remapped = tokens[index + 3];
                index += 3;
            },
            .semicolon => if (!braced) break,
            else => {},
        }
    }
    return remapped;
}

test "discarded error ignores an explanatory catch comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void { failing() catch { // Best effort cleanup.\n" ++
        "}; }\n";
    const configuration = support.only(&.{.discarded_error}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .discarded_error);
}

test "a catch body that records the captured error keeps its context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(cache: *Cache) !void {\n" ++
        "    cache.file.lock() catch |err| {\n" ++
        "        cache.diagnostic = err;\n" ++
        "        return error.CacheCheckFailed;\n" ++
        "    };\n" ++
        "}\n" ++
        "fn remap(cache: *Cache) !void {\n" ++
        "    cache.file.lock() catch return error.CacheCheckFailed;\n" ++
        "}\n";
    const configuration = support.only(&.{.lost_error_context}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var context_loss_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .lost_error_context) context_loss_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), context_loss_count);
}

test "catch diagnostics distinguish unreachable assertions from error remapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn fail() error{Failed}!void { return error.Failed; }\n" ++
        "fn run() error{Wrapped}!void {\n" ++
        "    fail() catch unreachable;\n" ++
        "    fail() catch return error.Wrapped;\n" ++
        "}\n";
    const configuration = support.only(&.{ .unsafe_catch_unreachable, .lost_error_context }, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var saw_unreachable = false;
    var saw_context_loss = false;
    for (found) |finding| switch (finding.rule) {
        .unsafe_catch_unreachable => saw_unreachable = true,
        .lost_error_context => saw_context_loss = true,
        else => {},
    };
    try std.testing.expect(saw_unreachable);
    try std.testing.expect(saw_context_loss);
}

test "discarded error is reported even with an unused capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() !u32 { return 1; }\n" ++
        "fn run() void {\n" ++
        "    load() catch |err| {};\n" ++
        "    load() catch |err| { log(err); };\n" ++
        "}\n";
    const configuration = support.only(&.{.discarded_error}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var discard_count: usize = 0;
    for (found) |finding| if (finding.rule == .discarded_error) {
        discard_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), discard_count);
}

test "lost error context ignores conditional remaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() !u32 { return 1; }\n" ++
        "fn conditional() !u32 {\n" ++
        "    return load() catch |err| {\n" ++
        "        if (err == error.FileNotFound) return error.ConfigMissing;\n" ++
        "        return err;\n" ++
        "    };\n" ++
        "}\n" ++
        "fn unconditional() !u32 {\n" ++
        "    return load() catch { return error.LoadFailed; };\n" ++
        "}\n";
    const configuration = support.only(&.{.lost_error_context}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var context_count: usize = 0;
    for (found) |finding| if (finding.rule == .lost_error_context) {
        context_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "LoadFailed") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), context_count);
}

test "catch unreachable offers try only inside fallible functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn fail() !void { return error.Failed; }\n" ++
        "fn propagate() !void {\n" ++
        "    fail() catch unreachable;\n" ++
        "}\n" ++
        "fn swallow() void {\n" ++
        "    fail() catch unreachable;\n" ++
        "}\n";
    const configuration = support.only(&.{.unsafe_catch_unreachable}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var unreachable_count: usize = 0;
    for (found) |finding| if (finding.rule == .unsafe_catch_unreachable) {
        unreachable_count += 1;
        if (finding.span.start < std.mem.find(u8, source, "fn swallow").?) {
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
            try std.testing.expectEqualStrings("try fail()", finding.fixes[0].edits[0].replacement);
        } else {
            try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
        }
    };
    try std.testing.expectEqual(@as(usize, 2), unreachable_count);
}
