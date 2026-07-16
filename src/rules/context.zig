const std = @import("std");
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
        if (finding.level == .off or suppressed(context.source, finding.rule.code(), finding.span.start)) return;
        try context.findings.append(context.allocator, finding);
    }

    pub fn tokenText(context: RuleRun, index: usize) []const u8 {
        const token = context.tokens[index];
        return context.source[token.loc.start..token.loc.end];
    }

    pub fn tokenIs(context: RuleRun, index: usize, expected: []const u8) bool {
        return index < context.tokens.len and std.mem.eql(u8, context.tokenText(index), expected);
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

fn suppressed(source: []const u8, rule: []const u8, offset: usize) bool {
    const prefix = source[0..@min(offset, source.len)];
    var lines = std.mem.splitScalar(u8, prefix, '\n');
    var previous: []const u8 = "";
    var current: []const u8 = "";
    while (lines.next()) |line| {
        if (directiveContains(line, "disable-file", rule)) return true;
        previous = current;
        current = line;
    }
    return directiveContains(previous, "disable-next-line", rule);
}

fn directiveContains(line: []const u8, directive: []const u8, rule: []const u8) bool {
    const marker = "// zig-analyzer:";
    const marker_index = std.mem.indexOf(u8, line, marker) orelse return false;
    var remainder = std.mem.trim(u8, line[marker_index + marker.len ..], " \t\r");
    if (!std.mem.startsWith(u8, remainder, directive)) return false;
    remainder = std.mem.trim(u8, remainder[directive.len..], " \t\r");
    var names = std.mem.splitScalar(u8, remainder, ',');
    while (names.next()) |name| {
        if (std.mem.eql(u8, std.mem.trim(u8, name, " \t\r"), rule)) return true;
    }
    return false;
}
