const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;

pub fn run(context: RuleRun) !void {
    const level = context.level(.returning_local_slice);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            !insideFunctionOrTestBody(context.tokens, declaration_index)) continue;
        // A 'comptime var' array is interned into the binary; slices of it are
        // valid after the function returns.
        if (declaration_index > 0 and context.tokens[declaration_index - 1].tag == .keyword_comptime) continue;
        // A function with only comptime parameters is evaluated from values
        // known during compilation, so its local result storage is promoted.
        if (enclosingFunctionHasOnlyComptimeParameters(context, declaration_index)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!declarationStoresArray(context, declaration_index, declaration_end)) continue;
        const declaration_scope = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(declaration_scope, .l_brace, .r_brace) orelse continue;
        const binding_index = declaration_index + 1;
        const binding_name = context.tokenText(binding_index);

        var return_index = declaration_end + 1;
        while (return_index + 3 < scope_end) : (return_index += 1) {
            if (context.tokens[return_index].tag != .keyword_return or
                context.enclosingOpeningBrace(return_index) != declaration_scope or
                !context.tokenIs(return_index + 1, binding_name) or
                context.tokens[return_index + 2].tag != .l_bracket) continue;
            const slice_end = context.matchingToken(return_index + 2, .l_bracket, .r_bracket) orelse continue;
            if (slice_end >= scope_end or !containsRange(context.tokens, return_index + 3, slice_end)) continue;
            if (slice_end + 1 < scope_end and context.tokens[slice_end + 1].tag == .period_asterisk) continue;
            try context.emit(.{
                .rule = .returning_local_slice,
                .level = level,
                .span = context.tokens[return_index + 1].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "returned slice '{s}' refers to a local array whose storage expires when this function returns",
                    .{binding_name},
                ),
            });
        }
    }
}

fn enclosingFunctionHasOnlyComptimeParameters(context: RuleRun, declaration_index: usize) bool {
    const body_opening = context.enclosingOpeningBrace(declaration_index) orelse return false;
    var function_index = body_opening;
    while (function_index > 0) {
        function_index -= 1;
        switch (context.tokens[function_index].tag) {
            .keyword_fn => break,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    } else return false;

    var parameters_opening = function_index + 1;
    while (parameters_opening < body_opening and context.tokens[parameters_opening].tag != .l_paren) : (parameters_opening += 1) {}
    if (parameters_opening == body_opening) return false;
    const parameters_closing = context.matchingToken(parameters_opening, .l_paren, .r_paren) orelse return false;
    if (parameters_closing == parameters_opening + 1) return false;

    var saw_parameter = false;
    var segment_has_comptime = false;
    var nested: usize = 0;
    for (context.tokens[parameters_opening + 1 .. parameters_closing]) |token| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => nested += 1,
            .r_paren, .r_bracket, .r_brace => nested -|= 1,
            .keyword_comptime => {
                if (nested == 0) segment_has_comptime = true;
            },
            .comma => if (nested == 0) {
                if (!segment_has_comptime) return false;
                saw_parameter = true;
                segment_has_comptime = false;
            },
            else => {},
        }
    }
    if (!segment_has_comptime) return false;
    return saw_parameter or segment_has_comptime;
}

fn declarationStoresArray(context: RuleRun, declaration_index: usize, declaration_end: usize) bool {
    var index = declaration_index + 2;
    while (index < declaration_end) : (index += 1) {
        if (context.tokens[index].tag == .colon and index + 2 < declaration_end and
            context.tokens[index + 1].tag == .l_bracket and arrayLengthToken(context.tokens[index + 2].tag)) return true;
        if (context.tokens[index].tag == .equal and index + 2 < declaration_end and
            context.tokens[index + 1].tag == .l_bracket and arrayLengthToken(context.tokens[index + 2].tag)) return true;
    }
    return false;
}

fn arrayLengthToken(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .number_literal, .identifier => true,
        else => false,
    };
}

fn containsRange(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| if (token.tag == .ellipsis2) return true;
    return false;
}

fn insideFunctionOrTestBody(tokens: []const std.zig.Token, declaration_index: usize) bool {
    var nested_closing_braces: usize = 0;
    var cursor = declaration_index;
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
                        .keyword_fn, .keyword_test => return true,
                        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return false,
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

test "returning a slice of a local array expires its storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn bytes() []u8 { var local = [_]u8{ 1, 2 }; return local[0..]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    var configuration = @import("types.zig").Configuration.defaults();
    const context: RuleRun = .{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    };
    try run(context);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);

    configuration.levels[@intFromEnum(@import("types.zig").Rule.returning_local_slice)] = .off;
    var disabled: std.ArrayList(@import("types.zig").Finding) = .empty;
    var disabled_context = context;
    disabled_context.configuration = configuration;
    disabled_context.findings = &disabled;
    try run(disabled_context);
    try std.testing.expectEqual(@as(usize, 0), disabled.items.len);
}

test "dereferencing the slice returns the array by value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn digest() [4]u8 { var buf = [_]u8{ 1, 2, 3, 4 }; return buf[0..4].*; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "comptime var arrays are interned and outlive the function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn snake(comptime input: []const u8) []const u8 { comptime var output: [input.len * 2]u8 = undefined; return output[0..1]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "functions with only comptime parameters return promoted local slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn description(comptime input: []const u8) []const u8 { var output: [input.len]u8 = undefined; return output[0..1]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a runtime parameter keeps local slice storage temporary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn bytes(comptime size: usize, fill: u8) []const u8 { var output: [size]u8 = undefined; output[0] = fill; return output[0..1]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
}

test "heap-backed slices and local array values do not warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn heap(allocator: std.mem.Allocator) ![]u8 { var bytes: []u8 = try allocator.alloc(u8, 2); return bytes; }\n" ++
        "fn value() [2]u8 { var local = [_]u8{ 1, 2 }; return local; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
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
