const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;

pub fn run(context: RuleRun) !void {
    const level = context.level(.unsafe_orelse_unreachable);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .keyword_orelse or index + 1 >= context.tokens.len or
            context.tokens[index + 1].tag != .keyword_unreachable or insideTestBody(context.tokens, index)) continue;
        if (subjectSpan(context.tokens, index)) |span| {
            const subject_text = context.source[context.tokens[span.start].loc.start..context.tokens[span.end - 1].loc.end];
            if (isGuardedByNullAssertion(context, subject_text, span.start)) continue;
        }

        try context.emit(.{
            .rule = .unsafe_orelse_unreachable,
            .level = level,
            .span = context.tokens[index + 1].loc,
            .message = try context.allocator.dupe(
                u8,
                "orelse unreachable turns an absent optional into a panic; handle null or document the invariant with an assertion",
            ),
        });
    }
}

fn subjectSpan(tokens: []const std.zig.Token, orelse_index: usize) ?struct { start: usize, end: usize } {
    if (orelse_index == 0) return null;
    var cursor = orelse_index;
    if (tokens[cursor - 1].tag != .identifier) return null;
    cursor -= 1;
    while (cursor >= 2 and tokens[cursor - 1].tag == .period and tokens[cursor - 2].tag == .identifier) {
        cursor -= 2;
    }
    return .{ .start = cursor, .end = orelse_index };
}

fn isGuardedByNullAssertion(context: RuleRun, subject_text: []const u8, start_index: usize) bool {
    var brace_depth: usize = 0;
    var cursor = start_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .r_brace => brace_depth += 1,
            .l_brace => {
                if (brace_depth == 0) return false;
                brace_depth -= 1;
            },
            .keyword_fn => return false,
            else => {},
        }
        if (brace_depth != 0) continue;

        if (context.tokens[cursor].tag == .identifier and
            cursor + 1 < start_index and
            isAssignmentOp(context.tokens[cursor + 1].tag))
        {
            if (std.mem.startsWith(u8, subject_text, context.tokenText(cursor))) {
                return false;
            }
        }

        if (isAssertCallee(context, cursor)) {
            if (cursor + 1 < context.tokens.len and context.tokens[cursor + 1].tag == .l_paren) {
                const close_paren = context.matchingToken(cursor + 1, .l_paren, .r_paren) orelse continue;
                if (assertionChecksNonNull(context, cursor + 2, close_paren, subject_text)) {
                    return true;
                }
            }
        }
    }
    return false;
}

fn isAssignmentOp(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal, .percent_equal => true,
        else => false,
    };
}

fn isAssertCallee(context: RuleRun, assert_index: usize) bool {
    if (!context.tokenIs(assert_index, "assert")) return false;
    if (assert_index >= 4 and
        context.tokenIs(assert_index - 4, "std") and
        context.tokens[assert_index - 3].tag == .period and
        context.tokenIs(assert_index - 2, "debug") and
        context.tokens[assert_index - 1].tag == .period and
        (assert_index == 4 or context.tokens[assert_index - 5].tag != .period))
    {
        return true;
    }
    if (assert_index >= 2 and
        context.tokenIs(assert_index - 2, "debug") and
        context.tokens[assert_index - 1].tag == .period and
        (assert_index == 2 or context.tokens[assert_index - 3].tag != .period))
    {
        return true;
    }
    if (assert_index == 0 or context.tokens[assert_index - 1].tag != .period) {
        return true;
    }
    return false;
}

fn assertionChecksNonNull(context: RuleRun, start: usize, end: usize, subject_text: []const u8) bool {
    var i = start;
    while (i < end) : (i += 1) {
        if (context.tokens[i].tag != .bang_equal) continue;
        if (i + 1 < end and context.tokenIs(i + 1, "null")) {
            const lhs_end = i;
            if (lhs_end > start and context.tokens[lhs_end - 1].tag == .identifier) {
                var lhs_start = lhs_end - 1;
                while (lhs_start >= start + 2 and context.tokens[lhs_start - 1].tag == .period and context.tokens[lhs_start - 2].tag == .identifier) {
                    lhs_start -= 2;
                }
                const lhs_text = context.source[context.tokens[lhs_start].loc.start..context.tokens[lhs_end - 1].loc.end];
                if (std.mem.eql(u8, lhs_text, subject_text)) return true;
            }
        }
        if (i > start and context.tokenIs(i - 1, "null")) {
            if (i + 1 < end and context.tokens[i + 1].tag == .identifier) {
                var rhs_end = i + 2;
                while (rhs_end + 1 < end and context.tokens[rhs_end].tag == .period and context.tokens[rhs_end + 1].tag == .identifier) {
                    rhs_end += 2;
                }
                const rhs_text = context.source[context.tokens[i + 1].loc.start..context.tokens[rhs_end - 1].loc.end];
                if (std.mem.eql(u8, rhs_text, subject_text)) return true;
            }
        }
    }
    return false;
}

fn insideTestBody(tokens: []const std.zig.Token, index: usize) bool {
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
                        .keyword_test => return true,
                        .keyword_fn, .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return false,
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

test "orelse unreachable warns only when the idiomatic rule is enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 = "const value = optional orelse unreachable;";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.unsafe_orelse_unreachable)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
}

test "test fixtures may use orelse unreachable as an assertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 = "test \"fixture\" { _ = optional orelse unreachable; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.unsafe_orelse_unreachable)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "modular rules honor source suppressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line unsafe-orelse-unreachable\n" ++
        "const value = optional orelse unreachable;";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.unsafe_orelse_unreachable)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "orelse unreachable does not warn when preceded by assert non-null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn foo(opt: ?u32) u32 {\n" ++
        "    assert(opt != null);\n" ++
        "    return opt orelse unreachable;\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.unsafe_orelse_unreachable)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "orelse unreachable does not warn when preceded by std.debug.assert non-null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn foo(self: Struct) u32 {\n" ++
        "    std.debug.assert(self.opt != null and self.valid);\n" ++
        "    return self.opt orelse unreachable;\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.unsafe_orelse_unreachable)] = .information;
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
