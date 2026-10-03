const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.redundant_slice_end);
    if (level == .off) return;

    for (context.tokens, 0..) |token, dotdot_index| {
        if (token.tag != .ellipsis2 or dotdot_index == 0 or dotdot_index + 3 >= context.tokens.len) continue;

        // Find enclosing slice bracket: [start..end]
        const l_bracket = findSliceBracketBefore(context.tokens, dotdot_index) orelse continue;

        // Find base path before [
        const base_span = pathBefore(context.tokens, l_bracket) orelse continue;

        // Find matching ] after dotdot_index
        const r_bracket = context.matchingToken(l_bracket, .l_bracket, .r_bracket) orelse continue;
        if (r_bracket <= dotdot_index + 1) continue;

        // Check if expression between dotdot_index + 1 and r_bracket is: base.len
        const upper_tokens = r_bracket - (dotdot_index + 1);
        const base_tokens = base_span.end - base_span.start;
        // upper must have base_tokens + 2 tokens (. and len)
        if (upper_tokens != base_tokens + 2) continue;

        var matches = true;
        for (0..base_tokens) |offset| {
            const base_tok = base_span.start + offset;
            const upper_tok = dotdot_index + 1 + offset;
            if (context.tokens[base_tok].tag != context.tokens[upper_tok].tag or
                !context.tokenIs(base_tok, context.tokenText(upper_tok)))
            {
                matches = false;
                break;
            }
        }
        if (!matches) continue;

        if (context.tokens[dotdot_index + 1 + base_tokens].tag != .period or
            !context.tokenIs(dotdot_index + 1 + base_tokens + 1, "len")) continue;

        const slice_source = context.source[context.tokens[base_span.start].loc.start..context.tokens[r_bracket].loc.end];
        if (containsComment(slice_source)) continue;

        const base_text = context.source[context.tokens[base_span.start].loc.start..context.tokens[base_span.end - 1].loc.end];

        // Quickfix: remove `base.len` from after `..` up to `r_bracket`
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{
            .span = .{ .start = context.tokens[dotdot_index].loc.end, .end = context.tokens[r_bracket].loc.start },
            .replacement = "",
        };
        const fixes = try context.allocator.alloc(types.Fix, 1);
        fixes[0] = .{
            .title = try std.fmt.allocPrint(context.allocator, "Omit redundant upper bound '{s}.len'", .{base_text}),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };

        try context.emit(.{
            .rule = .redundant_slice_end,
            .level = level,
            .span = .{ .start = context.tokens[dotdot_index + 1].loc.start, .end = context.tokens[r_bracket - 1].loc.end },
            .message = try std.fmt.allocPrint(
                context.allocator,
                "redundant upper slice bound '{s}.len'; '{s}[...]' implicitly bounds to the slice length",
                .{ base_text, base_text },
            ),
            .fixes = fixes,
        });
    }
}

fn findSliceBracketBefore(tokens: []const std.zig.Token, dotdot_index: usize) ?usize {
    var cursor = dotdot_index;
    var paren_depth: usize = 0;
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_paren => paren_depth += 1,
            .l_paren => if (paren_depth > 0) {
                paren_depth -= 1;
            } else return null,
            .r_brace => brace_depth += 1,
            .l_brace => if (brace_depth > 0) {
                brace_depth -= 1;
            } else return null,
            .r_bracket => bracket_depth += 1,
            .l_bracket => {
                if (bracket_depth > 0) {
                    bracket_depth -= 1;
                } else if (paren_depth == 0 and brace_depth == 0) {
                    return cursor;
                }
            },
            .semicolon => return null,
            else => {},
        }
    }
    return null;
}

const PathSpan = struct {
    start: usize,
    end: usize,
};

fn pathBefore(tokens: []const std.zig.Token, before: usize) ?PathSpan {
    if (before == 0 or tokens[before - 1].tag != .identifier) return null;
    var cursor = before - 1;
    while (cursor >= 2 and tokens[cursor - 1].tag == .period and tokens[cursor - 2].tag == .identifier) {
        cursor -= 2;
    }
    return .{ .start = cursor, .end = before };
}

fn containsComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "//") != null or std.mem.indexOf(u8, source, "/*") != null;
}

test "redundant slice end reports slice.len as upper bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(buf: []const u8, self: Struct) void {\n" ++
        "    _ = buf[0..buf.len];\n" ++
        "    _ = self.data[start..self.data.len];\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "buf.len") != null);
    try std.testing.expectEqualStrings("", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expect(std.mem.indexOf(u8, findings[1].message, "self.data.len") != null);
}

test "meaningful upper slice bounds stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(buf: []const u8, other: []const u8) void {\n" ++
        "    _ = buf[0..other.len];\n" ++
        "    _ = buf[0..buf.len - 1];\n" ++
        "    _ = buf[0..];\n" ++
        "    _ = buf[..];\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "redundant slice end honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(buf: []const u8) void {\n" ++
        "    // zig-analyzer: disable-next-line redundant-slice-end\n" ++
        "    _ = buf[0..buf.len];\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.redundant_slice_end)] = .information;
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
