const std = @import("std");
const configuration = @import("configuration.zig");
const types = @import("types.zig");

pub const RuleRun = struct {
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    configuration: types.Configuration,
    findings: *std.ArrayList(types.Finding),

    pub fn level(context: RuleRun, rule: types.Rule) types.Level {
        return context.configuration.level(rule);
    }

    pub fn emit(context: RuleRun, finding: types.Finding) !void {
        if (finding.level == .off or configuration.isSuppressed(context.source, finding.rule, finding.span.start)) return;
        try context.findings.append(context.allocator, finding);
    }

    pub fn tokenText(context: RuleRun, index: usize) []const u8 {
        const token = context.tokens[index];
        return context.source[token.loc.start..token.loc.end];
    }

    pub fn tokenIs(context: RuleRun, index: usize, expected: []const u8) bool {
        return index < context.tokens.len and std.mem.eql(u8, context.tokenText(index), expected);
    }

    pub fn refersToBinding(context: RuleRun, index: usize, name: []const u8) bool {
        return tokenRefersToBinding(context.source, context.tokens, index, name);
    }

    pub fn matchingToken(
        context: RuleRun,
        opening_index: usize,
        opening_tag: std.zig.Token.Tag,
        closing_tag: std.zig.Token.Tag,
    ) ?usize {
        var depth: usize = 0;
        for (context.tokens[opening_index..], opening_index..) |token, index| {
            if (token.tag == opening_tag) depth += 1;
            if (token.tag != closing_tag) continue;
            depth -= 1;
            if (depth == 0) return index;
        }
        return null;
    }

    pub fn statementEnd(context: RuleRun, start: usize) ?usize {
        var parenthesis_depth: usize = 0;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        for (context.tokens[start..], start..) |token, index| {
            switch (token.tag) {
                .l_paren => parenthesis_depth += 1,
                .r_paren => parenthesis_depth -|= 1,
                .l_bracket => bracket_depth += 1,
                .r_bracket => bracket_depth -|= 1,
                .l_brace => brace_depth += 1,
                .r_brace => {
                    if (brace_depth == 0) return null;
                    brace_depth -= 1;
                },
                .semicolon => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index,
                else => {},
            }
        }
        return null;
    }

    pub fn enclosingOpeningBrace(context: RuleRun, index: usize) ?usize {
        var depth: usize = 0;
        var cursor = index;
        while (cursor > 0) {
            cursor -= 1;
            switch (context.tokens[cursor].tag) {
                .r_brace => depth += 1,
                .l_brace => {
                    if (depth == 0) return cursor;
                    depth -= 1;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn enclosingScopeEnd(context: RuleRun, index: usize) ?usize {
        const opening = context.enclosingOpeningBrace(index) orelse return null;
        return context.matchingToken(opening, .l_brace, .r_brace);
    }
};

pub fn tokenRefersToBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    index: usize,
    name: []const u8,
) bool {
    const token = tokens[index];
    if (token.tag != .identifier or !std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) return false;
    return index == 0 or tokens[index - 1].tag != .period;
}
