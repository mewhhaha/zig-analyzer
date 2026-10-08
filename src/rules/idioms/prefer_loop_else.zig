const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const findTag = @import("../../syntax/tokens.zig").findTag;

pub const rules = [_]types.Rule{
    .prefer_loop_else,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_loop_else);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 4 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        var cursor = declaration_index + 2;
        if (cursor < context.tokens.len and context.tokens[cursor].tag == .colon) {
            cursor += 1;
            if (cursor >= context.tokens.len or context.tokens[cursor].tag != .identifier) continue;
            cursor += 1;
        }
        if (cursor + 2 >= context.tokens.len or
            context.tokens[cursor].tag != .equal or
            !context.tokenIs(cursor + 1, "false") or
            context.tokens[cursor + 2].tag != .semicolon) continue;
        const flag = context.tokenText(declaration_index + 1);
        const for_index = cursor + 3;
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
            !context.tokenIs(fallback_if + 3, flag) or context.tokens[fallback_if + 4].tag != .r_paren) continue;
        const fallback_end = if (context.tokens[fallback_if + 5].tag == .l_brace)
            context.matchingToken(fallback_if + 5, .l_brace, .r_brace) orelse continue
        else
            context.statementEnd(fallback_if + 5) orelse continue;
        if (bindingUsed(context, fallback_if + 5, fallback_end, flag)) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse context.tokens.len;
        if (bindingUsed(context, fallback_end + 1, scope_end, flag)) continue;

        try context.emit(.{
            .rule = .prefer_loop_else,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print(
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

test "explicit bool flag and unbraced fallback prefer loop else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var found: bool = false;\n" ++
        "for (values) |value| {\n" ++
        "    if (matches(value)) { found = true; break; }\n" ++
        "}\n" ++
        "if (!found) fallback();";
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

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.prefer_loop_else}, .information));
}
