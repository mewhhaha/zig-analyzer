const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_loop_else);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            context.tokens[declaration_index + 2].tag != .equal or
            !context.tokenIs(declaration_index + 3, "false") or
            context.tokens[declaration_index + 4].tag != .semicolon) continue;
        const flag = context.tokenText(declaration_index + 1);
        const for_index = declaration_index + 5;
        if (for_index + 6 >= context.tokens.len or context.tokens[for_index].tag != .keyword_for or
            context.tokens[for_index + 1].tag != .l_paren) continue;
        const iterable_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (iterable_end + 2 >= context.tokens.len or context.tokens[iterable_end + 1].tag != .pipe) continue;
        const capture_end = findTag(context.tokens, iterable_end + 2, context.tokens.len, .pipe) orelse continue;
        const loop_start = capture_end + 1;
        if (loop_start >= context.tokens.len or context.tokens[loop_start].tag != .l_brace) continue;
        const loop_end = context.matchingToken(loop_start, .l_brace, .r_brace) orelse continue;
        if (!loopOnlySetsFlagAndBreaks(context, loop_start, loop_end, flag)) continue;

        const fallback_if = loop_end + 1;
        if (fallback_if + 5 >= context.tokens.len or context.tokens[fallback_if].tag != .keyword_if or
            context.tokens[fallback_if + 1].tag != .l_paren or context.tokens[fallback_if + 2].tag != .bang or
            !context.tokenIs(fallback_if + 3, flag) or context.tokens[fallback_if + 4].tag != .r_paren or
            context.tokens[fallback_if + 5].tag != .l_brace) continue;
        const fallback_end = context.matchingToken(fallback_if + 5, .l_brace, .r_brace) orelse continue;
        if (bindingUsed(context, fallback_if + 5, fallback_end, flag)) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse context.tokens.len;
        if (bindingUsed(context, fallback_end + 1, scope_end, flag)) continue;

        try context.emit(.{
            .rule = .prefer_loop_else,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "flag '{s}' only records whether the loop broke; put the fallback in the loop's else branch",
                .{flag},
            ),
        });
    }
}

fn loopOnlySetsFlagAndBreaks(context: RuleRun, opening: usize, closing: usize, flag: []const u8) bool {
    const if_index = opening + 1;
    if (if_index + 2 >= closing or context.tokens[if_index].tag != .keyword_if or
        context.tokens[if_index + 1].tag != .l_paren) return false;
    const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse return false;
    if (bindingUsed(context, if_index + 2, condition_end, flag)) return false;
    const match_start = condition_end + 1;
    if (match_start >= closing or context.tokens[match_start].tag != .l_brace) return false;
    const match_end = context.matchingToken(match_start, .l_brace, .r_brace) orelse return false;
    if (match_end + 1 != closing or match_start + 7 != match_end) return false;
    return context.tokenIs(match_start + 1, flag) and context.tokens[match_start + 2].tag == .equal and
        context.tokenIs(match_start + 3, "true") and context.tokens[match_start + 4].tag == .semicolon and
        context.tokens[match_start + 5].tag == .keyword_break and context.tokens[match_start + 6].tag == .semicolon;
}

fn bindingUsed(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.refersToBinding(index, name)) return true;
    }
    return false;
}

fn findTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    for (tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

test "a found flag used only by fallback prefers loop else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var found = false;\n" ++
        "for (values) |value| {\n" ++
        "    if (matches(value)) { found = true; break; }\n" ++
        "}\n" ++
        "if (!found) { fallback(); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "flags used after fallback and loops with other work stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var kept = false; for (values) |value| { if (matches(value)) { kept = true; break; } } if (!kept) {} use(kept);\n" ++
        "var busy = false; for (values) |value| { inspect(value); if (matches(value)) { busy = true; break; } } if (!busy) {}\n" ++
        "var leaked = false; for (values) |value| { if (matches(value)) { leaked = true; break; } } if (!leaked) { use(leaked); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "loop else preference respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line prefer-loop-else\n" ++
        "var found = false;\n" ++
        "for (values) |value| { if (matches(value)) { found = true; break; } }\n" ++
        "if (!found) {}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_loop_else)] = .information;
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
