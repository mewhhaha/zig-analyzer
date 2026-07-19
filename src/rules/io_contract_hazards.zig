const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

const FunctionRange = struct {
    parameters_start: usize,
    parameters_end: usize,
    signature_end: usize,
    body_start: usize,
    body_end: usize,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.silent_buffer_truncation);
    if (level == .off) return;

    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = functionRange(context, function_index) orelse continue;
        if (!returnsVoid(context, function.parameters_end + 1, function.signature_end)) continue;
        const source_name = sliceParameter(context, function.parameters_start, function.parameters_end) orelse continue;
        const amount = minimumBinding(context, source_name, function.body_start + 1, function.body_end) orelse continue;
        const copy_index = truncatingCopy(context, source_name, amount.name, amount.declaration_end + 1, function.body_end) orelse continue;
        if (hasExplicitCapacityFailure(context, source_name, function.body_start + 1, amount.declaration_end)) continue;
        if (writesTerminatorAtAmount(context, amount.name, copy_index + 1, function.body_end) and
            minimumReservesTerminator(context, source_name, amount.minimum_index, amount.declaration_end)) continue;
        try context.emit(.{
            .rule = .silent_buffer_truncation,
            .level = level,
            .span = context.tokens[copy_index].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "write copies only min({s}.len, available capacity) but returns no byte count or error when input is truncated",
                .{source_name},
            ),
        });
    }
}

fn writesTerminatorAtAmount(context: RuleRun, amount_name: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (context.tokens[index].tag != .l_bracket or !context.tokenIs(index + 1, amount_name) or
            context.tokens[index + 2].tag != .r_bracket or context.tokens[index + 3].tag != .equal or
            context.tokens[index + 4].tag != .number_literal) continue;
        if (std.mem.eql(u8, context.tokenText(index + 4), "0")) return true;
    }
    return false;
}

fn functionRange(context: RuleRun, function_index: usize) ?FunctionRange {
    var parameters_start = function_index + 1;
    while (parameters_start < context.tokens.len and context.tokens[parameters_start].tag != .l_paren) : (parameters_start += 1) {}
    if (parameters_start >= context.tokens.len) return null;
    const parameters_end = context.matchingToken(parameters_start, .l_paren, .r_paren) orelse return null;
    var body_start = parameters_end + 1;
    while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace and
        context.tokens[body_start].tag != .semicolon) : (body_start += 1)
    {}
    if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) return null;
    const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse return null;
    return .{
        .parameters_start = parameters_start,
        .parameters_end = parameters_end,
        .signature_end = body_start,
        .body_start = body_start,
        .body_end = body_end,
    };
}

fn returnsVoid(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "void")) return true;
    }
    return false;
}

fn sliceParameter(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start + 1 .. end], start + 1..) |token, name_index| {
        if (token.tag != .identifier or name_index + 4 >= end or context.tokens[name_index + 1].tag != .colon) continue;
        var type_index = name_index + 2;
        if (context.tokens[type_index].tag == .question_mark) type_index += 1;
        if (type_index + 1 < end and context.tokens[type_index].tag == .l_bracket and
            context.tokens[type_index + 1].tag == .r_bracket) return context.tokenText(name_index);
    }
    return null;
}

const MinimumBinding = struct {
    name: []const u8,
    minimum_index: usize,
    declaration_end: usize,
};

fn minimumBinding(context: RuleRun, source_name: []const u8, start: usize, end: usize) ?MinimumBinding {
    for (context.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 5 >= end or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const minimum_index = builtinInRange(context, "@min", declaration_index + 2, declaration_end) orelse continue;
        if (!pathInRange(context, source_name, "len", minimum_index + 1, declaration_end)) continue;
        return .{
            .name = context.tokenText(declaration_index + 1),
            .minimum_index = minimum_index,
            .declaration_end = declaration_end,
        };
    }
    return null;
}

fn minimumReservesTerminator(
    context: RuleRun,
    source_name: []const u8,
    minimum_index: usize,
    declaration_end: usize,
) bool {
    if (minimum_index + 1 >= declaration_end or context.tokens[minimum_index + 1].tag != .l_paren) return false;
    const closing = context.matchingToken(minimum_index + 1, .l_paren, .r_paren) orelse return false;
    var index = minimum_index + 2;
    while (index + 2 < @min(closing, declaration_end)) : (index += 1) {
        if (!context.tokenIs(index, "len") or context.tokens[index + 1].tag != .minus or
            context.tokens[index + 2].tag != .number_literal or !context.tokenIs(index + 2, "1")) continue;
        const direct_source_length = index >= 2 and context.tokens[index - 1].tag == .period and
            context.tokenIs(index - 2, source_name) and (index < 4 or context.tokens[index - 3].tag != .period);
        if (!direct_source_length) return true;
    }
    return false;
}

fn truncatingCopy(context: RuleRun, source_name: []const u8, amount_name: []const u8, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, copy_index| {
        if ((token.tag != .builtin or !context.tokenIs(copy_index, "@memcpy")) and
            (token.tag != .identifier or !context.tokenIs(copy_index, "copyForwards"))) continue;
        const statement_end = context.statementEnd(copy_index) orelse continue;
        if (statement_end > end or !pathInRange(context, source_name, "", copy_index + 1, statement_end) or
            !nameInRange(context, amount_name, copy_index + 1, statement_end)) continue;
        return copy_index;
    }
    return null;
}

fn hasExplicitCapacityFailure(context: RuleRun, source_name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_if) continue;
        const statement_end = @min(context.statementEnd(index) orelse end, end);
        if (pathInRange(context, source_name, "len", index + 1, statement_end) and
            (tagInRange(context, .keyword_return, index + 1, statement_end) or tagInRange(context, .keyword_unreachable, index + 1, statement_end))) return true;
    }
    return false;
}

fn builtinInRange(context: RuleRun, name: []const u8, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .builtin and context.tokenIs(index, name)) return index;
    }
    return null;
}

fn pathInRange(context: RuleRun, base: []const u8, field: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, base)) continue;
        if (field.len == 0) return true;
        if (index + 2 < end and context.tokens[index + 1].tag == .period and context.tokenIs(index + 2, field)) return true;
    }
    return false;
}

fn nameInRange(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

fn tagInRange(context: RuleRun, tag: std.zig.Token.Tag, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| if (token.tag == tag) return true;
    return false;
}

test "fixed-buffer writes cannot silently truncate input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn write(self: *Writer, bytes: []const u8) void { " ++
        "const amount = @min(bytes.len, self.storage.len - self.used); " ++
        "@memcpy(self.storage[self.used..][0..amount], bytes[0..amount]); self.used += amount; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.silent_buffer_truncation, findings[0].rule);
}

test "returning the written byte count makes truncation visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn write(self: *Writer, bytes: []const u8) usize { " ++
        "const amount = @min(bytes.len, self.storage.len - self.used); " ++
        "@memcpy(self.storage[self.used..][0..amount], bytes[0..amount]); return amount; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "fixed C buffers reserve space before terminating truncated text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn setTitle(self: *Message, title: []const u8) void { " ++
        "const length = @min(title.len, self.title.len - 1); " ++
        "@memcpy(self.title[0..length], title[0..length]); self.title[length] = 0; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "terminating at the full buffer length does not make truncation safe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn setTitle(self: *Message, title: []const u8) void { " ++
        "const length = @min(title.len, self.title.len); " ++
        "@memcpy(self.title[0..length], title[0..length]); self.title[length] = 0; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "shortening the source does not reserve destination capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn setTitle(self: *Message, title: []const u8) void { " ++
        "const length = @min(title.len - 1, self.title.len); " ++
        "@memcpy(self.title[0..length], title[0..length]); self.title[length] = 0; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = allocator, .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
